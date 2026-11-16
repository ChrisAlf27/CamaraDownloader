# Cámara Downloader - copia rapida de GoPro / Insta360 / cualquier carpeta al disco,
# organizando los archivos en carpetas por fecha de grabacion.
# Soporta camara por USB (MTP), camara/tarjeta montada como unidad, o una carpeta elegida.
# La copia corre en un hilo aparte para que la ventana nunca se congele.

$AppName    = 'Cámara Downloader'
$AppVersion = '2.0.0'
$UpdateRepo = 'ChrisAlf27/CamaraDownloader'
$SetupAsset = 'CamaraDownloader-Setup.exe'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$AppDir      = $PSScriptRoot
$IsInstalled = Test-Path (Join-Path $AppDir 'CamaraDownloader.exe')   # solo la version instalada se auto-actualiza

# ============================================================ configuracion guardada
$SettingsDir  = Join-Path $env:APPDATA 'CamaraDownloader'
$SettingsFile = Join-Path $SettingsDir 'settings.json'
$Videos = [Environment]::GetFolderPath('MyVideos')
$DeviceTypes = @('GoPro', 'Insta360', 'Folder')
$Settings = @{
    Device = 'GoPro'; SourceFolder = ''; IncludeSidecar = $false
    Dest = @{
        # G:\GoPro era el destino fijo de la version anterior: si existe, se respeta
        GoPro    = if (Test-Path -LiteralPath 'G:\GoPro') { 'G:\GoPro' } else { Join-Path $Videos 'GoPro' }
        Insta360 = Join-Path $Videos 'Insta360'
        Folder   = Join-Path $Videos 'Cámara Downloader'
    }
}
try {
    if (Test-Path -LiteralPath $SettingsFile) {
        $j = Get-Content -LiteralPath $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($DeviceTypes -contains $j.Device) { $Settings.Device = [string]$j.Device }
        if ($j.SourceFolder) { $Settings.SourceFolder = [string]$j.SourceFolder }
        $Settings.IncludeSidecar = [bool]$j.IncludeSidecar
        foreach ($k in $DeviceTypes) { if ($j.Dest.$k) { $Settings.Dest[$k] = [string]$j.Dest.$k } }
    }
} catch {}

function Save-Settings {
    try {
        New-Item -ItemType Directory -Force -Path $SettingsDir | Out-Null
        $Settings | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $SettingsFile -Encoding UTF8
    } catch {}
}

# ============================================================ codigo compartido
# Se carga en la ventana y en el hilo de copia.
$CoreCode = @'
$ErrorActionPreference = 'Stop'
$SidecarExt = @('.LRV', '.THM')   # proxies / miniaturas (GoPro e Insta360)
$SkipNames  = @('Thumbs.db', 'desktop.ini', '.DS_Store', 'fileinfo_list.list')
$StageName  = '_copiando'         # carpeta temporal dentro del destino (copias a medio hacer)
$script:Shell = New-Object -ComObject Shell.Application

function Format-Size([double]$b) {
    if ($b -ge 1GB) { return '{0:N2} GB' -f ($b / 1GB) }
    if ($b -ge 1MB) { return '{0:N1} MB' -f ($b / 1MB) }
    if ($b -ge 1KB) { return '{0:N0} KB' -f ($b / 1KB) }
    return "$b B"
}

# Clave para relacionar un video con sus LRV/THM:
#   GoPro:    GX010123.MP4 / GL010123.LRV / GX010123.THM          -> 010123
#   Insta360: VID_20261116_101500_00_001.insv / LRV_..._11_001.lrv -> I20261116_101500_001
function Get-MediaKey([string]$name) {
    $base = [IO.Path]::GetFileNameWithoutExtension($name).ToUpper()
    if ($base -match '^(?:PRO_)?(?:VID|LRV|IMG)_(\d{8}_\d{6})_\d{2}_(\d+)$') { return "I$($Matches[1])_$($Matches[2])" }
    if ($base -match '^G[A-Z]\d{6}$') { return $base.Substring(2) }
    return $base
}

# Fecha escrita en el nombre (Insta360, celulares): ..._20261116_101500_...
function Get-NameDate([string]$name) {
    if ($name -match '(?<!\d)(20\d{6})[_-]?(\d{6})(?!\d)') {
        $d = [datetime]::MinValue
        if ([datetime]::TryParseExact($Matches[1] + $Matches[2], 'yyyyMMddHHmmss', $null, 'None', [ref]$d) -and (Test-GoodDate $d)) { return $d }
    }
    return $null
}

# Nombre REAL con extension (FolderItem.Name puede venir sin extension
# si Windows tiene "ocultar extensiones" activado)
function Get-ItemFileName($item) {
    try { $n = [string]$item.ExtendedProperty('System.FileName'); if ($n -and [IO.Path]::GetExtension($n)) { return $n } } catch {}
    $n = [string]$item.Name
    if (-not [IO.Path]::GetExtension($n)) {
        try { $e = [string]$item.ExtendedProperty('System.FileExtension'); if ($e) { return $n + $e } } catch {}
    }
    return $n
}

function Get-MtpSize($item) {
    try { $s = $item.ExtendedProperty('System.Size'); if ($s) { return [int64]$s } } catch {}
    try { if ($item.Size -gt 0) { return [int64]$item.Size } } catch {}
    return [int64]0
}

# Fecha valida = posterior a 2000 (MTP devuelve 1899-12-30 cuando no tiene el dato)
function Test-GoodDate($d) { return ($d -is [datetime]) -and $d.Year -ge 2000 -and $d -le (Get-Date).AddDays(2) }

