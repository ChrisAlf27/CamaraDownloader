# GoPro Downloader - copia rapida de archivos de la GoPro al disco G
# Soporta GoPro conectada por USB (MTP) o tarjeta SD en lector (letra de unidad).
# La copia corre en un hilo aparte para que la ventana nunca se congele.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$DefaultDest = 'G:\GoPro'

# ============================================================ codigo compartido
# Se carga en la ventana y en el hilo de copia.
$CoreCode = @'
$ErrorActionPreference = 'Stop'
$SidecarExt = @('.LRV', '.THM')   # proxies / miniaturas que genera la GoPro
$script:Shell = New-Object -ComObject Shell.Application

function Format-Size([double]$b) {
    if ($b -ge 1GB) { return '{0:N2} GB' -f ($b / 1GB) }
    if ($b -ge 1MB) { return '{0:N1} MB' -f ($b / 1MB) }
    if ($b -ge 1KB) { return '{0:N0} KB' -f ($b / 1KB) }
    return "$b B"
}

# GX010123.MP4 -> 010123 (para relacionarlo con GL010123.LRV / GX010123.THM)
function Get-MediaKey([string]$name) {
    $base = [IO.Path]::GetFileNameWithoutExtension($name)
    if ($base.Length -gt 2) { return $base.Substring(2).ToUpper() }
    return $base.ToUpper()
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

function Find-GoPro {
    # 1) Tarjeta SD / camara montada como unidad (lo mas rapido)
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        if (-not $d.IsReady) { continue }
        $dcim = Join-Path $d.RootDirectory.FullName 'DCIM'
        if (Test-Path $dcim) {
            $sub = @(Get-ChildItem $dcim -Directory -ErrorAction SilentlyContinue | Where-Object Name -match 'GOPRO')
            if ($sub.Count -gt 0) { return @{ Mode = 'Drive'; Name = "Unidad $($d.Name) $($d.VolumeLabel)"; Folders = $sub } }
        }
    }
    # 2) GoPro por USB (MTP), aparece en "Este equipo"
    foreach ($dev in $script:Shell.NameSpace(17).Items()) {
        if ($dev.Name -notmatch 'GoPro|HERO|MAX') { continue }
        $dcim = Find-ShellDcim $dev.GetFolder 0
        if ($dcim) { return @{ Mode = 'MTP'; Name = $dev.Name; Folders = @($dcim.Items() | Where-Object { $_.IsFolder }) } }
    }
    return $null
}

# Lista: Name, Size, Date, Folder, Ref (FileInfo o FolderItem), Sidecar
function Get-SourceFiles($src) {
    $list = New-Object System.Collections.ArrayList
    foreach ($f in $src.Folders) {
        if ($src.Mode -eq 'Drive') {
            foreach ($fi in Get-ChildItem $f.FullName -File) {
                [void]$list.Add([pscustomobject]@{ Name = $fi.Name; Size = [int64]$fi.Length; Date = $fi.LastWriteTime
                    Folder = $f.Name; Ref = $fi; Sidecar = ($SidecarExt -contains $fi.Extension.ToUpper()) })
            }
        } else {
            $sf = $f.GetFolder
            foreach ($it in $sf.Items()) {
                if ($it.IsFolder) { continue }
                $name = Get-ItemFileName $it
                [void]$list.Add([pscustomobject]@{ Name = $name; Size = (Get-MtpSize $it); Date = (Get-MtpDate $it $sf)
                    Folder = $f.Name; Ref = $it; Sidecar = ($SidecarExt -contains [IO.Path]::GetExtension($name).ToUpper()) })
            }
        }
    }
    return $list
}
'@

# ============================================================ hilo de copia
$WorkerCode = @'
param($sync, $destRoot, $includeSidecar, $coreCode)
. ([scriptblock]::Create($coreCode))
function Log([string]$m) { $sync.Log.Enqueue(('[{0:HH:mm:ss}] {1}' -f (Get-Date), $m)) }

function Test-FileUnlocked([string]$p) {
    try { $fs = [IO.File]::Open($p, 'Open', 'Read', 'None'); $fs.Close(); return $true } catch { return $false }
}

