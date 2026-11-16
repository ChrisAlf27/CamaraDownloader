# Compila el instalador de Cámara Downloader y, con -Publish, lo sube como Release a GitHub.
#   .\build.ps1             -> dist\CamaraDownloader-Setup.exe
#   .\build.ps1 -Publish    -> ademas crea el Release vX.Y.Z (la version sale de src\CamaraDownloader.ps1)
# Para sacar una version nueva: subir $AppVersion en src\CamaraDownloader.ps1, commit, y .\build.ps1 -Publish
param([switch]$Publish, [string]$Notes = '')
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$repo = 'ChrisAlf27/CamaraDownloader'

# --- version
$src = Join-Path $root 'src\CamaraDownloader.ps1'
$m = Select-String -LiteralPath $src -Pattern "^\`$AppVersion\s*=\s*'([\d.]+)'" | Select-Object -First 1
if (-not $m) { throw 'No se encontro $AppVersion en el script.' }
$version = $m.Matches[0].Groups[1].Value
Write-Host "Version $version"

# --- el script tiene que ser UTF-8 con BOM (PowerShell 5.1 lee mal los acentos sin BOM)
$bytes = [IO.File]::ReadAllBytes($src)
if (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) {
    $text = [IO.File]::ReadAllText($src, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($src, ($text -replace "(?<!`r)`n", "`r`n"), [Text.UTF8Encoding]::new($true))
    Write-Host 'Script convertido a UTF-8 con BOM'
}
$errors = $null
[void][Management.Automation.Language.Parser]::ParseFile($src, [ref]$null, [ref]$errors)
if ($errors) { $errors | ForEach-Object { Write-Host $_ -ForegroundColor Red }; throw 'El script tiene errores de sintaxis.' }

# --- icono
$ico = Join-Path $root 'assets\app.ico'
if (-not (Test-Path $ico)) { & (Join-Path $root 'assets\make-icon.ps1') -Path $ico }

# --- lanzador (.exe)
$buildDir = Join-Path $root 'build'
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
& $csc /nologo /codepage:65001 /target:winexe /optimize+ "/win32icon:$ico" "/out:$(Join-Path $buildDir 'CamaraDownloader.exe')" `
    /r:System.Windows.Forms.dll (Join-Path $root 'src\Launcher.cs')
if ($LASTEXITCODE) { throw 'Fallo la compilacion del lanzador.' }

# --- instalador
$iscc = @("$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe", "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe") |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw 'Falta Inno Setup 6: winget install JRSoftware.InnoSetup' }
& $iscc /Q "/DAppVersion=$version" (Join-Path $root 'installer\CamaraDownloader.iss')
if ($LASTEXITCODE) { throw 'Fallo la compilacion del instalador.' }
$setup = Join-Path $root 'dist\CamaraDownloader-Setup.exe'
Write-Host "Listo: $setup" -ForegroundColor Green

# --- publicar
if ($Publish) {
    $gh = (Get-Command gh -ErrorAction SilentlyContinue).Source
    if (-not $gh) { $gh = "$env:ProgramFiles\GitHub CLI\gh.exe" }
    if (-not $Notes) { $Notes = "Versión $version" }
    & $gh release create "v$version" $setup --repo $repo --title "Cámara Downloader $version" --notes $Notes
    if ($LASTEXITCODE) { throw 'No se pudo crear el Release (¿ya existe esa version? ¿gh auth login?).' }
    Write-Host "Publicado v$version. Las apps instaladas se actualizan al abrirse." -ForegroundColor Green
}
