#Requires -Version 5.1
<#
    escaner.ps1  -  motor de reglas que CLASIFICA el disco solo
    =============================================================
    No usa listas fijas: aplica ~40 reglas (rutas conocidas + patrones de
    nombre) y clasifica cada carpeta y archivo grande en 3 niveles:

        SEGURO   -> cache, temporal, instalador ya usado, huerfano probado
        REVISAR  -> candidato que puede ser dato tuyo (builds, saves, caches
                    de juegos, backups). NUNCA se borra sin -IncludeReview
        NUNCA    -> nucleo de Windows, juegos, documentos, config, DBs

    Fuentes de datos:
      - WizTree CSV (instantaneo): detecta el mas nuevo en Documentos
      - -Live: recorre el disco (mas lento, no necesita WizTree)

    Uso:
      .\escaner.ps1                                    -> reporte, no borra
      .\escaner.ps1 -Live                              -> escaneo en vivo
      .\escaner.ps1 -ExecuteSafe -Yes                  -> borra lo SEGURO
      .\escaner.ps1 -ExecuteSafe -IncludeReview -Yes   -> tambien REVISAR

    NOTA: archivo en ASCII puro a proposito. PowerShell 5.1 lee los .ps1 como
    ANSI si no tienen BOM, y cualquier tilde o guion largo rompe el parser.
#>
[CmdletBinding()]
param(
    [string]$Csv,
    [switch]$Live,
    [int]$MinMB = 20,
    [int]$MinFileMB = 100,
    [string]$Out = "$env:USERPROFILE\Desktop\escaneo-c.csv",
    [switch]$ExecuteSafe,
    [switch]$IncludeReview,
    [switch]$Yes
)

$ErrorActionPreference = 'Continue'
$GB = 1024MB
$script:Items = New-Object System.Collections.Generic.List[object]

# ======================================================== MOTOR DE REGLAS
# El primer patron que coincide gana. NUNCA va primero (proteccion).
$Rules = @(
    # ---------------------------------------------- NUNCA
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

    # ---------------------------------------------- SEGURO (cache pura)
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

    # ---------------------------------------------- REVISAR (tu criterio)
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
    foreach ($r in $Rules) {
        if ($low -match $r.R) { return $r }
    }
    return $null
}