# Busca el archivo destino aunque Windows lo haya escrito con otro nombre/extension
function Resolve-Dest([string]$dir, [string]$dest) {
    if (Test-Path -LiteralPath $dest) { return $dest }
    $base = [IO.Path]::GetFileNameWithoutExtension($dest)
    $m = Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
         Where-Object { $_.BaseName -eq $base -or $_.Name -eq $base } | Select-Object -First 1
    if ($m) { return $m.FullName }
    return $null
}

function Copy-DriveFile($file, [string]$dest) {
    $buf = New-Object byte[] (8MB)
    $in = [IO.File]::OpenRead($file.Ref.FullName); $out = [IO.File]::Create($dest)
    try {
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $out.Write($buf, 0, $n); $sync.Done += $n
            if ($sync.Cancel) { throw 'Cancelado' }
        }
    } finally { $in.Close(); $out.Close() }
    return $dest
}

function Copy-MtpFile($file, [string]$dir, [string]$dest) {
    $start = $sync.Done
    $script:Shell.NameSpace($dir).CopyHere($file.Ref, 1556)   # sin dialogos
    $last = [int64]-1; $lastChange = Get-Date; $stable = $null
    while ($true) {
        Start-Sleep -Milliseconds 250
        $real = Resolve-Dest $dir $dest
        $len = if ($real) { ([IO.FileInfo]::new($real)).Length } else { [int64]0 }
        if ($len -ne $last) { $last = $len; $lastChange = Get-Date; $stable = $null; $sync.Done = $start + $len }
        if ($real -and $len -gt 0) {
            if ($file.Size -gt 0) { if ($len -ge $file.Size -and (Test-FileUnlocked $real)) { return $real } }
            else {
                if (-not $stable) { $stable = Get-Date }
                if (((Get-Date) - $stable).TotalSeconds -ge 3 -and (Test-FileUnlocked $real)) { return $real }
            }
        }
        if (((Get-Date) - $lastChange).TotalSeconds -gt 300) { throw 'La copia no avanza (5 min sin datos)' }
    }
}

