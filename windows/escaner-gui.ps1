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
    try { $it = @(Get-ChildItem -LiteralPath $Ruta -Force -ErrorAction Stop | Select-Object -First 500) }
    catch { return $null }
    if ($it.Count -eq 0) { return $null }
    $nombres = @($it | ForEach-Object { $_.Name.ToLower() })
    $hoja = (Split-Path -Leaf $Ruta).ToLower()
    $ext = @{}
    $nArch = 0
    foreach ($x in $it) {
        if (-not $x.PSIsContainer) {
            $nArch++
            $e = [System.IO.Path]::GetExtension($x.Name).ToLower()
            if ($e) { if ($ext.ContainsKey($e)) { $ext[$e] = $ext[$e] + 1 } else { $ext[$e] = 1 } }
        }
    }
    function Cuenta { param($k) if ($ext.ContainsKey($k)) { return $ext[$k] } else { return 0 } }
    $cDll = Cuenta '.dll'; $cExe = Cuenta '.exe'; $cMsi = Cuenta '.msi'
    $cLog = (Cuenta '.log') + (Cuenta '.tmp') + (Cuenta '.dmp') + (Cuenta '.etl')
    $cDb  = (Cuenta '.db') + (Cuenta '.sqlite') + (Cuenta '.mdf') + (Cuenta '.ldb')
    $cAs  = (Cuenta '.pak') + (Cuenta '.psarc') + (Cuenta '.pck') + (Cuenta '.assets') + (Cuenta '.pak')
    if ($nombres -contains 'unins000.exe' -or $nombres -contains 'uninstall.exe' -or $nombres -contains 'uninst.exe' -or $nombres -contains 'unins001.exe') {
        return @{ C='NUNCA'; W='huella: tiene desinstalador, es una app instalada' }
    }
    if ($nombres -contains ($hoja + '.exe')) {
        return @{ C='NUNCA'; W='huella: el .exe coincide con la carpeta, es la aplicacion' }
    }
    if ($cDb -gt 0) { return @{ C='NUNCA'; W='huella: contiene base de datos' } }
    if ($cAs -gt 0) { return @{ C='NUNCA'; W='huella: contiene assets de juego' } }
    if ($nArch -gt 3 -and $cDll -ge ($nArch * 0.4)) { return @{ C='NUNCA'; W='huella: mayoria de bibliotecas .dll' } }
    if ($cMsi -gt 0 -or $nombres -contains 'setup.exe') { return @{ C='REVISAR'; W='huella: instalador empaquetado' } }
    if ($nArch -gt 3 -and $cLog -ge ($nArch * 0.4)) { return @{ C='SEGURO'; W='huella: mayoria de logs y temporales' } }
    if ($nArch -gt 200 -and $cExe -eq 0) { return @{ C='REVISAR'; W='huella: cientos de archivos sueltos (cache probable)' } }
    return @{ C='DESCONOCIDO'; W='huella: contenido vario, revisar a mano' }
}

