#Requires -Version 7

<#
.SYNOPSIS
    Prueba las 3 Lambda Functions desplegadas en LocalStack
.DESCRIPTION
    Script para verificar que ImageProcessor, Reports y EmailBatch funcionan correctamente
.PARAMETER Test
    Especifica qué Lambda probar: All, ImageProcessor, Reports, EmailBatch
.EXAMPLE
    .\Test-Lambdas.ps1 -Test All
    .\Test-Lambdas.ps1 -Test ImageProcessor
#>

param(
    [ValidateSet("All", "ImageProcessor", "Reports", "EmailBatch")]
    [string]$Test = "All"
)

$ErrorActionPreference = "Stop"

Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║          TESTING DE LAMBDAS SEMANA 1 EN LOCALSTACK            ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# Configuración
$LocalStackEndpoint = "http://localhost:4566"
$ContainerName = "localstack-aws"

# Verificar que LocalStack esté corriendo
Write-Host "`n🔍 Verificando LocalStack..." -ForegroundColor Yellow
try {
    $response = Invoke-WebRequest -Uri "$LocalStackEndpoint/_localstack/health" -UseBasicParsing
    Write-Host "✅ LocalStack está disponible" -ForegroundColor Green
} catch {
    Write-Host "❌ LocalStack no está disponible" -ForegroundColor Red
    exit 1
}

# Función para obtener logs de CloudWatch
function Get-LambdaLogs {
    param(
        [string]$FunctionName,
        [int]$Lines = 20
    )

    Write-Host "`n  📋 Últimos logs de CloudWatch:" -ForegroundColor Yellow
    
    $logGroupName = "/aws/lambda/$FunctionName"
    
    # Obtener streams
    $streams = docker exec $ContainerName awslocal logs describe-log-streams `
        --log-group-name $logGroupName `
        --order-by LastEventTime `
        --descending `
        --max-items 1 `
        --query 'logStreams[0].logStreamName' `
        --output text 2>&1

    if ($LASTEXITCODE -eq 0 -and $streams -and -not [string]::IsNullOrWhiteSpace($streams)) {
        $streamName = $streams.Trim()
        
        # Obtener logs
        $logs = docker exec $ContainerName awslocal logs get-log-events `
            --log-group-name $logGroupName `
            --log-stream-name $streamName `
            --limit $Lines `
            --query 'events[*].message' `
            --output text 2>&1

        if ($LASTEXITCODE -eq 0) {
            Write-Host $logs -ForegroundColor Gray
        } else {
            Write-Host "  ⚠️ No se pudieron obtener logs" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  ⚠️ No hay logs disponibles aún" -ForegroundColor Yellow
    }
}

# Función para esperar y verificar logs
function Wait-AndCheckLogs {
    param(
        [string]$FunctionName,
        [string]$ExpectedPattern,
        [int]$TimeoutSeconds = 30
    )

    Write-Host "  ⏳ Esperando ejecución (máx $TimeoutSeconds seg)..." -ForegroundColor Yellow
    
    $startTime = Get-Date
    $found = $false

    while (((Get-Date) - $startTime).TotalSeconds -lt $TimeoutSeconds) {
        Start-Sleep -Seconds 2

        $logGroupName = "/aws/lambda/$FunctionName"
        $streams = docker exec $ContainerName awslocal logs describe-log-streams `
            --log-group-name $logGroupName `
            --order-by LastEventTime `
            --descending `
            --max-items 1 `
            --query 'logStreams[0].logStreamName' `
            --output text 2>&1

        if ($LASTEXITCODE -eq 0 -and $streams) {
            $streamName = $streams.Trim()
            $logs = docker exec $ContainerName awslocal logs get-log-events `
                --log-group-name $logGroupName `
                --log-stream-name $streamName `
                --limit 50 `
                --query 'events[*].message' `
                --output text 2>&1

            if ($logs -and $logs -match $ExpectedPattern) {
                $found = $true
                break
            }
        }
    }

    return $found
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# TEST 1: IMAGEPROCESSOR LAMBDA
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

