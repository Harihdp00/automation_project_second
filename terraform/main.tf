terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
    tls = { source = "hashicorp/tls", version = "~> 4.0" }
  }
  backend "local" {}
}

provider "aws" { region = var.aws_region }

# =====================================================================
# SSH Key Generation
# =====================================================================

resource "tls_private_key" "ansible_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_file" "private_key_pem" {
  content         = tls_private_key.ansible_key.private_key_pem
  filename        = var.key_private_path
  file_permission = "0600"
}

resource "aws_key_pair" "ansible_key" {
  key_name   = "${var.prefix}-key"
  public_key = tls_private_key.ansible_key.public_key_openssh
}

locals {
  devops_public_key  = tls_private_key.ansible_key.public_key_openssh
  devops_private_key = tls_private_key.ansible_key.private_key_pem

  jenkins_admin_user = var.jenkins_admin_user
  jenkins_admin_pass = var.jenkins_admin_password
}

# =====================================================================
# NETWORKING
# =====================================================================

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "${var.prefix}-vpc" }
}

data "aws_availability_zones" "available" {}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[0]
  tags = { Name = "${var.prefix}-public" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags = { Name = "${var.prefix}-igw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = { Name = "${var.prefix}-rt" }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# =====================================================================
# SECURITY GROUP
# =====================================================================

resource "aws_security_group" "nodes_sg" {
  name        = "${var.prefix}-sg"
  description = "Allow SSH and Jenkins"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Jenkins UI"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "JNLP port (internal)"
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

  tags = { Name = "${var.prefix}-sg" }
}

# =====================================================================
# AMI
# =====================================================================

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# =====================================================================
# CLOUD-INIT COMMON BASE (devops user + hardening)
# =====================================================================

locals {
  base_userdata = <<-EOT
    #!/bin/bash
    set -ex

    export DEBIAN_FRONTEND=noninteractive

    apt-get update -y
    apt-get upgrade -y

    apt-get install -y curl wget git python3 python3-pip ufw fail2ban \
      software-properties-common apt-transport-https ca-certificates

    # Create devops user
    useradd -m -s /bin/bash devops || true
    mkdir -p /home/devops/.ssh
    echo "${local.devops_public_key}" > /home/devops/.ssh/authorized_keys
    chmod 700 /home/devops/.ssh
    chmod 600 /home/devops/.ssh/authorized_keys
    chown -R devops:devops /home/devops/.ssh
    usermod -aG sudo devops

    # SSH hardening
    sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
    sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    echo "AllowUsers devops" >> /etc/ssh/sshd_config
    systemctl reload sshd

    # UFW
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp
    ufw allow from 10.0.0.0/16
    ufw --force enable

    # fail2ban
    cat > /etc/fail2ban/jail.local <<'EOF'
    [sshd]
    enabled = true
    port = ssh
    logpath = /var/log/auth.log
    bantime = 3600
    maxretry = 5
    EOF

    systemctl enable --now fail2ban
  EOT
}

# =====================================================================
# CONTROL NODE (ANSIBLE AUTO-RUN)
# =====================================================================

locals {
  control_userdata = <<-EOT
    ${local.base_userdata}

    # Install ansible
    apt-get install -y ansible sshpass python3-apt

    mkdir -p /home/devops/.ssh

    # Write private key for ansible use
    cat > /home/devops/.ssh/ansible_key.pem <<'KEY'
${local.devops_private_key}
KEY
    chmod 600 /home/devops/.ssh/ansible_key.pem
    chown devops:devops /home/devops/.ssh/ansible_key.pem

    mkdir -p /home/devops/ansible
    chown devops:devops /home/devops/ansible

    # Generate inventory
    cat > /home/devops/ansible/inventory.ini <<'INV'
[jenkins_master]
${aws_instance.jenkins_master.private_ip} ansible_user=devops

[jenkins_worker]
${aws_instance.jenkins_worker.private_ip} ansible_user=devops

[all:vars]
ansible_ssh_private_key_file=/home/devops/.ssh/ansible_key.pem
INV

    chown devops:devops /home/devops/ansible/inventory.ini

    # Playbook (NO DOCKER EXCEPT ON WORKER)
    cat > /home/devops/ansible/site.yml <<'PLAY'
---
# -----------------------------
# WORKER CONFIG (Java + Docker)
# -----------------------------
- name: Prepare Jenkins worker
  hosts: jenkins_worker
  become: yes
  tasks:
    - name: install Java
      apt:
        name: openjdk-11-jdk
        state: present
        update_cache: yes

    - name: install docker
      shell: |
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sh /tmp/get-docker.sh

    - name: add devops to docker group
      user:
        name: devops
        groups: docker
        append: yes

# -----------------------------
# MASTER CONFIG (SSH Credential)
# -----------------------------
- name: Prepare Jenkins master
  hosts: jenkins_master
  become: yes
  tasks:
    - name: create jenkins dir
      file:
        path: /var/lib/jenkins
        state: directory
        owner: jenkins
        group: jenkins

    - name: copy private key to master
      copy:
        src: /home/devops/.ssh/ansible_key.pem
        dest: /var/lib/jenkins/devops_id_rsa
        owner: jenkins
        group: jenkins
        mode: '0600'

    - name: write worker IP
      copy:
        content: "{{ hostvars[groups['jenkins_worker'][0]].ansible_host }}"
        dest: /var/lib/jenkins/worker_ip
        owner: jenkins
        group: jenkins
        mode: '0644'
PLAY

    chown devops:devops /home/devops/ansible/site.yml

    # Auto run ansible
    su - devops -c "ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i /home/devops/ansible/inventory.ini /home/devops/ansible/site.yml" \
      > /var/log/ansible-autorun.log 2>&1 || true
  EOT
}

# =====================================================================
# JENKINS MASTER CLOUD-INIT (Admin + Bootstrap)
# =====================================================================

locals {
  jenkins_master_userdata = <<-EOT
    ${local.base_userdata}

    apt-get install -y openjdk-11-jdk gnupg

    curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key \
      | tee /usr/share/keyrings/jenkins-keyring.asc > /dev/null

    echo deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] \
      https://pkg.jenkins.io/debian-stable binary/ \
      > /etc/apt/sources.list.d/jenkins.list

    apt-get update -y
    apt-get install -y jenkins

    mkdir -p /var/lib/jenkins/init.groovy.d

    # Create admin user
    cat > /var/lib/jenkins/init.groovy.d/00_admin.groovy <<'GROOVY'
    import jenkins.model.*
    import hudson.security.*
    def instance = Jenkins.getInstance()
    def realm = new HudsonPrivateSecurityRealm(false)
    realm.createAccount("${local.jenkins_admin_user}", "${local.jenkins_admin_pass}")
    instance.setSecurityRealm(realm)
    instance.setAuthorizationStrategy(new FullControlOnceLoggedInAuthorizationStrategy())
    instance.save()
    GROOVY

    chmod 644 /var/lib/jenkins/init.groovy.d/00_admin.groovy
    chown -R jenkins:jenkins /var/lib/jenkins

    # Jenkins bootstrap → create SSH credential + node
    cat > /usr/local/bin/jenkins-bootstrap.sh <<'BOOT'
    #!/bin/bash
    set -e

    for i in {1..60}; do
      if curl -sSf http://localhost:8080/login >/dev/null 2>&1; then break; fi
      sleep 5
    done

    CLI=/tmp/jenkins-cli.jar
    wget -q -O $CLI http://localhost:8080/jnlpJars/jenkins-cli.jar

    PRIV="/var/lib/jenkins/devops_id_rsa"
    WORKER="/var/lib/jenkins/worker_ip"

    if [[ ! -f "$PRIV" || ! -f "$WORKER" ]]; then exit 0; fi

    cat > /tmp/create.groovy <<'GROOVY'
    import jenkins.model.*
    import com.cloudbees.plugins.credentials.*
    import com.cloudbees.plugins.credentials.domains.*
    import com.cloudbees.jenkins.plugins.sshcredentials.impl.*
    import hudson.slaves.*
    def j = Jenkins.getInstance()
    def priv = new File('/var/lib/jenkins/devops_id_rsa').text
    def store = SystemCredentialsProvider.getInstance().getStore()
    def domain = Domain.global()

    def sshCred = new BasicSSHUserPrivateKey(
      CredentialsScope.GLOBAL,
      "devops-ssh-cred",
      "devops",
      new BasicSSHUserPrivateKey.DirectEntryPrivateKeySource(priv),
      "",
      "DevOps SSH Key"
    )

    store.addCredentials(domain, sshCred)

    def ip = new File('/var/lib/jenkins/worker_ip').text.trim()
    def launcher = new SSHLauncher(ip, 22, "devops-ssh-cred")
    def node = new DumbSlave("jenkins-worker", "Auto worker", "/home/devops", "1",
        Node.Mode.NORMAL, "devops", launcher, new RetentionStrategy.Always(), [])

    j.addNode(node)
    j.save()
    GROOVY

    java -jar $CLI -s http://localhost:8080/ \
      -auth ${local.jenkins_admin_user}:${local.jenkins_admin_pass} \
      groovy = < /tmp/create.groovy || true
    BOOT

    chmod +x /usr/local/bin/jenkins-bootstrap.sh

    cat > /etc/systemd/system/jenkins-bootstrap.service <<'SERV'
    [Unit]
    Description=Jenkins bootstrap (credentials + worker)
    After=jenkins.service

    [Service]
    Type=oneshot
    ExecStart=/usr/local/bin/jenkins-bootstrap.sh

    [Install]
    WantedBy=multi-user.target
    SERV

    systemctl daemon-reload
    systemctl enable --now jenkins
    systemctl enable --now jenkins-bootstrap.service
  EOT
}

# =====================================================================
# JENKINS WORKER CLOUD-INIT (Java + Docker)
# =====================================================================

locals {
  jenkins_worker_userdata = <<-EOT
    ${local.base_userdata}

    # Install Java
    apt-get install -y openjdk-11-jdk

    # Install Docker ONLY on worker
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh

    usermod -aG docker devops
  EOT
}

# =====================================================================
# INSTANCES
# =====================================================================

resource "aws_instance" "jenkins_master" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.nodes_sg.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.ansible_key.key_name
  user_data = base64encode(local.jenkins_master_userdata)
  tags = { Name = "${var.prefix}-master" }
}

resource "aws_instance" "jenkins_worker" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.nodes_sg.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.ansible_key.key_name
  user_data = base64encode(local.jenkins_worker_userdata)
  tags = { Name = "${var.prefix}-worker" }
}

resource "aws_instance" "control" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.nodes_sg.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.ansible_key.key_name
  user_data = base64encode(local.control_userdata)
  tags = { Name = "${var.prefix}-control" }
}
