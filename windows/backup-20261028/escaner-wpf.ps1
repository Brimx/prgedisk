#Requires -Version 5.1
<#
    escaner-gui.ps1  -  limpiador visual con seleccion por casillas
    =================================================================
    Mismo motor de reglas que escaner.ps1, pero con ventana:
    seleccionas que borrar, ves cuanto pesa, y confirmas.

    Uso:
        powershell -ExecutionPolicy Bypass -File .\escaner-gui.ps1
        powershell -ExecutionPolicy Bypass -File .\escaner-gui.ps1 -SelfTest   (prueba sin ventana)

    Archivo en ASCII puro: PowerShell 5.1 lee los .ps1 como ANSI sin BOM y
    cualquier tilde o guion largo rompe el parser.
#>
[CmdletBinding()]
param(
    [string]$Csv,
    [switch]$SelfTest,
    [switch]$NoShow
)

$ErrorActionPreference = 'Continue'
$GB = 1024MB
$script:Items = New-Object System.Collections.Generic.List[object]
$script:MinMB = 20
$script:MinFileMB = 100

# ======================================================== MOTOR DE REGLAS
$Rules = @(
    @{ C='NUNCA'; R='^c:\\windows\\(winsxs|system32|syswow64|assembly|servicing|installer|microsoft\.net|systemresources|boot)(\\|$)'; W='nucleo de Windows' }
    @{ C='NUNCA'; R='^c:\\windows\\[^\\]+$';                                                W='carpeta raiz de Windows' }
    @{ C='NUNCA'; R='^c:\\program files\\windowsapps';                                       W='apps de la Store' }
    @{ C='NUNCA'; R='^c:\\program files\\(microsoft visual studio|dotnet|microsoft office)'; W='VS / dotnet / Office' }
    @{ C='NUNCA'; R='^c:\\program files \(x86\)\\steam\\steamapps\\common';                  W='juegos de Steam' }
    @{ C='NUNCA'; R='^c:\\games';                                                            W='tus juegos' }
    @{ C='NUNCA'; R='^c:\\(system volume information|recovery|\$recycle\.bin|\$sysreset|\$extend)'; W='sistema / restauracion' }
    @{ C='NUNCA'; R='^c:\\\$'; W='metadatos NTFS (MFT, LogFile, Bitmap, UpCase)' }
    @{ C='NUNCA'; R='^c:\\program files( \(x86\))?\\microsoft\\edge'; W='Edge / WebView2' }

    @{ C='NUNCA'; R='^c:\\(hiberfil\.sys|pagefile\.sys|swapfile\.sys|dumpstack\.log\.tmp)';  W='memoria virtual' }
    @{ C='NUNCA'; R='^c:\\programdata\\(microsoft\\windows\\apprepository|microsoft\\crypto|microsoft\\windows defender)'; W='base de datos del sistema' }
    @{ C='NUNCA'; R='\\(documents|onedrive|escritorio|desktop|pictures|imagenes|videos|music|musica)\\(?!.*\\(cache|temp|caches)$)'; W='tus documentos' }
    @{ C='NUNCA'; R='\\(saved games|my games|savegame|savegames)\\';                          W='partidas guardadas' }
    @{ C='NUNCA'; R='\\(\.local\\share|\.opencode-mem|\.codex|\.bun|\.claude|\.gemini)(\\|$)';   W='datos y config de herramientas dev' }
    @{ C='NUNCA'; R='\\(\.ssh|\.gnupg|\.dsh|\.git)(\\|$)';                                    W='config / claves / sandbox DSH' }
    @{ C='NUNCA'; R='\\appdata\\roaming\\[^\\]+$';                                            W='perfil de aplicacion' }
    @{ C='NUNCA'; R='\\appdata\\roaming\\[^\\]+\\[^\\]+$';                                    W='datos de aplicacion' }
    @{ C='NUNCA'; R='\\appdata\\local\\(programs|packages)\\[^\\]+$';                          W='aplicacion instalada' }
    @{ C='NUNCA'; R='\\.(docx?|xlsx?|pptx?|pdf|psd|blend|kra|zip|7z|rar|iso|vhdx?|img)$';      W='archivo de usuario' }
    @{ C='NUNCA'; R='\\.(psarc|pak|mpk|pck|vpk|bsa|ba2|bundle)$';                              W='assets de juego' }

    @{ C='SEGURO'; R='\\appdata\\local\\temp(\\|$)';                                           W='temporal del usuario' }
    @{ C='SEGURO'; R='^c:\\windows\\temp(\\|$)';                                               W='temporal de Windows' }
    @{ C='SEGURO'; R='\\appdata\\local\\packages\\[^\\]+\\localcache(\\|$)';                   W='cache de app UWP' }
    @{ C='SEGURO'; R='\\appdata\\local\\packages\\[^\\]+\\tempstate(\\|$)';                    W='estado temporal de app UWP' }
    @{ C='SEGURO'; R='\\appdata\\local\\(npm-cache|pip|ms-playwright|crashdumps|thumbnails|node-gyp)(\\|$)'; W='cache de herramientas' }
    @{ C='SEGURO'; R='\\appdata\\local\\(yarn|pnpm|cargo|go-build|gradle)(\\|$)';              W='cache de build' }
    @{ C='SEGURO'; R='\\appdata\\roaming\\[^\\]+\\(cache|caches|code cache|gpucache|dawncache|dawnwebgpucache|grshadercache|cachestorage|scriptcache|blob_storage|gpu cache|shadercache)(\\|$)'; W='cache en perfil de app' }
    @{ C='SEGURO'; R='\\appdata\\local\\[^\\]+\\(cache|caches|code cache|gpucache|dawncache|dawnwebgpucache|grshadercache|cachestorage|scriptcache|blob_storage|gpu cache|shadercache|tempstate)(\\|$)'; W='cache en perfil de app' }
    @{ C='SEGURO'; R='^c:\\windows\\(logs|livekernelreports|minidump)(\\|$)';                  W='logs y dumps de Windows' }
    @{ C='SEGURO'; R='^c:\\windows\\softwaredistribution\\download(\\|$)';                     W='cache de Windows Update' }
    @{ C='SEGURO'; R='^c:\\windows\\serviceprofiles\\[^\\]+\\appdata\\local\\microsoft\\windows\\deliveryoptimization'; W='cache P2P de updates' }
    @{ C='SEGURO'; R='^c:\\programdata\\(package cache|microsoft\\visualstudio\\packages|microsoft\\edgeupdate|usoshared)(\\|$)'; W='cache de instaladores' }
    @{ C='SEGURO'; R='\\programdata\\microsoft\\windows defender\\(scans|definition updates\\backup)(\\|$)'; W='cache de Defender' }
    @{ C='SEGURO'; R='\\steamapps\\(downloading|temp)(\\|$)';                                   W='descargas temporales de Steam' }
    @{ C='SEGURO'; R='\\.(dmp|mdmp|etl|tmp|old|bak|log)$';                                      W='dumps / logs / temporales' }
    @{ C='SEGURO'; R='\\\.cache\\';                                                             W='cache de herramientas dev' }

    @{ C='REVISAR'; R='\\(node_modules|__pycache__|\.pytest_cache|\.mypy_cache)(\\|$)';         W='dependencias de proyecto' }
    @{ C='REVISAR'; R='\\(dist|build|out|target|\.next|\.nuxt|coverage)(\\|$)';                 W='artefactos de build' }
    @{ C='REVISAR'; R='(\\|^)(cache|caches|cache_pc|shadercache|shader cache|logs|log|crashdumps|crashdump|temp)(\\|$)'; W='cache dentro de programa o juego' }
    @{ C='REVISAR'; R='^c:\\program files \(x86\)\\steam\\steamapps\\common\\[^\\]+\\(shadercache|cache|logs)'; W='cache de juego Steam' }
    @{ C='REVISAR'; R='\.old$|_old$|\.bak$|backup|respaldo';                                    W='respaldo probable' }
    @{ C='REVISAR'; R='\\(downloads|desktop|escritorio)\\.*\.(msi|exe|msix|appx)$';             W='instalador descargado' }
    @{ C='NUNCA'; R='\.(exe|dll|sys|ocx|node|pyd)$';                                            W='binario de programa (no es instalador)' }
    @{ C='REVISAR'; R='\\appdata\\local\\programs\\';                                           W='app instalada por usuario' }
    @{ C='NUNCA'; R='\\appdata\\local\\[^\\]+$'; W='perfil de aplicacion' }
)

