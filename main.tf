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

  backend "local" {}  # explicitly local; no S3
}

provider "aws" {
  region = var.aws_region
}

# Generate an SSH keypair locally and register with AWS
resource "tls_private_key" "ansible_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_file" "private_key_pem" {
  content  = tls_private_key.ansible_key.private_key_pem
  filename = var.key_private_path
  file_permission = "0600"
}

resource "aws_key_pair" "ansible_key" {
  key_name   = "${var.prefix}-key"
  public_key = tls_private_key.ansible_key.public_key_openssh
}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags = { Name = "${var.prefix}-vpc" }
}

# single public subnet
resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone = data.aws_availability_zones.available.names[0]
  tags = { Name = "${var.prefix}-public-subnet" }
}

data "aws_availability_zones" "available" {}

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

resource "aws_route_table_association" "public_association" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Security group - allow:
# - SSH (22) from anywhere (recommend restricting to your IP)
# - HTTP-like for Jenkins UI (8080) from anywhere (change to restrict)
# - Jenkins agent JNLP (50000) from VPC (10.0.0.0/16)
resource "aws_security_group" "nodes_sg" {
  name        = "${var.prefix}-sg"
  description = "Allow SSH, Jenkins UI, agent port"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # RECOMMEND: replace with your IP CIDR
  }

  ingress {
    description = "Jenkins UI"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # you can restrict
  }

  ingress {
    description = "Jenkins agent port (JNLP) - allow inside VPC only"
    from_port   = 50000
    to_port     = 50000
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.prefix}-sg" }
}

# Find a recent Ubuntu 22.04 LTS AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# Shared cloud-init for base installs
locals {
  base_userdata = <<-EOT
    #!/bin/bash
    set -e
    apt-get update -y
    apt-get upgrade -y
    # common utilities
    apt-get install -y curl wget git python3 python3-pip apt-transport-https ca-certificates
  EOT

  control_userdata = <<-EOT
    ${local.base_userdata}
    # install ansible
    apt-get install -y software-properties-common
    add-apt-repository --yes --update ppa:ansible/ansible
    apt-get update -y
    apt-get install -y ansible sshpass
    # ensure /home/ubuntu/.ssh exists
    mkdir -p /home/ubuntu/.ssh
    chown ubuntu:ubuntu /home/ubuntu/.ssh
    chmod 700 /home/ubuntu/.ssh
  EOT

  jenkins_master_userdata = <<-EOT
    ${local.base_userdata}
    # install Java and Jenkins (APT repo)
    apt-get install -y openjdk-11-jdk gnupg
    curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key | tee /usr/share/keyrings/jenkins-keyring.asc > /dev/null
    echo deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/ > /etc/apt/sources.list.d/jenkins.list
    apt-get update -y
    apt-get install -y jenkins
    systemctl enable --now jenkins
  EOT

  jenkins_worker_userdata = <<-EOT
    ${local.base_userdata}
    # install Java for Jenkins agent compatibility
    apt-get install -y openjdk-11-jdk
    # create jenkins user to be used by master for SSH-based agents
    useradd -m -s /bin/bash jenkins
    mkdir -p /home/jenkins/.ssh
    chown -R jenkins:jenkins /home/jenkins/.ssh
    chmod 700 /home/jenkins/.ssh
  EOT
}

# Instances
resource "aws_instance" "control" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.nodes_sg.id]
  key_name                    = aws_key_pair.ansible_key.key_name
  associate_public_ip_address = true
  tags = { Name = "${var.prefix}-control" }

  user_data = base64encode(local.control_userdata)
}

resource "aws_instance" "jenkins_master" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.nodes_sg.id]
  key_name                    = aws_key_pair.ansible_key.key_name
  associate_public_ip_address = true
  tags = { Name = "${var.prefix}-master" }

  user_data = base64encode(local.jenkins_master_userdata)
}

resource "aws_instance" "jenkins_worker" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.nodes_sg.id]
  key_name                    = aws_key_pair.ansible_key.key_name
  associate_public_ip_address = true
  tags = { Name = "${var.prefix}-worker" }

  user_data = base64encode(local.jenkins_worker_userdata)
}
