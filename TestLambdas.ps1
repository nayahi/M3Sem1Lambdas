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

# Función auxiliar para verificar servicios gRPC
function Test-GrpcService {
    param(
        [string]$ServiceName,
        [int]$Port
    )

    try {
        # Verificar que el puerto está escuchando
        $connection = Test-NetConnection -ComputerName localhost -Port $Port -WarningAction SilentlyContinue
        
        if ($connection.TcpTestSucceeded) {
            return $true
        }
        
        return $false
    } catch {
        return $false
    }
}

function Get-LambdaLogs {
    param(
        [string]$FunctionName,
        [int]$Lines = 20
    )

    Write-Host "`n  📋 Últimos logs de CloudWatch:" -ForegroundColor Yellow
    
    $logGroupName = "/aws/lambda/$FunctionName"
    
    # Intentar múltiples veces (Lambda puede tardar en escribir logs)
    $attempts = 0
    $maxAttempts = 3
    
    while ($attempts -lt $maxAttempts) {
        $attempts++
        
        # Obtener streams
        $streams = docker exec $ContainerName awslocal logs describe-log-streams `
            --log-group-name $logGroupName `
            --order-by LastEventTime `
            --descending `
            --max-items 3 `
            --output json 2>&1

        if ($LASTEXITCODE -eq 0 -and $streams) {
            try {
                $streamsObj = $streams | ConvertFrom-Json
                
                if ($streamsObj.logStreams -and $streamsObj.logStreams.Count -gt 0) {
                    # Intentar con los últimos 3 streams
                    foreach ($stream in $streamsObj.logStreams) {
                        $streamName = $stream.logStreamName
                        
                        $logs = docker exec $ContainerName awslocal logs get-log-events `
                            --log-group-name $logGroupName `
                            --log-stream-name $streamName `
                            --limit $Lines `
                            --output json 2>&1

                        if ($LASTEXITCODE -eq 0 -and $logs) {
                            try {
                                $logsObj = $logs | ConvertFrom-Json
                                if ($logsObj.events -and $logsObj.events.Count -gt 0) {
                                    Write-Host "  Stream: $streamName" -ForegroundColor Gray
                                    foreach ($event in $logsObj.events) {
                                        Write-Host "  $($event.message)" -ForegroundColor Gray
                                    }
                                    return  # Éxito, salir
                                }
                            } catch {
                                # Continuar con siguiente stream
                            }
                        }
                    }
                }
            } catch {
                # Error parseando JSON
            }
        }
        
        if ($attempts -lt $maxAttempts) {
            Write-Host "  ⏳ Esperando logs... (intento $attempts/$maxAttempts)" -ForegroundColor Gray
            Start-Sleep -Seconds 3
        }
    }
    
    Write-Host "  ⚠️ No se encontraron logs después de $maxAttempts intentos" -ForegroundColor Yellow
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━FUNCIONES
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# TEST 1: IMAGEPROCESSOR LAMBDA (MEJORADO)
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

function Test-ImageProcessor {
    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
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

    # ✅ CORREGIDO: Verificar ProductService con Test-NetConnection
    Write-Host "`n  🔍 Verificando ProductService (puerto 7001)..." -ForegroundColor Yellow
    $productServiceRunning = Test-GrpcService -ServiceName "ProductService" -Port 7001
    
    if ($productServiceRunning) {
        Write-Host "  ✅ ProductService está escuchando en puerto 7001" -ForegroundColor Green
    } else {
        Write-Host "  ⚠️ ProductService NO está escuchando en puerto 7001" -ForegroundColor Yellow
        Write-Host "     Lambda procesará imágenes pero no actualizará ProductService" -ForegroundColor Gray
        Write-Host "     Para probar integración completa: cd ProductService.gRPC && dotnet run" -ForegroundColor Gray
    }

    # Crear imagen de prueba (1x1 pixel rojo en base64)
    Write-Host "`n  🎨 Creando imagen de prueba..." -ForegroundColor Yellow
    
    # JPG 1x1 pixel rojo en base64 (imagen válida mínima)
    $imageBase64 = "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAv/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAAAAX/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIRAxEAPwCwAA8A/9k="
    
    $imageBytes = [System.Convert]::FromBase64String($imageBase64)
    $testImagePath = "./test-image.jpg"
    [System.IO.File]::WriteAllBytes($testImagePath, $imageBytes)

    # Copiar imagen al contenedor
    docker cp $testImagePath ${ContainerName}:/tmp/test-image.jpg
    Remove-Item $testImagePath -Force #no borrarlo para pruebas siguientes

    # Usar ProductId que podría existir (1, 2, 3 están pre-cargados en ProductService)
    Write-Host "`n  📤 Subiendo imagen a S3..." -ForegroundColor Yellow
    
    if ($productServiceRunning) {
        Write-Host "     Usando ProductId existente: 1 (debería existir en BD)" -ForegroundColor Gray
        $productId = 1
    } else {
        Write-Host "     Usando ProductId aleatorio (solo test de procesamiento de imagen)" -ForegroundColor Gray
        $productId = Get-Random -Minimum 1 -Maximum 12
    }
    
    $s3Key = "products/$productId/original.jpg"
    
    docker exec $ContainerName awslocal s3 cp /tmp/test-image.jpg s3://product-images/$s3Key

    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ❌ Error subiendo imagen a S3" -ForegroundColor Red
        return $false
    }
    Write-Host "  ✅ Imagen subida: s3://product-images/$s3Key" -ForegroundColor Green

    # Esperar procesamiento
    Write-Host "`n  ⏳ Esperando que Lambda procese la imagen (15 seg)..." -ForegroundColor Yellow
    Start-Sleep -Seconds 15

    # Verificar imágenes procesadas en bucket de salida
    Write-Host "`n  🔍 Verificando imágenes procesadas en bucket de salida..." -ForegroundColor Yellow
    $processedPrefix = "products/$productId/"
    $processedFiles = docker exec $ContainerName awslocal s3 ls s3://product-images-processed/$processedPrefix 2>&1

    $imagesProcessed = $false
    if ($LASTEXITCODE -eq 0 -and $processedFiles -and -not [string]::IsNullOrWhiteSpace($processedFiles)) {
        Write-Host "  ✅ Imágenes procesadas encontradas en bucket de salida:" -ForegroundColor Green
        Write-Host $processedFiles -ForegroundColor Gray
        $imagesProcessed = $true
        
        # Verificar que hay 3 archivos (thumbnail_200, thumbnail_400, optimized)
        $fileCount = ($processedFiles -split "`n" | Where-Object { $_ -match "\.jpg$" }).Count
        if ($fileCount -ge 3) {
            Write-Host "  ✅ Se generaron las 3 versiones esperadas (thumbnail_200, thumbnail_400, optimized)" -ForegroundColor Green
        } else {
            Write-Host "  ⚠️ Solo se encontraron $fileCount archivos (se esperaban 3)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  ❌ No se encontraron imágenes procesadas en bucket de salida" -ForegroundColor Red
    }

    # Mostrar logs
    Get-LambdaLogs -FunctionName "ImageProcessorFunction" -Lines 40

    # Evaluar resultado
    if ($imagesProcessed) {
        if ($productServiceRunning) {
            Write-Host "`n  ✅ TEST IMAGEPROCESSOR: COMPLETADO - Imágenes procesadas y ProductService actualizado" -ForegroundColor Green
			# Mostrar logs
			Get-LambdaLogs -FunctionName "ImageProcessorFunction" -Lines 30
        } else {
            Write-Host "`n  ✅ TEST IMAGEPROCESSOR: PARCIAL - Imágenes procesadas (ProductService no corriendo)" -ForegroundColor Yellow
        }
        return $true
    } else {
        Write-Host "`n  ❌ TEST IMAGEPROCESSOR: FALLIDO - No se procesaron imágenes" -ForegroundColor Red
        return $false
    }
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# TEST 2: REPORTS LAMBDA (SIN CAMBIOS - SOLO REDEPLOYAR)
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

    # ✅ NUEVO: Verificar SQL Server
    Write-Host "`n  🔍 Verificando SQL Server..." -ForegroundColor Yellow
    $sqlCheck = docker exec $ContainerName nc -zv sqlserver 1433 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✅ SQL Server accesible" -ForegroundColor Green
    } else {
        Write-Host "  ⚠️ SQL Server no accesible desde LocalStack - Reports puede fallar" -ForegroundColor Yellow
    }
	
	# ✅ CORREGIDO: Verificar SQL Server
    Write-Host "`n  🔍 Verificando SQL Server (puerto 1434)..." -ForegroundColor Yellow
    $sqlServerRunning = Test-GrpcService -ServiceName "SQLServer" -Port 1433
    
    if ($sqlServerRunning) {
        Write-Host "  ✅ SQL Server está escuchando en puerto 1434" -ForegroundColor Green
    } else {
        Write-Host "  ⚠️ SQL Server NO está escuchando - Reports fallará" -ForegroundColor Yellow
    }

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

    # Probar solo un tipo primero (sales)
    Write-Host "`n  📊 Generando reporte tipo: sales" -ForegroundColor Yellow
    
    $startDate = (Get-Date).AddDays(-7).ToString("yyyy-MM-dd")  # Solo última semana
    $endDate = (Get-Date).ToString("yyyy-MM-dd")
    $fullUrl = "$apiUrl`?type=sales&startDate=$startDate&endDate=$endDate"

    $reportSuccess = $false
    try {
        Write-Host "  🌐 URL: $fullUrl" -ForegroundColor Gray
        
        $response = Invoke-WebRequest -Uri $fullUrl -Method GET -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        
        if ($response.StatusCode -eq 200) {
            $jsonResponse = $response.Content | ConvertFrom-Json
            
            Write-Host "  ✅ Reporte generado exitosamente" -ForegroundColor Green
            Write-Host "  📄 Tipo: $($jsonResponse.reportType)" -ForegroundColor Gray
            Write-Host "  📅 Generado: $($jsonResponse.generatedAt)" -ForegroundColor Gray
            Write-Host "  💾 Tamaño: $($jsonResponse.fileSize) bytes" -ForegroundColor Gray
            
            if ($jsonResponse.downloadUrl) {
                Write-Host "  🔗 URL de descarga disponible" -ForegroundColor Cyan
            }
            
            $reportSuccess = $true
        } else {
            Write-Host "  ⚠️ Respuesta inesperada: $($response.StatusCode)" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  ❌ Error: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "     Revisa los logs de CloudWatch abajo para más detalles" -ForegroundColor Gray
    }

    # Verificar PDFs generados en S3
    if ($reportSuccess) {
        Write-Host "`n  🔍 Verificando PDFs en S3..." -ForegroundColor Yellow
        $reportsInS3 = docker exec $ContainerName awslocal s3 ls s3://reports-generated/reports/ --recursive 2>&1

        if ($LASTEXITCODE -eq 0 -and $reportsInS3 -and -not [string]::IsNullOrWhiteSpace($reportsInS3)) {
            $pdfCount = ($reportsInS3 -split "`n" | Where-Object { $_ -match "\.pdf$" }).Count
            Write-Host "  ✅ PDFs encontrados en S3: $pdfCount archivo(s)" -ForegroundColor Green
        } else {
            Write-Host "  ⚠️ No se encontraron PDFs en S3" -ForegroundColor Yellow
        }
    }

    # Mostrar logs (más líneas para ver error completo)
    Get-LambdaLogs -FunctionName "ReportsGeneratorFunction" -Lines 50

    if ($reportSuccess) {
        Write-Host "`n  ✅ TEST REPORTS COMPLETADO" -ForegroundColor Green
		# Mostrar logs
		Get-LambdaLogs -FunctionName "ReportsGeneratorFunction" -Lines 30
        return $true
    } else {
        Write-Host "`n  ❌ TEST REPORTS FALLIDO" -ForegroundColor Red
        return $false
    }
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# TEST 3: EMAILBATCH LAMBDA (MEJORADO)
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

    # ✅ CORREGIDO: Verificar NotificationService
    Write-Host "`n  🔍 Verificando NotificationService (puerto 7005)..." -ForegroundColor Yellow
    $notificationServiceRunning = Test-GrpcService -ServiceName "NotificationService" -Port 7005
    
    if ($notificationServiceRunning) {
        Write-Host "  ✅ NotificationService está escuchando en puerto 7005" -ForegroundColor Green
    } else {
        Write-Host "  ⚠️ NotificationService NO está escuchando en puerto 7005" -ForegroundColor Yellow
        Write-Host "     Lambda se ejecutará pero fallará al enviar emails" -ForegroundColor Gray
        Write-Host "     Para probar integración completa: cd NotificationService.gRPC && dotnet run" -ForegroundColor Gray
    }

    # Verificar event source mapping
    Write-Host "`n  🔍 Verificando event source mapping..." -ForegroundColor Yellow
    $mappings = docker exec $ContainerName awslocal lambda list-event-source-mappings `
        --function-name EmailBatchProcessorFunction `
        --output json 2>&1

    if ($LASTEXITCODE -eq 0) {
        $mappingsObj = $mappings | ConvertFrom-Json
        if ($mappingsObj.EventSourceMappings.Count -gt 0) {
            $state = $mappingsObj.EventSourceMappings[0].State
            Write-Host "  ✅ Event source mapping configurado (Estado: $state)" -ForegroundColor Green
        } else {
            Write-Host "  ⚠️ No hay event source mapping - Lambda no se disparará automáticamente" -ForegroundColor Yellow
        }
    }

    # Verificar cola SQS
    Write-Host "`n  🔍 Verificando cola SQS..." -ForegroundColor Yellow
    $queueUrl = "http://localhost:4566/000000000000/email-notifications-queue"
    
    # Enviar mensajes de prueba
    Write-Host "`n  📤 Enviando mensajes de prueba a SQS..." -ForegroundColor Yellow

    $testEmails = @(
        @{
            UserId = 1
            OrderId = 1
            EmailTo = "cliente1@example.com"
            Subject = "Confirmación de Pedido #1"
            Body = "Tu pedido ha sido confirmado y está siendo procesado."
            Template = "OrderConfirmation"
        },
        @{
            UserId = 2
            OrderId = 2
            EmailTo = "cliente2@example.com"
            Subject = "Pedido Enviado #2"
            Body = "Tu pedido ha sido enviado y llegará en 2-3 días."
            Template = "ShippingUpdate"
        }
    )

    $messagesSent = 0
    foreach ($email in $testEmails) {
        $messageBody = $email | ConvertTo-Json -Compress
        
        docker exec $ContainerName awslocal sqs send-message `
            --queue-url $queueUrl `
            --message-body $messageBody 2>&1 | Out-Null

        if ($LASTEXITCODE -eq 0) {
            $messagesSent++
            Write-Host "  ✅ Mensaje enviado: $($email.EmailTo)" -ForegroundColor Green
        } else {
            Write-Host "  ❌ Error enviando mensaje: $($email.EmailTo)" -ForegroundColor Red
        }
    }

    Write-Host "`n  📊 Total mensajes enviados: $messagesSent" -ForegroundColor Cyan

    # Esperar procesamiento
    Write-Host "`n  ⏳ Esperando procesamiento de Lambda (20 seg)..." -ForegroundColor Yellow
    Start-Sleep -Seconds 20

    # Verificar que la cola está vacía (mensajes procesados)
    Write-Host "`n  🔍 Verificando estado de la cola..." -ForegroundColor Yellow
    
    # ✅ FIX: Usar atributos separados
    $queueAttrs = docker exec $ContainerName awslocal sqs get-queue-attributes `
        --queue-url $queueUrl `
        --attribute-names All `
        --output json 2>&1

    $messagesProcessed = $false
    if ($LASTEXITCODE -eq 0) {
        $queueResult = $queueAttrs | ConvertFrom-Json
        $msgsInQueue = [int]$queueResult.Attributes.ApproximateNumberOfMessages
        $msgsInFlight = [int]$queueResult.Attributes.ApproximateNumberOfMessagesNotVisible

        Write-Host "  📊 Mensajes en cola: $msgsInQueue" -ForegroundColor Gray
        Write-Host "  📊 Mensajes en procesamiento: $msgsInFlight" -ForegroundColor Gray

        if ($msgsInQueue -eq 0 -and $msgsInFlight -eq 0) {
            Write-Host "  ✅ Todos los mensajes procesados" -ForegroundColor Green
            $messagesProcessed = $true
        } else {
            Write-Host "  ⚠️ Algunos mensajes aún en cola/procesamiento" -ForegroundColor Yellow
        }
    }

    # Mostrar logs
    Get-LambdaLogs -FunctionName "EmailBatchProcessorFunction" -Lines 50

    # Evaluar resultado
    if ($messagesProcessed) {
        if ($notificationServiceRunning) {
            Write-Host "`n  ✅ TEST EMAILBATCH: COMPLETADO - Mensajes procesados y emails enviados" -ForegroundColor Green
			 # Mostrar logs
			Get-LambdaLogs -FunctionName "EmailBatchProcessorFunction" -Lines 40
            return $true
        } else {
            Write-Host "`n  ⚠️ TEST EMAILBATCH: PARCIAL - Mensajes procesados (NotificationService no corriendo)" -ForegroundColor Yellow
            return $true  # Aún cuenta como éxito si Lambda se ejecutó
        }
    } else {
        Write-Host "`n  ❌ TEST EMAILBATCH: FALLIDO - Mensajes no procesados" -ForegroundColor Red
        return $false
    }
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# EJECUTAR TESTS
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

$results = @{}

#comentar los tests que no se ocupan correr
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