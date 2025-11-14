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
# SSH Key Generation
# -----------------------------------------------------
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

  root_pass  = var.root_password
  devops_pass = var.devops_password
}

# -----------------------------------------------------
# Networking (VPC/Subnet/IGW/RT)
# -----------------------------------------------------
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
  availability_zone       = element(data.aws_availability_zones.available.names, 0)
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

# -----------------------------------------------------
# Security Group (SSH & Jenkins 8080)
# -----------------------------------------------------
resource "aws_security_group" "nodes_sg" {
  name        = "${var.prefix}-sg"
  description = "Allow SSH and Jenkins UI; JNLP limited to VPC"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Consider restricting to your IP
  }

  ingress {
    description = "Jenkins UI"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "JNLP (agent) inside VPC"
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

# -----------------------------------------------------
# AMI
# -----------------------------------------------------
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# -----------------------------------------------------
# Cloud-init / user_data templates
# - NO UFW
# - NO fail2ban
# - SSH config allows PasswordAuthentication and PermitRootLogin
# - set root and devops passwords
# -----------------------------------------------------

locals {
  base_userdata = <<-EOT
    #!/bin/bash
    set -ex
    export DEBIAN_FRONTEND=noninteractive

    apt-get update -y
    apt-get upgrade -y

    apt-get install -y curl wget git python3 python3-pip software-properties-common apt-transport-https ca-certificates

    # Create devops user if missing
    if ! id -u devops >/dev/null 2>&1; then
      useradd -m -s /bin/bash devops
    fi

    # Put public key for devops
    mkdir -p /home/devops/.ssh
    echo "${local.devops_public_key}" > /home/devops/.ssh/authorized_keys
    chmod 700 /home/devops/.ssh
    chmod 600 /home/devops/.ssh/authorized_keys
    chown -R devops:devops /home/devops/.ssh

    # Set devops password (so you can sudo or SSH with password)
    echo "devops:${local.devops_pass}" | chpasswd

    # Set root password
    echo "root:${local.root_pass}" | chpasswd

    # Adjust sshd_config: enable password auth and permit root login
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config || true
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config || true

    # Remove any AllowUsers lines (allow all)
    sed -i '/^AllowUsers/d' /etc/ssh/sshd_config || true

    systemctl reload sshd || true
  EOT

  control_userdata = <<-EOT
    ${local.base_userdata}

    # Install Ansible
    apt-get install -y ansible sshpass python3-apt

    # Write private key for ansible use (note: security risk for production)
    mkdir -p /home/devops/.ssh
    cat > /home/devops/.ssh/ansible_key.pem <<'KEY'
${local.devops_private_key}
KEY
    chmod 600 /home/devops/.ssh/ansible_key.pem
    chown devops:devops /home/devops/.ssh/ansible_key.pem

    # Prepare ansible workspace
    mkdir -p /home/devops/ansible
    chown devops:devops /home/devops/ansible

    # Generate inventory using private IPs (injected by Terraform)
    cat > /home/devops/ansible/inventory.ini <<'INV'
[jenkins_master]
${aws_instance.jenkins_master.private_ip} ansible_user=devops

[jenkins_worker]
${aws_instance.jenkins_worker.private_ip} ansible_user=devops

[all:vars]
ansible_ssh_private_key_file=/home/devops/.ssh/ansible_key.pem
INV
    chown devops:devops /home/devops/ansible/inventory.ini
    chmod 600 /home/devops/ansible/inventory.ini

    # Create Ansible playbook: install Java on worker; copy key+workerip to master; DOCKER installed only on worker
    cat > /home/devops/ansible/site.yml <<'PLAY'
---
- name: Configure Jenkins worker (Java + Docker)
  hosts: jenkins_worker
  become: yes
  tasks:
    - name: update apt cache
      apt:
        update_cache: yes
        cache_valid_time: 3600

    - name: install openjdk
      apt:
        name: openjdk-11-jdk
        state: present
        update_cache: yes

    - name: install docker using get.docker.com
      shell: |
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sh /tmp/get-docker.sh
      args:
        creates: /usr/bin/dockerd

    - name: add devops to docker group
      user:
        name: devops
        groups: docker
        append: yes

- name: Configure Jenkins master (place private key and worker ip to trigger bootstrap)
  hosts: jenkins_master
  become: yes
  tasks:
    - name: ensure /var/lib/jenkins exists
      file:
        path: /var/lib/jenkins
        state: directory
        owner: jenkins
        group: jenkins
        mode: '0755'

    - name: copy devops private key to master for jenkins bootstrap
      copy:
        src: /home/devops/.ssh/ansible_key.pem
        dest: /var/lib/jenkins/devops_id_rsa
        owner: jenkins
        group: jenkins
        mode: '0600'

    - name: write worker private IP for jenkins bootstrap
      copy:
        content: "{{ hostvars[groups['jenkins_worker'][0]]['ansible_host'] | default(hostvars[groups['jenkins_worker'][0]]['inventory_hostname']) | default('') }}"
        dest: /var/lib/jenkins/worker_ip
        owner: jenkins
        group: jenkins
        mode: '0644'
PLAY
    chown devops:devops /home/devops/ansible/site.yml
    chmod 644 /home/devops/ansible/site.yml

    # Run Ansible automatically
    su - devops -c "ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i /home/devops/ansible/inventory.ini /home/devops/ansible/site.yml" > /var/log/ansible-autorun.log 2>&1 || true
    touch /home/devops/ansible/.autorun_complete
  EOT

  # Jenkins master userdata: installs Jenkins + admin, plus bootstrap script that reads /var/lib/jenkins/devops_id_rsa and /var/lib/jenkins/worker_ip
  jenkins_master_userdata = <<-EOT
    ${local.base_userdata}

    apt-get install -y openjdk-11-jdk gnupg

    curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key | tee /usr/share/keyrings/jenkins-keyring.asc > /dev/null
    echo deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/ > /etc/apt/sources.list.d/jenkins.list
    apt-get update -y
    apt-get install -y jenkins

    mkdir -p /var/lib/jenkins/init.groovy.d
    chown -R jenkins:jenkins /var/lib/jenkins

    # create admin user
    cat > /var/lib/jenkins/init.groovy.d/00_create_admin.groovy <<'GROOVY'
    import jenkins.model.*
    import hudson.security.*
    def instance = Jenkins.getInstance()
    def hudsonRealm = new HudsonPrivateSecurityRealm(false)
    hudsonRealm.createAccount("${local.jenkins_admin_user}", "${local.jenkins_admin_pass}")
    instance.setSecurityRealm(hudsonRealm)
    def strategy = new FullControlOnceLoggedInAuthorizationStrategy()
    instance.setAuthorizationStrategy(strategy)
    instance.save()
    GROOVY

    chown jenkins:jenkins /var/lib/jenkins/init.groovy.d/00_create_admin.groovy
    chmod 644 /var/lib/jenkins/init.groovy.d/00_create_admin.groovy

    # bootstrap helper script - create credentials & node when /var/lib/jenkins/devops_id_rsa and /var/lib/jenkins/worker_ip exist
    cat > /usr/local/bin/jenkins-bootstrap.sh <<'BOOT'
    #!/bin/bash
    set -e
    for i in {1..60}; do
      if curl -sSf http://localhost:8080/login >/dev/null 2>&1; then break; fi
      sleep 5
    done

    CLI=/tmp/jenkins-cli.jar
    wget -q -O $CLI http://localhost:8080/jnlpJars/jenkins-cli.jar || true

    PRIV="/var/lib/jenkins/devops_id_rsa"
    WORKER="/var/lib/jenkins/worker_ip"

    if [[ ! -f "$PRIV" || ! -f "$WORKER" ]]; then
      echo "bootstrap: missing files; exiting"
      exit 0
    fi

    cat > /tmp/create_creds_node.groovy <<'GROOVY'
    import jenkins.model.*
    import com.cloudbees.plugins.credentials.*
    import com.cloudbees.plugins.credentials.domains.*
    import com.cloudbees.jenkins.plugins.sshcredentials.impl.*
    import hudson.slaves.*
    def instance = Jenkins.getInstance()
    def priv = new File('/var/lib/jenkins/devops_id_rsa').text
    def store = SystemCredentialsProvider.getInstance().getStore()
    def domain = Domain.global()
    def creds = new BasicSSHUserPrivateKey(CredentialsScope.GLOBAL, 'devops-ssh-cred', 'devops', new BasicSSHUserPrivateKey.DirectEntryPrivateKeySource(priv), '', 'Devops key')
    store.addCredentials(domain, creds)
    def ip = new File('/var/lib/jenkins/worker_ip').text.trim()
    if (ip) {
      def launcher = new hudson.plugins.sshslaves.SSHLauncher(ip, 22, 'devops-ssh-cred')
      def node = new DumbSlave('jenkins-worker', 'Auto worker', '/home/devops', '1', Node.Mode.NORMAL, 'devops', launcher, new RetentionStrategy.Always(), [])
      instance.addNode(node)
    }
    instance.save()
    GROOVY

    java -jar $CLI -s http://localhost:8080/ -auth ${local.jenkins_admin_user}:${local.jenkins_admin_pass} groovy = < /tmp/create_creds_node.groovy || true
    BOOT

    chmod +x /usr/local/bin/jenkins-bootstrap.sh

    cat > /etc/systemd/system/jenkins-bootstrap.service <<'SERV'
    [Unit]
    Description=Jenkins bootstrap to create credentials & node
    After=jenkins.service
    Wants=jenkins.service

    [Service]
    Type=oneshot
    ExecStart=/usr/local/bin/jenkins-bootstrap.sh

    [Install]
    WantedBy=multi-user.target
    SERV

    systemctl daemon-reload
    systemctl enable --now jenkins
    systemctl enable --now jenkins-bootstrap.service || true
  EOT

  # jenkins worker: install Java + Docker
  jenkins_worker_userdata = <<-EOT
    ${local.base_userdata}

    apt-get install -y openjdk-11-jdk

    # Install Docker on worker only
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh || true

    usermod -aG docker devops || true
  EOT
}

# -----------------------------------------------------
# EC2 Instances
# -----------------------------------------------------
resource "aws_instance" "jenkins_master" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.nodes_sg.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.ansible_key.key_name
  user_data                   = base64encode(local.jenkins_master_userdata)
  tags = { Name = "${var.prefix}-master" }
}

resource "aws_instance" "jenkins_worker" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.nodes_sg.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.ansible_key.key_name
  user_data                   = base64encode(local.jenkins_worker_userdata)
  tags = { Name = "${var.prefix}-worker" }
}

resource "aws_instance" "control" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.nodes_sg.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.ansible_key.key_name
  user_data                   = base64encode(local.control_userdata)
  tags = { Name = "${var.prefix}-control" }
}