function Get-MtpDate($item, $folder) {
    # 1) Propiedades del sistema (vienen en UTC)
    foreach ($p in 'System.DateModified', 'System.DateCreated', 'System.Media.DateEncoded', 'System.Photo.DateTaken', 'System.ItemDate', 'System.DateAcquired') {
        try {
            $d = $item.ExtendedProperty($p)
            if ($d) { $d = [datetime]$d; if (Test-GoodDate $d) { return [datetime]::SpecifyKind($d, 'Utc').ToLocalTime() } }
        } catch {}
    }
    # 2) Columnas de fecha que muestra el Explorador (hora local, texto)
    if ($folder) {
        if (-not $script:DateCols) {
            $script:DateCols = @()
            for ($c = 0; $c -lt 320; $c++) {
                $h = [string]$folder.GetDetailsOf($null, $c)
                if ($h -match 'fecha|date|creado|modific|created|modified|taken|tomada|codific|encoded') { $script:DateCols += $c }
            }
        }
        foreach ($c in $script:DateCols) {
            $txt = ([string]$folder.GetDetailsOf($item, $c)) -replace '[\u200e\u200f\u202a\u202c]', ''
            if (-not $txt.Trim()) { continue }
            $d = [datetime]::MinValue
            if ([datetime]::TryParse($txt, [Globalization.CultureInfo]::CurrentCulture, 'AllowWhiteSpaces', [ref]$d) -and (Test-GoodDate $d)) { return $d }
        }
    }
    # 3) Propiedad directa
    try { $d = [datetime]$item.ModifyDate; if (Test-GoodDate $d) { return $d } } catch {}
    return $null
}

function Find-ShellDcim($folder, [int]$depth) {
    if ($depth -gt 3 -or $null -eq $folder) { return $null }
    foreach ($it in $folder.Items()) { if ($it.IsFolder -and $it.Name -eq 'DCIM') { return $it.GetFolder } }
    foreach ($it in $folder.Items()) {
        if (-not $it.IsFolder) { continue }
        $r = Find-ShellDcim $it.GetFolder ($depth + 1)
        if ($r) { return $r }
    }
    return $null
}

function Get-CameraType([string]$name) {
    if ($name -match 'Insta ?360') { return 'Insta360' }
    if ($name -match 'GoPro|HERO|MAX') { return 'GoPro' }
    return $null
}

# Devuelve todas las camaras conectadas: @{ Type; Mode (Drive|MTP); Name; Folders }
function Find-Cameras {
    $found = New-Object System.Collections.ArrayList
    # 1) Tarjeta SD en lector o camara montada como unidad (lo mas rapido)
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        if ('Removable', 'Fixed' -notcontains [string]$d.DriveType) { continue }
        try { if (-not $d.IsReady) { continue } } catch { continue }
        $dcim = Join-Path $d.RootDirectory.FullName 'DCIM'
        if (-not (Test-Path -LiteralPath $dcim)) { continue }
        $subs  = @(Get-ChildItem -LiteralPath $dcim -Directory -ErrorAction SilentlyContinue)
        $label = ("Unidad $($d.Name.TrimEnd('\')) $($d.VolumeLabel)").Trim()
        $gp = @($subs | Where-Object { $_.Name -match 'GOPRO' })
        if ($gp.Count) { [void]$found.Add(@{ Type = 'GoPro'; Mode = 'Drive'; Name = $label; Folders = $gp }) }
        $in = @($subs | Where-Object { $_.Name -match '^Camera\d+$' })
        if ($in.Count) { [void]$found.Add(@{ Type = 'Insta360'; Mode = 'Drive'; Name = $label; Folders = $in }) }
    }
    # 2) Camara por USB (MTP), aparece en "Este equipo"
    foreach ($dev in $script:Shell.NameSpace(17).Items()) {
        if ($dev.IsFileSystem) { continue }   # las unidades con letra ya se revisaron arriba
        $t = Get-CameraType $dev.Name
        if (-not $t) { continue }
        $dcim = Find-ShellDcim $dev.GetFolder 0
        if ($dcim) { [void]$found.Add(@{ Type = $t; Mode = 'MTP'; Name = $dev.Name; Folders = @($dcim.Items() | Where-Object { $_.IsFolder }) }) }
    }
    return $found.ToArray()
}

# Origen a descargar segun el tipo elegido (camara detectada o carpeta)
function Find-Source([string]$type, [string]$folder) {
    if ($type -eq 'Folder') {
        if (-not $folder -or -not (Test-Path -LiteralPath $folder -PathType Container)) { return $null }
        $fi = Get-Item -LiteralPath $folder
        return @{ Type = 'Folder'; Mode = 'Drive'; Name = $fi.FullName; Folders = @($fi); Recurse = $true }
    }
    return @(Find-Cameras) | Where-Object { $_.Type -eq $type } | Select-Object -First 1
}