function Get-RuleFor {
    param([string]$Path)
    $low = $Path.ToLower().TrimEnd('\')
    foreach ($r in $Rules) { if ($low -match $r.R) { return $r } }
    return $null
}

# ======================================================== ESCANEO
function Get-Huella {
    param([string]$Ruta)
    try {
        $it = @(Get-ChildItem -LiteralPath $Ruta -Force -ErrorAction SilentlyContinue | Select-Object -First 500)
        if ($it.Count -eq 0) { return $null }
        $nombres = @()
        $nArch = 0
        $cDll = 0; $cExe = 0; $cMsi = 0; $cLog = 0; $cDb = 0; $cAs = 0
        foreach ($x in $it) {
            $nm = $x.Name.ToLower()
            $nombres += $nm
            if (-not $x.PSIsContainer) {
                $nArch++
                $ex = [System.IO.Path]::GetExtension($nm)
                if ($ex -eq '.dll') { $cDll++ }
                elseif ($ex -eq '.exe') { $cExe++ }
                elseif ($ex -eq '.msi') { $cMsi++ }
                elseif ($ex -eq '.log' -or $ex -eq '.tmp' -or $ex -eq '.dmp' -or $ex -eq '.etl') { $cLog++ }
                elseif ($ex -eq '.db' -or $ex -eq '.sqlite' -or $ex -eq '.mdf' -or $ex -eq '.ldb') { $cDb++ }
                elseif ($ex -eq '.pak' -or $ex -eq '.psarc' -or $ex -eq '.pck' -or $ex -eq '.assets') { $cAs++ }
            }
        }
        $hoja = (Split-Path -Leaf $Ruta).ToLower()
        if ($nombres -contains 'unins000.exe' -or $nombres -contains 'uninstall.exe' -or $nombres -contains 'uninst.exe') { return @{ C='NUNCA'; W='huella: tiene desinstalador, es app instalada' } }
        if ($nombres -contains ($hoja + '.exe')) { return @{ C='NUNCA'; W='huella: el .exe coincide con la carpeta' } }
        if ($cDb -gt 0) { return @{ C='NUNCA'; W='huella: contiene base de datos' } }
        if ($cAs -gt 0) { return @{ C='NUNCA'; W='huella: contiene assets de juego' } }
        if ($nArch -gt 3 -and $cDll -ge ($nArch * 0.4)) { return @{ C='NUNCA'; W='huella: mayoria de bibliotecas .dll' } }
        if ($cMsi -gt 0 -or $nombres -contains 'setup.exe') { return @{ C='REVISAR'; W='huella: instalador empaquetado' } }
        if ($nArch -gt 3 -and $cLog -ge ($nArch * 0.4)) { return @{ C='SEGURO'; W='huella: mayoria de logs y temporales' } }
        if ($nArch -gt 200 -and $cExe -eq 0) { return @{ C='REVISAR'; W='huella: cientos de archivos sueltos (cache probable)' } }
        if ($nArch -eq 0) { return @{ C='DESCONOCIDO'; W='huella: solo subcarpetas, revisar a mano' } }
        return @{ C='DESCONOCIDO'; W='huella: contenido vario, revisar a mano' }
    } catch {
        return @{ C='DESCONOCIDO'; W='huella: no se pudo inspeccionar' }
    }
}
function Invoke-Scan {
    param([switch]$LiveScan, [string]$CsvPath)

    $dirs  = New-Object System.Collections.Generic.List[object]
    $files = New-Object System.Collections.Generic.List[object]

    if ($LiveScan) {
        $prune = @('c:\windows\winsxs','c:\games','c:\program files\windowsapps','c:\system volume information','c:\$recycle.bin','c:\users\santi\onedrive')
        $stack = New-Object System.Collections.Generic.Stack[string]
        $stack.Push('C:\Users\santi')
        $stack.Push('C:\')
        while ($stack.Count -gt 0) {
            $cur = $stack.Pop()
            $lowCur = $cur.ToLower()
            $skip = $false
            foreach ($p in $prune) { if ($lowCur.StartsWith($p)) { $skip = $true; break } }
            if ($skip) { continue }
            try {
                foreach ($d in [System.IO.Directory]::EnumerateDirectories($cur)) {
                    $nm = [System.IO.Path]::GetFileName($d)
                    if ($nm -eq 'System Volume Information' -or $nm -eq '$Recycle.Bin') { continue }
                    $stack.Push($d)
                }
            } catch { }
            $sum = 0L
            try {
                foreach ($fi in (New-Object System.IO.DirectoryInfo($cur)).EnumerateFiles()) {
                    try {
                        $sum += $fi.Length
                        if ($fi.Length -ge ($script:MinFileMB * 1MB)) { $files.Add([pscustomobject]@{ Path = $fi.FullName; Bytes = $fi.Length }) }
                    } catch { }
                }
            } catch { }
            if ($sum -ge ($script:MinMB * 1MB)) { $dirs.Add([pscustomobject]@{ Path = $cur; Bytes = $sum; Depth = ($cur.Split('\').Count) }) }
        }
    } else {
        if (-not $CsvPath) {
            $found = Get-ChildItem "$env:USERPROFILE\OneDrive\Documentos","$env:USERPROFILE\Documentos" -Filter 'WizTree_*.csv' -ErrorAction SilentlyContinue |
                     Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($found) { $CsvPath = $found.FullName }
        }
        if (-not $CsvPath -or -not (Test-Path -LiteralPath $CsvPath)) { throw "No hay CSV de WizTree. Marca 'Escaneo en vivo'." }
        $reader = New-Object System.IO.StreamReader($CsvPath, [System.Text.Encoding]::UTF8)
        try {
            $null = $reader.ReadLine(); $null = $reader.ReadLine()
            while ($null -ne ($line = $reader.ReadLine())) {
                if ($line.Length -lt 5 -or $line[0] -ne [char]'"') { continue }
                $end = $line.IndexOf('"', 1)
                if ($end -lt 0) { continue }
                $path = $line.Substring(1, $end - 1)
                $rest = $line.Substring($end + 1).Split(',')
                if ($rest.Count -lt 3) { continue }
                $alloc = 0L
                if (-not [long]::TryParse($rest[2], [ref]$alloc)) { continue }
                if ($path.EndsWith('\')) {
                    if ($alloc -lt ($script:MinMB * 1MB)) { continue }
                    $p = $path.TrimEnd('\')
                    $dirs.Add([pscustomobject]@{ Path = $p; Bytes = $alloc; Depth = ($p.Split('\').Count) })
                } else {
                    if ($alloc -lt ($script:MinFileMB * 1MB)) { continue }
                    $files.Add([pscustomobject]@{ Path = $path; Bytes = $alloc })
                }
            }
        } finally { $reader.Close() }
    }

    $items = New-Object System.Collections.Generic.List[object]
    $covered = New-Object 'System.Collections.Generic.HashSet[string]'

    foreach ($d in ($dirs | Sort-Object Depth)) {
        $parts = $d.Path.ToLower().Split('\')
        $acc = ''; $skp = $false
        for ($i = 0; $i -lt ($parts.Count - 1); $i++) {
            if ($i -eq 0) { $acc = $parts[0] } else { $acc = $acc + '\' + $parts[$i] }
            if ($covered.Contains($acc)) { $skp = $true; break }
        }
        if ($skp) { continue }
        $rule = Get-RuleFor -Path $d.Path
        if (-not $rule) { continue }
        $null = $covered.Add($d.Path.ToLower())
        $items.Add([pscustomobject]@{
            Categoria = $rule.C; Motivo = $rule.W; Ruta = $d.Path; Tipo = 'Carpeta'
            GiB = [math]::Round($d.Bytes / $GB, 2); Bytes = $d.Bytes; RegPath = $null; RegName = $null
        })
    }
    # --- 1b) cobertura: carpetas pesadas que ninguna regla explica
    foreach ($d in ($dirs | Sort-Object Depth)) {
        if ($d.Bytes -lt (1GB)) { continue }
        if ($d.Path.Split('\').Count -lt 6) { continue }
        if (@('appdata','roaming','local','locallow','programdata','program files','program files (x86)','windows','users','onedrive','documentos','documents') -contains (Split-Path -Leaf $d.Path).ToLower()) { continue }
        $parts = $d.Path.ToLower().Split('\')
        $acc = ''; $skp = $false
        for ($i = 0; $i -lt ($parts.Count - 1); $i++) {
            if ($i -eq 0) { $acc = $parts[0] } else { $acc = $acc + '\' + $parts[$i] }
            if ($covered.Contains($acc)) { $skp = $true; break }
        }
        if ($skp) { continue }
        if (Get-RuleFor -Path $d.Path) { continue }
        $null = $covered.Add($d.Path.ToLower())
        $h = Get-Huella -Ruta $d.Path
        if (-not $h) { $h = @{ C='DESCONOCIDO'; W='carpeta pesada sin regla' } }
        $items.Add([pscustomobject]@{
            Categoria = $h.C; Motivo = $h.W
            Ruta = $d.Path; Tipo = 'Carpeta'
            GiB = [math]::Round($d.Bytes / $GB, 2); Bytes = $d.Bytes; RegPath = $null; RegName = $null
        })
    }

    foreach ($f in ($files | Sort-Object Bytes -Descending)) {
        $parts = $f.Path.ToLower().Split('\')
        $acc = ''; $skp = $false
        for ($i = 0; $i -lt ($parts.Count - 1); $i++) {
            if ($i -eq 0) { $acc = $parts[0] } else { $acc = $acc + '\' + $parts[$i] }
            if ($covered.Contains($acc)) { $skp = $true; break }
        }
        if ($skp) { continue }
        $rule = Get-RuleFor -Path $f.Path
        if (-not $rule) {
        if ($f.Path -match '^c:\\(program files|windows|programdata)') { $rule = @{ C='NUNCA'; W='binario de sistema o programa' } }
        else { $rule = @{ C='DESCONOCIDO'; W='archivo grande sin clasificar' } }
    }
        $items.Add([pscustomobject]@{
            Categoria = $rule.C; Motivo = $rule.W; Ruta = $f.Path; Tipo = 'Archivo'
            GiB = [math]::Round($f.Bytes / $GB, 2); Bytes = $f.Bytes; RegPath = $null; RegName = $null
        })
    }

    # --- registros huerfanos (autostart a la nada)
    $hives = @('HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run')
    foreach ($hive in $hives) {
        if (-not (Test-Path $hive)) { continue }
        $props = Get-ItemProperty $hive -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -like 'PS*') { continue }
            $cmd = [string]$p.Value
            $exe = $null
            if ($cmd -match '^\s*"([^"]+)"') { $exe = $Matches[1] } elseif ($cmd -match '^\s*(\S+\.exe)') { $exe = $Matches[1] }
            if (-not $exe) { continue }
            $exe = [Environment]::ExpandEnvironmentVariables($exe)
            if (-not (Test-Path -LiteralPath $exe -ErrorAction SilentlyContinue)) {
                $items.Add([pscustomobject]@{
                    Categoria = 'SEGURO'; Motivo = 'autostart roto (exe inexistente)'
                    Ruta = $exe; Tipo = 'Registro'; GiB = 0; Bytes = 0; RegPath = $hive; RegName = $p.Name
                })
            }
        }
    }

    # --- registros de desinstalacion huerfanos (programa ya no esta)
    $uninst = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')
    foreach ($root in $uninst) {
        foreach ($k in (Get-ItemProperty $root -ErrorAction SilentlyContinue)) {
            $loc = $k.InstallLocation
            $dn  = $k.DisplayName
            if (-not $dn -or -not $loc) { continue }
            $loc = $loc.Trim().Trim('"')
            if ($loc.Length -lt 4) { continue }
            if (-not (Test-Path -LiteralPath $loc -ErrorAction SilentlyContinue)) {
                $items.Add([pscustomobject]@{
                    Categoria = 'REVISAR'; Motivo = ('registro huerfano: ' + $dn)
                    Ruta = $loc; Tipo = 'Registro'; GiB = 0; Bytes = 0
                    RegPath = ($k.PSPath -replace '^Microsoft\.PowerShell\.Core\\Registry::', ''); RegName = $null
                })
            }
        }
    }
    return $items
}

# ======================================================== BORRADO
function Remove-ItemSafe {
    param($Item)
    if ($Item.Categoria -eq 'NUNCA') { return $false }
    if ($Item.Tipo -eq 'Registro') {
        if ($Item.RegName) { Remove-ItemProperty -Path $Item.RegPath -Name $Item.RegName -Force -ErrorAction SilentlyContinue }
        else { Remove-Item -LiteralPath $Item.RegPath -Recurse -Force -ErrorAction SilentlyContinue }
        return $true
    }
    if (-not (Test-Path -LiteralPath $Item.Ruta)) { return $false }
    if ($Item.Ruta -match '\\temp$') {
        Get-ChildItem -LiteralPath $Item.Ruta -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike 'dsh-*' } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    } elseif ($Item.Tipo -eq 'Archivo') {
        Remove-Item -LiteralPath $Item.Ruta -Force -ErrorAction SilentlyContinue
    } else {
        Remove-Item -LiteralPath $Item.Ruta -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $true
}

# ======================================================== MODO PRUEBA
if ($SelfTest) {
    Write-Host "SelfTest: escaneando..."
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $script:Items = Invoke-Scan -CsvPath $Csv
    $sw.Stop()
    Write-Host ("Items: {0}  en {1:N1} s" -f $script:Items.Count, $sw.Elapsed.TotalSeconds)
    foreach ($cat in @('SEGURO','REVISAR','DESCONOCIDO','NUNCA')) {
        $s = @($script:Items | Where-Object { $_.Categoria -eq $cat })
        $t = ($s | Measure-Object Bytes -Sum).Sum / $GB
        Write-Host ("  {0}: {1} items, {2:N2} GiB" -f $cat, $s.Count, $t)
    }
    $reg = @($script:Items | Where-Object { $_.Tipo -eq 'Registro' })
    Write-Host ("  registros: {0}" -f $reg.Count)
    foreach ($r in $reg) { Write-Host ("     {0} [{1}] {2}" -f $r.Motivo, $r.Tipo, $r.Ruta) }
    Write-Host "SelfTest OK (no se abrio ventana, no se borro nada)"
    return
}


# ======================================================== VENTANA WPF
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

class Fila {
    [string]$Nivel
    [string]$Motivo
    [double]$GiB
    [string]$Tipo
    [string]$Ruta
    [string]$Propietario
    [bool]$Marcado
    [object]$Dato
}

function Get-Propietario {
    param([string]$Ruta)
    $p = $Ruta
    $raices = @('\appdata\local\','\appdata\roaming\','\appdata\locallow\','\program files\','\program files (x86)\','\programdata\')
    $low = $p.ToLower()
    foreach ($r in $raices) {
        $i = $low.IndexOf($r)
        if ($i -ge 0) {
            $resto = $p.Substring($i + $r.Length)
            $seg = $resto.Split('\')[0]
            if ($seg) { return $seg }
        }
    }
    if ($low.StartsWith('c:\games\')) { return $p.Substring(9).Split('\')[0] }
    if ($low -match '^c:\\users\\[^\\]+\\([^\\]+)') { return '.' + $Matches[1] }
    if ($low -match '^c:\\(windows|programdata)') { return '(sistema)' }
    return '(sin dueno)'
}

$Colores = @{
    'SEGURO' = '#82D282'; 'REVISAR' = '#EBC35A'; 'DESCONOCIDO' = '#CD82E1'; 'NUNCA' = '#7D7D8A'
}

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Limpiador C:  -  WPF" Height="780" Width="1240"
        Background="#26262C" Foreground="#E8E8EE"
        WindowStartupLocation="CenterScreen" MinWidth="1000" MinHeight="620">
  <Window.Resources>
    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#E8E8EE"/></Style>
    <Style TargetType="Label"><Setter Property="Foreground" Value="#E8E8EE"/></Style>
    <Style TargetType="CheckBox"><Setter Property="Foreground" Value="#E8E8EE"/><Setter Property="VerticalAlignment" Value="Center"/><Setter Property="Margin" Value="4,0,10,0"/></Style>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#3C3C48"/>
      <Setter Property="Foreground" Value="#E8E8EE"/>
      <Setter Property="BorderBrush" Value="#4A4A58"/>
      <Setter Property="Padding" Value="10,4"/>
      <Setter Property="Margin" Value="4,2"/>
      <Setter Property="BorderThickness" Value="1"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#1E1E23"/>
      <Setter Property="Foreground" Value="#E8E8EE"/>
      <Setter Property="BorderBrush" Value="#4A4A58"/>
      <Setter Property="CaretBrush" Value="#E8E8EE"/>
      <Setter Property="Padding" Value="4,3"/>
    </Style>
    <Style TargetType="DataGrid">
      <Setter Property="Background" Value="#1E1E23"/>
      <Setter Property="Foreground" Value="#E8E8EE"/>
      <Setter Property="RowBackground" Value="#1E1E23"/>
      <Setter Property="AlternatingRowBackground" Value="#232329"/>
      <Setter Property="GridLinesVisibility" Value="None"/>
      <Setter Property="BorderBrush" Value="#4A4A58"/>
      <Setter Property="HeadersVisibility" Value="Column"/>
      <Setter Property="SelectionMode" Value="Extended"/>
      <Setter Property="CanUserSortColumns" Value="True"/>
    </Style>
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="#32323A"/>
      <Setter Property="Foreground" Value="#E8E8EE"/>
      <Setter Property="Padding" Value="6,5"/>
      <Setter Property="BorderBrush" Value="#4A4A58"/>
      <Setter Property="BorderThickness" Value="0,0,1,1"/>
    </Style>
    <Style TargetType="DataGridCell">
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#E8E8EE"/>
    </Style>
    <Style TargetType="DataGridRow">
      <Setter Property="Foreground" Value="#E8E8EE"/>
    </Style>
    <Style TargetType="GroupBox">
      <Setter Property="Foreground" Value="#E8E8EE"/>
      <Setter Property="BorderBrush" Value="#4A4A58"/>
    </Style>
  </Window.Resources>
  <Grid Margin="8">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="*"/>
      <ColumnDefinition Width="420"/>
    </Grid.ColumnDefinitions>

    <StackPanel Grid.Row="0" Grid.ColumnSpan="2" Orientation="Horizontal">
      <TextBlock Text="Niveles:" VerticalAlignment="Center" Margin="0,0,6,0"/>
      <CheckBox x:Name="chkSeguro" Content="SEGURO" IsChecked="True"/>
      <CheckBox x:Name="chkRevisar" Content="REVISAR" IsChecked="True"/>
      <CheckBox x:Name="chkDesc" Content="DESCONOCIDO" IsChecked="True"/>
      <CheckBox x:Name="chkNunca" Content="NUNCA" IsChecked="False"/>
      <CheckBox x:Name="chkGrande" Content="Solo &gt; 1 GiB" IsChecked="False"/>
      <CheckBox x:Name="chkAgrupar" Content="Agrupar por programa" IsChecked="False"/>
    </StackPanel>

    <StackPanel Grid.Row="1" Grid.ColumnSpan="2" Orientation="Horizontal" Margin="0,6,0,6">
      <TextBlock Text="Buscar:" VerticalAlignment="Center" Margin="0,0,6,0"/>
      <TextBox x:Name="txtBuscar" Width="260"/>
      <Button x:Name="btnEscanear" Content="Escanear" Margin="12,0,4,0"/>
      <Button x:Name="btnTodos" Content="Marcar visibles"/>
      <Button x:Name="btnNinguno" Content="Desmarcar"/>
      <Button x:Name="btnExportar" Content="Exportar seleccion"/>
      <TextBlock x:Name="lblEstado" Text="Escaneando..." VerticalAlignment="Center" Margin="12,0,0,0" Foreground="#96969E"/>
    </StackPanel>

    <DataGrid x:Name="dg" Grid.Row="2" Grid.Column="0" AutoGenerateColumns="False"
              IsReadOnly="False" CanUserAddRows="False" CanUserDeleteRows="False" SelectionUnit="FullRow" AlternationCount="2" Margin="0,0,8,0">
      <DataGrid.Columns>
        <DataGridCheckBoxColumn Binding="{Binding Marcado, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" Width="34"/>
        <DataGridTextColumn Header="Nivel" Binding="{Binding Nivel}" Width="86" IsReadOnly="True"/>
        <DataGridTextColumn Header="Motivo" Binding="{Binding Motivo}" Width="190" IsReadOnly="True"/>
        <DataGridTextColumn Header="GiB" Binding="{Binding GiB, StringFormat=N2}" Width="66" IsReadOnly="True">
          <DataGridTextColumn.ElementStyle>
            <Style TargetType="TextBlock"><Setter Property="HorizontalAlignment" Value="Right"/></Style>
          </DataGridTextColumn.ElementStyle>
        </DataGridTextColumn>
        <DataGridTextColumn Header="Tipo" Binding="{Binding Tipo}" Width="62" IsReadOnly="True"/>
        <DataGridTextColumn Header="Dueño" Binding="{Binding Propietario}" Width="120" IsReadOnly="True"/>
        <DataGridTextColumn Header="Ruta" Binding="{Binding Ruta}" Width="*" IsReadOnly="True"/>
      </DataGrid.Columns>
    </DataGrid>

    <DockPanel Grid.Row="2" Grid.Column="1">
      <TextBlock DockPanel.Dock="Top" Text="Que hay aqui" FontWeight="Bold" Margin="0,0,0,4"/>
      <Button x:Name="btnAbrir" DockPanel.Dock="Bottom" Content="Abrir carpeta en Explorer" Margin="0,6,0,0"/>
      <TextBox x:Name="txtPreview" IsReadOnly="True" AcceptsReturn="True" TextWrapping="NoWrap"
               VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
               FontFamily="Consolas" FontSize="11"/>
    </DockPanel>

    <DockPanel Grid.Row="3" Grid.ColumnSpan="2" Margin="0,8,0,0">
      <TextBlock x:Name="lblTotal" Text="Seleccionado: 0 elementos, 0.00 GiB" FontWeight="Bold" VerticalAlignment="Center"/>
      <Button x:Name="btnBorrar" Content="Borrar seleccionado" DockPanel.Dock="Right" Background="#BE3737" Foreground="White" Margin="8,0,0,0"/>
    </DockPanel>
  </Grid>
</Window>
"@

$win = [Windows.Markup.XamlReader]::Parse($xaml)

$dg         = $win.FindName('dg')
$txtBuscar  = $win.FindName('txtBuscar')
$txtPreview = $win.FindName('txtPreview')
$lblTotal   = $win.FindName('lblTotal')
$lblEstado  = $win.FindName('lblEstado')
$chkSeguro  = $win.FindName('chkSeguro')
$chkRevisar = $win.FindName('chkRevisar')
$chkDesc    = $win.FindName('chkDesc')
$chkNunca   = $win.FindName('chkNunca')
$chkGrande  = $win.FindName('chkGrande')
$chkAgrupar = $win.FindName('chkAgrupar')
$btnEscanear= $win.FindName('btnEscanear')
$btnTodos   = $win.FindName('btnTodos')
$btnNinguno = $win.FindName('btnNinguno')
$btnExportar= $win.FindName('btnExportar')
$btnBorrar  = $win.FindName('btnBorrar')
$btnAbrir   = $win.FindName('btnAbrir')

$script:Vista = New-Object System.Windows.Data.CollectionViewSource

function Get-NivelesActivos {
    $n = @()
    if ($chkSeguro.IsChecked)  { $n += 'SEGURO' }
    if ($chkRevisar.IsChecked) { $n += 'REVISAR' }
    if ($chkDesc.IsChecked)    { $n += 'DESCONOCIDO' }
    if ($chkNunca.IsChecked)   { $n += 'NUNCA' }
    return $n
}

function Update-Total {
    $sum = 0.0; $cnt = 0
    foreach ($f in $script:Vista.Source) {
        if ($f.Marcado) { $cnt++; $sum += $f.GiB }
    }
    $lblTotal.Text = ('Seleccionado: {0} elementos, {1:N2} GiB' -f $cnt, $sum)
}

function Refrescar {
    $niveles = Get-NivelesActivos
    $texto = $txtBuscar.Text.Trim().ToLower()
    $soloGrande = [bool]$chkGrande.IsChecked
    $lista = New-Object System.Collections.ObjectModel.ObservableCollection[Fila]
    foreach ($it in $script:Items) {
        if ($niveles.Count -gt 0 -and ($niveles -notcontains $it.Categoria)) { continue }
        if ($soloGrande -and $it.GiB -lt 1) { continue }
        if ($texto.Length -gt 0 -and ($it.Ruta.ToLower().IndexOf($texto) -lt 0)) { continue }
        $f = New-Object Fila
        $f.Nivel = $it.Categoria
        $f.Motivo = $it.Motivo
        $f.GiB = $it.GiB
        $f.Tipo = $it.Tipo
        $f.Ruta = $it.Ruta
        $f.Propietario = Get-Propietario -Ruta $it.Ruta
        $f.Marcado = $false
        $f.Dato = $it
        $lista.Add($f)
    }
    $script:Vista.Source = $lista
    $dg.ItemsSource = $script:Vista.View
    $script:Vista.GroupDescriptions.Clear()
    if ($chkAgrupar.IsChecked) {
        $script:Vista.GroupDescriptions.Add((New-Object System.Windows.Data.PropertyGroupDescription('Propietario')))
        $dg.Items.Refresh()
    }
    $lblEstado.Text = ('Mostrando {0} de {1} elementos' -f $lista.Count, $script:Items.Count)
    Update-Total
}

function Show-Preview {
    param($It)
    if (-not $It) { $txtPreview.Text = ''; return }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine($It.Categoria + '  -  ' + $It.Motivo)
    [void]$sb.AppendLine(('Tamano: {0:N2} GiB     Tipo: {1}' -f $It.GiB, $It.Tipo))
    [void]$sb.AppendLine($It.Ruta)
    [void]$sb.AppendLine('')
    if ($It.Tipo -eq 'Registro') {
        [void]$sb.AppendLine('Entrada de registro, no ocupa disco.')
        if ($It.RegPath) { [void]$sb.AppendLine('Clave: ' + $It.RegPath) }
        if ($It.RegName) { [void]$sb.AppendLine('Valor: ' + $It.RegName) }
    } elseif (Test-Path -LiteralPath $It.Ruta) {
        try {
            if ($It.Tipo -eq 'Archivo') {
                $fi = Get-Item -LiteralPath $It.Ruta -Force -ErrorAction Stop
                [void]$sb.AppendLine(('Archivo: {0:N1} MB' -f ($fi.Length / 1MB)))
                [void]$sb.AppendLine('Modificado: ' + $fi.LastWriteTime)
            } else {
                $kids = @(Get-ChildItem -LiteralPath $It.Ruta -Force -ErrorAction SilentlyContinue)
                $arch = @($kids | Where-Object { -not $_.PSIsContainer })
                $dirs = @($kids | Where-Object { $_.PSIsContainer })
                [void]$sb.AppendLine(('Contenido: {0} archivos, {1} subcarpetas' -f $arch.Count, $dirs.Count))
                [void]$sb.AppendLine('')
                foreach ($x in ($arch | Sort-Object Length -Descending | Select-Object -First 14)) {
                    [void]$sb.AppendLine(('  {0,8:N1} MB  {1}' -f ($x.Length / 1MB), $x.Name))
                }
                foreach ($d in ($dirs | Select-Object -First 14)) { [void]$sb.AppendLine('  [dir] ' + $d.Name) }
            }
        } catch { [void]$sb.AppendLine('No se pudo leer: ' + $_.Exception.Message) }
    } else { [void]$sb.AppendLine('La ruta ya no existe en disco.') }
    $txtPreview.Text = $sb.ToString()
}

$dg.ItemsSource = $script:Vista.View

$dg.Add_SelectionChanged({
    if ($dg.SelectedItem) { Show-Preview -It $dg.SelectedItem.Dato } else { $txtPreview.Text = '' }
})

$dg.Add_MouseDoubleClick({
    if ($dg.SelectedItem) {
        $f = $dg.SelectedItem
        if ($f.Nivel -ne 'NUNCA') { $f.Marcado = -not $f.Marcado; $dg.Items.Refresh(); Update-Total }
    }
})

$dg.Add_KeyDown({
    param($snd, $evt)
    if ($evt.Key -eq 'A' -and $evt.KeyboardDevice.Modifiers -eq 'Control') {
        foreach ($f in $script:Vista.Source) { if ($f.Nivel -ne 'NUNCA') { $f.Marcado = $true } }
        $dg.Items.Refresh(); Update-Total
        $evt.Handled = $true
    }
})

$dg.Add_CurrentCellChanged({ Update-Total })

$chkSeguro.Add_Click({ Refrescar })
$chkRevisar.Add_Click({ Refrescar })
$chkDesc.Add_Click({ Refrescar })
$chkNunca.Add_Click({ Refrescar })
$chkGrande.Add_Click({ Refrescar })
$chkAgrupar.Add_Click({ Refrescar })
$txtBuscar.Add_TextChanged({ Refrescar })

$btnEscanear.Add_Click({
    $lblEstado.Text = 'Escaneando...'
    try {
        $script:Items = Invoke-Scan -LiveScan:$false -CsvPath $Csv
        Refrescar
        $lblEstado.Text = ('Listo: {0} elementos clasificados' -f $script:Items.Count)
    } catch {
        $lblEstado.Text = 'Error: ' + $_.Exception.Message
    }
})

$btnTodos.Add_Click({
    foreach ($f in $script:Vista.Source) {
        if ($f.Nivel -ne 'NUNCA' -and $f.Nivel -ne 'DESCONOCIDO') { $f.Marcado = $true }
    }
    $dg.Items.Refresh(); Update-Total
})

$btnNinguno.Add_Click({
    foreach ($f in $script:Vista.Source) { $f.Marcado = $false }
    $dg.Items.Refresh(); Update-Total
})

$btnAbrir.Add_Click({
    if (-not $dg.SelectedItem) { return }
    $it = $dg.SelectedItem.Dato
    $p = $it.Ruta
    if ($it.Tipo -eq 'Archivo') { $p = Split-Path -LiteralPath $p -Parent }
    if (Test-Path -LiteralPath $p) { Start-Process explorer.exe -ArgumentList ('"' + $p + '"') }
})

$btnExportar.Add_Click({
    $sel = @()
    foreach ($f in $script:Vista.Source) { if ($f.Marcado) { $sel += $f.Dato } }
    if ($sel.Count -eq 0) { [void][System.Windows.MessageBox]::Show('No hay nada seleccionado.'); return }
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'CSV (*.csv)|*.csv'
    $dlg.FileName = 'seleccion-para-borrar.csv'
    if ($dlg.ShowDialog() -eq $true) {
        $sel | Select-Object Categoria, Motivo, Tipo, GiB, Ruta, RegPath, RegName | Export-Csv -LiteralPath $dlg.FileName -NoTypeInformation -Encoding UTF8
    }
})

$btnBorrar.Add_Click({
    $sel = @()
    foreach ($f in $script:Vista.Source) { if ($f.Marcado -and $f.Nivel -ne 'NUNCA') { $sel += $f.Dato } }
    if ($sel.Count -eq 0) { [void][System.Windows.MessageBox]::Show('No hay nada seleccionado.'); return }
    $sum = ($sel | Measure-Object Bytes -Sum).Sum / $GB
    $msg = ('Vas a borrar {0} elementos ({1:N2} GiB).' -f $sel.Count, $sum) + [Environment]::NewLine + [Environment]::NewLine + 'No se puede deshacer. Continuar?'
    if ([System.Windows.MessageBox]::Show($msg, 'Confirmar', 'YesNo', 'Warning') -ne 'Yes') { return }
    $ok = 0
    foreach ($it in $sel) { if (Remove-ItemSafe -Item $it) { $ok++ } }
    $libre = [math]::Round((Get-Volume -DriveLetter C).SizeRemaining / $GB, 2)
    [void][System.Windows.MessageBox]::Show(('Borrados {0} elementos.' -f $ok) + [Environment]::NewLine + 'Libre ahora: ' + $libre + ' GiB', 'Listo')
    $script:Items = @($script:Items | Where-Object { $sel -notcontains $_ })
    Refrescar
})

# ---------------------------------------------------------------- arranque
try {
    $script:Items = Invoke-Scan -LiveScan:$false -CsvPath $Csv
    Refrescar
    $lblEstado.Text = ('Listo: {0} elementos clasificados' -f $script:Items.Count)
} catch {
    $lblEstado.Text = 'Sin datos: pulsa Escanear'
}

if (-not $NoShow) {
    [void]$win.ShowDialog()
} else {
    $win.UpdateLayout()
    Write-Host ('NoShow OK: ventana WPF construida, {0} filas' -f $script:Vista.Source.Count)
    Write-Host ('DataGrid.Items.Count = ' + $dg.Items.Count + '   ItemsSource null? ' + ($dg.ItemsSource -eq $null))
    $prueba = Get-Huella -Ruta 'C:\Users\santi\.vscode\extensions'
    if ($prueba) { Write-Host ('huella .vscode -> ' + $prueba.C + ' / ' + $prueba.W) } else { Write-Host 'huella .vscode -> NULL (excepcion dentro de Get-Huella)' }
    foreach ($it in $script:Items) { if ($it.Categoria -eq 'DESCONOCIDO') { Write-Host ('  DESC  {0,7:N2} GiB  [{1}]  {2}' -f $it.GiB, $it.Motivo, $it.Ruta) } }
    $win.Close()
}


