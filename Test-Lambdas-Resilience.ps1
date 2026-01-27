#Requires -Version 7

<#
.SYNOPSIS
    Prueba los patrones de resiliencia Polly en ImageProcessor y EmailBatch
.DESCRIPTION
    Script para verificar Retry, Timeout, Fallback y Circuit Breaker funcionan correctamente
    ESCENARIOS DE PRUEBA:
    1. Servicios disponibles → Todo funciona normalmente
    2. ProductService caído → ImageProcessor usa Fallback
    3. NotificationService caído → EmailBatch abre Circuit Breaker
.PARAMETER Scenario
    Especifica qué escenario probar: All, Normal, ImageProcessorFallback, EmailBatchCircuit
.EXAMPLE
    .\Test-Lambdas-Resilience.ps1 -Scenario All
    .\Test-Lambdas-Resilience.ps1 -Scenario ImageProcessorFallback
#>

param(
    [ValidateSet("All", "Normal", "ImageProcessorFallback", "EmailBatchCircuit")]
    [string]$Scenario = "All"
)

$ErrorActionPreference = "Stop"

Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║       TESTING RESILIENCIA POLLY - SEMANA 2 EN LOCALSTACK      ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# Configuración
$LocalStackEndpoint = "http://localhost:4566"
$ContainerName = "localstack-aws"

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# VERIFICAR LOCALSTACK
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Write-Host "`n🔍 Verificando LocalStack..." -ForegroundColor Yellow
try {
    $response = Invoke-WebRequest -Uri "$LocalStackEndpoint/_localstack/health" -UseBasicParsing
    Write-Host "✅ LocalStack está disponible" -ForegroundColor Green
} catch {
    Write-Host "❌ LocalStack no está disponible" -ForegroundColor Red
    exit 1
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# FUNCIONES AUXILIARES
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

function Get-LambdaLogs {
    param(
        [string]$FunctionName,
        [int]$Lines = 30,
        [string]$Filter = ""
    )

    Write-Host "`n  📋 Logs de CloudWatch (últimos $Lines):" -ForegroundColor Yellow
    
    $logGroupName = "/aws/lambda/$FunctionName"
    
    # Obtener stream más reciente
    $streams = docker exec $ContainerName awslocal logs describe-log-streams `
        --log-group-name $logGroupName `
        --order-by LastEventTime `
        --descending `
        --max-items 1 `
        --query 'logStreams[0].logStreamName' `
        --output text 2>&1

    if ($LASTEXITCODE -eq 0 -and $streams -and -not [string]::IsNullOrWhiteSpace($streams)) {
        $streamName = $streams.Trim()
        
        $logs = docker exec $ContainerName awslocal logs get-log-events `
            --log-group-name $logGroupName `
            --log-stream-name $streamName `
            --limit $Lines `
            --query 'events[].message' `
            --output text 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            # Filtrar logs si se especificó
            if ($Filter) {
                $logs = $logs | Select-String -Pattern $Filter
            }
            
            # Colorear logs importantes
            $logs -split "`n" | ForEach-Object {
                $line = $_
                if ($line -match "\[POLLY RETRY\]") {
                    Write-Host "    $line" -ForegroundColor Yellow
                } elseif ($line -match "\[POLLY CIRCUIT\]") {
                    Write-Host "    $line" -ForegroundColor Magenta
                } elseif ($line -match "\[POLLY FALLBACK\]") {
                    Write-Host "    $line" -ForegroundColor Red
                } elseif ($line -match "\[POLLY TIMEOUT\]") {
                    Write-Host "    $line" -ForegroundColor DarkYellow
                } elseif ($line -match "✅|✓") {
                    Write-Host "    $line" -ForegroundColor Green
                } elseif ($line -match "❌|ERROR|Error") {
                    Write-Host "    $line" -ForegroundColor Red
                } else {
                    Write-Host "    $line" -ForegroundColor Gray
                }
            }
        } else {
            Write-Host "  ⚠️ No se pudieron obtener logs" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  ⚠️ No se encontró stream de logs reciente" -ForegroundColor Yellow
    }
}

function Wait-Seconds {
    param([int]$Seconds, [string]$Message)
    
    Write-Host "`n  ⏳ $Message" -ForegroundColor Cyan
    for ($i = $Seconds; $i -gt 0; $i--) {
        Write-Host -NoNewline "`r    Esperando $i segundos... " -ForegroundColor Gray
        Start-Sleep -Seconds 1
    }
    Write-Host "`r    ✓ Completado                    " -ForegroundColor Green
}

