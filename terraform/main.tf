terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
  backend "local" {}
}

provider "aws" {
  region = var.aws_region
}

# ---- generate ssh keypair, register with AWS, save private locally ----
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
  devops_public_key = tls_private_key.ansible_key.public_key_openssh
  jenkins_admin_user = var.jenkins_admin_user
  jenkins_admin_pass = var.jenkins_admin_password

  # Jenkins init Groovy script (runs on first Jenkins boot)
  jenkins_init_groovy = <<-EOT
    import jenkins.model.*
    import hudson.security.*
    import hudson.model.*
    import com.cloudbees.plugins.credentials.*
    import com.cloudbees.plugins.credentials.domains.*
    import com.cloudbees.plugins.credentials.impl.*
    import com.cloudbees.plugins.credentials.impl.BasicSSHUserPrivateKey.*
    import org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl
    import com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl
    import hudson.plugins.sshslaves.*;

    def instance = Jenkins.getInstance()

    // Create admin user if not exists
    def hudsonRealm = new HudsonPrivateSecurityRealm(false)
    hudsonRealm.createAccount("${local.jenkins_admin_user}", "${local.jenkins_admin_pass}")
    instance.setSecurityRealm(hudsonRealm)
    def strategy = new FullControlOnceLoggedInAuthorizationStrategy()
    instance.setAuthorizationStrategy(strategy)
    instance.save()

    // Create an SSH private key credential that uses the 'devops' key
    def creds = com.cloudbees.plugins.credentials.SystemCredentialsProvider.getInstance().getStore()
    def domain = Domain.global()
    // Key content will be replaced by file content injection in cloud-init (we will create the file /var/lib/jenkins/devops_id_rsa)
    def privateKey = new BasicSSHUserPrivateKey.SourceFromString("${local.devops_public_key}") // placeholder: jenkins will not accept pubkey here but we will add private key file later via cloud-init
    // NOTE: The previous line is kept as placeholder; in our cloud-init we will create a proper private key file and then create credentials via another method.
    // This script will ensure admin exists; further credential/node creation will be done by cloud-init helper script below
    println("Init groovy executed: admin created.")
  EOT
}

# ---- Networking ----
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

# ---- SG ----
resource "aws_security_group" "nodes_sg" {
  name        = "${var.prefix}-sg"
  description = "Allow SSH and Jenkins (8080) and JNLP (50000) limited"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # RECOMMEND: restrict to your IP
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

  tags = { Name = "${var.prefix}-sg" }
}

