Invoke-WebRequest -Uri "http://localhost:4566" -Method POST -Headers @{
    "X-Amz-Target" = "secretsmanager.GetSecretValue"
    "Content-Type"  = "application/x-amz-json-1.1"
} -Body '{"SecretId":"feature-flags/use_lambda_notifications"}'