# Lista: Name, Size, Date, Folder, Ref (FileInfo o FolderItem), Sidecar
function Get-SourceFiles($src) {
    $list = New-Object System.Collections.ArrayList
    foreach ($f in $src.Folders) {
        if ($src.Mode -eq 'Drive') {
            $rootLen = $f.FullName.TrimEnd('\').Length
            $items = if ($src.Recurse) { Get-ChildItem -LiteralPath $f.FullName -File -Recurse -ErrorAction SilentlyContinue }
                     else { Get-ChildItem -LiteralPath $f.FullName -File }
            foreach ($fi in $items) {
                if ($SkipNames -contains $fi.Name) { continue }
                $folderKey = $f.Name
                if ($src.Recurse) { $folderKey = $fi.DirectoryName.Substring([Math]::Min($rootLen, $fi.DirectoryName.Length)).Trim('\'); if (-not $folderKey) { $folderKey = '.' } }
                $date = Get-NameDate $fi.Name; if (-not $date) { $date = $fi.LastWriteTime }
                [void]$list.Add([pscustomobject]@{ Name = $fi.Name; Size = [int64]$fi.Length; Date = $date
                    Folder = $folderKey; Ref = $fi; Sidecar = ($SidecarExt -contains $fi.Extension.ToUpper()) })
            }
        } else {
            $sf = $f.GetFolder
            foreach ($it in $sf.Items()) {
                if ($it.IsFolder) { continue }
                $name = Get-ItemFileName $it
                if ($SkipNames -contains $name) { continue }
                $date = Get-NameDate $name; if (-not $date) { $date = Get-MtpDate $it $sf }
                [void]$list.Add([pscustomobject]@{ Name = $name; Size = (Get-MtpSize $it); Date = $date
                    Folder = $f.Name; Ref = $it; Sidecar = ($SidecarExt -contains [IO.Path]::GetExtension($name).ToUpper()) })
            }
        }
    }
    return $list
}
'@

# ============================================================ hilo de copia
$WorkerCode = @'
param($sync, $destRoot, $includeSidecar, $coreCode, $type, $srcFolder)
. ([scriptblock]::Create($coreCode))
function Log([string]$m) { $sync.Log.Enqueue(('[{0:HH:mm:ss}] {1}' -f (Get-Date), $m)) }

function Test-FileUnlocked([string]$p) {
    try { $fs = [IO.File]::Open($p, 'Open', 'Read', 'None'); $fs.Close(); return $true } catch { return $false }
}

# Busca el archivo copiado aunque Windows lo haya escrito con otro nombre/extension
function Resolve-Dest([string]$dir, [string]$name) {
    $p = Join-Path $dir $name
    if (Test-Path -LiteralPath $p) { return $p }
    $base = [IO.Path]::GetFileNameWithoutExtension($name)
    $m = Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
         Where-Object { $_.BaseName -eq $base -or $_.Name -eq $base } | Select-Object -First 1
    if ($m) { return $m.FullName }
    return $null
}

# Copia a "archivo.part" y renombra al terminar: en el destino nunca queda un archivo a medias
function Copy-DriveFile($file, [string]$dest) {
    $part = "$dest.part"
    $buf = New-Object byte[] (8MB)
    $in = [IO.File]::OpenRead($file.Ref.FullName); $out = [IO.File]::Create($part)
    try {
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $out.Write($buf, 0, $n); $sync.Done += $n
            if ($sync.Cancel) { throw 'Cancelado' }
        }
    } finally { $in.Close(); $out.Close() }
    return $part
}

# MTP: Windows copia a una carpeta temporal (con el nombre original) y despues se mueve
function Copy-MtpFile($file, [string]$stage) {
    $start = $sync.Done
    $script:Shell.NameSpace($stage).CopyHere($file.Ref, 1556)   # sin dialogos
    $last = [int64]-1; $lastChange = Get-Date; $stable = $null
    while ($true) {
        Start-Sleep -Milliseconds 250
        $real = Resolve-Dest $stage $file.Name
        $len = if ($real) { ([IO.FileInfo]::new($real)).Length } else { [int64]0 }
        if ($len -ne $last) { $last = $len; $lastChange = Get-Date; $stable = $null; $sync.Done = $start + $len }
        if ($real -and $len -gt 0) {
            if ($file.Size -gt 0) { if ($len -ge $file.Size -and (Test-FileUnlocked $real)) { return $real } }
            else {
                if (-not $stable) { $stable = Get-Date }
                if (((Get-Date) - $stable).TotalSeconds -ge 3 -and (Test-FileUnlocked $real)) { return $real }
            }
        }
        if ($sync.Cancel -and ((Get-Date) - $lastChange).TotalSeconds -gt 5) { throw 'Cancelado' }
        if (((Get-Date) - $lastChange).TotalSeconds -gt 300) { throw 'La copia no avanza (5 min sin datos)' }
    }
}

$stage = Join-Path $destRoot $StageName
try {
    $src = Find-Source $type $srcFolder
    if (-not $src) { throw "No se encontro el origen ($type)." }
    Log "Leyendo archivos de $($src.Name)..."
    $files = @(Get-SourceFiles $src | Where-Object { $includeSidecar -or -not $_.Sidecar } | Sort-Object Date, Name)
    $noDate = @($files | Where-Object { -not $_.Date }).Count
    if ($noDate -gt 0) { Log "Atencion: $noDate archivos sin fecha legible, van a la carpeta 'Sin fecha'." }

    New-Item -ItemType Directory -Force -Path $destRoot | Out-Null
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }

    # Indice de lo que ya hay en el destino (nombre+tamano) para no recopiar.
    # "foto (2).jpg" tambien cuenta como "foto.jpg" (renombrada por coincidir con otro archivo).
    # Los ".part" son restos de una copia cortada (app cerrada a la mitad): se borran.
    $existing = @{}
    Get-ChildItem -LiteralPath $destRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notlike (Join-Path $destRoot 'App\*') } |
        ForEach-Object {
            if ($_.Extension -eq '.part' -and $_.Directory.Name -match '^\d{4}-\d{2}-\d{2}$|^Sin fecha$') { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue; return }
            $existing["$($_.Name.ToUpper())|$($_.Length)"] = $_.FullName
            if ($_.BaseName -match '^(.*) \(\d+\)$') { $existing["$($Matches[1].ToUpper())$($_.Extension.ToUpper())|$($_.Length)"] = $_.FullName }
        }

    $todo = New-Object System.Collections.ArrayList; $planned = @{}; $skipped = 0; $moved = 0
    foreach ($f in $files) {
        $folderName = if ($f.Date) { $f.Date.ToString('yyyy-MM-dd') } else { 'Sin fecha' }
        $dir = Join-Path $destRoot $folderName
        $dest = Join-Path $dir $f.Name
        $prev = if ($f.Size -gt 0) { $existing["$($f.Name.ToUpper())|$($f.Size)"] } else { $null }
        if ($prev) {
            $prevDir = Split-Path $prev -Parent
            if ($prevDir -ne $dir -and (Split-Path $prevDir -Leaf) -match '^1899-12-30$|^Sin fecha$') {
                # ya copiado pero con fecha erronea: se mueve a la carpeta correcta
                New-Item -ItemType Directory -Force -Path $dir | Out-Null
                if (-not (Test-Path -LiteralPath $dest)) {
                    Move-Item -LiteralPath $prev -Destination $dest; $moved++
                    if ($f.Date) { [IO.File]::SetLastWriteTime($dest, $f.Date); [IO.File]::SetCreationTime($dest, $f.Date) }
                }
            }
            $skipped++; [void]$sync.Copied.Add("$($f.Folder)\$($f.Name)"); continue
        }
        # Si ya existe otro archivo distinto con el mismo nombre, no se pisa: "nombre (2).ext"
        $n = 1
        while ($planned.ContainsKey($dest.ToUpper()) -or (Test-Path -LiteralPath $dest)) {
            $n++; $dest = Join-Path $dir ('{0} ({1}){2}' -f [IO.Path]::GetFileNameWithoutExtension($f.Name), $n, [IO.Path]::GetExtension($f.Name))
        }
        $planned[$dest.ToUpper()] = $true
        [void]$todo.Add([pscustomobject]@{ File = $f; Dir = $dir; Dest = $dest })
    }
    $sync.Total = [int64](($todo | ForEach-Object { $_.File.Size } | Measure-Object -Sum).Sum)
    # Limpia carpetas que quedaron vacias (ej. 1899-12-30)
    Get-ChildItem -LiteralPath $destRoot -Directory | Where-Object { $_.Name -ne 'App' -and -not (Get-ChildItem -LiteralPath $_.FullName -Force) } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
    if ($moved -gt 0) { Log "$moved archivos ya copiados se movieron a su carpeta de fecha correcta." }
    Log ('{0} archivos en el origen, {1} ya estaban copiados, {2} nuevos ({3}).' -f $files.Count, $skipped, $todo.Count, (Format-Size $sync.Total))
    $sync.Started = Get-Date

    $i = 0
    foreach ($t in $todo) {
        if ($sync.Cancel) { Log 'Cancelado por el usuario.'; break }
        $i++
        $sync.File = "($i/$($todo.Count))  $($t.File.Name)  -  $(Format-Size $t.File.Size)"
        $before = $sync.Done
        $tmp = $null
        try {
            New-Item -ItemType Directory -Force -Path $t.Dir | Out-Null
            if ($src.Mode -eq 'Drive') { $tmp = Copy-DriveFile $t.File $t.Dest }
            else {
                if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
                (New-Item -ItemType Directory -Force -Path $stage).Attributes = 'Directory, Hidden'
                $tmp = Copy-MtpFile $t.File $stage
            }
            $len = ([IO.FileInfo]::new($tmp)).Length
            if ($t.File.Size -gt 0 -and $len -ne $t.File.Size) { throw "tamano distinto ($len vs $($t.File.Size))" }
            Move-Item -LiteralPath $tmp -Destination $t.Dest; $tmp = $null
            if ($t.File.Date) { [IO.File]::SetLastWriteTime($t.Dest, $t.File.Date); [IO.File]::SetCreationTime($t.Dest, $t.File.Date) }
            $sync.Done = $before + [Math]::Max($t.File.Size, $len)
            [void]$sync.Copied.Add("$($t.File.Folder)\$($t.File.Name)")
            Log "OK  $($t.File.Name)  ->  $($t.Dest)"
        } catch {
            $sync.Errors++
            $sync.Done = $before + $t.File.Size
            if ("$_" -eq 'Cancelado') { Log "Cancelado: $($t.File.Name) (no se guardo)" }
            else { Log "ERROR  $($t.File.Name): $_" }
            if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        }
    }
    $sync.File = "Listo: $($i - $sync.Errors) copiados, $($sync.Errors) con error."
} catch {
    $sync.Errors++
    Log "ERROR: $_"
} finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    $sync.Finished = $true
}
'@