try {
    $src = Find-GoPro
    if (-not $src) { throw 'No se encontro la GoPro.' }
    Log "Leyendo archivos de $($src.Name)..."
    $files = @(Get-SourceFiles $src | Where-Object { $includeSidecar -or -not $_.Sidecar } | Sort-Object Date, Name)
    $noDate = @($files | Where-Object { -not $_.Date }).Count
    if ($noDate -gt 0) { Log "Atencion: $noDate archivos sin fecha legible, van a la carpeta 'Sin fecha'." }

    # Indice de lo que ya hay en el destino (nombre+tamano) para no recopiar
    $existing = @{}
    Get-ChildItem -LiteralPath $destRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notlike (Join-Path $destRoot 'App\*') } |
        ForEach-Object { $existing["$($_.Name.ToUpper())|$($_.Length)"] = $_.FullName }

    $todo = New-Object System.Collections.ArrayList; $skipped = 0; $moved = 0
    foreach ($f in $files) {
        $folderName = if ($f.Date) { $f.Date.ToString('yyyy-MM-dd') } else { 'Sin fecha' }
        $dir = Join-Path $destRoot $folderName
        $dest = Join-Path $dir $f.Name
        $prev = if ($f.Size -gt 0) { $existing["$($f.Name.ToUpper())|$($f.Size)"] } else { $null }
        if ($prev) {
            if ($prev -ne $dest) {   # ya copiado pero en otra carpeta (ej. 1899-12-30): se mueve
                New-Item -ItemType Directory -Force -Path $dir | Out-Null
                Move-Item -LiteralPath $prev -Destination $dest -Force; $moved++
                if ($f.Date) { [IO.File]::SetLastWriteTime($dest, $f.Date); [IO.File]::SetCreationTime($dest, $f.Date) }
            }
            $skipped++; [void]$sync.Copied.Add("$($f.Folder)\$($f.Name)"); continue
        }
        [void]$todo.Add([pscustomobject]@{ File = $f; Dir = $dir; Dest = $dest })
    }
    $sync.Total = [int64](($todo | ForEach-Object { $_.File.Size } | Measure-Object -Sum).Sum)
    # Restos incompletos del intento con fecha erronea
    $bad = Join-Path $destRoot '1899-12-30'
    if (Test-Path -LiteralPath $bad) {
        $camNames = @{}; foreach ($f in $files) { $camNames[$f.Name.ToUpper()] = $true }
        Get-ChildItem -LiteralPath $bad -File | Where-Object { $camNames.ContainsKey($_.Name.ToUpper()) } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
    }
    # Limpia carpetas que quedaron vacias (ej. 1899-12-30)
    Get-ChildItem -LiteralPath $destRoot -Directory | Where-Object { $_.Name -ne 'App' -and -not (Get-ChildItem -LiteralPath $_.FullName -Force) } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
    if ($moved -gt 0) { Log "$moved archivos ya copiados se movieron a su carpeta de fecha correcta." }
    Log ('{0} archivos en la camara, {1} ya estaban copiados, {2} nuevos ({3}).' -f $files.Count, $skipped, $todo.Count, (Format-Size $sync.Total))
    $sync.Started = Get-Date

    $i = 0
    foreach ($t in $todo) {
        if ($sync.Cancel) { Log 'Cancelado por el usuario.'; break }
        $i++
        $sync.File = "($i/$($todo.Count))  $($t.File.Name)  -  $(Format-Size $t.File.Size)"
        $before = $sync.Done
        try {
            New-Item -ItemType Directory -Force -Path $t.Dir | Out-Null
            $old = Resolve-Dest $t.Dir $t.Dest
            if ($old) { Remove-Item -LiteralPath $old -Force }   # copia incompleta anterior
            $real = if ($src.Mode -eq 'Drive') { Copy-DriveFile $t.File $t.Dest } else { Copy-MtpFile $t.File $t.Dir $t.Dest }
            if ($real -ne $t.Dest) { Move-Item -LiteralPath $real -Destination $t.Dest -Force }
            $len = ([IO.FileInfo]::new($t.Dest)).Length
            if ($t.File.Size -gt 0 -and $len -ne $t.File.Size) { throw "tamano distinto ($len vs $($t.File.Size))" }
            if ($t.File.Date) { [IO.File]::SetLastWriteTime($t.Dest, $t.File.Date); [IO.File]::SetCreationTime($t.Dest, $t.File.Date) }
            $sync.Done = $before + [Math]::Max($t.File.Size, $len)
            [void]$sync.Copied.Add("$($t.File.Folder)\$($t.File.Name)")
            Log "OK  $($t.File.Name)  ->  $($t.Dir)"
        } catch {
            $sync.Errors++
            $sync.Done = $before + $t.File.Size
            Log "ERROR  $($t.File.Name): $_"
            if ("$_" -eq 'Cancelado' -and (Test-Path -LiteralPath $t.Dest)) { Remove-Item -LiteralPath $t.Dest -Force }
        }
    }
    $sync.File = "Listo: $($i - $sync.Errors) copiados, $($sync.Errors) con error."
} catch {
    $sync.Errors++
    Log "ERROR: $_"
} finally {
    $sync.Finished = $true
}
'@

# ============================================================ ventana
. ([scriptblock]::Create($CoreCode))
$script:Source = $null
$script:Sync = $null
$script:PS = $null

function Write-Log([string]$msg) {
    $txtLog.AppendText(('[{0:HH:mm:ss}] {1}' -f (Get-Date), $msg) + [Environment]::NewLine)
}

function Set-Busy([bool]$b) {
    $btnDownload.Enabled = -not $b; $btnDetect.Enabled = -not $b; $btnBrowse.Enabled = -not $b
    $btnCancel.Enabled = $b; $chkSidecar.Enabled = -not $b; $txtDest.Enabled = -not $b
}

function Invoke-Detect {
    $lblDevice.Text = 'Buscando GoPro...'; $lblDevice.ForeColor = 'DimGray'
    [System.Windows.Forms.Application]::DoEvents()
    try { $script:Source = Find-GoPro } catch { $script:Source = $null; Write-Log "Error buscando: $_" }
    if ($script:Source) {
        $mode = if ($script:Source.Mode -eq 'MTP') { 'USB' } else { 'lector SD' }
        $lblDevice.Text = "Conectada: $($script:Source.Name)  ($mode)"; $lblDevice.ForeColor = 'ForestGreen'
        Write-Log "Detectada $($script:Source.Name) - carpetas: $(($script:Source.Folders | ForEach-Object Name) -join ', ')"
    } else {
        $lblDevice.Text = 'No se encontro la GoPro. Conectala por USB (modo MTP), encendela y toca "Buscar".'
        $lblDevice.ForeColor = 'Firebrick'
    }
}