# ======================================================== CARGA DE DATOS
function Get-EntriesFromWizTree {
    param([string]$File)
    $dirs  = New-Object System.Collections.Generic.List[object]
    $files = New-Object System.Collections.Generic.List[object]
    $reader = New-Object System.IO.StreamReader($File, [System.Text.Encoding]::UTF8)
    try {
        $null = $reader.ReadLine()
        $null = $reader.ReadLine()
        while ($null -ne ($line = $reader.ReadLine())) {
            if ($line.Length -lt 5) { continue }
            if ($line[0] -ne [char]'"') { continue }
            $end = $line.IndexOf('"', 1)
            if ($end -lt 0) { continue }
            $path = $line.Substring(1, $end - 1)
            $rest = $line.Substring($end + 1).Split(',')
            if ($rest.Count -lt 3) { continue }
            $alloc = 0L
            if (-not [long]::TryParse($rest[2], [ref]$alloc)) { continue }
            if ($path.EndsWith('\')) {
                if ($alloc -lt ($MinMB * 1MB)) { continue }
                $p = $path.TrimEnd('\')
                $dirs.Add([pscustomobject]@{ Path = $p; Bytes = $alloc; Depth = ($p.Split('\').Count) })
            } else {
                if ($alloc -lt ($MinFileMB * 1MB)) { continue }
                $files.Add([pscustomobject]@{ Path = $path; Bytes = $alloc })
            }
        }
    } finally { $reader.Close() }
    return @{ Dirs = $dirs; Files = $files }
}

function Get-EntriesLive {
    param([string[]]$Roots)
    $dirs  = New-Object System.Collections.Generic.List[object]
    $files = New-Object System.Collections.Generic.List[object]
    $prune = @('c:\windows\winsxs','c:\games','c:\program files\windowsapps','c:\system volume information','c:\$recycle.bin','c:\users\santi\onedrive')
    $stack = New-Object System.Collections.Generic.Stack[string]
    foreach ($r in $Roots) { if (Test-Path -LiteralPath $r) { $stack.Push($r) } }
    while ($stack.Count -gt 0) {
        $cur = $stack.Pop()
        $lowCur = $cur.ToLower()
        $isPruned = $false
        foreach ($p in $prune) { if ($lowCur.StartsWith($p)) { $isPruned = $true; break } }
        if ($isPruned) { continue }
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
                    if ($fi.Length -ge ($MinFileMB * 1MB)) {
                        $files.Add([pscustomobject]@{ Path = $fi.FullName; Bytes = $fi.Length })
                    }
                } catch { }
            }
        } catch { }
        if ($sum -ge ($MinMB * 1MB)) {
            $dirs.Add([pscustomobject]@{ Path = $cur; Bytes = $sum; Depth = ($cur.Split('\').Count) })
        }
    }
    return @{ Dirs = $dirs; Files = $files }
}

# ======================================================== ESCANEO
Write-Host ""
Write-Host "=============== escaner ===============" -ForegroundColor Magenta

if ($Live) {
    Write-Host "Modo: escaneo en vivo (puede tardar varios minutos)..." -ForegroundColor Cyan
    $data = Get-EntriesLive -Roots @('C:\','C:\Users\santi')
} else {
    if (-not $Csv) {
        $found = Get-ChildItem "$env:USERPROFILE\OneDrive\Documentos","$env:USERPROFILE\Documentos" -Filter 'WizTree_*.csv' -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($found) { $Csv = $found.FullName }
    }
    if (-not $Csv -or -not (Test-Path -LiteralPath $Csv)) {
        Write-Host "No hay CSV de WizTree. Usa -Live." -ForegroundColor Red; return
    }
    $age = [math]::Round(((Get-Date) - (Get-Item -LiteralPath $Csv).LastWriteTime).TotalHours, 1)
    Write-Host ("Modo: WizTree CSV ({0}, hace {1} h)" -f (Split-Path $Csv -Leaf), $age) -ForegroundColor Cyan
    if ($age -gt 6) { Write-Host "  AVISO: CSV viejo. Re-escanea con WizTree para datos frescos." -ForegroundColor Yellow }
    $data = Get-EntriesFromWizTree -File $Csv
}
$allDirs  = $data.Dirs
$allFiles = $data.Files

Write-Host ("Carpetas > {0} MB: {1}   |   Archivos > {2} MB: {3}" -f $MinMB, $allDirs.Count, $MinFileMB, $allFiles.Count) -ForegroundColor Cyan

$covered = New-Object 'System.Collections.Generic.HashSet[string]'

function Test-Covered {
    param([string]$Path)
    $parts = $Path.ToLower().Split('\')
    $acc = ''
    for ($i = 0; $i -lt ($parts.Count - 1); $i++) {
        if ($i -eq 0) { $acc = $parts[0] } else { $acc = $acc + '\' + $parts[$i] }
        if ($covered.Contains($acc)) { return $true }
    }
    return $false
}

# --- 1) carpetas, de padre a hijo
foreach ($d in ($allDirs | Sort-Object Depth)) {
    if (Test-Covered -Path $d.Path) { continue }
    $rule = Get-RuleFor -Path $d.Path
    if (-not $rule) { continue }
    $null = $covered.Add($d.Path.ToLower())
    $script:Items.Add([pscustomobject]@{
        Categoria = $rule.C; Motivo = $rule.W; Ruta = $d.Path
        GiB = [math]::Round($d.Bytes / $GB, 2); Bytes = $d.Bytes
    })
}

# --- 2) archivos grandes (dumps huerfanos, instaladores, imagenes)
foreach ($f in ($allFiles | Sort-Object Bytes -Descending)) {
    if (Test-Covered -Path $f.Path) { continue }
    $rule = Get-RuleFor -Path $f.Path
    if (-not $rule) {
        if ($f.Path -match '^c:\\(program files|windows|programdata)') { $rule = @{ C='NUNCA'; W='binario de sistema o programa' } }
        else { $rule = @{ C='DESCONOCIDO'; W='archivo grande sin clasificar' } }
    }
    $script:Items.Add([pscustomobject]@{
        Categoria = $rule.C; Motivo = $rule.W; Ruta = $f.Path
        GiB = [math]::Round($f.Bytes / $GB, 2); Bytes = $f.Bytes
    })
}

# ======================================================== HUERFANOS
Write-Host ""
Write-Host "--- Huerfanos en el registro (autostart a la nada) ---" -ForegroundColor Cyan
$orphans = 0
$hives = @(
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
)
foreach ($hive in $hives) {
    if (-not (Test-Path $hive)) { continue }
    $props = Get-ItemProperty $hive -ErrorAction SilentlyContinue
    if (-not $props) { continue }
    foreach ($p in $props.PSObject.Properties) {
        if ($p.Name -like 'PS*') { continue }
        $cmd = [string]$p.Value
        $exe = $null
        if ($cmd -match '^\s*"([^"]+)"') { $exe = $Matches[1] }
        elseif ($cmd -match '^\s*(\S+\.exe)') { $exe = $Matches[1] }
        if (-not $exe) { continue }
        $exe = [Environment]::ExpandEnvironmentVariables($exe)
        if (-not (Test-Path -LiteralPath $exe -ErrorAction SilentlyContinue)) {
            Write-Host ("  HUERFANO  {0}  ->  {1}" -f $p.Name, $exe) -ForegroundColor Yellow
            $script:Items.Add([pscustomobject]@{
                Categoria = 'SEGURO'; Motivo = 'autostart roto (exe inexistente)'
                Ruta = $p.Name; GiB = 0; Bytes = 0
            })
            $orphans++
        }
    }
}
if ($orphans -eq 0) { Write-Host "  ninguno" -ForegroundColor Green }

# ======================================================== REPORTE
Write-Host ""
Write-Host "=============== RESULTADO ===============" -ForegroundColor Magenta
foreach ($cat in @('SEGURO','REVISAR','DESCONOCIDO','NUNCA')) {
    $set = @($script:Items | Where-Object { $_.Categoria -eq $cat })
    if ($set.Count -eq 0) { continue }
    $tot = ($set | Measure-Object Bytes -Sum).Sum
    $color = 'DarkGray'
    if ($cat -eq 'SEGURO')  { $color = 'Green' }
    if ($cat -eq 'REVISAR') { $color = 'Yellow' }
    if ($cat -eq 'DESCONOCIDO') { $color = 'Magenta' }
    Write-Host ""
    Write-Host ("{0}  -  {1} elementos, {2:N2} GiB" -f $cat, $set.Count, ($tot / $GB)) -ForegroundColor $color
    if ($cat -ne 'NUNCA') {
        $set | Sort-Object Bytes -Descending | Select-Object -First 15 | ForEach-Object {
            Write-Host ("   {0,8:N2} GiB  [{1}]  {2}" -f $_.GiB, $_.Motivo, $_.Ruta) -ForegroundColor $color
        }
    }
}

$script:Items | Sort-Object Categoria, Bytes -Descending |
    Select-Object Categoria, Motivo, GiB, Ruta |
    Export-Csv -LiteralPath $Out -NoTypeInformation -Encoding UTF8
Write-Host ""
Write-Host ("Reporte completo: {0}" -f $Out) -ForegroundColor Cyan

# ======================================================== BORRADO
if ($ExecuteSafe) {
    $targets = @($script:Items | Where-Object { $_.Categoria -eq 'SEGURO' -and $_.Bytes -gt 0 })
    if ($IncludeReview) {
        $targets += @($script:Items | Where-Object { $_.Categoria -eq 'REVISAR' -and $_.Bytes -gt 0 })
    }
    $planGB = ($targets | Measure-Object Bytes -Sum).Sum / $GB
    Write-Host ""
    Write-Host ("Se borrarian {0} elementos = {1:N2} GiB" -f $targets.Count, $planGB) -ForegroundColor Magenta
    if (-not $Yes) {
        $ans = Read-Host "Escribe BORRAR para confirmar"
        if ($ans -ne 'BORRAR') { Write-Host "Cancelado. Nada se borro." -ForegroundColor Yellow; return }
    }
    $freeBefore = [math]::Round((Get-Volume -DriveLetter C).SizeRemaining / $GB, 2)
    $done = 0
    foreach ($t in ($targets | Sort-Object Bytes -Descending)) {
        try {
            if ($t.Bytes -eq 0) { continue }
            if (-not (Test-Path -LiteralPath $t.Ruta)) { continue }
            if ($t.Ruta -match '\\temp$') {
                Get-ChildItem -LiteralPath $t.Ruta -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -notlike 'dsh-*' } |
                    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
            } else {
                Remove-Item -LiteralPath $t.Ruta -Recurse -Force -ErrorAction Stop
            }
            $done++
        } catch { Write-Host ("  no se pudo: {0}" -f $t.Ruta) -ForegroundColor DarkYellow }
    }
    $freeAfter = [math]::Round((Get-Volume -DriveLetter C).SizeRemaining / $GB, 2)
    Write-Host ""
    Write-Host ("Procesados {0} elementos.  Libre: {1} -> {2} GiB  (+{3:N2})" -f $done, $freeBefore, $freeAfter, ($freeAfter - $freeBefore)) -ForegroundColor Green
}
Write-Host ""