# ============================================================ actualizaciones (GitHub Releases)
$UpdateCheckCode = @'
param($sync, $repo, $assetName)
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'CamaraDownloader' } -TimeoutSec 15
    $asset = @($rel.assets) | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
    if ($asset) { $sync.Version = ([string]$rel.tag_name).TrimStart('v', 'V'); $sync.Url = [string]$asset.browser_download_url }
} catch { $sync.Error = "$_" }
finally { $sync.Done = $true }
'@

$UpdateDownloadCode = @'
param($sync)
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add('User-Agent', 'CamaraDownloader')
    $wc.DownloadFile($sync.Url, $sync.File)
} catch { $sync.Error = "$_" }
finally { $sync.Done = $true }
'@

# ============================================================ ventana
. ([scriptblock]::Create($CoreCode))
$script:Cameras = @()
$script:Device  = $Settings.Device
$script:Sync    = $null
$script:PS      = $null
$script:Upd     = $null
$script:Updating = $false
$script:Loading = $true

function Write-Log([string]$msg) {
    $txtLog.AppendText(('[{0:HH:mm:ss}] {1}' -f (Get-Date), $msg) + [Environment]::NewLine)
}

function Set-Status([string]$text, [string]$color) { $lblDevice.Text = $text; $lblDevice.ForeColor = $color }