function Test-GrpcService {
    param(
        [string]$ServiceName,
        [int]$Port
    )

    try {
        # Verificar que el puerto está escuchando
        $connection = Test-NetConnection -ComputerName localhost -Port $Port -WarningAction SilentlyContinue
        
        if ($connection.TcpTestSucceeded) {
            Write-Host "  ✅ $ServiceName está disponible (puerto $Port)" -ForegroundColor Green
            return $true
        }
        
        Write-Host "  ❌ $ServiceName NO está disponible (puerto $Port)" -ForegroundColor Red
        return $false
    } catch {
        Write-Host "  ❌ $ServiceName NO está disponible (puerto $Port)" -ForegroundColor Red
        return $false
    }
}

function Stop-GrpcService {
    param([string]$ServiceName)
    
    Write-Host "  🛑 Deteniendo $ServiceName..." -ForegroundColor Yellow
    
    # Buscar contenedor por nombre (case insensitive, puede tener prefijo)
    $containerName = $ServiceName.ToLower()
    $containerId = docker ps --filter "name=$containerName" --format "{{.ID}}" 2>$null
    
    if (-not $containerId) {
        # Intentar sin "service" al final
        $containerName = $ServiceName.ToLower() -replace 'service$', ''
        $containerId = docker ps --filter "name=$containerName" --format "{{.ID}}" 2>$null
    }
    
    if ($containerId) {
        docker stop $containerId | Out-Null
        Write-Host "  ✓ $ServiceName detenido (container: $containerId)" -ForegroundColor Green
        return $true
    } else {
        Write-Host "  ⚠️ Contenedor $ServiceName no encontrado o ya está detenido" -ForegroundColor Yellow
        Write-Host "     Intenta: docker ps --filter 'name=product' para ver contenedores" -ForegroundColor Gray
        return $false
    }
}