function Start-Download {
    if (-not $script:Source) { Invoke-Detect; if (-not $script:Source) { return } }
    $destRoot = $txtDest.Text.Trim()
    try { New-Item -ItemType Directory -Force -Path $destRoot | Out-Null }
    catch { [System.Windows.Forms.MessageBox]::Show("No se puede crear $destRoot`n$_", 'Error') | Out-Null; return }

    $script:Sync = [hashtable]::Synchronized(@{
        Cancel = $false; Finished = $false; Done = [int64]0; Total = [int64]0; Errors = 0
        File = ''; Started = $null
        Log = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
        Copied = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    })
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    $script:PS = [powershell]::Create()
    $script:PS.Runspace = $rs
    [void]$script:PS.AddScript($WorkerCode).AddArgument($script:Sync).AddArgument($destRoot).AddArgument($chkSidecar.Checked).AddArgument($CoreCode)
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
        elseif ($s.Errors -gt 0) { Write-Log 'Hubo errores: no se ofrece borrar la camara. Toca "Descargar todo" otra vez para reintentar (saltea lo ya copiado).' }
    }
}

function Ask-Delete {
    $copied = @{}; foreach ($k in $script:Sync.Copied) { $copied[$k] = $true }
    if ($copied.Count -eq 0) { return }
    Invoke-Detect; if (-not $script:Source) { return }
    $all = Get-SourceFiles $script:Source
    $keys = @{}
    foreach ($f in $all) { if (-not $f.Sidecar -and $copied.ContainsKey("$($f.Folder)\$($f.Name)")) { $keys[(Get-MediaKey $f.Name)] = $true } }
    # Incluye LRV/THM de los videos copiados (no sirven sin el original)
    $toDelete = @($all | Where-Object { $copied.ContainsKey("$($_.Folder)\$($_.Name)") -or ($_.Sidecar -and $keys.ContainsKey((Get-MediaKey $_.Name))) })
    if ($toDelete.Count -eq 0) { return }
    $bytes = ($toDelete | Measure-Object Size -Sum).Sum
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Todos los archivos estan copiados y verificados en el disco.`n`nBorrar $($toDelete.Count) archivos ($(Format-Size $bytes)) de la GoPro para liberar la tarjeta?",
        'Liberar tarjeta', 'YesNo', 'Question')
    if ($r -ne 'Yes') { Write-Log 'Los archivos quedan en la camara.'; return }
    Write-Log 'Borrando archivos de la camara...'
    try {
        if ($script:Source.Mode -eq 'Drive') {
            foreach ($f in $toDelete) { Remove-Item -LiteralPath $f.Ref.FullName -Force }
        } else {
            # Un borrado por carpeta: Windows pide una sola confirmacion
            foreach ($grp in ($toDelete | Group-Object Folder)) {
                $fold = $script:Source.Folders | Where-Object Name -eq $grp.Name | Select-Object -First 1
                $items = $fold.GetFolder.Items()
                $items.Filter(0x40, (($grp.Group | ForEach-Object { $_.Ref.Name } | Sort-Object -Unique) -join ';'))
                if ($items.Count -gt 0) { $items.InvokeVerbEx('delete') }
                [System.Windows.Forms.Application]::DoEvents()
            }
        }
        Write-Log "Borrados $($toDelete.Count) archivos de la camara."
    } catch { Write-Log "ERROR borrando: $_" }
    Invoke-Detect
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'GoPro Downloader'
$form.Size = New-Object System.Drawing.Size(720, 560)
$form.MinimumSize = $form.Size
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)

$lblDevice = New-Object System.Windows.Forms.Label
$lblDevice.Location = '15,15'; $lblDevice.Size = '560,25'; $lblDevice.Anchor = 'Top,Left,Right'
$lblDevice.Font = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Bold)

$btnDetect = New-Object System.Windows.Forms.Button
$btnDetect.Text = 'Buscar'; $btnDetect.Location = '590,12'; $btnDetect.Size = '100,30'; $btnDetect.Anchor = 'Top,Right'

