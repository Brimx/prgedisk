#Requires -Version 5.1
<#
    limpiar-win.ps1  â€”  script unico (reemplaza cleanup.ps1 + debloat-santi.ps1)
    ============================================================================
    POR DEFECTO SOLO INFORMA. Nada se borra sin -Execute.
    Ejecutar en PowerShell COMO ADMINISTRADOR.

      .\limpiar-win.ps1                       -> inventario, no borra nada
      .\limpiar-win.ps1 -Execute              -> fases 1-7 (rapido, ~30 seg)
      .\limpiar-win.ps1 -Execute -System      -> + usmt.ppkg, restore, DISM (lento)
      .\limpiar-win.ps1 -Execute -PageFile16  -> + pagefile 26->16 GiB (requiere reinicio)
      .\limpiar-win.ps1 -Execute -AiWorkloads -> + stack de IA de Windows (vuelve solo)

    NO toca: juegos, Visual Studio, dotnet SDK, Office, Node, Python 3.14,
             documentos, OneDrive, ni ninguna foto/video tuyo.
#>
[CmdletBinding()]
param(
    [switch]$Execute,
    [switch]$System,
    [switch]$PageFile16,
    [switch]$ResetBase,
    [switch]$AiWorkloads,
    [string]$LogPath = "$env:USERPROFILE\Desktop\limpiar-win-log.txt"
)

$ErrorActionPreference = 'Continue'
$script:Freed   = 0.0
$script:Log     = New-Object System.Collections.Generic.List[string]
$script:Phase   = ''

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] {1,-6} {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    $script:Log.Add($line)
    $c = 'Gray'
    if ($Level -eq 'OK')    { $c = 'Green' }
    if ($Level -eq 'DRY')   { $c = 'Cyan' }
    if ($Level -eq 'WARN')  { $c = 'Yellow' }
    if ($Level -eq 'ERROR') { $c = 'Red' }
    Write-Host $line -ForegroundColor $c
}

function Get-SizeOf {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $it = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $it) { return $null }
    if ($it.PSIsContainer) {
        $s = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
              Measure-Object -Property Length -Sum).Sum
    } else { $s = $it.Length }
    if ($null -eq $s) { return 0.0 }
    return [double]$s
}

function Do-Item {
    param([string]$Path, [string]$Label, [string]$Mode = 'tree')
    $bytes = Get-SizeOf -Path $Path
    if ($null -eq $bytes) { Write-Log ("SKIP   {0}" -f $Label) 'INFO'; return }
    $gb = $bytes / 1GB
    if ($gb -lt 0.005) { Write-Log ("SKIP   {0} (despreciable)" -f $Label) 'INFO'; return }

    if (-not $Execute) {
        Write-Log ("DRY    {0,7:N2} GiB  {1}" -f $gb, $Label) 'DRY'
        $script:Freed += $gb
        return
    }
    Write-Log ("BORRA  {0,7:N2} GiB  {1}" -f $gb, $Label)
    if ($Mode -eq 'contents') {
        Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike 'dsh-*' } | ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    } else {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
    $after = Get-SizeOf -Path $Path
    if ($null -eq $after) { $after = 0.0 }
    $got = ($bytes - $after) / 1GB
    $script:Freed += $got
    if ($got -gt 0.001) { Write-Log ("OK     liberados {0:N2} GiB  ({1})" -f $got, $Label) 'OK' }
    else { Write-Log ("WARN   no se pudo borrar todo: {0}" -f $Path) 'WARN' }
}

# ============================================================================
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host ""
Write-Host "================= limpiar-win =================" -ForegroundColor Magenta
Write-Log ("Modo  : {0}" -f $(if ($Execute) { 'EJECUTAR (borra)' } else { 'INVENTARIO (no borra)' }))
Write-Log ("Admin : {0}" -f $isAdmin)
$freeBefore = $null
try { $freeBefore = [math]::Round((Get-Volume -DriveLetter C -ErrorAction Stop).SizeRemaining / 1GB, 2); Write-Log ("Libre : {0} GiB" -f $freeBefore) } catch {}
if ($Execute -and -not $isAdmin) { Write-Log "Necesitas Administrador para -Execute." 'ERROR'; return }

