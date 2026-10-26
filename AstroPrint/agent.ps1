# AstroPrint agent (hasta la version 7 se llamaba AstrobitPrint)
# Responde en 127.0.0.1:9100 (HTTP) y :9101 (HTTPS) con la misma API que Zebra Browser Print
# (/default, /available, /write, /read, /config, /convert) y envía el ZPL en RAW a una cola de
# Windows. /convert recibe las etiquetas que el courier entrega en PDF (la ERP las pasa a JPEG) y
# las imprime como grafico ZPL, asi que tampoco depende del driver de la impresora.
# Lo instala install.ps1 como tarea programada (SYSTEM): arranca con Windows y una vigia lo
# relanza cada minuto si murio. Si los puertos estan tomados, reintenta en vez de salir.

$ErrorActionPreference = 'Continue'
$Root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$CfgPath = Join-Path $Root 'config.json'
$LogPath = Join-Path $Root 'agent.log'
# La ERP lo lee en https://127.0.0.1:9101/ para saber que AstroPrint esta instalado y su version.
$Version = '8.0.0'

function Write-Log([string]$msg) {
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    try {
        if ((Test-Path $LogPath) -and ((Get-Item $LogPath).Length -gt 2MB)) {
            Move-Item $LogPath "$LogPath.old" -Force
        }
        Add-Content -Path $LogPath -Value $line -Encoding UTF8
    } catch { }
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class RawPrinter {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public class DOCINFO {
        [MarshalAs(UnmanagedType.LPWStr)] public string pDocName;
        [MarshalAs(UnmanagedType.LPWStr)] public string pOutputFile;
        [MarshalAs(UnmanagedType.LPWStr)] public string pDataType;
    }

    [DllImport("winspool.drv", EntryPoint = "OpenPrinterW", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool OpenPrinter(string name, out IntPtr h, IntPtr defaults);
    [DllImport("winspool.drv", SetLastError = true)]
    static extern bool ClosePrinter(IntPtr h);
    [DllImport("winspool.drv", EntryPoint = "StartDocPrinterW", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern int StartDocPrinter(IntPtr h, int level, [In] DOCINFO di);
    [DllImport("winspool.drv", SetLastError = true)]
    static extern bool EndDocPrinter(IntPtr h);
    [DllImport("winspool.drv", SetLastError = true)]
    static extern bool StartPagePrinter(IntPtr h);
    [DllImport("winspool.drv", SetLastError = true)]
    static extern bool EndPagePrinter(IntPtr h);
    [DllImport("winspool.drv", SetLastError = true)]
    static extern bool WritePrinter(IntPtr h, IntPtr buf, int count, out int written);

    public static int Send(string printer, byte[] data) {
        IntPtr h;
        if (!OpenPrinter(printer, out h, IntPtr.Zero))
            throw new Exception("OpenPrinter fallo (" + Marshal.GetLastWin32Error() + ") para '" + printer + "'");
        try {
            var di = new DOCINFO { pDocName = "AstroPrint ZPL", pDataType = "RAW" };
            int job = StartDocPrinter(h, 1, di);
            if (job == 0)
                throw new Exception("StartDocPrinter fallo (" + Marshal.GetLastWin32Error() + ")");
            try {
                StartPagePrinter(h);
                IntPtr p = Marshal.AllocCoTaskMem(data.Length);
                try {
                    Marshal.Copy(data, 0, p, data.Length);
                    int written;
                    if (!WritePrinter(h, p, data.Length, out written) || written != data.Length)
                        throw new Exception("WritePrinter fallo (" + Marshal.GetLastWin32Error() + ")");
                } finally { Marshal.FreeCoTaskMem(p); }
                EndPagePrinter(h);
            } finally { EndDocPrinter(h); }
            return job;
        } finally { ClosePrinter(h); }
    }
}
'@

# Estados de la cola o del trabajo en que la etiqueta no va a salir ahora. Si se manda igual,
# queda esperando en Windows: la ERP la da por impresa y sale horas despues, al prender la
# impresora, o repetida si el operario reintento.
$BadState = 'Offline|Paused|Error|Paper|NotAvailable|UserIntervention|DoorOpen|NoToner|OutputBinFull|Blocked'

function Get-PrinterProblem([string]$name) {
    $pr = Get-Printer -Name $name -ErrorAction SilentlyContinue
    if (-not $pr) { return "La impresora '$name' no existe en Windows" }
    if ([string]$pr.PrinterStatus -match $BadState) {
        return "La impresora '$name' esta '$($pr.PrinterStatus)' (apagada o desconectada?)"
    }
    if ($pr.PortName -match '^USB\d+$' -and -not [AstroUtil]::UsbPortPresent($pr.PortName)) {
        return "La impresora '$name' no esta conectada en $($pr.PortName) (apagada o sin cable USB)"
    }
    # Etiquetas nuestras con error o de hace mas de 2 minutos: no estan saliendo. Se borran para
    # que no salgan todas juntas cuando vuelva la impresora. Las recientes sin error se respetan
    # (una tanda grande tarda lo que tarda en imprimirse).
    $stuck = @(Get-PrintJob -PrinterName $name -ErrorAction SilentlyContinue | Where-Object {
        $_.DocumentName -eq 'AstroPrint ZPL' -and
        ([string]$_.JobStatus -match $BadState -or $_.SubmittedTime -lt (Get-Date).AddMinutes(-2))
    })
    if ($stuck.Count) {
        $stuck | ForEach-Object { Remove-PrintJob -InputObject $_ -ErrorAction SilentlyContinue }
        return "Habia $($stuck.Count) etiqueta(s) atascada(s) en '$name'; se borraron. Revisa la impresora."
    }
    return $null
}

function Wait-PrintJob([string]$name, [int]$id) {
    # Hasta 5 s: si sale de la cola, o sigue sin error, va bien. Si Windows lo marca con error,
    # se borra y la ERP recibe el error (ofrece «Ver en PDF»).
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Milliseconds 500
        $job = Get-PrintJob -PrinterName $name -ID $id -ErrorAction SilentlyContinue
        if (-not $job) { return $null }
        if ([string]$job.JobStatus -match $BadState) {
            Remove-PrintJob -InputObject $job -ErrorAction SilentlyContinue
            return "La impresora no recibio la etiqueta ('$($job.JobStatus)'); apagada o sin papel?"
        }
    }
    return $null
}

Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class AstroUtil {
    // Contenido de la parte name="..." de un multipart/form-data, como bytes.
    public static byte[] GetPart(byte[] body, string boundary, string name) {
        byte[] delim = Encoding.ASCII.GetBytes("--" + boundary);
        int pos = IndexOf(body, delim, 0);
        while (pos >= 0) {
            int start = pos + delim.Length + 2;                       // salta el \r\n
            int next = IndexOf(body, delim, start);
            if (next < 0) break;
            int hdrEnd = IndexOf(body, new byte[] { 13, 10, 13, 10 }, start);
            if (hdrEnd > 0 && hdrEnd < next) {
                string hdr = Encoding.UTF8.GetString(body, start, hdrEnd - start);
                // Chrome manda name="blob"; otros clientes, name=blob sin comillas.
                if (System.Text.RegularExpressions.Regex.IsMatch(hdr, "name=\"?" + name + "\"?(;|\\s|$)",
                        System.Text.RegularExpressions.RegexOptions.IgnoreCase)) {
                    int from = hdrEnd + 4, len = next - 2 - from;     // sin el \r\n previo al delimitador
                    byte[] part = new byte[Math.Max(len, 0)];
                    Array.Copy(body, from, part, 0, part.Length);
                    return part;
                }
            }
            pos = next;
        }
        return null;
    }

    static int IndexOf(byte[] hay, byte[] needle, int from) {
        for (int i = Math.Max(from, 0); i <= hay.Length - needle.Length; i++) {
            int j = 0;
            while (j < needle.Length && hay[i + j] == needle[j]) j++;
            if (j == needle.Length) return i;
        }
        return -1;
    }

    // Imagen (JPEG/PNG; o en base64) a una etiqueta ZPL con un ^GFA a tamaño real: un pixel por punto.
    public static string ImageToZpl(byte[] img) {
        bool binary = img.Length > 3 && (img[0] == 0xFF || img[0] == 0x89 || img[0] == (byte)'B' || img[0] == (byte)'G');
        if (!binary) {
            string t = Encoding.ASCII.GetString(img).Trim();
            int comma = t.IndexOf("base64,");
            if (comma >= 0) t = t.Substring(comma + 7);
            img = Convert.FromBase64String(t);
        }
        using (var ms = new MemoryStream(img))
        using (var src = new Bitmap(ms)) {
            int w = src.Width, h = src.Height;
            using (var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb)) {
                using (var g = Graphics.FromImage(bmp)) { g.Clear(Color.White); g.DrawImage(src, 0, 0, w, h); }
                BitmapData data = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
                int[] px = new int[w * h];
                Marshal.Copy(data.Scan0, px, 0, px.Length);
                bmp.UnlockBits(data);

                int bpr = (w + 7) / 8, total = bpr * h;
                const string hex = "0123456789ABCDEF";
                var sb = new StringBuilder(total * 2 + 64);
                sb.Append("^XA^PW").Append(w).Append("^LL").Append(h).Append("^FO0,0^GFA,")
                  .Append(total).Append(',').Append(total).Append(',').Append(bpr).Append(',');
                for (int y = 0; y < h; y++) {
                    for (int bx = 0; bx < bpr; bx++) {
                        int b = 0;
                        for (int bit = 0; bit < 8; bit++) {
                            int x = bx * 8 + bit;
                            b <<= 1;
                            if (x < w) {
                                int c = px[y * w + x];
                                int lum = ((c >> 16) & 255) * 299 + ((c >> 8) & 255) * 587 + (c & 255) * 114;
                                if (lum < 128000) b |= 1;                // oscuro = punto negro
                            }
                        }
                        sb.Append(hex[b >> 4]).Append(hex[b & 15]);
                    }
                }
                sb.Append("^FS^XZ");
                return sb.ToString();
            }
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    struct SP_DEVINFO_DATA { public int cbSize; public Guid ClassGuid; public int DevInst; public IntPtr Reserved; }
    [DllImport("setupapi.dll", EntryPoint = "SetupDiGetClassDevsW", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr SetupDiGetClassDevs(IntPtr classGuid, string enumerator, IntPtr hwnd, int flags);
    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiEnumDeviceInfo(IntPtr set, int index, ref SP_DEVINFO_DATA data);
    [DllImport("setupapi.dll", EntryPoint = "SetupDiGetDeviceInstanceIdW", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool SetupDiGetDeviceInstanceId(IntPtr set, ref SP_DEVINFO_DATA data, StringBuilder id, int size, out int required);
    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);

    // ¿Hay una impresora USB enchufada y prendida en ese puerto (USB001...)? Con la impresora apagada
    // Windows igual acepta el trabajo; asi la ERP recibe el error en el momento.
    public static bool UsbPortPresent(string port) {
        IntPtr set = SetupDiGetClassDevs(IntPtr.Zero, "USBPRINT", IntPtr.Zero, 0x2 | 0x4); // PRESENT | ALLCLASSES
        if (set == new IntPtr(-1)) return true;                       // sin poder saberlo, no bloquear
        try {
            var d = new SP_DEVINFO_DATA();
            d.cbSize = Marshal.SizeOf(typeof(SP_DEVINFO_DATA));
            for (int i = 0; SetupDiEnumDeviceInfo(set, i, ref d); i++) {
                var id = new StringBuilder(512);
                int req;
                if (SetupDiGetDeviceInstanceId(set, ref d, id, id.Capacity, out req) &&
                    id.ToString().EndsWith("&" + port, StringComparison.OrdinalIgnoreCase)) return true;
            }
            return false;
        } finally { SetupDiDestroyDeviceInfoList(set); }
    }
}
'@

function Get-Config {
    try { return Get-Content $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Write-Log "No se pudo leer config.json: $_"; return $null }
}

function New-Device([string]$name) {
    [ordered]@{
        deviceType   = 'printer'
        uid          = $name
        provider     = 'com.zebra.ds.webdriver.desktop.provider.DefaultDeviceProvider'
        name         = $name
        connection   = 'driver'
        version      = 3
        manufacturer = 'Zebra Technologies'
    }
}

function Get-DeviceList($cfg) {
    $names = New-Object System.Collections.Generic.List[string]
    $names.Add([string]$cfg.printer)
    if ($cfg.listAllPrinters) {
        try {
            Get-Printer -ErrorAction Stop | ForEach-Object {
                if (-not $names.Contains($_.Name)) { $names.Add($_.Name) }
            }
        } catch { }
    }
    return @($names | ForEach-Object { New-Device $_ })
}

function Send-Response($ctx, [int]$status, [string]$body, [string]$ctype = 'application/json') {
    $res = $ctx.Response
    $origin = $ctx.Request.Headers['Origin']
    if ($origin) { $res.Headers['Access-Control-Allow-Origin'] = $origin; $res.Headers['Vary'] = 'Origin' }
    else { $res.Headers['Access-Control-Allow-Origin'] = '*' }
    $res.Headers['Access-Control-Allow-Methods'] = 'GET, POST, OPTIONS'
    $res.Headers['Access-Control-Allow-Headers'] = '*'
    $res.Headers['Access-Control-Allow-Private-Network'] = 'true'
    $res.StatusCode = $status
    $res.ContentType = "$ctype; charset=utf-8"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $res.ContentLength64 = $bytes.Length
    try { $res.OutputStream.Write($bytes, 0, $bytes.Length) } catch { }
    try { $res.OutputStream.Close() } catch { }
}

function Read-Body($req) {
    if (-not $req.HasEntityBody) { return '' }
    $sr = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
    try { return $sr.ReadToEnd() } finally { $sr.Close() }
}

function Read-BodyBytes($req) {
    $ms = New-Object System.IO.MemoryStream
    try { $req.InputStream.CopyTo($ms); return $ms.ToArray() } finally { $ms.Dispose() }
}

# Al comienzo de cada etiqueta (despues de cada ^XA):
#  - ^LH0,0^LT0: el origen de la etiqueta. La impresora lo guarda de un trabajo al siguiente. El ZPL
#    de Mercado Libre termina en ^LH0,410, y todo lo que venia despues partia 51 mm mas abajo y se
#    cortaba (visto en la Xprinter de electrolandia).
#  - ^MNY^MMT: etiquetas con separacion y corte a mano; sin ^MNY la Xprinter puede tomar el rollo
#    como continuo. "gapMedia": false en config.json lo saca (rollo continuo de verdad).
#  - ^LL con el largo de la etiqueta si el formato no lo trae (el de Mercado Libre no lo trae).
# Si el ZPL del courier trae sus propios ^LH/^MN, van despues y mandan esos.
function Get-LabelSetup {
    $setup = '^LH0,0^LT0'
    if ((Get-Config).gapMedia -ne $false) { $setup += '^MNY^MMT' }
    return $setup
}

# Largo de la etiqueta en puntos: 150 mm a 203 dpi. "labelLengthDots" en config.json lo cambia.
function Get-LabelLength {
    $l = (Get-Config).labelLengthDots
    if ($l) { return [int]$l } else { return 1199 }
}

# Formatos que solo traen ajustes (Mercado Libre cierra con ^XA^MCY^XZ): la Xprinter puede sacar
# una etiqueta en blanco por cada uno. Solo se descartan si TODOS sus comandos son de esta lista.
$SetupOnly = '^(MC|LH|LT|MN|MM|CI|PO|PM|LR|FW|CF|BY|PR|MD|PW|LL|LS|JM|MT)$'

# Parametro numerico $i de un comando ZPL (0 si falta o no es numero).
function Get-ZplNum([string[]]$params, [int]$i) {
    $v = 0
    if ($params.Count -gt $i) { [void][int]::TryParse(($params[$i] -replace '[^0-9]', ''), [ref]$v) }
    return $v
}

# Lo que baja cada campo de un formato, agrupado por secciones ^LH. Estimacion por lo alto:
# alcanza para decidir si el formato cabe en la etiqueta, no para dibujarlo. PreFields indica
# campos antes del primer ^LH: ese formato no se parte.
function Get-ZplSections([string[]]$tokens) {
    $pre = New-Object System.Collections.ArrayList
    $sections = New-Object System.Collections.ArrayList
    $cur = $null; $preFields = $false
    $fo = $null; $h = 0; $font = 30; $lines = 1; $byH = 10
    foreach ($t in $tokens) {
        $cmd = if ($t.Length -ge 3) { $t.Substring(1, 2).ToUpperInvariant() } else { '' }
        $p = if ($t.Length -gt 3) { $t.Substring(3).Split(',') } else { @() }
        if ($cmd -eq 'LH') {
            $cur = [pscustomobject]@{ X = (Get-ZplNum $p 0); Y = (Get-ZplNum $p 1); Tokens = (New-Object System.Collections.ArrayList); Bottom = 0 }
            [void]$sections.Add($cur); continue
        }
        if ($cur) { [void]$cur.Tokens.Add($t) } else { [void]$pre.Add($t) }
        switch -regex ($cmd) {
            '^(FO|FT)$'      { $fo = Get-ZplNum $p 1; $h = 0; $lines = 1 }
            '^A[0-9A-Z@]$'   { $fh = Get-ZplNum $p 1; if ($fh -gt 0) { $font = $fh } }
            '^CF$'           { $fh = Get-ZplNum $p 1; if ($fh -gt 0) { $font = $fh } }
            '^FB$'           { $lines = [Math]::Max(1, (Get-ZplNum $p 1)) }
            '^GB$'           { $h = [Math]::Max($h, [Math]::Max((Get-ZplNum $p 1), (Get-ZplNum $p 2))) }
            '^GF$'           { $bpr = Get-ZplNum $p 3; if ($bpr -gt 0) { $h = [Math]::Max($h, [int][Math]::Ceiling((Get-ZplNum $p 1) / $bpr)) } }
            '^BY$'           { $bh = Get-ZplNum $p 2; if ($bh -gt 0) { $byH = $bh } }
            '^BQ$'           { $h = [Math]::Max($h, [Math]::Max(1, (Get-ZplNum $p 2)) * 57) }
            '^B[0-9A-PR-XZ]$' { $bh = Get-ZplNum $p 1; $h = [Math]::Max($h, $(if ($bh -gt 0) { $bh } else { $byH })) }
            '^FS$' {
                if ($null -ne $fo) {
                    $bottom = $fo + [Math]::Max($h, $font * $lines)
                    if ($cur) { $cur.Bottom = [Math]::Max($cur.Bottom, $bottom) } else { $preFields = $true }
                }
                $fo = $null; $h = 0; $lines = 1
            }
        }
    }
    return [pscustomobject]@{ Pre = $pre.ToArray(); Sections = $sections.ToArray(); PreFields = $preFields }
}

# Cada formato ^XA...^XZ sale con el ajuste de arriba. Si su contenido no cabe en la etiqueta y
# viene armado en secciones ^LH (el de Mercado Libre con detalle de producto: el detalle arriba y
# el envio desde ^LH0,410, ~187 mm en total), cada grupo de secciones que si cabe sale en su propia
# etiqueta, partiendo arriba. Un formato que cabe, o que no viene en secciones, sale igual que antes.
function Format-Zpl([string]$zpl) {
    $setup = Get-LabelSetup
    $len = Get-LabelLength
    $out = New-Object System.Text.StringBuilder
    $last = 0
    foreach ($m in [regex]::Matches($zpl, '(?is)\^XA(.*?)\^XZ')) {
        [void]$out.Append($zpl.Substring($last, $m.Index - $last)); $last = $m.Index + $m.Length
        $body = $m.Groups[1].Value
        $tokens = @($body -split '(?=[\^~])' | Where-Object { $_ -ne '' })
        $cmds = @($tokens | Where-Object { $_.Length -ge 3 } | ForEach-Object { $_.Substring(1, 2).ToUpperInvariant() })
        if (-not ($cmds | Where-Object { $_ -notmatch $SetupOnly })) { Write-Log "Formato sin contenido omitido: ^XA$body^XZ"; continue }
        $ll = if ($body -match '(?i)\^LL') { '' } else { "^LL$len" }

        $parsed = Get-ZplSections $tokens
        $secs = @($parsed.Sections)
        $fits = -not $secs.Count -or (($secs | ForEach-Object { $_.Y + $_.Bottom } | Measure-Object -Maximum).Maximum -le $len)
        if ($fits -or $secs.Count -lt 2 -or $parsed.PreFields) {
            [void]$out.Append("^XA$setup$ll$body^XZ"); continue
        }

        # Repartir las secciones en etiquetas: se juntan mientras quepan, contando desde la primera.
        $groups = New-Object System.Collections.ArrayList; $g = $null
        foreach ($sec in $secs) {
            if ($g -and ($sec.Y + $sec.Bottom - $g[0].Y) -le $len) { [void]$g.Add($sec) }
            else { $g = New-Object System.Collections.ArrayList; [void]$g.Add($sec); [void]$groups.Add($g) }
        }
        $pre = ($parsed.Pre -join '')
        foreach ($grp in $groups) {
            $part = New-Object System.Text.StringBuilder
            [void]$part.Append("^XA$setup$ll$pre")
            foreach ($sec in $grp) { [void]$part.Append(("^LH{0},{1}" -f $sec.X, ($sec.Y - $grp[0].Y)) + (($sec.Tokens.ToArray()) -join '')) }
            [void]$out.Append($part.Append('^XZ').ToString())
        }
        Write-Log ("Formato de {0} secciones no cabia en {1} puntos: sale en {2} etiquetas" -f $secs.Count, $len, $groups.Count)
    }
    [void]$out.Append($zpl.Substring($last))
    return $out.ToString()
}

function Send-Zpl($ctx, [string]$target, [string]$zpl, [string]$what) {
    try {
        $problem = Get-PrinterProblem $target
        if ($problem) { throw $problem }
        $zpl = Format-Zpl $zpl
        $jobId = [RawPrinter]::Send($target, [System.Text.Encoding]::UTF8.GetBytes($zpl))
        $problem = Wait-PrintJob $target $jobId
        if ($problem) { throw $problem }
        Write-Log ("OK  {0}  {1}  {2} bytes" -f $target, $what, $zpl.Length)
        Send-Response $ctx 200 '' 'text/plain'
    } catch {
        Write-Log ("ERR {0}  {1}  {2}" -f $target, $what, $_.Exception.Message)
        Send-Response $ctx 500 $_.Exception.Message 'text/plain'
    }
}

function Get-ZplFromBody([string]$body) {
    # Browser Print envía JSON {device:{...}, data:"^XA..."}; aceptamos también ZPL plano.
    $t = $body.Trim()
    if ($t.StartsWith('{')) {
        try {
            $obj = $t | ConvertFrom-Json
            return @{ data = [string]$obj.data; deviceName = [string]$obj.device.name }
        } catch { }
    }
    return @{ data = $body; deviceName = $null }
}

function Handle($ctx) {
    $req  = $ctx.Request
    $path = $req.Url.AbsolutePath.Trim('/').ToLowerInvariant()
    if ($req.HttpMethod -eq 'OPTIONS') { Send-Response $ctx 204 ''; return }

    $cfg = Get-Config
    if (-not $cfg) { Send-Response $ctx 500 'config.json invalido' 'text/plain'; return }

    switch ($path) {
        '' {
            Send-Response $ctx 200 (ConvertTo-Json -InputObject ([ordered]@{ status = 'ok'; agent = 'AstroPrint'; version = $Version }) -Compress)
        }
        'default' {
            $dev = New-Device ([string]$cfg.printer)
            if ($req.QueryString['type']) {
                # BrowserPrint.js (la libreria de Zebra) pide ?type=printer y espera JSON.
                Send-Response $ctx 200 (ConvertTo-Json -InputObject $dev -Compress)
            } else {
                # Sin ?type, Browser Print contesta en texto, y la ERP lo lee asi: exige 7 partes
                # separadas por "\n\t" (utils/zebra.js). Con JSON cree que no hay impresora y pasa a PDF.
                $txt = "Device: `n`tName: {0}`n`tType: {1}`n`tConnection: {2}`n`tID: {3}`n`tProvider: {4}`n`tManufacturer: {5}" -f `
                    $dev.name, $dev.deviceType, $dev.connection, $dev.uid, $dev.provider, $dev.manufacturer
                Send-Response $ctx 200 $txt 'text/plain'
            }
        }
        'available' {
            $list = Get-DeviceList $cfg
            Send-Response $ctx 200 (ConvertTo-Json -InputObject ([ordered]@{ printer = $list }) -Depth 4 -Compress)
        }
        'config' {
            $app = [ordered]@{ application = [ordered]@{
                supportedConversions = [ordered]@{}
                version = '1.3.2.489'; build_number = 489; api_level = 2; platform = 'windows'
            } }
            Send-Response $ctx 200 (ConvertTo-Json -InputObject $app -Depth 4 -Compress)
        }
        'write' {
            $p = Get-ZplFromBody (Read-Body $req)
            $target = $p.deviceName
            if (-not $target) { $target = [string]$cfg.printer }
            # Si la ERP manda el nombre de una Zebra que no existe en este PC, usar la configurada.
            if ($target -ne [string]$cfg.printer -and -not (Get-Printer -Name $target -ErrorAction SilentlyContinue)) {
                Write-Log "Impresora '$target' no existe aqui; usando '$($cfg.printer)'"
                $target = [string]$cfg.printer
            }
            Send-Zpl $ctx $target $p.data 'ZPL'
        }
        'convert' {
            # La ERP manda multipart: «json» {device, options:{action:'print', fromFormat:'jpeg'}} y
            # «blob» con la imagen de una pagina de la etiqueta (100x150 mm a 203 dpi).
            $m = [regex]::Match([string]$req.ContentType, 'boundary="?([^";]+)"?')
            if (-not $m.Success) { Send-Response $ctx 400 'falta el boundary del multipart' 'text/plain'; return }
            $body = Read-BodyBytes $req
            $img = [AstroUtil]::GetPart($body, $m.Groups[1].Value, 'blob')
            if (-not $img -or -not $img.Length) { Send-Response $ctx 400 'falta la imagen (blob)' 'text/plain'; return }
            try { $zpl = [AstroUtil]::ImageToZpl($img) }
            catch {
                Write-Log ("ERR convert  imagen ilegible: {0}" -f $_.Exception.Message)
                Send-Response $ctx 400 "imagen ilegible: $($_.Exception.Message)" 'text/plain'; return
            }
            Send-Zpl $ctx ([string]$cfg.printer) $zpl ("imagen {0} bytes" -f $img.Length)
        }
        'read' {
            # Las impresoras por driver no devuelven datos; Browser Print responde vacío igual.
            Send-Response $ctx 200 '' 'text/plain'
        }
        default {
            Send-Response $ctx 404 'not found' 'text/plain'
        }
    }
}

# Una sola instancia: la vigia lo lanza cada minuto y, si ya hay uno vivo, este sale. Si el
# mutex es de SYSTEM y esto corre como usuario, abrirlo falla: tambien significa que hay otro.
try {
    $mutex = New-Object System.Threading.Mutex($false, 'Global\AstroPrintAgent')
    try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
} catch { $owned = $false }
if (-not $owned) { exit 0 }

$prefixes = @('http://127.0.0.1:9100/', 'http://localhost:9100/', 'https://127.0.0.1:9101/', 'https://localhost:9101/')
$lastError = $null
while ($true) {
    $listener = New-Object System.Net.HttpListener
    foreach ($prefix in $prefixes) { $listener.Prefixes.Add($prefix) }
    try {
        $listener.Start()
    } catch {
        # Puertos tomados (Browser Print u otro): reintentar, anotando el error una sola vez.
        if ("$_" -ne $lastError) {
            Write-Log "No se pudo abrir los puertos 9100/9101 (¿Browser Print sigue abierto?): $_ Reintentando cada 10 s."
            $lastError = "$_"
        }
        try { $listener.Close() } catch { }
        Start-Sleep -Seconds 10
        continue
    }
    $lastError = $null
    Write-Log "AstroPrint $Version iniciado. Impresora: $((Get-Config).printer)"

    while ($listener.IsListening) {
        try { $ctx = $listener.GetContext() }
        catch { Write-Log "Se cayo la escucha: $_"; break }
        try { Handle $ctx } catch { Write-Log "Error de solicitud: $_" }
    }
    try { $listener.Close() } catch { }
    Start-Sleep -Seconds 2
}