function Test-ImageProcessor {
    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "📸 TEST: ImageProcessor Lambda" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

    # Verificar que Lambda existe
    Write-Host "`n  🔍 Verificando Lambda..." -ForegroundColor Yellow
    $lambdaCheck = docker exec $ContainerName awslocal lambda get-function --function-name ImageProcessorFunction 2>&1
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ❌ Lambda no encontrada. Ejecuta Deploy-All-Lambdas.ps1 primero" -ForegroundColor Red
        return $false
    }
    Write-Host "  ✅ Lambda encontrada" -ForegroundColor Green

    # Crear imagen de prueba (1x1 pixel rojo en base64)
    Write-Host "`n  🎨 Creando imagen de prueba..." -ForegroundColor Yellow
    
    # JPG 1x1 pixel rojo en base64 (imagen válida mínima)
    $imageBase64 = "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAv/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAAAAX/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIRAxEAPwCwAA8A/9k="
    
    $imageBytes = [System.Convert]::FromBase64String($imageBase64)
    $testImagePath = "./test-image.jpg"
    [System.IO.File]::WriteAllBytes($testImagePath, $imageBytes)

    # Copiar imagen al contenedor
    docker cp $testImagePath ${ContainerName}:/tmp/test-image.jpg
    Remove-Item $testImagePath -Force

    # Subir a S3
    Write-Host "  📤 Subiendo imagen a S3 (bucket: product-images)..." -ForegroundColor Yellow
    $productId = Get-Random -Minimum 1000 -Maximum 9999
    $s3Key = "products/$productId/original.jpg"
    
    docker exec $ContainerName awslocal s3 cp /tmp/test-image.jpg s3://product-images/$s3Key

    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ❌ Error subiendo imagen a S3" -ForegroundColor Red
        return $false
    }
    Write-Host "  ✅ Imagen subida: s3://product-images/$s3Key" -ForegroundColor Green

    # Esperar procesamiento
    Write-Host "`n  ⏳ Esperando que Lambda procese la imagen (30 seg)..." -ForegroundColor Yellow
    Start-Sleep -Seconds 10

    # Verificar imágenes procesadas
    Write-Host "`n  🔍 Verificando imágenes procesadas..." -ForegroundColor Yellow
    $processedPrefix = "products/$productId/processed/"
    $processedFiles = docker exec $ContainerName awslocal s3 ls s3://product-images-processed/$processedPrefix 2>&1

    if ($LASTEXITCODE -eq 0 -and $processedFiles) {
        Write-Host "  ✅ Imágenes procesadas encontradas:" -ForegroundColor Green
        Write-Host $processedFiles -ForegroundColor Gray
    } else {
        Write-Host "  ⚠️ No se encontraron imágenes procesadas aún" -ForegroundColor Yellow
    }

    # Mostrar logs
    Get-LambdaLogs -FunctionName "ImageProcessorFunction" -Lines 30

    Write-Host "`n  ✅ TEST IMAGEPROCESSOR COMPLETADO" -ForegroundColor Green
    return $true
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# TEST 2: REPORTS LAMBDA
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