# ---------------------------------------------------------------- FASE 1
$script:Phase = '1. Temporales'
Write-Host "`n--- 1. Temporales y caches de sistema ---" -ForegroundColor Cyan
Do-Item "$env:LOCALAPPDATA\Temp"                    "TEMP del usuario"        contents
Do-Item "$env:WINDIR\Temp"                          "Windows\Temp"            contents
if ($Execute -and $isAdmin) {
    Stop-Service wuauserv, bits -Force -ErrorAction SilentlyContinue
    Do-Item "$env:WINDIR\SoftwareDistribution\Download" "Descargas de Windows Update (servicios detenidos)" contents
    Start-Service wuauserv -ErrorAction SilentlyContinue
    Start-Service bits -ErrorAction SilentlyContinue
} else {
    Do-Item "$env:WINDIR\SoftwareDistribution\Download" "Descargas de Windows Update" contents
}
Do-Item "$env:WINDIR\LiveKernelReports"             "Dumps de kernel"          contents
Do-Item "$env:LOCALAPPDATA\CrashDumps"              "Crash dumps de apps"      contents
Do-Item "$env:LOCALAPPDATA\Microsoft\Windows\INetCache" "Cache de internet"     contents
Do-Item "$env:LOCALAPPDATA\Microsoft\Windows\Explorer" "Miniaturas (se regeneran)" contents
Do-Item "C:\Windows\Logs" "Windows\Logs (1.14 GiB en julio)" contents
Do-Item "C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache" "Cache de Delivery Optimization / P2P" contents
Do-Item "$env:LOCALAPPDATA\pip" "Cache de pip" contents
Do-Item "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache" "Edge: Cache" contents
Do-Item "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Code Cache" "Edge: Code Cache" contents
Do-Item "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\GPUCache" "Edge: GPUCache" contents
Do-Item "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\DawnWebGPUCache" "Edge: DawnWebGPUCache" contents

# ---------------------------------------------------------------- FASE 2
$script:Phase = '2. Restos de instaladores'
Write-Host "`n--- 2. Restos de instaladores y versiones viejas ---" -ForegroundColor Cyan
Do-Item "C:\Program Files\Microsoft Office\Updates\Download"  "Updates de Office ya aplicados"
Do-Item "C:\ProgramData\Microsoft\VisualStudio\Packages"      "Cache del instalador de Visual Studio"
Do-Item "C:\ProgramData\Package Cache"                        "Package Cache (driver WiFi)"
Do-Item "$env:LOCALAPPDATA\Package Cache"                     "Package Cache (MSI PowerToys)"
Do-Item "$env:LOCALAPPDATA\Microsoft\Office\SolutionPackages" "SolutionPackages de Office"
Do-Item "$env:LOCALAPPDATA\Packages\AppleInc.AppleMusicWin_nzyj5cx40ttqa\LocalCache" "Cache de Apple Music"
Do-Item "$env:LOCALAPPDATA\CapCut\User Data\Cache" "CapCut: cache de trabajo (CapCut.exe y Apps\ NO se tocan)"
Do-Item "C:\ProgramData\Codemasters\GRID\DataCache\santi\replay\replay.pbf" "GRID: replay.pbf (1.95 GiB en agosto)"
Do-Item "$env:LOCALAPPDATA\puccinialin"                       "Cache de puccinialin"
Do-Item "C:\Program Files (x86)\Microsoft\EdgeUpdate\Download" "Instaladores de Edge"
Do-Item "C:\ProgramData\ASUS\ASUS System Control Interface\log" "Logs .etl de ASUS"
Do-Item "C:\ProgramData\Microsoft\Windows Defender\Scans"     "Cache de escaneos de Defender"
Do-Item "C:\Program Files (x86)\InstallShield Installation Information\{99F0EE11-3211-4EEF-85DB-75715978A3D6}\data2.cab" "data2.cab huerfano"
    Write-Host "`n--- 2b. Restos de apps que usas ---" -ForegroundColor Cyan
    Do-Item "C:\Program Files\Mozilla Firefox\updated"  "Firefox: archivos de la version anterior"
    Do-Item "$env:LOCALAPPDATA\obsidian-updater"        "Obsidian: installer.exe descargado (la app NO se toca)"
    Do-Item "$env:LOCALAPPDATA\upscayl-updater"         "Upscayl: installer.exe descargado"

# OneDrive deja la version anterior completa al actualizarse
$odRoot = "C:\Program Files\Microsoft OneDrive"
if (Test-Path -LiteralPath $odRoot) {
    $vers = @(Get-ChildItem -LiteralPath $odRoot -Directory -Force -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -match '^\d+(\.\d+){1,3}$' } | Sort-Object { [version]$_.Name } -Descending)
    if ($vers.Count -gt 1) {
        Write-Log ("OneDrive: {0} versiones instaladas -> se conserva la {1}" -f $vers.Count, $vers[0].Name)
        foreach ($v in ($vers | Select-Object -Skip 1)) { Do-Item $v.FullName ("OneDrive version vieja " + $v.Name) }
    }
}