function Set-Busy([bool]$b) {
    foreach ($c in @($btnDownload, $btnDetect, $btnBrowse, $chkSidecar, $txtDest, $rbGoPro, $rbInsta, $rbFolder)) { $c.Enabled = -not $b }
    $btnSrc.Enabled = (-not $b) -and $script:Device -eq 'Folder'
    $txtSrc.Enabled = -not $b
    $btnCancel.Enabled = $b
}

function Update-Status {
    $t = $script:Device
    if ($t -eq 'Folder') {
        $p = $txtSrc.Text.Trim()
        if (-not $p) { Set-Status 'Elegí la carpeta de origen con "Elegir..."' 'DimGray' }
        elseif (Test-Path -LiteralPath $p -PathType Container) { Set-Status 'Carpeta de origen lista' 'ForestGreen' }
        else { Set-Status 'La carpeta de origen no existe' 'Firebrick' }
        return
    }
    $cam = $script:Cameras | Where-Object { $_.Type -eq $t } | Select-Object -First 1
    if ($cam) {
        $mode = if ($cam.Mode -eq 'MTP') { 'USB' } else { 'unidad / lector SD' }
        Set-Status "Conectada: $($cam.Name)  ($mode)" 'ForestGreen'
        $txtSrc.Text = "$($cam.Name)  -  DCIM\" + (($cam.Folders | ForEach-Object { $_.Name }) -join ', ')
    } else {
        $txtSrc.Text = ''
        if ($t -eq 'GoPro') { Set-Status 'No se encontró la GoPro (USB en modo MTP, o la tarjeta en un lector)' 'Firebrick' }
        else { Set-Status 'No se encontró la Insta360 (USB en modo U-Disk, o la tarjeta en un lector)' 'Firebrick' }
    }
}

# Cambia el tipo de origen elegido y actualiza los campos
function Set-Device([string]$type) {
    $script:Device = $type; $Settings.Device = $type
    $script:Loading = $true
    $txtDest.Text = $Settings.Dest[$type]
    $txtSrc.ReadOnly = $type -ne 'Folder'
    $txtSrc.BackColor = if ($type -eq 'Folder') { [System.Drawing.SystemColors]::Window } else { [System.Drawing.SystemColors]::Control }
    $btnSrc.Enabled = $type -eq 'Folder'
    if ($type -eq 'Folder') { $txtSrc.Text = $Settings.SourceFolder }
    $script:Loading = $false
    Update-Status
}

function Select-Device([string]$type) {
    switch ($type) { 'GoPro' { $rbGoPro.Checked = $true } 'Insta360' { $rbInsta.Checked = $true } default { $rbFolder.Checked = $true } }
    Set-Device $type
}

function Invoke-Detect([bool]$autoSelect = $true) {
    Set-Status 'Buscando cámaras...' 'DimGray'
    [System.Windows.Forms.Application]::DoEvents()
    try { $script:Cameras = @(Find-Cameras) } catch { $script:Cameras = @(); Write-Log "Error buscando: $_" }
    foreach ($c in $script:Cameras) {
        Write-Log "Detectada $($c.Type): $($c.Name) - carpetas: $(($c.Folders | ForEach-Object { $_.Name }) -join ', ')"
    }
    # Si hay una camara conectada y no es la opcion elegida, se elige sola
    $types = @($script:Cameras | ForEach-Object { $_.Type })
    if ($autoSelect -and $types.Count -gt 0 -and $types -notcontains $script:Device) { Select-Device $types[0] }
    else { Update-Status }
}

