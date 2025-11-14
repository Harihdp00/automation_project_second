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