# ---------------------------------------------------------------- FASE 3
$script:Phase = '3. Huerfanos de desarrollo'
Write-Host "`n--- 3. Restos huerfanos (sin dueno) ---" -ForegroundColor Cyan
Do-Item "$env:USERPROFILE\.vscode"                  "VS Code completo (la app YA no esta instalada)"
Do-Item "$env:APPDATA\Code"                         "Roaming\Code (config huerfana)"
Do-Item "$env:USERPROFILE\.conda"                   ".conda (conda no esta en PATH)"
Do-Item "$env:USERPROFILE\.m2"                      ".m2 (cache de Maven)"
Do-Item "$env:APPDATA\Python\Python311"             "Python 3.11 (conservas 3.14)"
Do-Item "$env:LOCALAPPDATA\jdks"                    "JDK 21 de la extension Java"
Do-Item "$env:APPDATA\Cemu"                         "Cemu (quedaba el shaderCache)"

# ---------------------------------------------------------------- FASE 4
$script:Phase = '4. opencode'
Write-Host "`n--- 4. opencode (la app desktop v2.2.0 NO se toca) ---" -ForegroundColor Cyan
Do-Item "$env:USERPROFILE\.cache\opencode\packages" "opencode: paquetes descargados (se regeneran)"
Do-Item "$env:USERPROFILE\.cache\opencode\npm" "opencode: cache npm (se regenera)"
Do-Item "$env:APPDATA\npm\node_modules\opencode-ai"             "CLI de npm v1.18.32 (el que tapaba la v2)"
Do-Item "$env:APPDATA\npm\node_modules\.opencode-ai-aEzhiY0c"   "Restos de instalacion npm"
Do-Item "$env:LOCALAPPDATA\@opencodedesktop-updater"            "Updater viejo de opencode"
Do-Item "$env:LOCALAPPDATA\@opencode-aidesktop-updater"         "Updater viejo duplicado"
Write-Log "Conservado de opencode: .local\share\opencode (base de datos), .config\opencode (config), .opencode-mem y la app desktop." 'WARN'
if ($Execute) {
    foreach ($c in @("$env:APPDATA\npm\opencode.cmd","$env:APPDATA\npm\opencode.ps1","$env:APPDATA\npm\opencode")) {
        if (Test-Path -LiteralPath $c) { Remove-Item -LiteralPath $c -Force -ErrorAction SilentlyContinue; Write-Log ("OK     wrapper quitado: {0}" -f $c) 'OK' }
    }
}


# ---------------------------------------------------------------- FASE 5
$script:Phase = '5. Shader cache'
Write-Host "`n--- 5. Shader cache de Detroit Become Human ---" -ForegroundColor Cyan
Do-Item "C:\Program Files (x86)\Steam\steamapps\common\Detroit Become Human\ShaderCache" "VkPipelineCache.bin + .bak (se regeneran)"

# ---------------------------------------------------------------- FASE 6
$script:Phase = '6. Autostart y servicios'
Write-Host "`n--- 6. Autostart basura y servicios ASUS ---" -ForegroundColor Cyan
$hkRun = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$runTargets = @('MicrosoftEdgeAutoLaunch_18AEBF0A5E369741A2CD37FC714EA93F','Sideloadly Daemon','Mozilla-Firefox-308046B0AF4A39CB')
foreach ($t in $runTargets) {
    if (-not (Get-ItemProperty -Path $hkRun -Name $t -ErrorAction SilentlyContinue)) { Write-Log ("SKIP   autostart {0} (no existe)" -f $t) 'INFO'; continue }
    if ($Execute) { Remove-ItemProperty -Path $hkRun -Name $t -Force -ErrorAction SilentlyContinue; Write-Log ("OK     fuera del arranque: {0}" -f $t) 'OK' }
    else { Write-Log ("DRY    quitaria del arranque: {0}" -f $t) 'DRY' }
}
$svcManual = @('ASUSSoftwareManager','ASUSSystemAnalysis','ASUSSystemDiagnosis','AsusAppService')
foreach ($s in $svcManual) {
    if (-not (Get-Service -Name $s -ErrorAction SilentlyContinue)) { continue }
    if (-not $Execute) { Write-Log ("DRY    servicio {0} -> Manual" -f $s) 'DRY'; continue }
    try { Set-Service -Name $s -StartupType Manual -ErrorAction Stop; Write-Log ("OK     servicio {0} -> Manual" -f $s) 'OK' }
    catch { Write-Log ("WARN   no se pudo cambiar {0}" -f $s) 'WARN' }
}
Write-Log "Conservados: ASUSOptimization, AsusPTPService, ASUSSwitch (ventilador/touchpad/Fn)." 'WARN'