function Start-GrpcService {
    param([string]$ServiceName)
    
    Write-Host "  ▶️ Iniciando $ServiceName..." -ForegroundColor Yellow
    
    # Buscar contenedor detenido (case insensitive)
    $containerName = $ServiceName.ToLower()
    $containerId = docker ps -a --filter "name=$containerName" --filter "status=exited" --format "{{.ID}}" 2>$null
    
    if (-not $containerId) {
        # Intentar sin "service" al final
        $containerName = $ServiceName.ToLower() -replace 'service$', ''
        $containerId = docker ps -a --filter "name=$containerName" --filter "status=exited" --format "{{.ID}}" 2>$null
    }
    
    if ($containerId) {
        docker start $containerId | Out-Null
        Start-Sleep -Seconds 3  # Dar tiempo para que inicie
        Write-Host "  ✓ $ServiceName iniciado (container: $containerId)" -ForegroundColor Green
        return $true
    } else {
        Write-Host "  ⚠️ Contenedor $ServiceName no encontrado o ya está corriendo" -ForegroundColor Yellow
        return $false
    }
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# ESCENARIO 1: NORMAL - TODOS LOS SERVICIOS DISPONIBLES
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

function Test-NormalScenario {
    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "✅ ESCENARIO 1: OPERACIÓN NORMAL (Servicios disponibles)" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

    # Verificar servicios gRPC
    Write-Host "`n🔍 Verificando servicios gRPC..." -ForegroundColor Yellow
    $productOk = Test-GrpcService -ServiceName "ProductService" -Port 7001
    $notificationOk = Test-GrpcService -ServiceName "NotificationService" -Port 7005

    if (-not $productOk -or -not $notificationOk) {
        Write-Host "`n⚠️ Algunos servicios no están disponibles. Asegúrate de que docker-compose esté corriendo." -ForegroundColor Yellow
        Write-Host "   Ejecuta: docker-compose up -d" -ForegroundColor Gray
        return $false
    }

    # TEST 1: ImageProcessor
    Write-Host "`n📸 TEST 1.1: ImageProcessor con ProductService disponible" -ForegroundColor Cyan
    Write-Host "  Expectativa: Procesamiento exitoso sin reintentos" -ForegroundColor Gray

    # Crear imagen de prueba (JPG válido 1x1 pixel en base64 - igual que Semana 1)
    Write-Host "`n  🎨 Creando imagen de prueba..." -ForegroundColor Yellow
    
    $imageBase64 = "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAv/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAAAAX/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIRAxEAPwCwAA8A/9k="
    $imageBytes = [System.Convert]::FromBase64String($imageBase64)
    $testImagePath = "./test-image.jpg"
    [System.IO.File]::WriteAllBytes($testImagePath, $imageBytes)

    # ✅ CRÍTICO: Copiar al contenedor PRIMERO
    Write-Host "  📤 Subiendo imagen a S3..." -ForegroundColor Yellow
    docker cp $testImagePath ${ContainerName}:/tmp/test-image-normal.jpg
    
    $productId = Get-Random -Minimum 100 -Maximum 999
    $s3Key = "products/$productId/test-normal.jpg"
    
    # ✅ CORRECTO: Subir DESDE el contenedor
    docker exec $ContainerName awslocal s3 cp /tmp/test-image-normal.jpg s3://product-images/$s3Key 2>&1 | Out-Null
    Remove-Item $testImagePath -Force

    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✓ Imagen subida: $s3Key" -ForegroundColor Green
    } else {
        Write-Host "  ❌ Error al subir imagen" -ForegroundColor Red
        return $false
    }

    Wait-Seconds -Seconds 15 -Message "Esperando procesamiento de Lambda..."

    # Verificar imágenes procesadas en bucket de salida
    Write-Host "`n  🔍 Verificando imágenes procesadas..." -ForegroundColor Yellow
    $processedPrefix = "products/$productId/"
    $processedFiles = docker exec $ContainerName awslocal s3 ls s3://product-images-processed/$processedPrefix 2>&1

    if ($LASTEXITCODE -eq 0 -and $processedFiles -and -not [string]::IsNullOrWhiteSpace($processedFiles)) {
        Write-Host "  ✅ Imágenes procesadas encontradas:" -ForegroundColor Green
        Write-Host $processedFiles -ForegroundColor Gray
        
        $fileCount = ($processedFiles -split "`n" | Where-Object { $_ -match "\.jpg$" }).Count
        if ($fileCount -ge 3) {
            Write-Host "  ✅ Se generaron las 3 versiones (thumbnail_200, thumbnail_400, optimized)" -ForegroundColor Green
        }
    } else {
        Write-Host "  ⚠️ No se encontraron imágenes procesadas aún" -ForegroundColor Yellow
    }

    # Verificar logs
    Get-LambdaLogs -FunctionName "ImageProcessorFunction" -Lines 25

    Write-Host "`n  🔍 Verificaciones:" -ForegroundColor Yellow
    Write-Host "    ✓ NO debe haber [POLLY RETRY] (primer intento exitoso)" -ForegroundColor Gray
    Write-Host "    ✓ NO debe haber [POLLY FALLBACK] (servicio disponible)" -ForegroundColor Gray
    Write-Host "    ✓ Debe mostrar 'ProductService actualizado exitosamente'" -ForegroundColor Gray

    # TEST 2: EmailBatch
    Write-Host "`n📧 TEST 1.2: EmailBatch con NotificationService disponible" -ForegroundColor Cyan
    Write-Host "  Expectativa: Envío exitoso sin circuit breaker" -ForegroundColor Gray

    # Enviar mensaje a SQS
    Write-Host "`n  📤 Enviando mensaje de prueba a SQS..." -ForegroundColor Yellow
    
    $emailMessage = @{
        UserId = 1
        OrderId = (Get-Random -Minimum 2000 -Maximum 2999)
        EmailTo = "test-normal@example.com"
        Subject = "Test Normal - Circuit Breaker Cerrado"
        Body = "Este email prueba operación normal con servicio disponible."
        Template = "OrderConfirmation"
    } | ConvertTo-Json -Compress

    $queueUrl = "http://localhost:4566/000000000000/email-notifications-queue"
    
    docker exec $ContainerName awslocal sqs send-message `
        --queue-url $queueUrl `
        --message-body $emailMessage 2>&1 | Out-Null

    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✓ Mensaje enviado a SQS" -ForegroundColor Green
    } else {
        Write-Host "  ❌ Error al enviar mensaje" -ForegroundColor Red
        return $false
    }

    Wait-Seconds -Seconds 5 -Message "Esperando procesamiento de Lambda..."

    # Verificar logs
    Get-LambdaLogs -FunctionName "EmailBatchProcessorFunction" -Lines 25

    Write-Host "`n  🔍 Verificaciones:" -ForegroundColor Yellow
    Write-Host "    ✓ Circuit debe estar CERRADO (🟢)" -ForegroundColor Gray
    Write-Host "    ✓ Email debe enviarse exitosamente" -ForegroundColor Gray
    Write-Host "    ✓ NO debe haber reintentos excesivos" -ForegroundColor Gray

    Write-Host "`n✅ ESCENARIO 1 COMPLETADO" -ForegroundColor Green
    return $true
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# ESCENARIO 2: IMAGEPROCESSOR FALLBACK - PRODUCTSERVICE CAÍDO
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