$lblDest = New-Object System.Windows.Forms.Label
$lblDest.Text = 'Guardar en:'; $lblDest.Location = '15,55'; $lblDest.AutoSize = $true

$txtDest = New-Object System.Windows.Forms.TextBox
$txtDest.Text = $DefaultDest; $txtDest.Location = '100,52'; $txtDest.Size = '480,25'; $txtDest.Anchor = 'Top,Left,Right'

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = 'Cambiar...'; $btnBrowse.Location = '590,50'; $btnBrowse.Size = '100,28'; $btnBrowse.Anchor = 'Top,Right'

$chkSidecar = New-Object System.Windows.Forms.CheckBox
$chkSidecar.Text = 'Incluir archivos LRV/THM (proxies de baja resolucion y miniaturas)'
$chkSidecar.Location = '100,82'; $chkSidecar.AutoSize = $true

$btnDownload = New-Object System.Windows.Forms.Button
$btnDownload.Text = 'Descargar todo'; $btnDownload.Location = '15,115'; $btnDownload.Size = '180,42'
$btnDownload.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$btnDownload.BackColor = 'SteelBlue'; $btnDownload.ForeColor = 'White'; $btnDownload.FlatStyle = 'Flat'

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = 'Cancelar'; $btnCancel.Location = '205,115'; $btnCancel.Size = '100,42'; $btnCancel.Enabled = $false

$btnOpen = New-Object System.Windows.Forms.Button
$btnOpen.Text = 'Abrir carpeta'; $btnOpen.Location = '570,115'; $btnOpen.Size = '120,42'; $btnOpen.Anchor = 'Top,Right'

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = '15,170'; $progress.Size = '675,22'; $progress.Maximum = 1000; $progress.Anchor = 'Top,Left,Right'

$lblFile = New-Object System.Windows.Forms.Label
$lblFile.Location = '15,198'; $lblFile.Size = '675,20'; $lblFile.Anchor = 'Top,Left,Right'

$lblSpeed = New-Object System.Windows.Forms.Label
$lblSpeed.Location = '15,218'; $lblSpeed.Size = '675,20'; $lblSpeed.Anchor = 'Top,Left,Right'; $lblSpeed.ForeColor = 'DimGray'

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true; $txtLog.ScrollBars = 'Vertical'; $txtLog.ReadOnly = $true
$txtLog.Location = '15,245'; $txtLog.Size = '675,265'; $txtLog.Anchor = 'Top,Bottom,Left,Right'
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9); $txtLog.BackColor = 'White'

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 300
$timer.Add_Tick({ try { Update-Progress } catch { Write-Log "Error de interfaz: $_" } })

$form.Controls.AddRange(@($lblDevice, $btnDetect, $lblDest, $txtDest, $btnBrowse, $chkSidecar,
    $btnDownload, $btnCancel, $btnOpen, $progress, $lblFile, $lblSpeed, $txtLog))

$btnDetect.Add_Click({ Invoke-Detect })
$btnDownload.Add_Click({ Start-Download })
$btnCancel.Add_Click({ if ($script:Sync) { $script:Sync.Cancel = $true }; Write-Log 'Cancelando (termina el archivo actual)...' })
$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.SelectedPath = $txtDest.Text
    if ($dlg.ShowDialog() -eq 'OK') { $txtDest.Text = $dlg.SelectedPath }
})
$btnOpen.Add_Click({
    New-Item -ItemType Directory -Force -Path $txtDest.Text | Out-Null
    Start-Process explorer.exe $txtDest.Text
})
$form.Add_FormClosing({
    if ($script:Sync -and -not $script:Sync.Finished) {
        $r = [System.Windows.Forms.MessageBox]::Show('Hay una copia en curso. Cerrar igual? (el archivo actual quedara incompleto y se recopia la proxima vez)', 'GoPro Downloader', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { $_.Cancel = $true; return }
        $script:Sync.Cancel = $true
    }
})
$form.Add_Shown({ Invoke-Detect })

try { [void]$form.ShowDialog() }
catch { [System.Windows.Forms.MessageBox]::Show("Error inesperado:`n$_", 'GoPro Downloader') | Out-Null }
finally { if ($script:PS) { try { $script:PS.Stop() } catch {} } ; [Environment]::Exit(0) }