function Test-PathInside([string]$child, [string]$parent) {
    $c = [IO.Path]::GetFullPath($child).TrimEnd('\') + '\'
    $p = [IO.Path]::GetFullPath($parent).TrimEnd('\') + '\'
    return $c.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)
}

function Start-Download {
    $type = $script:Device
    $srcFolder = ''
    if ($type -eq 'Folder') {
        $srcFolder = $txtSrc.Text.Trim()
        if (-not $srcFolder -or -not (Test-Path -LiteralPath $srcFolder -PathType Container)) {
            [System.Windows.Forms.MessageBox]::Show('Elegí una carpeta de origen que exista.', $AppName) | Out-Null; return
        }
    } elseif (-not ($script:Cameras | Where-Object { $_.Type -eq $type })) {
        Invoke-Detect $false
        if (-not ($script:Cameras | Where-Object { $_.Type -eq $type })) { return }
    }
    $destRoot = $txtDest.Text.Trim()
    if (-not $destRoot) { [System.Windows.Forms.MessageBox]::Show('Elegí dónde guardar los archivos.', $AppName) | Out-Null; return }
    if ($type -eq 'Folder' -and ((Test-PathInside $destRoot $srcFolder) -or (Test-PathInside $srcFolder $destRoot))) {
        [System.Windows.Forms.MessageBox]::Show('La carpeta de origen y la de destino no pueden estar una dentro de la otra.', $AppName) | Out-Null; return
    }
    try { New-Item -ItemType Directory -Force -Path $destRoot | Out-Null }
    catch { [System.Windows.Forms.MessageBox]::Show("No se puede crear $destRoot`n$_", 'Error') | Out-Null; return }
    Save-Settings

    $script:Sync = [hashtable]::Synchronized(@{
        Cancel = $false; Finished = $false; Done = [int64]0; Total = [int64]0; Errors = 0
        File = ''; Started = $null; Type = $type; SrcFolder = $srcFolder
        Log = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
        Copied = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    })
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    $script:PS = [powershell]::Create()
    $script:PS.Runspace = $rs
    [void]$script:PS.AddScript($WorkerCode).AddArgument($script:Sync).AddArgument($destRoot).AddArgument($chkSidecar.Checked).AddArgument($CoreCode).AddArgument($type).AddArgument($srcFolder)
    $progress.Value = 0; $lblSpeed.Text = ''; $lblFile.Text = 'Preparando...'
    Set-Busy $true
    $script:Handle = $script:PS.BeginInvoke()
    $timer.Start()
}

function Update-Progress {
    $s = $script:Sync; if (-not $s) { return }
    $line = $null
    while ($s.Log.TryDequeue([ref]$line)) { $txtLog.AppendText($line + [Environment]::NewLine) }
    $lblFile.Text = $s.File
    if ($s.Total -gt 0) {
        $progress.Value = [int][Math]::Min(1000, 1000 * $s.Done / $s.Total)
        if ($s.Started) {
            $secs = ((Get-Date) - $s.Started).TotalSeconds
            if ($secs -gt 1) {
                $speed = $s.Done / $secs
                $eta = if ($speed -gt 0) { [TimeSpan]::FromSeconds([Math]::Max(0, ($s.Total - $s.Done) / $speed)) } else { [TimeSpan]::Zero }
                $lblSpeed.Text = '{0} de {1}  -  {2}/s  -  faltan {3:hh\:mm\:ss}' -f (Format-Size $s.Done), (Format-Size $s.Total), (Format-Size $speed), $eta
            }
        }
    }
    if ($s.Finished) {
        $timer.Stop()
        try { [void]$script:PS.EndInvoke($script:Handle) } catch {}
        try { $script:PS.Runspace.Close(); $script:PS.Dispose(); $script:PS = $null } catch {}
        Set-Busy $false
        if ($s.Errors -eq 0 -and -not $s.Cancel) { $progress.Value = 1000; Ask-Delete }
        elseif ($s.Errors -gt 0) { Write-Log 'Hubo errores: no se ofrece borrar el origen. Tocá "Descargar todo" otra vez para reintentar (saltea lo ya copiado).' }
    }
}

function Ask-Delete {
    $copied = @{}; foreach ($k in $script:Sync.Copied) { $copied[$k] = $true }
    if ($copied.Count -eq 0) { return }
    $type = $script:Sync.Type
    try { $src = Find-Source $type $script:Sync.SrcFolder } catch { $src = $null }
    if (-not $src) { return }
    $all = Get-SourceFiles $src
    $keys = @{}
    foreach ($f in $all) { if (-not $f.Sidecar -and $copied.ContainsKey("$($f.Folder)\$($f.Name)")) { $keys[(Get-MediaKey $f.Name)] = $true } }
    # Incluye LRV/THM de los videos copiados (no sirven sin el original)
    $toDelete = @($all | Where-Object { $copied.ContainsKey("$($_.Folder)\$($_.Name)") -or ($_.Sidecar -and $keys.ContainsKey((Get-MediaKey $_.Name))) })
    if ($toDelete.Count -eq 0) { return }
    $bytes = ($toDelete | Measure-Object Size -Sum).Sum
    $where = if ($type -eq 'Folder') { "de la carpeta de origen ($($src.Name))" } else { "de la cámara ($($src.Name))" }
    $default = if ($type -eq 'Folder') { 'Button2' } else { 'Button1' }
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Todos los archivos están copiados y verificados en el disco.`n`n¿Borrar $($toDelete.Count) archivos ($(Format-Size $bytes)) $where para liberar espacio?",
        'Liberar espacio', 'YesNo', 'Question', $default)
    if ($r -ne 'Yes') { Write-Log 'Los archivos quedan en el origen.'; return }
    Write-Log 'Borrando archivos del origen...'
    try {
        if ($src.Mode -eq 'Drive') {
            foreach ($f in $toDelete) { Remove-Item -LiteralPath $f.Ref.FullName -Force }
        } else {
            # Un borrado por carpeta: Windows pide una sola confirmacion
            foreach ($grp in ($toDelete | Group-Object Folder)) {
                $fold = $src.Folders | Where-Object { $_.Name -eq $grp.Name } | Select-Object -First 1
                $items = $fold.GetFolder.Items()
                $items.Filter(0x40, (($grp.Group | ForEach-Object { $_.Ref.Name } | Sort-Object -Unique) -join ';'))
                if ($items.Count -gt 0) { $items.InvokeVerbEx('delete') }
                [System.Windows.Forms.Application]::DoEvents()
            }
        }
        Write-Log "Borrados $($toDelete.Count) archivos del origen."
    } catch { Write-Log "ERROR borrando: $_" }
    Invoke-Detect $false
}

# ---------- actualizaciones
function Start-UpdateJob([string]$code, [object[]]$params) {
    $script:Upd.Done = $false
    $script:UpdPS = [powershell]::Create()
    [void]$script:UpdPS.AddScript($code)
    foreach ($p in $params) { [void]$script:UpdPS.AddArgument($p) }
    $script:UpdHandle = $script:UpdPS.BeginInvoke()
    $updTimer.Start()
}