# ---------------------------------------------------------------- FASE 7
if ($System) {
    $script:Phase = '7. Sistema'
    Write-Host "`n--- 7. Paquete OEM, puntos de restauracion y WinSxS ---" -ForegroundColor Cyan
    $usmt = "C:\Recovery\Customizations\usmt.ppkg"
    if (Test-Path -LiteralPath $usmt -ErrorAction SilentlyContinue) {
        $gb = (Get-SizeOf $usmt) / 1GB
        if (-not $Execute) { Write-Log ("DRY    {0,7:N2} GiB  usmt.ppkg de ASUS" -f $gb) 'DRY'; $script:Freed += $gb }
        else {
            Remove-Item -LiteralPath $usmt -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $usmt -ErrorAction SilentlyContinue)) { Write-Log ("OK     liberados {0:N2} GiB (usmt.ppkg)" -f $gb) 'OK'; $script:Freed += $gb }
            else { Write-Log "WARN   usmt.ppkg protegido; pruebe con takeown/icacls" 'WARN' }
        }
    }
    if ($Execute -and $isAdmin) {
        & vssadmin.exe resize shadowstorage /for=C: /on=C: /maxsize=2GB 2>&1 | Out-Null
        & vssadmin.exe delete shadows /for=C: /oldest /quiet 2>&1 | Out-Null
        & vssadmin.exe delete shadows /for=C: /oldest /quiet 2>&1 | Out-Null
        & vssadmin.exe delete shadows /for=C: /oldest /quiet 2>&1 | Out-Null
        Write-Log "Puntos de restauracion recortados a 2 GB" 'OK'
        Write-Log "Ejecutando DISM StartComponentCleanup (10-40 min). Sin /ResetBase por defecto, como decidiste el 31/08."
        if ($ResetBase) { & dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase /Quiet }
        else { & dism.exe /Online /Cleanup-Image /StartComponentCleanup /Quiet }
        if ($LASTEXITCODE -eq 0) { Write-Log "DISM completado (suele liberar 2-5 GiB)" 'OK' }
        else { Write-Log ("DISM devolvio codigo {0}" -f $LASTEXITCODE) 'WARN' }
    } else { Write-Log "DRY    recortaria restore a 2 GB y correria DISM sin /ResetBase" 'DRY' }
}

# ---------------------------------------------------------------- FASE 8
if ($PageFile16) {
    $script:Phase = '8. Pagefile'
    Write-Host "`n--- 8. Pagefile: 26 -> 16 GiB ---" -ForegroundColor Cyan
    if ($Execute -and $isAdmin) {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
        if ($cs -and $cs.AutomaticManagedPagefile) { Set-CimInstance -InputObject $cs -Property @{AutomaticManagedPagefile = $false } }
        $pf = Get-CimInstance -ClassName Win32_PageFileSetting -Filter "Name='C:\\pagefile.sys'" -ErrorAction SilentlyContinue
        if ($pf) { Set-CimInstance -InputObject $pf -Property @{ InitialSize = 16384; MaximumSize = 16384 } }
        else { New-CimInstance -ClassName Win32_PageFileSetting -Property @{ Name='C:\pagefile.sys'; InitialSize=16384; MaximumSize=16384 } | Out-Null }
        Write-Log "pagefile fijado en 16 GiB. Se aplica al REINICIAR y ahi se liberan los ~10 GiB." 'OK'
    } else { Write-Log "DRY    fijaria el pagefile en 16 GiB (libera ~10 GiB tras reiniciar)" 'DRY' }
}

# ---------------------------------------------------------------- FASE 9
if ($AiWorkloads) {
    $script:Phase = '9. IA de Windows'
    Write-Host "`n--- 9. Stack de IA (~7.5 GiB, suele volver) ---" -ForegroundColor Cyan
    $wl = @(Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'WindowsWorkload*' })
    Write-Log ("Paquetes WindowsWorkload encontrados: {0}" -f $wl.Count)
    foreach ($p in $wl) {
        if (-not $Execute) { continue }
        try { Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop; Write-Log ("OK     {0}" -f $p.Name) 'OK' }
        catch { Write-Log ("WARN   protegido: {0}" -f $p.Name) 'WARN' }
    }
}

# ---------------------------------------------------------------- RESUMEN
$freeAfter = $null
try { $freeAfter = [math]::Round((Get-Volume -DriveLetter C -ErrorAction Stop).SizeRemaining / 1GB, 2) } catch {}
Write-Host "`n================= RESUMEN =================" -ForegroundColor Magenta
Write-Log ("Total {0}: {1:N2} GiB" -f $(if ($Execute) { 'liberado' } else { 'recuperable' }), $script:Freed)
if ($freeBefore -ne $null -and $freeAfter -ne $null) { Write-Log ("Libre: {0} GiB  ->  {1} GiB" -f $freeBefore, $freeAfter) }
if (-not $Execute) { Write-Log "NADA SE BORRO. Repite con -Execute." 'DRY' }
if ($System -and -not $Execute) { Write-Log "Incluye Fase 7 (usmt + restore + DISM) en el calculo." 'DRY' }
$script:Log | Set-Content -LiteralPath $LogPath -Encoding UTF8 -ErrorAction SilentlyContinue
Write-Log ("Log: {0}" -f $LogPath)
Write-Host ""





