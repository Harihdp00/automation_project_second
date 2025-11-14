terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
    tls = { source = "hashicorp/tls", version = "~> 4.0" }
  }
  backend "local" {}
}

provider "aws" {
  region = var.aws_region
}

# -----------------------------------------------------
# SSH KEY GENERATION
# -----------------------------------------------------
resource "tls_private_key" "ansible_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_file" "private_key" {
  content         = tls_private_key.ansible_key.private_key_pem
  filename        = var.key_private_path
  file_permission = "0600"
}

resource "aws_key_pair" "ansible" {
  key_name   = "${var.prefix}-key"
  public_key = tls_private_key.ansible_key.public_key_openssh
}

locals {
  pubkey        = tls_private_key.ansible_key.public_key_openssh
  privkey       = tls_private_key.ansible_key.private_key_pem
  j_user        = var.jenkins_admin_user
  j_pass        = var.jenkins_admin_password
  root_pass     = var.root_password
  devops_pass   = var.devops_password
}

# -----------------------------------------------------
# NETWORK (VPC + SUBNET)
# -----------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "${var.prefix}-vpc" }
}

data "aws_availability_zones" "az" {}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.az.names[0]
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table" "rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "rt_assoc" {
  route_table_id = aws_route_table.rt.id
  subnet_id      = aws_subnet.public.id
}

