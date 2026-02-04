#Requires -Version 7

<#
.SYNOPSIS
    Test de Reports.Lambda con Redis Cache (Semana 3)
.DESCRIPTION
    Demuestra el funcionamiento de cache hit/miss con Redis
#>

$ErrorActionPreference = "Stop"

Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║       TEST: Reports.Lambda con Redis Cache (Semana 3)         ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

$LocalStackEndpoint = "http://localhost:4566"
$ContainerName = "localstack-aws"

# Verificar LocalStack
Write-Host "`n🔍 Verificando LocalStack..." -ForegroundColor Yellow
try {
    $response = Invoke-WebRequest -Uri "$LocalStackEndpoint/_localstack/health" -UseBasicParsing
    Write-Host "✅ LocalStack disponible" -ForegroundColor Green
} catch {
    Write-Host "❌ LocalStack no disponible" -ForegroundColor Red
    exit 1
}

# Verificar Redis
# Write-Host "`n🔍 Verificando Redis..." -ForegroundColor Yellow
# $redisCheck = docker exec $ContainerName redis-cli -h redis ping 2>&1
# if ($LASTEXITCODE -eq 0 -and $redisCheck -match "PONG") {
    # Write-Host "✅ Redis disponible y respondiendo" -ForegroundColor Green
# } else {
    # Write-Host "❌ Redis no disponible" -ForegroundColor Red
    # exit 1
# }

# Obtener API ID
Write-Host "`n🔍 Obteniendo API Gateway ID..." -ForegroundColor Yellow
$apiId = docker exec $ContainerName awslocal apigateway get-rest-apis `
    --query 'items[?name==`ReportsAPI`].id' `
    --output text

if ([string]::IsNullOrWhiteSpace($apiId)) {
    Write-Host "❌ No se encontró API Gateway. Ejecuta Deploy-Reports-Lambda-Redis.ps1 primero" -ForegroundColor Red
    exit 1
}

$endpoint = "http://localhost:4566/restapis/$apiId/prod/_user_request_/reports"
Write-Host "✅ API Endpoint: $endpoint" -ForegroundColor Green

Write-Host "✅ Limpiar cache" -ForegroundColor Green
docker exec -it microservices-redis redis-cli FLUSHALL

# Función para medir tiempo de respuesta
function Invoke-TimedRequest {
    param(
        [string]$Url,
        [string]$Description
    )

    Write-Host "`n$Description" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Gray
    
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    
    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 30
        $stopwatch.Stop()
        
        $responseObj = $response.Content | ConvertFrom-Json
        
        Write-Host "⏱️  Tiempo de respuesta: $($stopwatch.ElapsedMilliseconds) ms" -ForegroundColor Yellow
        
        if ($responseObj.cacheHit -eq $true) {
            Write-Host "🎯 CACHE HIT - Datos obtenidos desde Redis" -ForegroundColor Green
        } else {
            Write-Host "❌ CACHE MISS - Datos obtenidos desde SQL Server" -ForegroundColor Magenta
        }
        
        Write-Host "📊 Tipo de reporte: $($responseObj.reportType)" -ForegroundColor Gray
        Write-Host "📄 Tamaño PDF: $($responseObj.fileSize) bytes" -ForegroundColor Gray
        Write-Host "🔑 Cache Key: $($responseObj.cacheKey)" -ForegroundColor Gray
        
        return @{
            Success = $true
            Time = $stopwatch.ElapsedMilliseconds
            CacheHit = $responseObj.cacheHit
            CacheKey = $responseObj.cacheKey
        }
    }
    catch {
        $stopwatch.Stop()
        Write-Host "❌ Error: $($_.Exception.Message)" -ForegroundColor Red
        return @{
            Success = $false
            Time = $stopwatch.ElapsedMilliseconds
        }
    }
}

# ═══════════════════════════════════════════════════════════════════
# TEST 1: Primera consulta (CACHE MISS esperado)
# ═══════════════════════════════════════════════════════════════════

Write-Host "`n╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
Write-Host "║           TEST 1: Primera Consulta (CACHE MISS)               ║" -ForegroundColor Yellow
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow

# Limpiar caché de Redis antes de empezar
Write-Host "`n🧹 Limpiando caché de Redis..." -ForegroundColor Yellow
docker exec $ContainerName redis-cli -h redis FLUSHALL | Out-Null
Write-Host "✅ Caché limpiado" -ForegroundColor Green