function Test-Reports {
    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "📊 TEST: Reports Lambda" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

    # Verificar que Lambda existe
    Write-Host "`n  🔍 Verificando Lambda..." -ForegroundColor Yellow
    $lambdaCheck = docker exec $ContainerName awslocal lambda get-function --function-name ReportsGeneratorFunction 2>&1
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ❌ Lambda no encontrada. Ejecuta Deploy-All-Lambdas.ps1 primero" -ForegroundColor Red
        return $false
    }
    Write-Host "  ✅ Lambda encontrada" -ForegroundColor Green

    # Obtener API Gateway ID
    Write-Host "`n  🔍 Buscando API Gateway..." -ForegroundColor Yellow
    $apiId = docker exec $ContainerName awslocal apigateway get-rest-apis --query "items[?name=='ReportsAPI'].id" --output text
    
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($apiId)) {
        Write-Host "  ❌ API Gateway no encontrado" -ForegroundColor Red
        return $false
    }

    $apiId = $apiId.Trim()
    $apiUrl = "http://localhost:4566/restapis/$apiId/prod/_user_request_/reports"
    Write-Host "  ✅ API encontrado: $apiId" -ForegroundColor Green
    Write-Host "  🌐 URL: $apiUrl" -ForegroundColor Cyan

    # Probar diferentes tipos de reportes
    $reportTypes = @("sales", "products", "orders")

    foreach ($type in $reportTypes) {
        Write-Host "`n  📊 Generando reporte tipo: $type" -ForegroundColor Yellow
        
        $startDate = (Get-Date).AddDays(-30).ToString("yyyy-MM-dd")
        $endDate = (Get-Date).ToString("yyyy-MM-dd")
        $fullUrl = "$apiUrl`?type=$type&startDate=$startDate&endDate=$endDate"

        try {
            Write-Host "  🌐 URL: $fullUrl" -ForegroundColor Gray
            
            $response = Invoke-WebRequest -Uri $fullUrl -Method GET -UseBasicParsing -ErrorAction Stop
            
            if ($response.StatusCode -eq 200) {
                $jsonResponse = $response.Content | ConvertFrom-Json
                
                Write-Host "  ✅ Reporte generado exitosamente" -ForegroundColor Green
                Write-Host "  📄 Tipo: $($jsonResponse.reportType)" -ForegroundColor Gray
                Write-Host "  📅 Generado: $($jsonResponse.generatedAt)" -ForegroundColor Gray
                Write-Host "  💾 Tamaño: $($jsonResponse.fileSize) bytes" -ForegroundColor Gray
                Write-Host "  🔗 URL de descarga: $($jsonResponse.downloadUrl)" -ForegroundColor Cyan
            } else {
                Write-Host "  ⚠️ Respuesta inesperada: $($response.StatusCode)" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "  ❌ Error: $($_.Exception.Message)" -ForegroundColor Red
        }

        Start-Sleep -Seconds 2
    }

    # Verificar PDFs generados en S3
    Write-Host "`n  🔍 Verificando PDFs en S3..." -ForegroundColor Yellow
    $reportsInS3 = docker exec $ContainerName awslocal s3 ls s3://reports-generated/reports/ --recursive 2>&1

    if ($LASTEXITCODE -eq 0 -and $reportsInS3) {
        Write-Host "  ✅ PDFs encontrados en S3:" -ForegroundColor Green
        Write-Host $reportsInS3 -ForegroundColor Gray
    } else {
        Write-Host "  ⚠️ No se encontraron PDFs en S3" -ForegroundColor Yellow
    }

    # Mostrar logs
    Get-LambdaLogs -FunctionName "ReportsGeneratorFunction" -Lines 30

    Write-Host "`n  ✅ TEST REPORTS COMPLETADO" -ForegroundColor Green
    return $true
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# TEST 3: EMAILBATCH LAMBDA
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

function Test-EmailBatch {
    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "📧 TEST: EmailBatch Lambda" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

    # Verificar que Lambda existe
    Write-Host "`n  🔍 Verificando Lambda..." -ForegroundColor Yellow
    $lambdaCheck = docker exec $ContainerName awslocal lambda get-function --function-name EmailBatchProcessorFunction 2>&1
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ❌ Lambda no encontrada. Ejecuta Deploy-All-Lambdas.ps1 primero" -ForegroundColor Red
        return $false
    }
    Write-Host "  ✅ Lambda encontrada" -ForegroundColor Green

    # Verificar cola SQS
    Write-Host "`n  🔍 Verificando cola SQS..." -ForegroundColor Yellow
    $queueUrl = "http://localhost:4566/000000000000/email-notifications-queue"
    
    # Enviar mensajes de prueba
    Write-Host "`n  📤 Enviando mensajes de prueba a SQS..." -ForegroundColor Yellow

    $testEmails = @(
        @{
            UserId = 1
            OrderId = 1001
            EmailTo = "cliente1@example.com"
            Subject = "Confirmación de Pedido #1001"
            Body = "Tu pedido ha sido confirmado y está siendo procesado."
            Template = "OrderConfirmation"
        },
        @{
            UserId = 2
            OrderId = 1002
            EmailTo = "cliente2@example.com"
            Subject = "Pedido Enviado #1002"
            Body = "Tu pedido ha sido enviado y llegará en 2-3 días."
            Template = "ShippingUpdate"
        },
        @{
            UserId = 3
            OrderId = 1003
            EmailTo = "cliente3@example.com"
            Subject = "Pago Confirmado #1003"
            Body = "Hemos recibido tu pago exitosamente."
            Template = "PaymentSuccess"
        }
    )

    $messagesSent = 0
    foreach ($email in $testEmails) {
        $messageBody = $email | ConvertTo-Json -Compress
        
        docker exec $ContainerName awslocal sqs send-message `
            --queue-url $queueUrl `
            --message-body $messageBody | Out-Null

        if ($LASTEXITCODE -eq 0) {
            $messagesSent++
            Write-Host "  ✅ Mensaje enviado: $($email.EmailTo)" -ForegroundColor Green
        } else {
            Write-Host "  ❌ Error enviando mensaje: $($email.EmailTo)" -ForegroundColor Red
        }
    }

    Write-Host "`n  📊 Total mensajes enviados: $messagesSent" -ForegroundColor Cyan

    # Esperar procesamiento
    Write-Host "`n  ⏳ Esperando procesamiento de Lambda (15 seg)..." -ForegroundColor Yellow
    Start-Sleep -Seconds 15

    # Verificar que la cola está vacía (mensajes procesados)
    Write-Host "`n  🔍 Verificando estado de la cola..." -ForegroundColor Yellow
    $queueAttrs = docker exec $ContainerName awslocal sqs get-queue-attributes `
        --queue-url $queueUrl `
        --attribute-names ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible `
        --output json | ConvertFrom-Json

    $msgsInQueue = [int]$queueAttrs.Attributes.ApproximateNumberOfMessages
    $msgsInFlight = [int]$queueAttrs.Attributes.ApproximateNumberOfMessagesNotVisible

    Write-Host "  📊 Mensajes en cola: $msgsInQueue" -ForegroundColor Gray
    Write-Host "  📊 Mensajes en procesamiento: $msgsInFlight" -ForegroundColor Gray

    if ($msgsInQueue -eq 0 -and $msgsInFlight -eq 0) {
        Write-Host "  ✅ Todos los mensajes procesados" -ForegroundColor Green
    } else {
        Write-Host "  ⚠️ Algunos mensajes aún en cola/procesamiento" -ForegroundColor Yellow
    }

    # Verificar DLQ
    Write-Host "`n  🔍 Verificando Dead Letter Queue..." -ForegroundColor Yellow
    $dlqUrl = "http://localhost:4566/000000000000/email-notifications-dlq"
    $dlqAttrs = docker exec $ContainerName awslocal sqs get-queue-attributes `
        --queue-url $dlqUrl `
        --attribute-names ApproximateNumberOfMessages `
        --output json 2>&1

    if ($LASTEXITCODE -eq 0) {
        $dlqResult = $dlqAttrs | ConvertFrom-Json
        $msgsInDLQ = [int]$dlqResult.Attributes.ApproximateNumberOfMessages
        
        if ($msgsInDLQ -eq 0) {
            Write-Host "  ✅ No hay mensajes en DLQ (todos procesados exitosamente)" -ForegroundColor Green
        } else {
            Write-Host "  ⚠️ Mensajes en DLQ: $msgsInDLQ (fallos de procesamiento)" -ForegroundColor Yellow
        }
    }

    # Mostrar logs
    Get-LambdaLogs -FunctionName "EmailBatchProcessorFunction" -Lines 40

    Write-Host "`n  ✅ TEST EMAILBATCH COMPLETADO" -ForegroundColor Green
    return $true
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# EJECUTAR TESTS
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

$results = @{}

if ($Test -eq "All" -or $Test -eq "ImageProcessor") {
    $results["ImageProcessor"] = Test-ImageProcessor
}

if ($Test -eq "All" -or $Test -eq "Reports") {
    $results["Reports"] = Test-Reports
}

if ($Test -eq "All" -or $Test -eq "EmailBatch") {
    $results["EmailBatch"] = Test-EmailBatch
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# RESUMEN FINAL
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Write-Host "`n╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║                    RESUMEN DE TESTS                            ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

$allPassed = $true
foreach ($testName in $results.Keys) {
    $status = if ($results[$testName]) { "✅ PASSED" } else { "❌ FAILED" }
    $color = if ($results[$testName]) { "Green" } else { "Red" }
    
    Write-Host "  $testName : $status" -ForegroundColor $color
    
    if (-not $results[$testName]) {
        $allPassed = $false
    }
}

Write-Host ""
if ($allPassed) {
    Write-Host "🎉 TODOS LOS TESTS PASARON EXITOSAMENTE" -ForegroundColor Green
} else {
    Write-Host "⚠️ ALGUNOS TESTS FALLARON - Revisa los logs arriba" -ForegroundColor Yellow
}

Write-Host "`n💡 Tips:" -ForegroundColor Cyan
Write-Host "  - Ver logs completos en LocalStack web UI: http://localhost:4566/_localstack/health" -ForegroundColor White
Write-Host "  - Verificar buckets S3: docker exec localstack-aws awslocal s3 ls" -ForegroundColor White
Write-Host "  - Ver colas SQS: docker exec localstack-aws awslocal sqs list-queues" -ForegroundColor White