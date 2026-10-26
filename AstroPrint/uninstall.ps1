# Desinstala AstrobitPrint y deja el PC listo para volver a usar Zebra Browser Print
$Dest = Join-Path $env:ProgramData 'AstrobitPrint'

Stop-ScheduledTask -TaskName 'AstrobitPrint' -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName 'AstrobitPrint' -Confirm:$false -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*AstrobitPrint*agent.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

& netsh http delete sslcert ipport=0.0.0.0:9101 2>&1 | Out-Null
Get-ChildItem Cert:\LocalMachine\My, Cert:\LocalMachine\Root |
    Where-Object { $_.FriendlyName -eq 'AstrobitPrint' } | Remove-Item -ErrorAction SilentlyContinue

# Restaurar Browser Print en el inicio si se habia quitado
$bak = Join-Path $Dest 'startup-backup'
if (Test-Path $bak) {
    Get-ChildItem $bak | Move-Item -Destination ([Environment]::GetFolderPath('CommonStartup')) -Force
}

Write-Host 'AstrobitPrint desinstalado. Reinstala o abre Zebra Browser Print si lo necesitas.' -ForegroundColor Green
Write-Host "Puedes borrar la carpeta $Dest."