# ---- AMI ----
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# ---- Cloud-init snippets ----
# Common hardening: UFW, fail2ban, sshd hardening, create devops user
locals {
  base_userdata = <<-EOT
    #!/bin/bash
    set -e
    # update and common tools
    apt-get update -y
    apt-get upgrade -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget git python3 python3-pip software-properties-common apt-transport-https ca-certificates ufw fail2ban

    # Create devops user, setup ssh
    useradd -m -s /bin/bash devops
    mkdir -p /home/devops/.ssh
    echo "${local.devops_public_key}" > /home/devops/.ssh/authorized_keys
    chown -R devops:devops /home/devops/.ssh
    chmod 700 /home/devops/.ssh
    chmod 600 /home/devops/.ssh/authorized_keys
    usermod -aG sudo devops

    # SSH hardening
    sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config || true
    sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config || true
    # ensure devops allowed only
    echo "AllowUsers devops" >> /etc/ssh/sshd_config || true
    systemctl reload sshd || true

    # UFW basic rules (block by default, allow ssh)
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp
    # allow intra-vpc (10.0.0.0/16)
    ufw allow from 10.0.0.0/16
    ufw --force enable

    # fail2ban - basic config for ssh
    cat > /etc/fail2ban/jail.local <<'JAIL'
    [sshd]
    enabled = true
    port = ssh
    filter = sshd
    logpath = /var/log/auth.log
    maxretry = 5
    bantime = 3600
    JAIL

    systemctl enable --now fail2ban

  EOT

  control_userdata = <<-EOT
    ${local.base_userdata}
    # Install Ansible and sshpass (for quick ad-hoc tasks if needed)
    apt-get install -y ansible sshpass
    # Prepare .ssh for devops and put private key placeholder (we will SCP it from local workstation)
    mkdir -p /home/devops/.ssh
    chown -R devops:devops /home/devops/.ssh
  EOT

  # Jenkins init scripts and helper script created by cloud-init; note: we will create a file /var/lib/jenkins/devops_id_rsa with the private key content
  jenkins_master_userdata = <<-EOT
    ${local.base_userdata}
    apt-get install -y openjdk-11-jdk gnupg
    curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key | tee /usr/share/keyrings/jenkins-keyring.asc > /dev/null
    echo deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/ > /etc/apt/sources.list.d/jenkins.list
    apt-get update -y
    apt-get install -y jenkins

    # Create a helper directory for init scripts
    mkdir -p /var/lib/jenkins/init.groovy.d
    chown -R jenkins:jenkins /var/lib/jenkins

    # Place admin creation Groovy (the script will create admin user)
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

    # Add a small helper script that will wait for jenkins and then create SSH credentials and a node using the devops private key
    cat > /usr/local/bin/jenkins-bootstrap.sh <<'BOOT'
    #!/bin/bash
    # wait for jenkins
    set -e
    for i in {1..60}; do
      if curl -sSf http://localhost:8080/login >/dev/null 2>&1; then
        break
      fi
      sleep 5
    done

    ADMIN_USER="${local.jenkins_admin_user}"
    ADMIN_PASS="${local.jenkins_admin_pass}"
    WORKER_IP_FILE="/var/lib/jenkins/worker_ip"
    PRIV_KEY_FILE="/var/lib/jenkins/devops_id_rsa"

    # Jenkins CLI requires the war or CLI jar; download CLI
    JENKINS_CLI_JAR=/tmp/jenkins-cli.jar
    wget -q -O \$JENKINS_CLI_JAR http://localhost:8080/jnlpJars/jenkins-cli.jar

    # create credentials if private key exists
    if [ -f "\$PRIV_KEY_FILE" ] && [ -f "\$JENKINS_CLI_JAR" ]; then
      # the script uses groovy via CLI to create credentials and node
      groovy_script=/tmp/create-creds-node.groovy
      cat > \$groovy_script <<'GROOVY'
      import jenkins.model.*
      import hudson.model.*
      import com.cloudbees.plugins.credentials.*
      import com.cloudbees.plugins.credentials.domains.*
      import com.cloudbees.jenkins.plugins.sshcredentials.impl.*
      import com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl
      import jenkins.model.Jenkins
      import hudson.slaves.*
      import org.jenkinsci.plugins.workflow.job.WorkflowJob
      import java.nio.file.Files
      def instance = Jenkins.getInstance()
      // read private key file on disk (on master) - using a path is easier than embedding here
      def priv = new File('/var/lib/jenkins/devops_id_rsa').text
      // create ssh credentials
      def credentialsStore = com.cloudbees.plugins.credentials.SystemCredentialsProvider.getInstance().getStore()
      def domain = Domain.global()
      def creds = new BasicSSHUserPrivateKey(
          CredentialsScope.GLOBAL,
          'devops-ssh-cred',
          'devops',
          new BasicSSHUserPrivateKey.DirectEntryPrivateKeySource(priv),
          '',
          'Devops SSH key'
      )
      credentialsStore.addCredentials(domain, creds)

      // create a node if worker ip exists
      def ipFile = new File('/var/lib/jenkins/worker_ip')
      if (ipFile.exists()) {
         def ip = ipFile.text.trim()
         def nodeName = 'jenkins-worker'
         def remoteFS = '/home/devops'
         def launcher = new hudson.plugins.sshslaves.SSHLauncher(ip, 22, 'devops-ssh-cred')
         def node = new DumbSlave(nodeName, "Auto-created SSH worker", remoteFS, "1", hudson.model.Node.Mode.NORMAL, "devops", launcher, new RetentionStrategy.Always(), Collections.emptyList())
         instance.addNode(node)
      }
      instance.save()
      GROOVY

      java -jar \$JENKINS_CLI_JAR -s http://localhost:8080/ -auth ${local.jenkins_admin_user}:${local.jenkins_admin_pass} groovy = < \$groovy_script || true
    fi
    BOOT

    chmod +x /usr/local/bin/jenkins-bootstrap.sh
    chown root:root /usr/local/bin/jenkins-bootstrap.sh

    # systemd service to run the bootstrap after jenkins starts
    cat > /etc/systemd/system/jenkins-bootstrap.service <<'SERV'
    [Unit]
    Description=Jenkins bootstrap (create creds & node)
    After=jenkins.service
    Requires=jenkins.service

    [Service]
    Type=oneshot
    ExecStart=/usr/local/bin/jenkins-bootstrap.sh

    [Install]
    WantedBy=multi-user.target
    SERV

    systemctl daemon-reload
    systemctl enable --now jenkins-bootstrap.service || true

    systemctl enable --now jenkins
  EOT

  # worker: install java & docker, prepare jenkins user
  jenkins_worker_userdata = <<-EOT
    ${local.base_userdata}
    apt-get install -y openjdk-11-jdk
    # install docker
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    usermod -aG docker devops
  EOT
}

# ---- Instances ----
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
