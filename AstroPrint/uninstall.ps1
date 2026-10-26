# Desinstala AstroPrint y deja el PC listo para volver a usar Zebra Browser Print. Tambien quita
# AstrobitPrint, su nombre hasta la version 7, si quedo algo.
$Dest = Join-Path $env:ProgramData 'AstroPrint'

foreach ($name in @('AstroPrint', 'AstrobitPrint')) {
    Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
}
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'Astro(bit)?Print\\agent\.ps1' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

& netsh http delete sslcert ipport=0.0.0.0:9101 2>&1 | Out-Null
Get-ChildItem Cert:\LocalMachine\My, Cert:\LocalMachine\Root |
    Where-Object { $_.FriendlyName -in 'AstroPrint', 'AstrobitPrint' } | Remove-Item -ErrorAction SilentlyContinue

# Restaurar Browser Print en el inicio si se habia quitado
foreach ($dir in @($Dest, (Join-Path $env:ProgramData 'AstrobitPrint'))) {
    $bak = Join-Path $dir 'startup-backup'
    if (Test-Path $bak) {
        Get-ChildItem $bak | Move-Item -Destination ([Environment]::GetFolderPath('CommonStartup')) -Force
    }
}

Write-Host 'AstroPrint desinstalado. Reinstala o abre Zebra Browser Print si lo necesitas.' -ForegroundColor Green
Write-Host "Puedes borrar la carpeta $Dest."
