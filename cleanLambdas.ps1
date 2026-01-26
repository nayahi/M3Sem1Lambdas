Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║     LIMPIADO EmailBatch.Lambda para redesplegar                ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

cd EmailBatch.Lambda
dotnet clean
Remove-Item -Recurse bin, obj -Force

Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║     LIMPIADO Reports.Lambda para redesplegar                   ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

cd ..\Reports.Lambda
dotnet clean
Remove-Item -Recurse bin, obj -Force

Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║     LIMPIADO ImageProcessor.Lambda para redesplegar            ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

cd ..\ImageProcessor.Lambda
dotnet clean
Remove-Item -Recurse bin, obj -Force

cd ..