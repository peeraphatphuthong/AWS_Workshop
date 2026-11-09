output "identifier" {
  value = aws_db_instance.mysql.identifier
}

output "arn" {
  value = aws_db_instance.mysql.arn
}

output "address" {
  description = "Private DNS name of the MySQL instance (resolvable only inside the VPC)."
  value       = aws_db_instance.mysql.address
}

output "master_secret_arn" {
  description = "RDS-managed master user secret."
  value       = aws_db_instance.mysql.master_user_secret[0].secret_arn
}

output "app_secret_arn" {
  description = "Application user secret. Available only once the secret has a value."
  value       = aws_secretsmanager_secret.db_app.arn
  # Consumers (the web host's first boot) need the secret VALUE, not just the secret.
  depends_on = [aws_secretsmanager_secret_version.db_app]
}

output "app_secret_name" {
  value = aws_secretsmanager_secret.db_app.name
}