$url1 = "${endpoint}?type=sales&startDate=2024-01-01&endDate=2024-12-31"
$result1 = Invoke-TimedRequest -Url $url1 -Description "📊 Generando Reporte de Ventas 2024..."

# ═══════════════════════════════════════════════════════════════════
# TEST 2: Segunda consulta IDÉNTICA (CACHE HIT esperado)
# ═══════════════════════════════════════════════════════════════════

Write-Host "`n╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
Write-Host "║           TEST 2: Segunda Consulta (CACHE HIT)                ║" -ForegroundColor Yellow
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow

Start-Sleep -Seconds 2

$result2 = Invoke-TimedRequest -Url $url1 -Description "📊 Generando el MISMO Reporte de Ventas 2024..."

# ═══════════════════════════════════════════════════════════════════
# TEST 3: Consulta diferente (CACHE MISS esperado)
# ═══════════════════════════════════════════════════════════════════

Write-Host "`n╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
Write-Host "║        TEST 3: Reporte Diferente (CACHE MISS)                 ║" -ForegroundColor Yellow
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow

$url2 = "${endpoint}?type=products"
$result3 = Invoke-TimedRequest -Url $url2 -Description "📦 Generando Reporte de Productos..."

# ═══════════════════════════════════════════════════════════════════
# TEST 4: Verificar caché en Redis directamente
# ═══════════════════════════════════════════════════════════════════

Write-Host "`n╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
Write-Host "║          TEST 4: Inspeccionar Redis Directamente              ║" -ForegroundColor Yellow
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow

Write-Host "`n🔍 Keys almacenados en Redis: 1=SI 0=no" -ForegroundColor Cyan
docker exec -it microservices-redis redis-cli EXISTS "report:sales:2024-01-01:2024-12-31"
# # Write-Host "`n🔍 Keys almacenados en Redis:" -ForegroundColor Cyan
 # $keys = docker exec $ContainerName redis-cli redis KEYS "report:*"
 # if ($keys) {
     # $keys | ForEach-Object {
         # Write-Host "  🔑 $_" -ForegroundColor Green
     # }
 # } else {
     # Write-Host "  ⚠️ No se encontraron keys" -ForegroundColor Yellow
 # }

# Write-Host "`n🔍 TTL del primer reporte:" -ForegroundColor Cyan
# if ($result1.CacheKey) {
    # $ttl = docker exec $ContainerName redis-cli redis TTL "$($result1.CacheKey)"
    # Write-Host "  ⏰ TTL restante: $ttl segundos (de 600)" -ForegroundColor Yellow
# }

# ═══════════════════════════════════════════════════════════════════
# RESUMEN DE RESULTADOS
# ═══════════════════════════════════════════════════════════════════

Write-Host "`n╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║                    RESUMEN DE TESTS                            ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

Write-Host "`n📊 Comparación de Tiempos:" -ForegroundColor Yellow
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Gray

if ($result1.Success -and $result2.Success) {
    Write-Host "`n  Test 1 (CACHE MISS): $($result1.Time) ms" -ForegroundColor Magenta
    Write-Host "  Test 2 (CACHE HIT):  $($result2.Time) ms" -ForegroundColor Green
    
    $improvement = [math]::Round((($result1.Time - $result2.Time) / $result1.Time) * 100, 2)
    Write-Host "`n  🚀 Mejora con caché: $improvement%" -ForegroundColor Yellow
    
    if ($result2.CacheHit) {
        Write-Host "  ✅ Cache funcionando correctamente" -ForegroundColor Green
    } else {
        Write-Host "  ⚠️ Cache no funcionó como esperado" -ForegroundColor Yellow
    }
}

Write-Host "`n📝 Observaciones:" -ForegroundColor Yellow
Write-Host "  • Cache MISS: Primera consulta hace query a SQL Server (~500-1500ms)" -ForegroundColor Gray
Write-Host "  • Cache HIT: Segunda consulta obtiene datos de Redis (~50-200ms)" -ForegroundColor Gray
Write-Host "  • TTL: Los datos expiran después de 10 minutos (600s)" -ForegroundColor Gray
Write-Host "  • Cada combinación type+startDate+endDate tiene su propio cache key" -ForegroundColor Gray

Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "✅ TESTS COMPLETADOS" -ForegroundColor Green
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n" -ForegroundColor Cyan