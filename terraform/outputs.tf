output "private_key_path" {
  value = local_file.private_key.filename
}

output "control_public_ip" {
  value = aws_instance.control.public_ip
}

output "jenkins_master_public_ip" {
  value = aws_instance.master.public_ip
}

output "jenkins_worker_public_ip" {
  value = aws_instance.worker.public_ip
}
