variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "ap-south-1"
}

variable "instance_type" {
  description = "EC2 instance type (free tier safe)"
  type        = string
  default     = "t2.micro"
}

variable "prefix" {
  description = "Resource name prefix"
  type        = string
  default     = "auto-jenkins"
}

variable "key_private_path" {
  description = "Where to write the generated private key locally"
  type        = string
  default     = "./ssh/ansible_key.pem"
}

variable "jenkins_admin_user" {
  description = "Initial Jenkins admin username created by init script"
  type        = string
  default     = "admin"
}

variable "jenkins_admin_password" {
  description = "Initial Jenkins admin password (change after first login)"
  type        = string
  default     = "ChangeMe123!"
}

# WARNING: These passwords will be placed in cloud-init. Change before apply if you want.
variable "root_password" {
  description = "Root password to set on instances (lab use only)"
  type        = string
  default     = "Root@123"
}

variable "devops_password" {
  description = "Password to set for devops user (lab use only)"
  type        = string
  default     = "Devops@123"
}
