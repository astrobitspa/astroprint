# Instalador de AstroPrint (ejecutar como administrador; install.bat lo hace solo)
# Sin preguntas: install.ps1 -Printer "Xprinter XP-420B" -KeepAwake S
param([string]$Printer, [ValidateSet('S', 'N', '')][string]$KeepAwake = '')
$ErrorActionPreference = 'Stop'
$Src       = Split-Path -Parent $MyInvocation.MyCommand.Path
$Dest      = Join-Path $env:ProgramData 'AstroPrint'
$TaskName  = 'AstroPrint'
$AppId     = '{6f4b1c2e-8a3d-4e5f-9b7a-1c2d3e4f5a6b}'
# Hasta la version 7 se llamaba AstrobitPrint: se reemplaza conservando su configuracion.
$OldName   = 'AstrobitPrint'
$OldDest   = Join-Path $env:ProgramData $OldName

# La configuracion de una instalacion anterior (gapMedia, labelLengthDots...) se conserva.
$prevCfg = $null
foreach ($dir in @($Dest, $OldDest)) {
    $f = Join-Path $dir 'config.json'
    if (-not $prevCfg -and (Test-Path $f)) {
        try { $prevCfg = Get-Content $f -Raw | ConvertFrom-Json } catch { }
    }
}

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }

# 1. Elegir impresora
Step 'Impresoras instaladas en este PC'
$printers = @(Get-Printer | Sort-Object Name)
if ($printers.Count -eq 0) { throw 'No hay impresoras instaladas en Windows.' }
for ($i = 0; $i -lt $printers.Count; $i++) {
    Write-Host ("  [{0}] {1}   ({2})" -f ($i + 1), $printers[$i].Name, $printers[$i].DriverName)
}
if ($Printer) {
    if (-not ($printers | Where-Object Name -eq $Printer)) { throw "No existe la impresora '$Printer'." }
    $printerName = $Printer
} else {
    $keep = $null
    if ($prevCfg -and ($printers | Where-Object Name -eq $prevCfg.printer)) { $keep = [string]$prevCfg.printer }
    $hint = ''
    if ($keep) { $hint = " (Enter: seguir con '$keep')" }
    $printerName = $null
    do {
        $sel = Read-Host "Numero de la impresora de etiquetas$hint"
        if (-not $sel -and $keep) { $printerName = $keep; break }
        $n = 0
        $ok = [int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le $printers.Count
    } until ($ok)
    if (-not $printerName) { $printerName = $printers[$n - 1].Name }
}
Write-Host "Seleccionada: $printerName" -ForegroundColor Green

# 2. Liberar puertos 9100/9101 (Zebra Browser Print, Text2Barcode u otro agente)
Step 'Revisando programas que usan los puertos 9100/9101'
# Un agente anterior escucha via http.sys, que figura como PID 4 y no lo encuentra el filtro de
# abajo: hay que detenerlo por su linea de comando, o el nuevo no puede abrir los puertos.
foreach ($name in @($TaskName, $OldName)) {
    Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
}
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'Astro(bit)?Print\\agent\.ps1' } |
    ForEach-Object { Write-Host "Deteniendo agente anterior (PID $($_.ProcessId))"; Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2
$owners = Get-NetTCPConnection -LocalPort 9100, 9101 -State Listen -ErrorAction SilentlyContinue |
          Select-Object -ExpandProperty OwningProcess -Unique | Where-Object { $_ -gt 4 }
foreach ($procId in $owners) {
    $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if ($p) {
        $ans = Read-Host ("'{0}' esta usando los puertos. ¿Cerrarlo? (S/N)" -f $p.ProcessName)
        if ($ans -match '^[sS]') { Stop-Process -Id $procId -Force }
        else { throw 'Cierra ese programa y vuelve a ejecutar el instalador.' }
    }
}
# Quitar Browser Print del inicio automatico (se guarda respaldo)
$startupDirs = @([Environment]::GetFolderPath('CommonStartup'), [Environment]::GetFolderPath('Startup'))
foreach ($d in $startupDirs) {
    Get-ChildItem $d -Filter '*Browser Print*' -ErrorAction SilentlyContinue | ForEach-Object {
        $bak = Join-Path $Dest 'startup-backup'
        New-Item -ItemType Directory -Force -Path $bak | Out-Null
        Move-Item $_.FullName $bak -Force
        Write-Host "Quitado del inicio: $($_.Name) (respaldo en $bak)"
    }
}

# 3. Copiar archivos y configuracion
Step "Copiando archivos a $Dest"
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
Copy-Item (Join-Path $Src 'agent.ps1') $Dest -Force
Copy-Item (Join-Path $Src 'uninstall.ps1') $Dest -Force -ErrorAction SilentlyContinue
$cfg = [ordered]@{ printer = $printerName; listAllPrinters = $false }
if ($prevCfg) {
    foreach ($p in $prevCfg.PSObject.Properties) { if ($p.Name -ne 'printer') { $cfg[$p.Name] = $p.Value } }
}
ConvertTo-Json -InputObject $cfg | Set-Content (Join-Path $Dest 'config.json') -Encoding UTF8
# AstrobitPrint: su respaldo del inicio pasa a la carpeta nueva (uninstall lo restaura desde ahi)
if (Test-Path $OldDest) {
    $oldBak = Join-Path $OldDest 'startup-backup'
    if (Test-Path $oldBak) {
        $bak = Join-Path $Dest 'startup-backup'
        New-Item -ItemType Directory -Force -Path $bak | Out-Null
        Get-ChildItem $oldBak | Move-Item -Destination $bak -Force
    }
    Remove-Item $OldDest -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Reemplazado AstrobitPrint ($OldDest)"
}

# 4. Certificado HTTPS local (la ERP corre en https y llama a https://127.0.0.1:9101)
Step 'Creando certificado local para HTTPS'
Get-ChildItem Cert:\LocalMachine\My, Cert:\LocalMachine\Root |
    Where-Object { $_.FriendlyName -in 'AstroPrint', $OldName } | Remove-Item -ErrorAction SilentlyContinue
$cert = New-SelfSignedCertificate -Subject 'CN=localhost' -FriendlyName 'AstroPrint' `
    -CertStoreLocation Cert:\LocalMachine\My -NotAfter (Get-Date).AddYears(10) `
    -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 -KeyExportPolicy NonExportable `
    -TextExtension @('2.5.29.17={text}DNS=localhost&IPAddress=127.0.0.1', '2.5.29.37={text}1.3.6.1.5.5.7.3.1')
$cer = Join-Path $env:TEMP 'astroprint.cer'
Export-Certificate -Cert $cert -FilePath $cer | Out-Null
Import-Certificate -FilePath $cer -CertStoreLocation Cert:\LocalMachine\Root | ForEach-Object { $_.FriendlyName = 'AstroPrint' }
Remove-Item $cer -Force

& netsh http delete sslcert ipport=0.0.0.0:9101 2>&1 | Out-Null
$r = & netsh http add sslcert ipport=0.0.0.0:9101 certhash=$($cert.Thumbprint) appid=$AppId certstorename=MY
if ($LASTEXITCODE -ne 0) { throw "No se pudo asociar el certificado al puerto 9101: $r" }

# 5. Tarea programada como SYSTEM: arranca con Windows y una vigia la lanza cada minuto. Si el
#    agente esta vivo, la vigia no hace nada (IgnoreNew + mutex del agente); si murio, vuelve.
#    «Reiniciar si falla» de Windows no sirve para esto: no relanza un proceso que termino.
Step 'Registrando el agente para que arranque con Windows'
$agent   = Join-Path $Dest 'agent.ps1'
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
           -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$agent`""
$every   = (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1)).Repetition
$boot    = New-ScheduledTaskTrigger -AtStartup
$boot.Repetition = $every
$watch   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1)
$watch.Repetition = $every
$princ   = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$set     = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
           -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
           -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($boot, $watch) -Principal $princ -Settings $set -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName

# 5b. Un PC de bodega que se suspende deja de imprimir hasta que alguien lo despierte
if (-not $KeepAwake) { $KeepAwake = Read-Host '¿Evitar que este PC se suspenda o hiberne enchufado? (S/N)' }
if ($KeepAwake -match '^[sS]') {
    & powercfg /change standby-timeout-ac 0
    & powercfg /change hibernate-timeout-ac 0
    Write-Host 'Listo: enchufado, el PC no se suspende (la pantalla si se puede apagar).'
}

# 6. Prueba
Step 'Probando el agente'
# Windows puede dejar la tarea «en cola» hasta un par de minutos antes de lanzarla (visto al
# instalar en un notebook), y el agente compila su parte en C# al arrancar: esperar hasta 3 min.
Write-Host 'Esperando que Windows arranque el agente (puede tardar hasta 3 minutos)...'
$d = $null; $t = $null
for ($i = 0; $i -lt 90 -and -not $d; $i++) {
    Start-Sleep -Seconds 2
    try {
        $d = Invoke-RestMethod -Uri 'https://127.0.0.1:9101/default?type=printer' -TimeoutSec 5
        # Sin ?type la ERP espera el texto de Browser Print; si llega JSON responde un agente antiguo.
        $t = (Invoke-WebRequest -UseBasicParsing -Uri 'https://127.0.0.1:9101/default' -TimeoutSec 5).Content
    } catch { $d = $null }
}
if (-not $d) {
    Write-Host "El agente no respondio. Revisa $Dest\agent.log" -ForegroundColor Red
    throw 'El agente no respondio en 3 minutos.'
}
if (-not $t.StartsWith('Device:')) { throw 'Sigue respondiendo un agente antiguo. Reinicia el PC.' }
Write-Host "OK: el agente responde en HTTPS con la impresora '$($d.name)'." -ForegroundColor Green

Write-Host "`nListo. Cierra y vuelve a abrir el navegador, entra a la ERP e imprime una etiqueta de prueba." -ForegroundColor Green