function Get-EntriesLive {
    param([string[]]$Roots)
    $dirs  = New-Object System.Collections.Generic.List[object]
    $files = New-Object System.Collections.Generic.List[object]
    $prune = @('c:\windows\winsxs','c:\games','c:\program files\windowsapps','c:\system volume information','c:\$recycle.bin')
        if ($env:USERPROFILE) { $prune += (Join-Path $env:USERPROFILE 'OneDrive').ToLower() }

    function Walk {
        param([string]$Path)
        $sum = 0L
        try {
            $di = [System.IO.DirectoryInfo]::new($Path)
            foreach ($fi in $di.EnumerateFiles()) {
                try {
                    $len = $fi.Length
                    $sum += $len
                    if ($len -ge ($script:MinFileMB * 1MB)) {
                        $files.Add([pscustomobject]@{ Path = $fi.FullName; Bytes = $len })
                    }
                } catch { }
            }
            foreach ($child in $di.EnumerateDirectories()) {
                try {
                    $low = $child.FullName.ToLower()
                    $skip = $false
                    foreach ($p in $prune) { if ($low.StartsWith($p)) { $skip = $true; break } }
                    if ($skip) { continue }
                    if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                    $sum += (Walk -Path $child.FullName)
                } catch { }
            }
        } catch { }
        if ($sum -ge ($script:MinMB * 1MB)) {
            $dirs.Add([pscustomobject]@{ Path = $Path; Bytes = $sum; Depth = ($Path.Split('\').Count) })
        }
        return $sum
    }

    foreach ($r in $Roots) {
        if (Test-Path -LiteralPath $r) { $null = Walk -Path $r }
    }
    return @{ Dirs = $dirs; Files = $files }
}

function Invoke-Scan {
    param([switch]$LiveScan, [string]$CsvPath, [switch]$AllowLive)

    $dirs  = New-Object System.Collections.Generic.List[object]
    $files = New-Object System.Collections.Generic.List[object]

    if (-not $LiveScan -and -not $CsvPath) {
        $found = Get-ChildItem "$env:USERPROFILE\OneDrive\Documentos","$env:USERPROFILE\Documentos" -Filter 'WizTree_*.csv' -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($found) { $CsvPath = $found.FullName }
    }
    if (-not $LiveScan -and (-not $CsvPath -or -not (Test-Path -LiteralPath $CsvPath))) {
        if ($AllowLive) {
            Write-Host "No hay CSV de WizTree: escaneo en vivo (puede tardar varios minutos)." -ForegroundColor Yellow
            $LiveScan = $true
        } else {
            throw "No hay CSV de WizTree. Usa -AllowLive o marca 'Escaneo en vivo'."
        }
    }

    if ($LiveScan) {
        $data = Get-EntriesLive -Roots @('C:\')
        $dirs = $data.Dirs
        $files = $data.Files
    } else {
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
        if ($d.Path.Split('\').Count -lt 5) { continue }
        $parts = $d.Path.ToLower().Split('\')
        $acc = ''; $skp = $false
        for ($i = 0; $i -lt ($parts.Count - 1); $i++) {
            if ($i -eq 0) { $acc = $parts[0] } else { $acc = $acc + '\' + $parts[$i] }
            if ($covered.Contains($acc)) { $skp = $true; break }
        }
        if ($skp) { continue }
        if (Get-RuleFor -Path $d.Path) { continue }
        $null = $covered.Add($d.Path.ToLower())
        $items.Add([pscustomobject]@{
            Categoria = 'DESCONOCIDO'; Motivo = 'carpeta pesada sin regla'
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
    $script:Items = Invoke-Scan -CsvPath $Csv -AllowLive
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


Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------------------------------------------------------------- paleta oscura
$colFondo   = [System.Drawing.Color]::FromArgb(38, 38, 44)
$colPanel   = [System.Drawing.Color]::FromArgb(50, 50, 58)
$colLista   = [System.Drawing.Color]::FromArgb(30, 30, 35)
$colTexto   = [System.Drawing.Color]::FromArgb(232, 232, 238)
$colTenue   = [System.Drawing.Color]::FromArgb(150, 150, 162)
$colBorde   = [System.Drawing.Color]::FromArgb(70, 70, 82)
$colBoton   = [System.Drawing.Color]::FromArgb(60, 60, 72)
$colSeguro  = [System.Drawing.Color]::FromArgb(130, 210, 130)
$colRevisar = [System.Drawing.Color]::FromArgb(235, 195, 90)
$colDesc    = [System.Drawing.Color]::FromArgb(205, 130, 225)
$colNunca   = [System.Drawing.Color]::FromArgb(125, 125, 138)

function Set-Oscuro {
    param($C)
    $C.BackColor = $colPanel
    $C.ForeColor = $colTexto
    return $C
}

function New-Boton {
    param([string]$Texto, [int]$X, [int]$Y, [int]$W, [int]$H, $Color)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Texto
    $b.Location = New-Object System.Drawing.Point($X, $Y)
    $b.Size = New-Object System.Drawing.Size($W, $H)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderColor = $colBorde
    if ($Color) { $b.BackColor = $Color; $b.ForeColor = [System.Drawing.Color]::White }
    else { $b.BackColor = $colBoton; $b.ForeColor = $colTexto }
    return $b
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Prgedisk C:  -  selecciona que borrar'
$form.Size = New-Object System.Drawing.Size(1180, 760)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(980, 620)
$form.BackColor = $colFondo
$form.ForeColor = $colTexto

# ---------------------------------------------------------------- barra superior
$panelTop = New-Object System.Windows.Forms.Panel
$panelTop.Dock = 'Top'
$panelTop.Height = 112
$panelTop.BackColor = $colFondo

$lblNiveles = New-Object System.Windows.Forms.Label
$lblNiveles.Text = 'Niveles a mostrar'
$lblNiveles.Location = New-Object System.Drawing.Point(8, 6)
$lblNiveles.AutoSize = $true
$lblNiveles.ForeColor = $colTenue
$panelTop.Controls.Add($lblNiveles)

$clbNivel = New-Object System.Windows.Forms.CheckedListBox
$clbNivel.Location = New-Object System.Drawing.Point(8, 26)
$clbNivel.Size = New-Object System.Drawing.Size(150, 78)
$clbNivel.CheckOnClick = $true
$clbNivel.BorderStyle = 'FixedSingle'
[void]$clbNivel.Items.AddRange(@('SEGURO', 'REVISAR', 'DESCONOCIDO', 'NUNCA'))
$clbNivel.SetItemChecked(0, $true)
$clbNivel.SetItemChecked(1, $true)
$clbNivel.SetItemChecked(2, $true)
[void](Set-Oscuro $clbNivel)
$clbNivel.BackColor = $colLista
$panelTop.Controls.Add($clbNivel)

$lblBuscar = New-Object System.Windows.Forms.Label
$lblBuscar.Text = 'Buscar en la ruta'
$lblBuscar.Location = New-Object System.Drawing.Point(172, 6)
$lblBuscar.AutoSize = $true
$lblBuscar.ForeColor = $colTenue
$panelTop.Controls.Add($lblBuscar)

$txtBuscar = New-Object System.Windows.Forms.TextBox
$txtBuscar.Location = New-Object System.Drawing.Point(172, 26)
$txtBuscar.Width = 250
$txtBuscar.BorderStyle = 'FixedSingle'
[void](Set-Oscuro $txtBuscar)
$txtBuscar.BackColor = $colLista
$panelTop.Controls.Add($txtBuscar)

$chkLive = New-Object System.Windows.Forms.CheckBox
$chkLive.Text = 'Escaneo en vivo (lento)'
$chkLive.Location = New-Object System.Drawing.Point(172, 58)
$chkLive.AutoSize = $true
$chkLive.ForeColor = $colTexto
$panelTop.Controls.Add($chkLive)

$chkGrande = New-Object System.Windows.Forms.CheckBox
$chkGrande.Text = 'Solo mayores a 1 GiB'
$chkGrande.Location = New-Object System.Drawing.Point(172, 80)
$chkGrande.AutoSize = $true
$chkGrande.ForeColor = $colTexto
$panelTop.Controls.Add($chkGrande)

$btnEscanear = New-Boton 'Escanear' 434 24 104 30
$panelTop.Controls.Add($btnEscanear)
$btnTodos = New-Boton 'Marcar visibles' 546 24 118 30
$panelTop.Controls.Add($btnTodos)
$btnNinguno = New-Boton 'Desmarcar todo' 672 24 118 30
$panelTop.Controls.Add($btnNinguno)
$btnExportar = New-Boton 'Exportar seleccion' 798 24 140 30
$panelTop.Controls.Add($btnExportar)

$lblEstado = New-Object System.Windows.Forms.Label
$lblEstado.Text = 'Pulsa Escanear para empezar.'
$lblEstado.Location = New-Object System.Drawing.Point(434, 62)
$lblEstado.AutoSize = $true
$lblEstado.ForeColor = $colTenue
$panelTop.Controls.Add($lblEstado)

$lblCuenta = New-Object System.Windows.Forms.Label
$lblCuenta.Text = ''
$lblCuenta.Location = New-Object System.Drawing.Point(434, 84)
$lblCuenta.AutoSize = $true
$lblCuenta.ForeColor = $colTenue
$panelTop.Controls.Add($lblCuenta)

# ---------------------------------------------------------------- lista
$list = New-Object System.Windows.Forms.ListView
$list.Dock = 'Fill'
$list.View = 'Details'
$list.CheckBoxes = $true
$list.FullRowSelect = $true
$list.GridLines = $false
$list.HideSelection = $false
$list.BorderStyle = 'None'
$list.BackColor = $colLista
$list.ForeColor = $colTexto
[void]$list.Columns.Add('Nivel', 82)
[void]$list.Columns.Add('Motivo', 180)
[void]$list.Columns.Add('GiB', 66, 'Right')
[void]$list.Columns.Add('Tipo', 62)
[void]$list.Columns.Add('Ruta', 320)
$form.Controls.Add($list)
$form.Controls.Add($panelTop)

# ---------------------------------------------------------------- panel de vista previa
$panelRight = New-Object System.Windows.Forms.Panel
$panelRight.Dock = 'Right'
$panelRight.Width = 430
$panelRight.Padding = New-Object System.Windows.Forms.Padding(8)
$panelRight.BackColor = $colFondo
$form.Controls.Add($panelRight)

$txtPreview = New-Object System.Windows.Forms.TextBox
$txtPreview.Multiline = $true
$txtPreview.ReadOnly = $true
$txtPreview.ScrollBars = 'Both'
$txtPreview.Dock = 'Fill'
$txtPreview.WordWrap = $false
$txtPreview.BorderStyle = 'FixedSingle'
$txtPreview.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtPreview.BackColor = $colLista
$txtPreview.ForeColor = $colTexto
$panelRight.Controls.Add($txtPreview)

$lblPrev = New-Object System.Windows.Forms.Label
$lblPrev.Text = 'Que hay aqui'
$lblPrev.Dock = 'Top'
$lblPrev.Height = 24
$lblPrev.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$lblPrev.ForeColor = $colTexto
$panelRight.Controls.Add($lblPrev)

$btnAbrir = New-Boton 'Abrir carpeta en Explorer' 0 0 410 30
$btnAbrir.Dock = 'Bottom'
$panelRight.Controls.Add($btnAbrir)

# ---------------------------------------------------------------- barra inferior
$panelBot = New-Object System.Windows.Forms.Panel
$panelBot.Dock = 'Bottom'
$panelBot.Height = 54
$panelBot.BackColor = $colFondo
$form.Controls.Add($panelBot)

$lblTotal = New-Object System.Windows.Forms.Label
$lblTotal.Text = 'Seleccionado: 0 elementos, 0.00 GiB'
$lblTotal.Location = New-Object System.Drawing.Point(10, 18)
$lblTotal.AutoSize = $true
$lblTotal.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$lblTotal.ForeColor = $colTexto
$panelBot.Controls.Add($lblTotal)

$btnBorrar = New-Boton 'Borrar seleccionado' 470 12 180 30 ([System.Drawing.Color]::FromArgb(190, 55, 55))
$panelBot.Controls.Add($btnBorrar)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = New-Object System.Drawing.Point(660, 18)
$progress.Size = New-Object System.Drawing.Size(220, 18)
$panelBot.Controls.Add($progress)

# ---------------------------------------------------------------- estado
$script:SortCol = 2
$script:SortAsc = $false

function Update-Total {
    $sel = @()
    foreach ($it in $list.CheckedItems) { $sel += $it.Tag }
    $sum = ($sel | Measure-Object Bytes -Sum).Sum
    if (-not $sum) { $sum = 0 }
    $lblTotal.Text = ('Seleccionado: {0} elementos, {1:N2} GiB' -f $sel.Count, ($sum / $GB))
}

function Show-Preview {
    param($Item)
    if (-not $Item) { $txtPreview.Text = ''; return }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine($Item.Categoria + '  -  ' + $Item.Motivo)
    [void]$sb.AppendLine(('Tamano: {0:N2} GiB     Tipo: {1}' -f $Item.GiB, $Item.Tipo))
    [void]$sb.AppendLine($Item.Ruta)
    [void]$sb.AppendLine('')
    if ($Item.Tipo -eq 'Registro') {
        [void]$sb.AppendLine('Entrada de registro, no ocupa disco.')
        [void]$sb.AppendLine('Clave: ' + $Item.RegPath)
        if ($Item.RegName) { [void]$sb.AppendLine('Valor: ' + $Item.RegName) }
    } elseif (Test-Path -LiteralPath $Item.Ruta) {
        try {
            if ($Item.Tipo -eq 'Archivo') {
                $fi = Get-Item -LiteralPath $Item.Ruta -Force -ErrorAction Stop
                [void]$sb.AppendLine(('Archivo: {0:N1} MB' -f ($fi.Length / 1MB)))
                [void]$sb.AppendLine('Modificado: ' + $fi.LastWriteTime)
            } else {
                $kids = @(Get-ChildItem -LiteralPath $Item.Ruta -Force -ErrorAction SilentlyContinue)
                $arch = @($kids | Where-Object { -not $_.PSIsContainer })
                $dirs = @($kids | Where-Object { $_.PSIsContainer })
                [void]$sb.AppendLine(('Contenido: {0} archivos, {1} subcarpetas' -f $arch.Count, $dirs.Count))
                [void]$sb.AppendLine('')
                foreach ($x in ($arch | Sort-Object Length -Descending | Select-Object -First 12)) {
                    [void]$sb.AppendLine(('  {0,8:N1} MB  {1}' -f ($x.Length / 1MB), $x.Name))
                }
                foreach ($d in ($dirs | Select-Object -First 12)) { [void]$sb.AppendLine('  [dir] ' + $d.Name) }
                if ($arch.Count -eq 0 -and $dirs.Count -eq 0) { [void]$sb.AppendLine('  (vacia o sin permiso)') }
            }
        } catch { [void]$sb.AppendLine('No se pudo leer: ' + $_.Exception.Message) }
    } else {
        [void]$sb.AppendLine('La ruta ya no existe en disco.')
    }
    $txtPreview.Text = $sb.ToString()
}

function Load-Items {
    param($Items)
    $niveles = @()
    foreach ($x in $clbNivel.CheckedItems) { $niveles += [string]$x }
    $texto = $txtBuscar.Text.Trim().ToLower()
    $soloGrande = $chkGrande.Checked

    $sel = @()
    foreach ($it in $Items) {
        if ($niveles.Count -gt 0 -and ($niveles -notcontains $it.Categoria)) { continue }
        if ($soloGrande -and $it.GiB -lt 1) { continue }
        if ($texto.Length -gt 0 -and ($it.Ruta.ToLower().IndexOf($texto) -lt 0)) { continue }
        $sel += $it
    }

    switch ($script:SortCol) {
        0 { $sel = @($sel | Sort-Object -Property Categoria) }
        1 { $sel = @($sel | Sort-Object -Property Motivo) }
        2 { $sel = @($sel | Sort-Object -Property Bytes -Descending:(-not $script:SortAsc)) }
        3 { $sel = @($sel | Sort-Object -Property Tipo) }
        4 { $sel = @($sel | Sort-Object -Property Ruta) }
    }
    if ($script:SortCol -ne 2 -and -not $script:SortAsc) {
        [array]::Reverse($sel)
    }

    $list.BeginUpdate()
    $list.Items.Clear()
    foreach ($it in $sel) {
        $row = New-Object System.Windows.Forms.ListViewItem($it.Categoria)
        [void]$row.SubItems.Add($it.Motivo)
        [void]$row.SubItems.Add(('{0:N2}' -f $it.GiB))
        [void]$row.SubItems.Add($it.Tipo)
        [void]$row.SubItems.Add($it.Ruta)
        $row.Tag = $it
        if ($it.Categoria -eq 'SEGURO')      { $row.ForeColor = $colSeguro }
        elseif ($it.Categoria -eq 'REVISAR') { $row.ForeColor = $colRevisar }
        elseif ($it.Categoria -eq 'DESCONOCIDO') { $row.ForeColor = $colDesc }
        else { $row.ForeColor = $colNunca }
        [void]$list.Items.Add($row)
    }
    $list.EndUpdate()
    $lblCuenta.Text = ('Mostrando {0} de {1} elementos  -  ordenado por {2} {3}' -f $sel.Count, $Items.Count, $list.Columns[$script:SortCol].Text, $(if ($script:SortAsc) { 'asc' } else { 'desc' }))
    Update-Total
}

# ---------------------------------------------------------------- eventos
$list.Add_ItemChecked({
    if ($_.Item.Tag.Categoria -eq 'NUNCA') { $_.Item.Checked = $false }
    Update-Total
})

$list.Add_SelectedIndexChanged({
    if ($list.SelectedItems.Count -gt 0) { Show-Preview -Item $list.SelectedItems[0].Tag } else { $txtPreview.Text = '' }
})

$list.Add_DoubleClick({
    if ($list.SelectedItems.Count -gt 0) {
        $row = $list.SelectedItems[0]
        if ($row.Tag.Categoria -ne 'NUNCA') { $row.Checked = -not $row.Checked; Update-Total }
    }
})

$list.Add_ColumnClick({
    param($snd, $evt)
    if ($script:SortCol -eq $evt.Column) { $script:SortAsc = -not $script:SortAsc }
    else { $script:SortCol = $evt.Column; $script:SortAsc = $true }
    Load-Items -Items $script:Items
})

$list.Add_KeyDown({
    param($snd, $evt)
    if ($evt.Control -and $evt.KeyCode -eq 'A') {
        foreach ($row in $list.Items) {
            if ($row.Tag.Categoria -ne 'NUNCA') { $row.Checked = $true }
        }
        Update-Total
        $evt.SuppressKeyPress = $true
    }
})

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.BackColor = $colPanel
$menu.ForeColor = $colTexto
$miAbrir = $menu.Items.Add('Abrir en Explorer')
$miCopiar = $menu.Items.Add('Copiar ruta')
$miMarcar = $menu.Items.Add('Marcar / desmarcar')
$list.ContextMenuStrip = $menu

$menu.Add_ItemClicked({
    param($snd, $evt)
    if ($list.SelectedItems.Count -eq 0) { return }
    $it = $list.SelectedItems[0].Tag
    $txt = $evt.ClickedItem.Text
    if ($txt -eq 'Abrir en Explorer') {
        $p = $it.Ruta
        if ($it.Tipo -eq 'Archivo') { $p = Split-Path -LiteralPath $p -Parent }
        if (Test-Path -LiteralPath $p) { Start-Process explorer.exe -ArgumentList ('"' + $p + '"') }
    }
    elseif ($txt -eq 'Copiar ruta') { [void][System.Windows.Forms.Clipboard]::SetText($it.Ruta) }
    elseif ($txt -eq 'Marcar / desmarcar') {
        $row = $list.SelectedItems[0]
        if ($it.Categoria -ne 'NUNCA') { $row.Checked = -not $row.Checked; Update-Total }
    }
})

$clbNivel.Add_ItemCheck({ $form.BeginInvoke([System.Action]{ Load-Items -Items $script:Items }) | Out-Null })
$chkGrande.Add_CheckedChanged({ Load-Items -Items $script:Items })
$txtBuscar.Add_TextChanged({ Load-Items -Items $script:Items })

$btnEscanear.Add_Click({
    $btnEscanear.Enabled = $false
    $lblEstado.Text = 'Escaneando...'
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $script:Items = Invoke-Scan -LiveScan:$chkLive.Checked -CsvPath $Csv -AllowLive
        Load-Items -Items $script:Items
        $lblEstado.Text = ('Listo: {0} elementos clasificados.' -f $script:Items.Count)
    } catch {
        $lblEstado.Text = 'Error: ' + $_.Exception.Message
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Error al escanear')
    }
    $btnEscanear.Enabled = $true
})

$btnTodos.Add_Click({
    foreach ($row in $list.Items) { if ($row.Tag.Categoria -ne 'NUNCA' -and $row.Tag.Categoria -ne 'DESCONOCIDO') { $row.Checked = $true } }
    Update-Total
})

$btnNinguno.Add_Click({
    foreach ($row in $list.Items) { $row.Checked = $false }
    Update-Total
})

$btnAbrir.Add_Click({
    if ($list.SelectedItems.Count -eq 0) { return }
    $it = $list.SelectedItems[0].Tag
    $p = $it.Ruta
    if ($it.Tipo -eq 'Archivo') { $p = Split-Path -LiteralPath $p -Parent }
    if (Test-Path -LiteralPath $p) { Start-Process explorer.exe -ArgumentList ('"' + $p + '"') }
})

$btnExportar.Add_Click({
    $sel = @()
    foreach ($it in $list.CheckedItems) { $sel += $it.Tag }
    if ($sel.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('No hay nada seleccionado.'); return }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'CSV (*.csv)|*.csv'
    $dlg.FileName = 'prgedisk-seleccion.csv'
    if ($dlg.ShowDialog() -eq 'OK') {
        $sel | Select-Object Categoria, Motivo, Tipo, GiB, Ruta, RegPath, RegName | Export-Csv -LiteralPath $dlg.FileName -NoTypeInformation -Encoding UTF8
        [void][System.Windows.Forms.MessageBox]::Show('Exportado a ' + $dlg.FileName)
    }
})

$btnBorrar.Add_Click({
    $sel = @()
    foreach ($it in $list.CheckedItems) { $sel += $it.Tag }
    $sel = @($sel | Where-Object { $_.Categoria -ne 'NUNCA' })
    if ($sel.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('No hay nada seleccionado (o solo hay NUNCA).'); return }
    $sum = ($sel | Measure-Object Bytes -Sum).Sum / $GB
    $msg = ('Vas a borrar {0} elementos ({1:N2} GiB).' -f $sel.Count, $sum) + "`n`nNo se puede deshacer. Continuar?"
    if ([System.Windows.Forms.MessageBox]::Show($msg, 'Confirmar borrado', 'YesNo', 'Warning') -ne 'Yes') { return }
    $progress.Maximum = $sel.Count
    $progress.Value = 0
    $ok = 0
    foreach ($it in $sel) {
        if (Remove-ItemSafe -Item $it) { $ok++ }
        $progress.Value = [Math]::Min($progress.Value + 1, $progress.Maximum)
        [System.Windows.Forms.Application]::DoEvents()
    }
    $libre = [math]::Round((Get-Volume -DriveLetter C).SizeRemaining / $GB, 2)
    [void][System.Windows.Forms.MessageBox]::Show(('Borrados {0} elementos.' -f $ok) + "`n`nLibre ahora: $libre GiB", 'Listo')
    $script:Items = @($script:Items | Where-Object { $sel -notcontains $_ })
    Load-Items -Items $script:Items
    $lblEstado.Text = ('Borrados {0} elementos.' -f $ok)
    $progress.Value = 0
})

# ---------------------------------------------------------------- arranque
$lblEstado.Text = 'Escaneando al iniciar...'
try {
    $script:Items = Invoke-Scan -CsvPath $Csv
    Load-Items -Items $script:Items
    $lblEstado.Text = ('Listo: {0} elementos clasificados.' -f $script:Items.Count)
} catch {
    $lblEstado.Text = 'Sin datos: pulsa Escanear.'
}

if (-not $NoShow) { [void]$form.ShowDialog() } else { Write-Host 'NoShow: formulario construido OK'; $form.Dispose() }





