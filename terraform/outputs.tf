output "private_key_path" {
  description = "Private key saved locally"
  value       = local_file.private_key_pem.filename
}

output "control_public_ip" {
  value = aws_instance.control.public_ip
}

output "jenkins_master_public_ip" {
  value = aws_instance.jenkins_master.public_ip
}

output "jenkins_worker_public_ip" {
  value = aws_instance.jenkins_worker.public_ip
}
