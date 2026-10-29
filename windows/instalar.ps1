#Requires -Version 5.1
<#
    instalar.ps1 - deja Prgedisk accesible como comando en PowerShell.
    Uso:
        .\instalar.ps1
        .\instalar.ps1 -Uninstall

    Crea %LOCALAPPDATA%\Prgedisk, copia los scripts y agrega esa carpeta al
    PATH del usuario. Despues hay que abrir una terminal NUEVA.
#>
[CmdletBinding()]
param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'
$dest = Join-Path $env:LOCALAPPDATA 'Prgedisk'
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not $userPath) { $userPath = '' }
$parts = @($userPath -split ';' | Where-Object { $_ })

if ($Uninstall) {
    if ($env:OS -eq 'Windows_NT') {
        $desktop = [Environment]::GetFolderPath('Desktop')
        if ($desktop) { Remove-Item -LiteralPath (Join-Path $desktop 'Prgedisk.lnk') -Force -ErrorAction SilentlyContinue }
    }
    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Recurse -Force
    }
    $newParts = @($parts | Where-Object { $_ -ne $dest })
    [Environment]::SetEnvironmentVariable('Path', ($newParts -join ';'), 'User')
    Write-Host "Desinstalado: $dest"
    Write-Host "Abri una terminal nueva."
    return
}

New-Item -ItemType Directory -Force -Path $dest | Out-Null
foreach ($f in @('escaner.ps1', 'escaner-wpf.ps1', 'escaner-gui.ps1', 'reglas.json')) {
    $src = Join-Path $PSScriptRoot $f
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination $dest -Force
    }
}

$cli = @'
@echo off
if /I "%~1"=="--help" goto help
if /I "%~1"=="-h" goto help
if /I "%~1"=="--version" goto version
if /I "%~1"=="-V" goto version
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0escaner.ps1" %*
exit /b
:help
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0escaner.ps1" -Help
exit /b
:version
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0escaner.ps1" -Version
exit /b
'@
Set-Content -LiteralPath (Join-Path $dest 'prgedisk.cmd') -Value $cli -Encoding ASCII

$ui = @'
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0escaner-wpf.ps1"
'@
Set-Content -LiteralPath (Join-Path $dest 'prgedisk-ui.cmd') -Value $ui -Encoding ASCII

if ($parts -notcontains $dest) {
    [Environment]::SetEnvironmentVariable('Path', (($parts + $dest) -join ';'), 'User')
}

if ($env:OS -eq 'Windows_NT') {
    try {
        $desktop = [Environment]::GetFolderPath('Desktop')
        if ($desktop) {
            $lnk = Join-Path $desktop 'Prgedisk.lnk'
            $ws = New-Object -ComObject WScript.Shell
            $sc = $ws.CreateShortcut($lnk)
            $sc.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $sc.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $dest 'escaner-wpf.ps1') + '"'
            $sc.WorkingDirectory = $dest
            $sc.Description = 'Prgedisk - limpiador de disco'
            $sc.Save()
            Write-Host "Acceso directo en el escritorio: $lnk"
        }
    } catch {
        Write-Host "No se pudo crear el acceso directo: $($_.Exception.Message)"
    }
}

Write-Host "Instalado en: $dest"
Write-Host "Abri una terminal NUEVA y ejecuta:"
Write-Host "  prgedisk [ruta]   (consola)"
Write-Host "  prgedisk --help"
Write-Host "  prgedisk --version"
Write-Host "  prgedisk-ui       (ventana WPF)"
