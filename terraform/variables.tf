variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "instance_type" {
  description = "EC2 free-tier type"
  type        = string
  default     = "t2.micro"
}

variable "prefix" {
  description = "Resource prefix"
  type        = string
  default     = "auto-jenkins"
}

variable "key_private_path" {
  description = "Path to save private key"
  type        = string
  default     = "./ssh/ansible_key.pem"
}

variable "jenkins_admin_user" {
  type    = string
  default = "admin"
}

variable "jenkins_admin_password" {
  type    = string
  default = "ChangeMe123!"
}

variable "root_password" {
  type    = string
  default = "Root@123"
}

variable "devops_password" {
  type    = string
  default = "Devops@123"
}
