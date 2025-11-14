output "private_key_path" {
  description = "Local private key path created by Terraform"
  value       = local_file.private_key_pem.filename
}

output "control_public_ip" {
  description = "Control node public IP"
  value       = aws_instance.control.public_ip
}

output "jenkins_master_public_ip" {
  description = "Jenkins master public IP"
  value       = aws_instance.jenkins_master.public_ip
}

output "jenkins_worker_public_ip" {
  description = "Jenkins worker public IP"
  value       = aws_instance.jenkins_worker.public_ip
}
