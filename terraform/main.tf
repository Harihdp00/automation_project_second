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
  devops_public_key = tls_private_key.ansible_key.public_key_openssh
}

# -----------------------------------------------------
# VPC + Networking
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

# -----------------------------------------------------
# Security Group
# -----------------------------------------------------

resource "aws_security_group" "nodes_sg" {
  name        = "${var.prefix}-sg"
  description = "Allow SSH and Jenkins"
  vpc_id      = aws_vpc.main.id

  # SSH
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Jenkins UI
  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Jenkins worker port (inside VPC)
  ingress {
    from_port   = 50000
    to_port     = 50000
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  # Allow all egress
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.prefix}-sg" }
}

# -----------------------------------------------------
# AMI Lookup
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
# Base User Data (devops user added)
# -----------------------------------------------------

locals {
  base_userdata = <<-EOT
    #!/bin/bash
    set -e

    apt-get update -y
    apt-get upgrade -y
    apt-get install -y curl wget git python3 python3-pip software-properties-common apt-transport-https ca-certificates

    # Create devops user
    useradd -m -s /bin/bash devops
    mkdir -p /home/devops/.ssh
    echo "${local.devops_public_key}" >> /home/devops/.ssh/authorized_keys
    chown -R devops:devops /home/devops/.ssh
    chmod 700 /home/devops/.ssh
    chmod 600 /home/devops/.ssh/authorized_keys
    usermod -aG sudo devops
  EOT

  control_userdata = <<-EOT
    ${local.base_userdata}
    apt-get install -y ansible sshpass
  EOT

  jenkins_master_userdata = <<-EOT
    ${local.base_userdata}
    apt-get install -y openjdk-11-jdk gnupg
    curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key | tee /usr/share/keyrings/jenkins.asc > /dev/null
    echo deb [signed-by=/usr/share/keyrings/jenkins.asc] https://pkg.jenkins.io/debian-stable binary/ > /etc/apt/sources.list.d/jenkins.list
    apt-get update -y
    apt-get install -y jenkins
    systemctl enable --now jenkins
  EOT

  jenkins_worker_userdata = <<-EOT
    ${local.base_userdata}
    apt-get install -y openjdk-11-jdk
  EOT
}

# -----------------------------------------------------
# EC2 Instances
# -----------------------------------------------------

resource "aws_instance" "control" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.nodes_sg.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.ansible_key.key_name

  user_data = base64encode(local.control_userdata)

  tags = {
    Name = "${var.prefix}-control"
  }
}

resource "aws_instance" "jenkins_master" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.nodes_sg.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.ansible_key.key_name

  user_data = base64encode(local.jenkins_master_userdata)

  tags = {
    Name = "${var.prefix}-master"
  }
}

resource "aws_instance" "jenkins_worker" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.nodes_sg.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.ansible_key.key_name

  user_data = base64encode(local.jenkins_worker_userdata)

  tags = {
    Name = "${var.prefix}-worker"
  }
}