function Start-UpdateCheck {
    if (-not $IsInstalled) { return }
    $script:Upd = [hashtable]::Synchronized(@{ Done = $false; Stage = 'check'; Version = $null; Url = $null; File = $null; Error = $null })
    Start-UpdateJob $UpdateCheckCode @($script:Upd, $UpdateRepo, $SetupAsset)
}

function Update-UpdateState {
    $s = $script:Upd
    if (-not $s -or -not $s.Done) { return }
    if ($s.Stage -eq 'check' -and $script:Sync -and -not $script:Sync.Finished) { return }   # espera a que termine la copia
    $updTimer.Stop()
    try { [void]$script:UpdPS.EndInvoke($script:UpdHandle); $script:UpdPS.Dispose() } catch {}
    if ($s.Stage -eq 'check') {
        if (-not $s.Version -or -not $s.Url) { return }
        try { $newer = [version]$s.Version -gt [version]$AppVersion } catch { $newer = $false }
        if (-not $newer) { return }
        $r = [System.Windows.Forms.MessageBox]::Show(
            "Hay una versión nueva de $AppName ($($s.Version)). Tenés la $AppVersion.`n`n¿Actualizar ahora? Tarda unos segundos y la app se vuelve a abrir sola.",
            'Actualización disponible', 'YesNo', 'Information')
        if ($r -ne 'Yes') { Write-Log "Hay una actualización ($($s.Version)); se vuelve a ofrecer la próxima vez que abras la app."; return }
        Write-Log 'Descargando actualización...'
        Set-Busy $true; $btnCancel.Enabled = $false
        $s.Stage = 'download'; $s.Error = $null
        $s.File = Join-Path $env:TEMP "CamaraDownloader-Setup-$($s.Version).exe"
        Start-UpdateJob $UpdateDownloadCode @($s)
    } else {
        if ($s.Error -or -not (Test-Path -LiteralPath $s.File)) {
            Write-Log "No se pudo descargar la actualización: $($s.Error)"; Set-Busy $false; return
        }
        Write-Log 'Instalando actualización...'
        try {
            Start-Process -FilePath $s.File -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART'
            $script:Updating = $true
            $form.Close()
        } catch { Write-Log "No se pudo iniciar la actualización: $_"; Set-Busy $false }
    }
}

# ---------- controles
$form = New-Object System.Windows.Forms.Form
$form.Text = "$AppName $AppVersion"
$form.Size = New-Object System.Drawing.Size(720, 620)
$form.MinimumSize = $form.Size
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
foreach ($ico in (Join-Path $AppDir 'app.ico'), (Join-Path $AppDir '..\assets\app.ico')) {
    if (Test-Path -LiteralPath $ico) { try { $form.Icon = New-Object System.Drawing.Icon($ico) } catch {}; break }
}

$lblType = New-Object System.Windows.Forms.Label
$lblType.Text = 'Descargar de:'; $lblType.Location = '15,18'; $lblType.AutoSize = $true

$rbGoPro = New-Object System.Windows.Forms.RadioButton
$rbGoPro.Text = 'GoPro'; $rbGoPro.Location = '110,15'; $rbGoPro.AutoSize = $true
$rbInsta = New-Object System.Windows.Forms.RadioButton
$rbInsta.Text = 'Insta360'; $rbInsta.Location = '195,15'; $rbInsta.AutoSize = $true
$rbFolder = New-Object System.Windows.Forms.RadioButton
$rbFolder.Text = 'Otra carpeta'; $rbFolder.Location = '295,15'; $rbFolder.AutoSize = $true

$btnDetect = New-Object System.Windows.Forms.Button
$btnDetect.Text = 'Buscar'; $btnDetect.Location = '590,10'; $btnDetect.Size = '100,30'; $btnDetect.Anchor = 'Top,Right'

$lblDevice = New-Object System.Windows.Forms.Label
$lblDevice.Location = '15,48'; $lblDevice.Size = '675,24'; $lblDevice.Anchor = 'Top,Left,Right'
$lblDevice.Font = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Bold)

$lblSrc = New-Object System.Windows.Forms.Label
$lblSrc.Text = 'Origen:'; $lblSrc.Location = '15,85'; $lblSrc.AutoSize = $true

$txtSrc = New-Object System.Windows.Forms.TextBox
$txtSrc.Location = '110,82'; $txtSrc.Size = '470,25'; $txtSrc.Anchor = 'Top,Left,Right'

$btnSrc = New-Object System.Windows.Forms.Button
$btnSrc.Text = 'Elegir...'; $btnSrc.Location = '590,80'; $btnSrc.Size = '100,28'; $btnSrc.Anchor = 'Top,Right'

$lblDest = New-Object System.Windows.Forms.Label
$lblDest.Text = 'Guardar en:'; $lblDest.Location = '15,119'; $lblDest.AutoSize = $true

$txtDest = New-Object System.Windows.Forms.TextBox
$txtDest.Location = '110,116'; $txtDest.Size = '470,25'; $txtDest.Anchor = 'Top,Left,Right'

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = 'Cambiar...'; $btnBrowse.Location = '590,114'; $btnBrowse.Size = '100,28'; $btnBrowse.Anchor = 'Top,Right'

