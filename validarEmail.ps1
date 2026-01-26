# Crear evento SQS de prueba
$testEvent = @"
{
  "Records": [
    {
      "messageId": "test-123",
      "receiptHandle": "test-handle",
      "body": "{\"UserId\":1,\"OrderId\":1,\"EmailTo\":\"test@example.com\",\"Subject\":\"Test Subject\",\"Body\":\"Test Body\",\"Template\":\"Test\"}",
      "attributes": {
        "ApproximateReceiveCount": "1",
        "SentTimestamp": "1609459200000",
        "SenderId": "test",
        "ApproximateFirstReceiveTimestamp": "1609459200000"
      },
      "messageAttributes": {},
      "md5OfBody": "test",
      "eventSource": "aws:sqs",
      "eventSourceARN": "arn:aws:sqs:us-east-1:000000000000:email-notifications-queue",
      "awsRegion": "us-east-1"
    }
  ]
}
"@

# Guardar en archivo
$testEvent | Out-File -FilePath "./test-sqs-event.json" -Encoding UTF8

# Copiar al contenedor
docker cp ./test-sqs-event.json localstack-aws:/tmp/test-sqs-event.json

# Invocar Lambda manualmente
docker exec localstack-aws awslocal lambda invoke `
    --function-name EmailBatchProcessorFunction `
    --payload file:///tmp/test-sqs-event.json `
    /tmp/response.json

# Ver respuesta
docker exec localstack-aws cat /tmp/response.json

# Limpiar
Remove-Item ./test-sqs-event.json