# -----------------------------------------------------
# SECURITY GROUP
# -----------------------------------------------------
resource "aws_security_group" "sg" {
  name   = "${var.prefix}-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 50000
    to_port     = 50000
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# -----------------------------------------------------
# AMI
# -----------------------------------------------------
data "aws_ami" "ubuntu" {
  owners      = ["099720109477"]
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# -----------------------------------------------------
# CLOUD-INIT (BASE — PASSWORD LOGIN + ROOT LOGIN)
# -----------------------------------------------------
locals {
  base = <<-EOF
    #!/bin/bash
    set -ex

    apt-get update -y
    apt-get upgrade -y
    apt-get install -y curl wget git python3 python3-pip

    # create devops user
    useradd -m -s /bin/bash devops || true
    mkdir -p /home/devops/.ssh
    echo "${local.pubkey}" > /home/devops/.ssh/authorized_keys
    chmod 600 /home/devops/.ssh/authorized_keys
    chown -R devops:devops /home/devops/.ssh

    echo "root:${local.root_pass}" | chpasswd
    echo "devops:${local.devops_pass}" | chpasswd

    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
    sed -i '/AllowUsers/d' /etc/ssh/sshd_config

    systemctl restart sshd
  EOF
}

# -----------------------------------------------------
# CONTROL NODE (ANSIBLE AUTO-RUN)
# -----------------------------------------------------
locals {
  control = <<-EOF
    ${local.base}

    apt-get install -y ansible sshpass python3-apt

    mkdir -p /home/devops/.ssh
    cat > /home/devops/.ssh/ansible_key.pem <<KEY
${local.privkey}
KEY
    chmod 600 /home/devops/.ssh/ansible_key.pem
    chown devops:devops /home/devops/.ssh/ansible_key.pem

    mkdir -p /home/devops/ansible
    cat > /home/devops/ansible/inventory.ini <<INV
[jenkins_master]
${aws_instance.master.private_ip} ansible_user=devops

[jenkins_worker]
${aws_instance.worker.private_ip} ansible_user=devops

[all:vars]
ansible_ssh_private_key_file=/home/devops/.ssh/ansible_key.pem
INV

    cat > /home/devops/ansible/site.yml <<PLAY
---
- name: Worker setup (Java17 + Docker)
  hosts: jenkins_worker
  become: yes
  tasks:
    - name: install java17
      apt:
        name: openjdk-17-jdk
        state: present
        update_cache: true

    - name: set java17 default
      alternatives:
        name: java
        path: /usr/lib/jvm/java-17-openjdk-amd64/bin/java

    - name: install docker
      shell: |
        curl -fsSL https://get.docker.com -o /tmp/get.sh
        sh /tmp/get.sh
      args:
        executable: /bin/bash

    - user:
        name: devops
        groups: docker
        append: yes

- name: Jenkins master prepare
  hosts: jenkins_master
  become: yes
  tasks:
    - copy:
        src: /home/devops/.ssh/ansible_key.pem
        dest: /var/lib/jenkins/devops_key
        owner: jenkins
        group: jenkins
        mode: '0600'

    - copy:
        content: "{{ hostvars[groups['jenkins_worker'][0]]['ansible_host'] }}"
        dest: /var/lib/jenkins/worker_ip
        owner: jenkins
        group: jenkins
        mode: '0644'
PLAY

    su - devops -c "ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i /home/devops/ansible/inventory.ini /home/devops/ansible/site.yml"
  EOF
}

# -----------------------------------------------------
# JENKINS MASTER (JAVA17 + AUTO CONFIG)
# -----------------------------------------------------
locals {
  master = <<-EOF
    ${local.base}

    apt-get install -y openjdk-17-jdk gnupg
    update-alternatives --set java /usr/lib/jvm/java-17-openjdk-amd64/bin/java || true

    curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key | tee /usr/share/keyrings/jenkins.asc >/dev/null
    echo deb [signed-by=/usr/share/keyrings/jenkins.asc] https://pkg.jenkins.io/debian-stable binary/ > /etc/apt/sources.list.d/jenkins.list
    apt-get update -y
    apt-get install -y jenkins

    mkdir -p /var/lib/jenkins/init.groovy.d

    cat > /var/lib/jenkins/init.groovy.d/00_admin.groovy <<G
import jenkins.model.*
import hudson.security.*
def j = Jenkins.getInstance()
def r = new HudsonPrivateSecurityRealm(false)
r.createAccount("${local.j_user}", "${local.j_pass}")
j.setSecurityRealm(r)
j.setAuthorizationStrategy(new FullControlOnceLoggedInAuthorizationStrategy())
j.save()
G

    cat > /usr/local/bin/bootstrap.sh <<'BOOT'
#!/bin/bash
set -e
sleep 40
CLI=/tmp/cli.jar
wget -q -O $CLI http://localhost:8080/jnlpJars/jenkins-cli.jar || exit 0

priv=/var/lib/jenkins/devops_key
worker=/var/lib/jenkins/worker_ip
[[ -f "$priv" && -f "$worker" ]] || exit 0

cat > /tmp/node.groovy <<'GG'
import jenkins.model.*
import com.cloudbees.plugins.credentials.*
import com.cloudbees.jenkins.plugins.sshcredentials.impl.*
import com.cloudbees.plugins.credentials.domains.*
def j = Jenkins.getInstance()
def store = SystemCredentialsProvider.getInstance().getStore()
def key = new BasicSSHUserPrivateKey(
  CredentialsScope.GLOBAL,
  "devops-ssh",
  "devops",
  new BasicSSHUserPrivateKey.DirectEntryPrivateKeySource(new File("/var/lib/jenkins/devops_key").text),
  "",
  "auto key"
)
store.addCredentials(Domain.global(), key)

def ip = new File("/var/lib/jenkins/worker_ip").text.trim()
if (ip) {
  def launcher = new hudson.plugins.sshslaves.SSHLauncher(ip,22,"devops-ssh")
  def node = new DumbSlave("jenkins-worker","auto","/home/devops","1",Node.Mode.NORMAL,"devops",launcher,new RetentionStrategy.Always(),[])
  j.addNode(node)
}
j.save()
GG

java -jar $CLI -s http://localhost:8080 -auth ${local.j_user}:${local.j_pass} groovy = < /tmp/node.groovy
BOOT

    chmod +x /usr/local/bin/bootstrap.sh

    cat > /etc/systemd/system/bootstrap.service <<S
[Unit]
After=jenkins.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/bootstrap.sh
[Install]
WantedBy=multi-user.target
S

    systemctl daemon-reload
    systemctl enable --now jenkins
    systemctl enable --now bootstrap.service
  EOF
}

# -----------------------------------------------------
# WORKER USERDATA (JAVA 17 + DOCKER)
# -----------------------------------------------------
locals {
  worker = <<-EOF
    ${local.base}

    apt-get install -y openjdk-17-jdk
    update-alternatives --set java /usr/lib/jvm/java-17-openjdk-amd64/bin/java || true

    curl -fsSL https://get.docker.com -o /tmp/docker.sh
    sh /tmp/docker.sh
    usermod -aG docker devops
  EOF
}

# -----------------------------------------------------
# EC2 INSTANCES
# -----------------------------------------------------
resource "aws_instance" "master" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.sg.id]
  associate_public_ip_address = true
  key_name               = aws_key_pair.ansible.key_name
  user_data              = base64encode(local.master)
  tags = { Name = "${var.prefix}-master" }
}

resource "aws_instance" "worker" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.sg.id]
  associate_public_ip_address = true
  key_name               = aws_key_pair.ansible.key_name
  user_data              = base64encode(local.worker)
  tags = { Name = "${var.prefix}-worker" }
}

resource "aws_instance" "control" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.sg.id]
  associate_public_ip_address = true
  key_name               = aws_key_pair.ansible.key_name
  user_data              = base64encode(local.control)
  tags = { Name = "${var.prefix}-control" }
}