$chkSidecar = New-Object System.Windows.Forms.CheckBox
$chkSidecar.Text = 'Incluir archivos LRV/THM (proxies de baja resolución y miniaturas)'
$chkSidecar.Location = '110,148'; $chkSidecar.AutoSize = $true; $chkSidecar.Checked = $Settings.IncludeSidecar

$btnDownload = New-Object System.Windows.Forms.Button
$btnDownload.Text = 'Descargar todo'; $btnDownload.Location = '15,180'; $btnDownload.Size = '180,42'
$btnDownload.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$btnDownload.BackColor = 'SteelBlue'; $btnDownload.ForeColor = 'White'; $btnDownload.FlatStyle = 'Flat'

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = 'Cancelar'; $btnCancel.Location = '205,180'; $btnCancel.Size = '100,42'; $btnCancel.Enabled = $false

$btnOpen = New-Object System.Windows.Forms.Button
$btnOpen.Text = 'Abrir carpeta'; $btnOpen.Location = '570,180'; $btnOpen.Size = '120,42'; $btnOpen.Anchor = 'Top,Right'

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = '15,235'; $progress.Size = '675,22'; $progress.Maximum = 1000; $progress.Anchor = 'Top,Left,Right'

$lblFile = New-Object System.Windows.Forms.Label
$lblFile.Location = '15,263'; $lblFile.Size = '675,20'; $lblFile.Anchor = 'Top,Left,Right'

$lblSpeed = New-Object System.Windows.Forms.Label
$lblSpeed.Location = '15,283'; $lblSpeed.Size = '675,20'; $lblSpeed.Anchor = 'Top,Left,Right'; $lblSpeed.ForeColor = 'DimGray'

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true; $txtLog.ScrollBars = 'Vertical'; $txtLog.ReadOnly = $true
$txtLog.Location = '15,310'; $txtLog.Size = '675,260'; $txtLog.Anchor = 'Top,Bottom,Left,Right'
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9); $txtLog.BackColor = 'White'

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 300
$timer.Add_Tick({ try { Update-Progress } catch { Write-Log "Error de interfaz: $_" } })

$updTimer = New-Object System.Windows.Forms.Timer
$updTimer.Interval = 500
$updTimer.Add_Tick({ try { Update-UpdateState } catch { $updTimer.Stop(); Write-Log "Error actualizando: $_" } })

$form.Controls.AddRange(@($lblType, $rbGoPro, $rbInsta, $rbFolder, $btnDetect, $lblDevice, $lblSrc, $txtSrc, $btnSrc,
    $lblDest, $txtDest, $btnBrowse, $chkSidecar, $btnDownload, $btnCancel, $btnOpen, $progress, $lblFile, $lblSpeed, $txtLog))

# ---------- eventos
$rbGoPro.Add_CheckedChanged({ if ($rbGoPro.Checked -and -not $script:Loading) { Set-Device 'GoPro' } })
$rbInsta.Add_CheckedChanged({ if ($rbInsta.Checked -and -not $script:Loading) { Set-Device 'Insta360' } })
$rbFolder.Add_CheckedChanged({ if ($rbFolder.Checked -and -not $script:Loading) { Set-Device 'Folder' } })
$txtDest.Add_TextChanged({ if (-not $script:Loading) { $Settings.Dest[$script:Device] = $txtDest.Text.Trim() } })
$txtSrc.Add_TextChanged({ if (-not $script:Loading -and $script:Device -eq 'Folder') { $Settings.SourceFolder = $txtSrc.Text.Trim(); Update-Status } })
$chkSidecar.Add_CheckedChanged({ $Settings.IncludeSidecar = $chkSidecar.Checked })

$btnDetect.Add_Click({ Invoke-Detect })
$btnDownload.Add_Click({ Start-Download })
$btnCancel.Add_Click({ if ($script:Sync) { $script:Sync.Cancel = $true }; Write-Log 'Cancelando (termina el archivo actual)...' })
$btnSrc.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Elegí la carpeta con los archivos a descargar'
    if ($txtSrc.Text -and (Test-Path -LiteralPath $txtSrc.Text)) { $dlg.SelectedPath = $txtSrc.Text }
    if ($dlg.ShowDialog() -eq 'OK') { $txtSrc.Text = $dlg.SelectedPath }
})
$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Elegí dónde guardar los archivos'
    $dlg.SelectedPath = $txtDest.Text
    if ($dlg.ShowDialog() -eq 'OK') { $txtDest.Text = $dlg.SelectedPath }
})
$btnOpen.Add_Click({
    try {
        New-Item -ItemType Directory -Force -Path $txtDest.Text | Out-Null
        Start-Process explorer.exe $txtDest.Text
    } catch { Write-Log "No se puede abrir la carpeta: $_" }
})
$form.Add_FormClosing({
    if (-not $script:Updating -and $script:Sync -and -not $script:Sync.Finished) {
        $r = [System.Windows.Forms.MessageBox]::Show('Hay una copia en curso. ¿Cerrar igual? (el archivo actual no se guarda y se vuelve a copiar la próxima vez)', $AppName, 'YesNo', 'Warning')
        if ($r -ne 'Yes') { $_.Cancel = $true; return }
        $script:Sync.Cancel = $true
    }
    Save-Settings
})
$form.Add_Shown({
    Select-Device $Settings.Device
    Invoke-Detect
    Start-UpdateCheck
})

try { [void]$form.ShowDialog() }
catch { [System.Windows.Forms.MessageBox]::Show("Error inesperado:`n$_", $AppName) | Out-Null }
finally { if ($script:PS) { try { $script:PS.Stop() } catch {} } ; [Environment]::Exit(0) }