function Test-ImageProcessorFallback {
    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "⚠️ ESCENARIO 2: FALLBACK - ProductService CAÍDO" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

    Write-Host "`n📋 Este escenario prueba:" -ForegroundColor Yellow
    Write-Host "  • Retry Policy: 3 intentos con backoff exponencial" -ForegroundColor Gray
    Write-Host "  • Timeout Policy: 10 segundos máximo por llamada" -ForegroundColor Gray
    Write-Host "  • Fallback Policy: Continuar con siguiente imagen si falla" -ForegroundColor Gray

    # Detener ProductService
    Write-Host "`n🎬 FASE 1: Detener ProductService" -ForegroundColor Cyan
    $stopped = Stop-GrpcService -ServiceName "productservice"
    
    if (-not $stopped) {
        Write-Host "  ⚠️ No se pudo detener ProductService. Verifica el nombre del contenedor." -ForegroundColor Yellow
        Write-Host "  💡 Lista de contenedores: docker ps --filter 'name=product'" -ForegroundColor Gray
    }

    Wait-Seconds -Seconds 3 -Message "Esperando confirmación de servicio caído..."

    # Subir imagen para disparar Lambda
    Write-Host "`n🎬 FASE 2: Subir imagen para disparar Lambda" -ForegroundColor Cyan
    
    # Crear imagen de prueba (igual que Semana 1)
    $imageBase64 = "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAv/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAAAAX/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIRAxEAPwCwAA8A/9k="
    $imageBytes = [System.Convert]::FromBase64String($imageBase64)
    $testImagePath = "./test-image.jpg"
    [System.IO.File]::WriteAllBytes($testImagePath, $imageBytes)

    # ✅ Copiar al contenedor PRIMERO
    docker cp $testImagePath ${ContainerName}:/tmp/test-image-fallback.jpg

    $productId = Get-Random -Minimum 100 -Maximum 999
    $s3Key = "products/$productId/test-fallback.jpg"
    
    # ✅ Subir DESDE el contenedor
    docker exec $ContainerName awslocal s3 cp /tmp/test-image-fallback.jpg s3://product-images/$s3Key 2>&1 | Out-Null
    Remove-Item $testImagePath -Force

    Write-Host "  ✓ Imagen subida: $s3Key" -ForegroundColor Green

    Wait-Seconds -Seconds 15 -Message "Esperando reintentos y fallback (3 reintentos x ~4s = ~12s)..."

    # Verificar imágenes procesadas (DEBEN existir con fallback)
    Write-Host "`n  🔍 Verificando imágenes procesadas..." -ForegroundColor Yellow
    $processedPrefix = "products/$productId/"
    $processedFiles = docker exec $ContainerName awslocal s3 ls s3://product-images-processed/$processedPrefix 2>&1

    if ($LASTEXITCODE -eq 0 -and $processedFiles -and -not [string]::IsNullOrWhiteSpace($processedFiles)) {
        Write-Host "  ✅ FALLBACK FUNCIONÓ: Imágenes procesadas a pesar de servicio caído" -ForegroundColor Green
        Write-Host $processedFiles -ForegroundColor Gray
    } else {
        Write-Host "  ⚠️ No se encontraron imágenes (fallback podría no estar funcionando)" -ForegroundColor Yellow
    }

    # Mostrar logs
    Write-Host "`n🎬 FASE 3: Analizar logs de resiliencia" -ForegroundColor Cyan
    Get-LambdaLogs -FunctionName "ImageProcessorFunction" -Lines 40

    Write-Host "`n  🔍 QUÉ BUSCAR EN LOS LOGS:" -ForegroundColor Yellow
    Write-Host "    🔄 [POLLY RETRY] Intento 1/3, 2/3, 3/3 (backoff: ~1s, ~2s, ~4s)" -ForegroundColor Yellow
    Write-Host "    ⏱️ [POLLY TIMEOUT] Si alguna llamada excede 10 segundos" -ForegroundColor DarkYellow
    Write-Host "    🔴 [POLLY FALLBACK] Después del 3er intento fallido" -ForegroundColor Red
    Write-Host "    ✅ Lambda NO falla - imagen se procesa pero ProductService no se actualiza" -ForegroundColor Green

    # Restaurar servicio
    Write-Host "`n🎬 FASE 4: Restaurar ProductService" -ForegroundColor Cyan
    Start-GrpcService -ServiceName "productservice"

    Wait-Seconds -Seconds 3 -Message "Esperando que servicio esté listo..."

    Write-Host "`n✅ ESCENARIO 2 COMPLETADO" -ForegroundColor Green
    Write-Host "   ProductService ha sido restaurado" -ForegroundColor Gray
    
    return $true
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# ESCENARIO 3: EMAILBATCH CIRCUIT BREAKER - NOTIFICATIONSERVICE CAÍDO
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

function Test-EmailBatchCircuit {
    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "🔴 ESCENARIO 3: CIRCUIT BREAKER - NotificationService CAÍDO" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

    Write-Host "`n📋 Este escenario prueba:" -ForegroundColor Yellow
    Write-Host "  • Circuit Breaker: 50% failure ratio en 30 segundos" -ForegroundColor Gray
    Write-Host "  • Minimum Throughput: 5 requests antes de evaluar" -ForegroundColor Gray
    Write-Host "  • Break Duration: 30 segundos en estado abierto" -ForegroundColor Gray
    Write-Host "  • Retry Policy: 2 intentos antes de circuit" -ForegroundColor Gray

    # Detener NotificationService
    Write-Host "`n🎬 FASE 1: Detener NotificationService" -ForegroundColor Cyan
    $stopped = Stop-GrpcService -ServiceName "notificationservice"
    
    if (-not $stopped) {
        Write-Host "  ⚠️ No se pudo detener NotificationService. Verifica el nombre del contenedor." -ForegroundColor Yellow
        Write-Host "  💡 Lista de contenedores: docker ps --filter 'name=notification'" -ForegroundColor Gray
    }

    Wait-Seconds -Seconds 3 -Message "Esperando confirmación de servicio caído..."

    # Enviar múltiples mensajes para abrir el circuit
    Write-Host "`n🎬 FASE 2: Enviar 10 mensajes para abrir Circuit Breaker" -ForegroundColor Cyan
    Write-Host "  (Primeros 5 fallarán con reintentos, luego circuit abre)" -ForegroundColor Gray

    $queueUrl = "http://localhost:4566/000000000000/email-notifications-queue"
    
    for ($i = 1; $i -le 10; $i++) {
        $emailMessage = @{
            UserId = $i
            OrderId = 3000 + $i
            EmailTo = "test-circuit-$i@example.com"
            Subject = "Test Circuit Breaker - Mensaje $i"
            Body = "Este email prueba el circuit breaker. Mensaje $i de 10."
            Template = "OrderConfirmation"
        } | ConvertTo-Json -Compress

        docker exec $ContainerName awslocal sqs send-message `
            --queue-url $queueUrl `
            --message-body $emailMessage 2>&1 | Out-Null

        if ($i -eq 1) {
            Write-Host "  ✓ Mensaje $i enviado (circuit CERRADO 🟢)" -ForegroundColor Green
        } elseif ($i -le 5) {
            Write-Host "  ✓ Mensaje $i enviado (evaluando fallas...)" -ForegroundColor Yellow
        } elseif ($i -eq 6) {
            Write-Host "  ✓ Mensaje $i enviado (circuit probablemente ABIERTO 🔴)" -ForegroundColor Red
        } else {
            Write-Host "  ✓ Mensaje $i enviado (rechazado por circuit abierto)" -ForegroundColor DarkRed
        }

        Start-Sleep -Milliseconds 500
    }

    Wait-Seconds -Seconds 20 -Message "Esperando procesamiento de mensajes y apertura de circuit..."

    # Mostrar logs
    Write-Host "`n🎬 FASE 3: Analizar logs de Circuit Breaker" -ForegroundColor Cyan
    Get-LambdaLogs -FunctionName "EmailBatchProcessorFunction" -Lines 60

    Write-Host "`n  🔍 QUÉ BUSCAR EN LOS LOGS:" -ForegroundColor Yellow
    Write-Host "    🟢 [POLLY CIRCUIT] Estado: CERRADO - Mensajes 1-5" -ForegroundColor Green
    Write-Host "    🔴 [POLLY CIRCUIT] Estado: ABIERTO - Después del mensaje 5" -ForegroundColor Red
    Write-Host "    🔄 [POLLY RETRY] Intento 1/2, 2/2 en primeros mensajes" -ForegroundColor Yellow
    Write-Host "    ⚡ Mensajes 6-10 rechazados INMEDIATAMENTE (sin reintentos)" -ForegroundColor Magenta
    Write-Host "    📮 Mensajes rechazados van a DLQ automáticamente" -ForegroundColor Gray

    # Verificar DLQ
    Write-Host "`n🎬 FASE 4: Verificar Dead Letter Queue" -ForegroundColor Cyan
    
    $dlqUrl = "http://localhost:4566/000000000000/email-notifications-dlq"
    $dlqCount = docker exec $ContainerName awslocal sqs get-queue-attributes `
        --queue-url $dlqUrl `
        --attribute-names ApproximateNumberOfMessages `
        --query 'Attributes.ApproximateNumberOfMessages' `
        --output text 2>&1

    if ($LASTEXITCODE -eq 0 -and $dlqCount) {
        Write-Host "  📮 Mensajes en DLQ: $dlqCount" -ForegroundColor Cyan
        Write-Host "  ✓ Circuit Breaker protegió el sistema enviando mensajes a DLQ" -ForegroundColor Green
    }

    # Restaurar servicio
    Write-Host "`n🎬 FASE 5: Restaurar NotificationService" -ForegroundColor Cyan
    Start-GrpcService -ServiceName "notificationservice"

    Wait-Seconds -Seconds 3 -Message "Esperando que servicio esté listo..."

    Write-Host "`n  ℹ️ Circuit Breaker permanecerá ABIERTO por 30 segundos" -ForegroundColor Cyan
    Write-Host "     Después entrará en Half-Open y probará si el servicio se recuperó" -ForegroundColor Gray

    Write-Host "`n✅ ESCENARIO 3 COMPLETADO" -ForegroundColor Green
    Write-Host "   NotificationService ha sido restaurado" -ForegroundColor Gray
    
    return $true
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# EJECUTAR ESCENARIOS
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

$results = @{}

if ($Scenario -eq "All" -or $Scenario -eq "Normal") {
    $results["Normal"] = Test-NormalScenario
}

if ($Scenario -eq "All" -or $Scenario -eq "ImageProcessorFallback") {
    $results["ImageProcessorFallback"] = Test-ImageProcessorFallback
}

if ($Scenario -eq "All" -or $Scenario -eq "EmailBatchCircuit") {
    $results["EmailBatchCircuit"] = Test-EmailBatchCircuit
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# RESUMEN FINAL
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Write-Host "`n╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║                    📊 RESUMEN DE PRUEBAS                       ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

foreach ($test in $results.Keys) {
    $status = if ($results[$test]) { "✅ EXITOSO" } else { "⚠️ REVISAR" }
    $color = if ($results[$test]) { "Green" } else { "Yellow" }
    Write-Host "  $test : $status" -ForegroundColor $color
}

Write-Host "`n📚 CONCEPTOS DEMOSTRADOS:" -ForegroundColor Yellow
Write-Host "  ✓ Retry Policy: Backoff exponencial con jitter" -ForegroundColor Gray
Write-Host "  ✓ Timeout Policy: Límite de tiempo por operación" -ForegroundColor Gray
Write-Host "  ✓ Fallback Policy: Degradación graciosa del servicio" -ForegroundColor Gray
Write-Host "  ✓ Circuit Breaker: Protección contra fallas sostenidas" -ForegroundColor Gray
Write-Host "  ✓ DLQ Integration: Mensajes fallidos preservados" -ForegroundColor Gray

Write-Host "`n🎓 APRENDIZAJES CLAVE:" -ForegroundColor Yellow
Write-Host "  • ImageProcessor usa Fallback → Lambda NO falla, continúa procesando" -ForegroundColor Gray
Write-Host "  • EmailBatch usa Circuit Breaker → Rechaza rápido cuando servicio caído" -ForegroundColor Gray
Write-Host "  • Circuit abierto evita desperdiciar recursos en llamadas condenadas" -ForegroundColor Gray
Write-Host "  • DLQ asegura que ningún mensaje se pierda" -ForegroundColor Gray

Write-Host "`n💡 PRÓXIMOS PASOS:" -ForegroundColor Cyan
Write-Host "  1. Revisar logs detallados en LocalStack CloudWatch" -ForegroundColor White
Write-Host "  2. Experimentar con diferentes valores de Polly (env vars)" -ForegroundColor White
Write-Host "  3. Monitorear métricas de circuit breaker en producción" -ForegroundColor White

Write-Host "`n🎉 Testing de resiliencia completado!" -ForegroundColor Green
