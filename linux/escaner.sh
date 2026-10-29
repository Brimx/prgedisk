#!/usr/bin/env bash
# =============================================================================
# escaner.sh  -  motor de reglas que CLASIFICA el disco (port Linux)
# =============================================================================
# Basado en escaner.ps1 / escaner-wpf.ps1 y en CRITERIOS.md + CONTEXTO-LINUX.md.
#
# No necesita WizTree ni ningún CSV: recorre el árbol con `du` (una sola
# pasada, sin leer contenidos). ncdu queda como herramienta para navegar a
# mano, no como entrada del escáner.
#
# Niveles:
#   SEGURO       cache/temporal que se regenera        -> se borra con --execute-safe
#   REVISAR      cache o resto real, depende del uso   -> solo con --include-review
#   DESCONOCIDO  carpeta pesada sin regla              -> nunca por defecto
#   NUNCA        dato, config, binario, base de datos  -> bloqueado por diseño
#
# Principio: ante la duda, no borrar. Un falso negativo cuesta 2 GB; un falso
# positivo cuesta una instalación rota o datos perdidos.
#
# Uso:
#   ./escaner.sh                                  escanea y abre la interfaz
#   ./escaner.sh --no-ui                          solo reporte, sin interfaz
#   ./escaner.sh --root /                         escanea todo el sistema (sudo)
#   ./escaner.sh --execute-safe                   borra lo SEGURO (batch)
#   ./escaner.sh --execute-safe --include-review  también lo REVISAR (batch)
#   ./escaner.sh --execute-safe --yes             sin confirmación interactiva
#
# Dependencias: bash >= 4.4, GNU coreutils (du, sort, df, find), awk.
# La interfaz es una TUI propia en bash: no necesita dependencias extra.
# =============================================================================
set -uo pipefail

VERSION="1.0"
TAB=$'\t'

# ---------------------------------------------------------------- defaults
MIN_MB=20
MIN_FILE_MB=100
COV_GB=1
OUT=""
EXECUTE=0
INCLUDE_REVIEW=0
ASSUME_YES=0
USE_FINGERPRINT=1
UI_MODE=auto
EXPLAIN=""
ROOTS=()

# Umbral de huella: no vale la pena inspeccionar carpetas diminutas
FP_MIN_BYTES=$((20 * 1024 * 1024))
# Tope de entradas que mira la huella (como el -First 500 de PowerShell)
FP_MAX_ENTRIES=500

# ---------------------------------------------------------------- helpers
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

usage() {
    printf 'prgedisk %s — clasificador y limpiador de disco para Linux\n\n' "$VERSION"
    cat <<'EOF'
Opciones:
  --min-mb N            tamaño mínimo de carpeta a reportar (default 20)
  --min-file-mb N       tamaño mínimo de archivo a reportar (default 100)
  --coverage-gb N       umbral de la pasada de cobertura (default 1)
  --root DIR            raíz a escanear; repetible (default: $HOME /tmp /var/tmp)
  --out FILE            CSV de salida (default: ~/prgedisk-<fecha>.csv)
  --execute-safe        borra lo clasificado como SEGURO
  --include-review      añade lo REVISAR al borrado (requiere --execute-safe)
  --yes                 no pedir confirmación (para automatizar)
  --no-fingerprint      desactiva la huella de contenido
  --ui                  fuerza la interfaz interactiva
  --no-ui               solo reporte, sin interfaz
  --explain RUTA        explica cómo se clasifica una ruta y sale
  -h, --help            esta ayuda
  -V, --version         muestra la versión

Niveles: SEGURO se borra solo con --execute-safe. REVISAR solo con
--include-review. DESCONOCIDO y NUNCA nunca se borran por defecto.

Ejemplos:
  prgedisk                     escanea $HOME y abre la TUI
  prgedisk /ruta               escanea esa ruta (o varias)
  prgedisk /ruta --no-ui       solo reporte, sin TUI
  prgedisk --execute-safe      borra lo SEGURO (batch)
  prgedisk --explain RUTA      explica una clasificación y sale

Sin --execute-*, en una terminal se abre la interfaz para elegir qué borrar.
También acepta los nombres de PowerShell: -MinMB, -MinFileMB, -Out,
-ExecuteSafe, -IncludeReview, -Yes.
EOF
}

need_num() {
    [[ ${2:-} =~ ^[0-9]+$ ]] || die "$1 necesita un entero, recibí '${2:-}'"
}

# ---------------------------------------------------------------- args
while (($#)); do
    case "$1" in
        --min-mb|-MinMB)        need_num "$1" "${2:-}"; MIN_MB=$2; shift 2 ;;
        --min-file-mb|-MinFileMB) need_num "$1" "${2:-}"; MIN_FILE_MB=$2; shift 2 ;;
        --coverage-gb)   need_num "$1" "${2:-}"; COV_GB=$2; shift 2 ;;
        --root)          [[ -n ${2:-} ]] || die "--root necesita un directorio"
                         ROOTS+=("$2"); shift 2 ;;
        --out|-Out)      [[ -n ${2:-} ]] || die "--out necesita un archivo"
                         OUT=$2; shift 2 ;;
        --execute-safe|-ExecuteSafe)   EXECUTE=1; shift ;;
        --include-review|-IncludeReview) INCLUDE_REVIEW=1; shift ;;
        --yes|-Yes)      ASSUME_YES=1; shift ;;
        --no-fingerprint) USE_FINGERPRINT=0; shift ;;
        --ui)            UI_MODE=on; shift ;;
        --no-ui)         UI_MODE=off; shift ;;
        --explain)       [[ -n ${2:-} ]] || die "--explain necesita una ruta"; EXPLAIN=$2; shift 2 ;;
        -h|--help)       usage; exit 0 ;;
        -V|--version)    printf 'prgedisk %s\n' "$VERSION"; exit 0 ;;
        --)              shift; while (($#)); do ROOTS+=("$1"); shift; done ;;
        -*)              die "opción desconocida: $1 (usá --help)" ;;
        *)               ROOTS+=("$1"); shift ;;
    esac
done

(( MIN_MB > 0 )) || die "--min-mb debe ser > 0"
(( MIN_FILE_MB > 0 )) || die "--min-file-mb debe ser > 0"
(( COV_GB >= 0 )) || die "--coverage-gb debe ser >= 0"

if [[ $UI_MODE == on ]]; then
    [[ -t 0 && -t 1 ]] || die "--ui necesita una terminal interactiva"
fi

MIN_DIR_B=$((MIN_MB * 1024 * 1024))
MIN_FILE_B=$((MIN_FILE_MB * 1024 * 1024))
COV_B=$((COV_GB * 1024 * 1024 * 1024))

[[ -n $OUT ]] || OUT="$HOME/prgedisk-$(date +%Y%m%d-%H%M).csv"

# Normalizar HOME sin barra final y escapar para regex
HOME=${HOME%/}
[[ -n $HOME ]] || die "HOME no está definido"
HOME_ESC=$(printf '%s' "$HOME" | sed 's/[][\\.^$*+?(){}|]/\\&/g')

# ---------------------------------------------------------------- raíces
if (( ${#ROOTS[@]} == 0 )); then
    ROOTS=("$HOME" /tmp /var/tmp)
fi

# Quitar raíces inexistentes y anidadas (evita doble conteo, bug de -Live)
declare -a CLEAN_ROOTS=()
for r in "${ROOTS[@]}"; do
    [[ $r == /* ]] || r="$PWD/$r"
    r=$(realpath -m -- "$r" 2>/dev/null || printf '%s' "$r")
    r=${r%/}; [[ -z $r ]] && r=/
    [[ -d $r ]] || { printf 'aviso: no existe la raíz %s, se omite\n' "$r" >&2; continue; }
    CLEAN_ROOTS+=("$r")
done
(( ${#CLEAN_ROOTS[@]} > 0 )) || die "ninguna raíz válida para escanear"

# Ordenar por longitud y quedarse con las que no estén dentro de otra
ROOTS=()
while IFS= read -r r; do
    nested=0
    for kept in "${ROOTS[@]}"; do
        [[ $r == "$kept" || $r == "$kept"/* ]] && { nested=1; break; }
    done
    (( nested )) || ROOTS+=("$r")
done < <(printf '%s\n' "${CLEAN_ROOTS[@]}" | awk '{print length($0)"\t"$0}' | sort -t$'\t' -k1,1n | cut -f2-)
(( ${#ROOTS[@]} > 0 )) || die "ninguna raíz válida para escanear"

# ---------------------------------------------------------------- temporal
WORK=$(mktemp -d "${TMPDIR:-/tmp}/escaner.XXXXXX") || die "no se pudo crear el temporal"
cleanup() { rm -rf -- "$WORK"; }
trap cleanup EXIT

empty_file() { : > "$1"; }
empty_file "$WORK/dirs.raw"
empty_file "$WORK/files.raw"
empty_file "$WORK/items.tsv"

# ---------------------------------------------------------------- reglas
# El primer match gana. En Linux, a diferencia de Windows, van primero las
# NUNCA "duras" y al final las NUNCA "paraguas" (~/.config, ~/.local/share),
# de modo que una cache específica dentro de un perfil pueda clasificarse
# SEGURO. Si el paraguas fuera primero, ninguna cache de ~/.config sería
# alcanzable (es el bug de orden que tiene escaner.ps1, ver REVISION-LINUX.md).
declare -a R_LEVEL=() R_WHY=() R_RE=()
add_rule() { R_LEVEL+=("$1"); R_WHY+=("$2"); R_RE+=("$3"); }

H=${HOME_ESC,,}

CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/prgedisk"
USER_RULES="$CONF_DIR/reglas.conf"
EXCL_FILE="$CONF_DIR/exclusiones.conf"

# --- NUNCA: sistema, claves, juegos, datos del usuario
add_rule NUNCA "kernel o sistema virtual"        "^/(proc|sys|dev|run)(/|$)"
add_rule NUNCA "sistema operativo"               "^/(boot|usr|lib|lib32|lib64|bin|sbin|etc|opt|snap|srv)(/|$)"
add_rule NUNCA "raíz del filesystem"             "^/$"
add_rule NUNCA "home del usuario"                "^${H}$"
add_rule NUNCA "base de datos del sistema"       "^/var/lib(/|$)"
add_rule NUNCA "claves y repositorios"           "^${H}/(\\.ssh|\\.gnupg|\\.git|\\.password-store|\\.pki)(/|$)"
add_rule NUNCA "historial de repositorios"        "/(\\.git|\\.hg|\\.svn)(/|$)"
add_rule NUNCA "datos de agentes CLI"            "^${H}/\\.(codex|claude|gemini|bun|opencode-mem)(/|$)"
add_rule NUNCA "almacenamiento de sitios (sesiones)" "^${H}/(\\.mozilla|\\.config/(mozilla|google-chrome|chromium|brave-browser|vivaldi|microsoft-edge))/.*/(storage|sessionstore-backups|indexeddb|local storage|session storage|service worker|cachestorage)(/|$)"
add_rule NUNCA "almacenamiento web de apps"      "/(indexeddb|local storage|session storage|service worker|cachestorage)(/|$)"
add_rule NUNCA "runtime del agente (cache)"      "^${H}/\\.cache/(opencode|dsh|deepseek|claude|codex)(/|$)"
add_rule NUNCA "toolchains, IDEs y agentes"      "^${H}/(\\.rustup|\\.cargo/bin|\\.nvm|\\.pyenv|\\.rbenv|\\.sdkman|\\.opencode|\\.pi|\\.vscode|\\.conda)(/|$)"
add_rule NUNCA "apps en local/share"             "^${H}/\\.local/share/(opencode|claude|codex|jetbrains|rider|nvm|fnm|pnpm|volta|containers|docker|flatpak|dolphin-emu|eden|lutris|heroic)(/|$)"
add_rule NUNCA "sandbox del agente"              "^/tmp/(dsh-|\\.dsh)|^/var/tmp/(dsh-|\\.dsh)"
add_rule NUNCA "juegos"                          "^${H}/(\\.steam|\\.local/share/steam/steamapps/common|games|juegos)(/|$)"
add_rule NUNCA "bibliotecas de juegos"           "/(steamapps/common)(/|$)"
add_rule NUNCA "juegos en discos externos"       "^/(mnt|media|run/media)/.*/(steamapps/common|games|juegos|steamlibrary)(/|$)"
add_rule NUNCA "documentos del usuario"          "^${H}/(documentos|documents|escritorio|desktop|imágenes|imagenes|pictures|vídeos|videos|música|musica|music)(/|$)"
add_rule NUNCA "prefijos wine / bottles"         "^${H}/(\\.wine|\\.var/app/[^/]+/(data|config))(/|$)"
add_rule NUNCA "imágenes de disco o VM"          "\\.(qcow2|vdi|vmdk|vhd|vhdx|iso|img)$"
add_rule NUNCA "assets de juego"                 "\\.(psarc|pak|pck|vpk|bsa|ba2|wad|uasset|ucas|utoc)$"
add_rule NUNCA "base de datos"                   "\\.(db|sqlite3?|ldb|mdb|realm)$"
add_rule NUNCA "binarios y bibliotecas"          "\\.(so(\\.[0-9.]+)*|a|o|elf|dll|exe|dylib|node)$"
add_rule NUNCA "documento del usuario"           "\\.(docx?|xlsx?|pptx?|odt|ods|odp|pdf|psd|blend|kra|epub)$"

# --- SEGURO: cache pura
add_rule SEGURO "cache del usuario"              "^${H}/\\.cache(/|$)"
add_rule SEGURO "temporales del sistema"         "^/(tmp|var/tmp)(/|$)"
add_rule SEGURO "cache de herramientas"          "^${H}/\\.(npm|yarn|pnpm-store|nuget/packages|gradle/caches|cargo/registry/cache|cargo/registry/src)(/|$)"
add_rule SEGURO "cache dentro de .config"        "^${H}/\\.config/[^/]+/(cache|caches|code cache|cacheddata|cachedextensionvsixs|gpucache|dawncache|dawnwebgpucache|grshadercache|shadercache|blob_storage|component_crx_cache|extensions_crx_cache|tmp)(/|$)"
add_rule SEGURO "cache dentro de .local/share"   "^${H}/\\.local/share/[^/]+/(cache|caches|code cache|gpucache|shadercache|logs|log|tmp|temp)(/|$)"
add_rule SEGURO "cache de flatpak"               "^${H}/\\.var/app/[^/]+/cache(/|$)"
add_rule SEGURO "steam: descargas y shadercache" "^${H}/(\\.steam|\\.local/share/steam)/steamapps/(downloading|temp|shadercache)(/|$)"
add_rule SEGURO "cache HTTP de firefox"          "^${H}/(\\.mozilla|\\.config/mozilla)/firefox/[^/]+/(cache2|startupcache|shader-cache)(/|$)"
add_rule SEGURO "cache HTTP de chromium"         "^${H}/\\.config/(google-chrome|chromium|brave-browser|vivaldi|microsoft-edge)/[^/]+/(cache|code cache|gpucache|dawncache|dawnwebgpucache|shadercache)(/|$)"
add_rule SEGURO "cache de stremio"               "^${H}/\\.stremio-server/stremio-cache(/|$)"
add_rule SEGURO "logs, dumps y temporales"       "\\.(log|tmp|dmp|etl|old|bak)$"

# --- REVISAR: depende del uso
add_rule REVISAR "papelera"                      "^${H}/\\.local/share/trash(/|$)"
add_rule REVISAR "cache de paquetes del sistema" "^/var/cache(/|$)"
add_rule REVISAR "logs del sistema"              "^/var/log(/|$)"
add_rule REVISAR "estado del usuario"            "^${H}/\\.local/state(/|$)"
add_rule REVISAR "dependencias de proyecto"      "/(node_modules|__pycache__|\\.pytest_cache|\\.mypy_cache|\\.tox|vendor/bundle)(/|$)"
add_rule REVISAR "artefactos de build"           "/(dist|build|out|target|\\.next|\\.nuxt|coverage|\\.venv|venv)(/|$)"
add_rule REVISAR "cache dentro de programa"      "/(cache|caches|cache_pc|shadercache|logs|crashdumps|crashdump|temp)(/|$)"
add_rule REVISAR "respaldo probable"             "\\.old$|_old$|\\.bak$|backup|respaldo"
add_rule REVISAR "instalador descargado"         "^${H}/(descargas|downloads|escritorio|desktop)/.*\\.(deb|rpm|appimage|flatpakref|txz|pkg\\.tar|msi|exe)$"
add_rule REVISAR "contenedores"                  "^${H}/\\.local/share/(containers|docker)(/|$)"

# --- NUNCA de cierre: solo las raíces exactas y datos de apps conocidos.
# No se usan paraguas tipo "todo ~/.local/share" porque taparían la pasada
# de cobertura: un desconocido de 20 GiB dentro de .local/share debe verse.
add_rule NUNCA "raíz de configuración"           "^${H}/\\.config$"
add_rule NUNCA "raíz de datos persistentes"      "^${H}/\\.local/share$"
add_rule NUNCA "datos de steam"                  "^${H}/\\.local/share/steam(/|$)"
add_rule NUNCA "datos de aplicaciones flatpak"   "^${H}/\\.var/app/[^/]+/(data|config)(/|$)"

# Reglas y exclusiones del usuario (se evalúan antes que las internas).
declare -a U_LEVEL=() U_RE=() U_WHY=() EXCLUDES=()

load_user_conf() {
    local line lvl rest re why p n=0
    if [[ -f $USER_RULES ]]; then
        while IFS= read -r line || [[ -n $line ]]; do
            [[ $line == \#* || -z ${line//[[:space:]]/} ]] && continue
            if [[ $line != *"|"*"|"* ]]; then
                printf 'aviso: regla ignorada (formato NIVEL|regex|motivo): %s\n' "$line" >&2
                continue
            fi
            lvl=${line%%|*}; rest=${line#*|}; re=${rest%|*}; why=${rest##*|}
            case ${lvl^^} in
                SEGURO|REVISAR|DESCONOCIDO|NUNCA) ;;
                *) printf 'aviso: nivel inválido en regla: %s\n' "$line" >&2; continue ;;
            esac
            [[ -n $re ]] || { printf 'aviso: regla sin regex: %s\n' "$line" >&2; continue; }
            [[ "" =~ $re ]] 2>/dev/null
            if (( $? == 2 )); then
                printf 'aviso: regex inválida en regla: %s\n' "$line" >&2
                continue
            fi
            [[ -z $why ]] && why="regla de usuario"
            re=${re//\$HOME/$HOME_ESC}
            U_LEVEL+=("${lvl^^}"); U_RE+=("$re"); U_WHY+=("$why")
            n=$((n + 1))
        done < "$USER_RULES"
    fi
    if [[ -f $EXCL_FILE ]]; then
        while IFS= read -r p || [[ -n $p ]]; do
            [[ $p == \#* || -z ${p//[[:space:]]/} ]] && continue
            case $p in
                "~")   p=$HOME ;;
                "~/"*) p="$HOME/${p#\~/}" ;;
            esac
            [[ $p == /* ]] || { printf 'aviso: exclusión ignorada (no absoluta): %s\n' "$p" >&2; continue; }
            EXCLUDES+=("${p%/}")
        done < "$EXCL_FILE"
    fi
    if [[ -z $EXPLAIN ]]; then
        if (( n > 0 )); then info "Reglas de usuario: $n ($USER_RULES)"; fi
        if (( ${#EXCLUDES[@]} > 0 )); then info "Exclusiones: ${#EXCLUDES[@]} ($EXCL_FILE)"; fi
    fi
}

# Devuelve 0 y deja CL/CR/CL_SRC si hay regla; 1 si no.
CL=""
CR=""
CL_SRC=""
classify() {
    local low=${1,,} i p
    for p in "${EXCLUDES[@]}"; do
        if [[ $low == "${p,,}" || $low == "${p,,}"/* ]]; then
            CL=NUNCA; CR="exclusión del usuario"; CL_SRC="exclusión"
            return 0
        fi
    done
    if (( ${#U_LEVEL[@]} )); then
        for i in "${!U_LEVEL[@]}"; do
            if [[ $low =~ ${U_RE[i]} ]]; then
                CL=${U_LEVEL[i]}; CR=${U_WHY[i]}; CL_SRC="usuario"
                return 0
            fi
        done
    fi
    for ((i = 0; i < ${#R_LEVEL[@]}; i++)); do
        if [[ $low =~ ${R_RE[i]} ]]; then
            CL=${R_LEVEL[i]}
            CR=${R_WHY[i]}
            CL_SRC="builtin"
            return 0
        fi
    done
    return 1
}

load_user_conf

if [[ -n $EXPLAIN ]]; then
    case $EXPLAIN in
        "~")   EXPLAIN=$HOME ;;
        "~/"*) EXPLAIN="$HOME/${EXPLAIN#\~/}" ;;
    esac
    EXPLAIN_ABS=$(realpath -m -- "$EXPLAIN" 2>/dev/null || printf '%s' "$EXPLAIN")
    printf 'Ruta: %s\n' "$EXPLAIN_ABS"
    if classify "$EXPLAIN_ABS"; then
        printf 'Nivel: %s\nMotivo: %s\nOrigen: %s\n' "$CL" "$CR" "$CL_SRC"
    else
        printf 'Nivel: DESCONOCIDO\nMotivo: sin regla (la cobertura la reportaría si pesa >= %s GiB)\n' "$COV_GB"
    fi
    exit 0
fi

# ---------------------------------------------------------------- procesos
declare -A COVERED=()

# ¿algún ancestro estricto ya está cubierto?
ancestor_covered() {
    local p=${1%/*}
    while [[ -n $p && $p != "/" ]]; do
        [[ -n ${COVERED[$p]:-} ]] && return 0
        p=${p%/*}
    done
    return 1
}

is_scan_root() {
    local r
    for r in "${ROOTS[@]}"; do [[ $1 == "$r" ]] && return 0; done
    return 1
}

# ---------------------------------------------------------------- huella
# Imprime "NIVEL<TAB>motivo" mirando el contenido, no el nombre.
fingerprint() {
    local dir=$1 stats total dirs libs logs dbs assets git
    stats=$(find "$dir" -xdev -maxdepth 2 -printf '%y\t%f\n' 2>/dev/null |
        head -n "$FP_MAX_ENTRIES" |
        awk -F'\t' '
            $1 == "d" { if ($2 == ".git") git = 1; dirs++; next }
            {
                total++; n = $2
                if (n ~ /\.so(\.[0-9]+)*$/ || n ~ /\.a$/) libs++
                if (n ~ /\.(log|tmp|dmp|etl|old|bak)$/) logs++
                if (n ~ /\.(db|sqlite3?|ldb|mdb|realm)$/) dbs++
                if (n ~ /\.(psarc|pak|pck|vpk|bsa|ba2|wad|uasset|ucas|utoc)$/) assets++
            }
            END { printf "%d %d %d %d %d %d %d\n", total, dirs, libs, logs, dbs, assets, git + 0 }
        ')
    read -r total dirs libs logs dbs assets git <<< "${stats:-0 0 0 0 0 0 0}"

    if (( git )); then
        printf 'NUNCA\thuella: contiene .git'
    elif (( dbs > 0 )); then
        printf 'NUNCA\thuella: contiene base de datos'
    elif (( assets > 0 )); then
        printf 'NUNCA\thuella: contiene assets de juego'
    elif (( total > 3 && libs * 10 >= total * 4 )); then
        printf 'NUNCA\thuella: mayoría de bibliotecas'
    elif (( total > 3 && logs * 10 >= total * 4 )); then
        printf 'SEGURO\thuella: mayoría de logs y temporales'
    elif (( total >= 200 && libs == 0 && assets == 0 )); then
        printf 'REVISAR\thuella: cientos de archivos sueltos (cache probable)'
    elif (( total == 0 && dirs == 0 )); then
        printf 'DESCONOCIDO\thuella: no se pudo inspeccionar'
    elif (( total == 0 )); then
        printf 'DESCONOCIDO\thuella: solo subcarpetas, revisar a mano'
    else
        printf 'DESCONOCIDO\thuella: contenido vario, revisar a mano'
    fi
}

should_fingerprint() {
    local p=$1
    (( USE_FINGERPRINT )) || return 1
    case "$p" in
        "$HOME/.cache"|/tmp|/var/tmp) return 1 ;;
    esac
    [[ ${p,,} =~ ^${H}/\.var/app/[^/]+/cache$ ]] && return 1
    return 0
}

# ---------------------------------------------------------------- items
add_item() {
    # nivel, bytes, tipo, motivo, ruta
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$WORK/items.tsv"
    COVERED["$5"]=1
}

gib() { # bytes -> "1.23"
    local b=${1:-0}
    printf '%d.%02d' $((b / 1073741824)) $(((b % 1073741824) * 100 / 1073741824))
}

# ---------------------------------------------------------------- huérfanos
# Equivalente Linux de los autostart rotos del registro: entradas .desktop
# cuyo Exec/TryExec apunta a un binario que no existe. No se ejecuta nada.
scan_orphans() {
    local f exec try cmd first toks kind
    ORPHANS=0
    for f in "$HOME"/.config/autostart/*.desktop "$HOME"/.local/share/applications/*.desktop; do
        [[ -f $f ]] || continue
        grep -qi '^Hidden=true' "$f" && continue
        try=$(grep -m1 '^TryExec=' "$f" 2>/dev/null)
        exec=$(grep -m1 '^Exec=' "$f" 2>/dev/null)
        if [[ -n $try ]]; then
            cmd=${try#TryExec=}
        else
            cmd=${exec#Exec=}
        fi
        [[ -n $cmd ]] || continue
        case $cmd in
            *';'*|*'|'*|*'&'*) continue ;;
        esac
        cmd=$(printf '%s' "$cmd" | sed 's/%[a-zA-Z]//g')
        toks=$(printf '%s' "$cmd" | xargs -n1 2>/dev/null)
        while :; do
            first=$(printf '%s\n' "$toks" | head -n1)
            [[ -n $first ]] || break
            case $first in
                env|*=*|-) toks=$(printf '%s\n' "$toks" | tail -n +2) ;;
                -*)       toks=$(printf '%s\n' "$toks" | tail -n +2) ;;
                *)        break ;;
            esac
        done
        first=$(printf '%s\n' "$toks" | head -n1)
        [[ -n $first ]] || continue
        case ${first,,} in
            sh|bash|dash|zsh|fish|flatpak|snap|xdg-open|python*|perl|ruby) continue ;;
        esac
        if [[ $first == /* ]]; then
            [[ -x $first ]] && continue
        else
            command -v "$first" >/dev/null 2>&1 && continue
        fi
        case $f in
            "$HOME"/.config/autostart/*) kind="autostart" ;;
            *) kind="menú" ;;
        esac
        add_item SEGURO 0 "Autostart" "$kind roto: $first no existe" "$f"
        ORPHANS=$((ORPHANS + 1))
        info "  huérfano ($kind): $f -> $first"
    done
    info "Huérfanos de autostart/menú: $ORPHANS"
}

# ---------------------------------------------------------------- escaneo
START=$SECONDS
info "=============== prgedisk (Linux) ==============="
info "Raíces   : ${ROOTS[*]}"
info "Umbrales : carpetas > ${MIN_MB} MB · archivos > ${MIN_FILE_MB} MB · cobertura > ${COV_GB} GiB"
SCAN_START=$(date +%s)
: > "$WORK/progress"
info "Escaneando: ${ROOTS[*]}"
info "  Una sola pasada de metadatos. En ~50 GB suele tardar ~30 s."
if [[ -t 1 ]]; then
    ( while [[ ! -e $WORK/scan.done ]]; do
          n=$(cat "$WORK/progress" 2>/dev/null || echo 0)
          printf '\r  %s rutas leídas · %ss ' "$n" "$(( $(date +%s) - SCAN_START ))"
          sleep 0.5
      done ) &
    SPINNER_PID=$!
fi

scan_du() {
    if du --help 2>&1 | grep -q -- '--zero'; then
        du -0 -a -B1 -x -- "${ROOTS[@]}" 2>/dev/null
    else
        du -a -B1 -x -- "${ROOTS[@]}" 2>/dev/null | tr '\n' '\0'
    fi
}

# Separa candidatos en carpetas (D) y archivos (F). du ya entrega tamaños
# acumulados de carpetas y el tamaño real de cada archivo.
seen=0
while IFS=$'\t' read -r -d '' size path; do
    seen=$((seen + 1))
    if (( seen % 2000 == 0 )); then printf '%s' "$seen" > "$WORK/progress"; fi
    [[ $size =~ ^[0-9]+$ ]] || continue
    (( size >= MIN_DIR_B )) || continue
    if [[ -d $path && ! -L $path ]]; then
        depth=${path//[!\/]/}
        printf 'D\t%d\t%s\t%s\0' "${#depth}" "$size" "$path" >> "$WORK/dirs.raw"
    elif (( size >= MIN_FILE_B )); then
        printf 'F\t%s\t%s\0' "$size" "$path" >> "$WORK/files.raw"
    fi
done < <(scan_du)
printf '%s' "$seen" > "$WORK/progress"
: > "$WORK/scan.done"
if [[ -n ${SPINNER_PID:-} ]]; then
    wait "$SPINNER_PID" 2>/dev/null
    printf '\r\033[K'
fi

LC_ALL=C sort -z -t "$TAB" -k2,2n  "$WORK/dirs.raw"  > "$WORK/dirs.sorted"
LC_ALL=C sort -z -t "$TAB" -k2,2nr "$WORK/files.raw" > "$WORK/files.sorted"

n_dirs=$(tr -cd '\0' < "$WORK/dirs.sorted" | wc -c)
n_files=$(tr -cd '\0' < "$WORK/files.sorted" | wc -c)
info "Candidatos: ${n_dirs} carpetas, ${n_files} archivos. Clasificando..."

# --- 1a) Qué carpetas son objetivo real (SEGURO/REVISAR) y qué ancestros
# solo hacen de contenedor. Sin esto, un paraguas NUNCA (~/.local/share,
# ~/.config) taparía sus propias caches: el bug de orden del original.
declare -A ONPATH=()
while IFS=$'\t' read -r -d '' _tag _depth bytes path; do
    is_scan_root "$path" && continue
    classify "$path" || continue
    [[ $CL == SEGURO || $CL == REVISAR ]] || continue
    p=${path%/*}
    while [[ -n $p && $p != "/" ]]; do
        ONPATH["$p"]=1
        p=${p%/*}
    done
done < "$WORK/dirs.sorted"

# --- 1b) carpetas: padre a hijo (ya ordenadas por profundidad)
while IFS=$'\t' read -r -d '' _tag _depth bytes path; do
    is_scan_root "$path" && continue
    ancestor_covered "$path" && continue
    classify "$path" || continue
    lvl=$CL why=$CR

    if [[ $lvl == NUNCA ]]; then
        # contenedor de una cache concreta: no se reporta ni se tapa
        [[ -n ${ONPATH[$path]:-} ]] && continue
        add_item NUNCA "$bytes" "Carpeta" "$why" "$path"
        continue
    fi

    if [[ $lvl == REVISAR ]] && (( bytes >= FP_MIN_BYTES )) && should_fingerprint "$path"; then
        fp=$(fingerprint "$path")
        fp_lvl=${fp%%$TAB*}
        fp_why=${fp#*$TAB}
        case "$fp_lvl" in
            NUNCA)  lvl=NUNCA;   why=$fp_why ;;
            SEGURO) lvl=SEGURO;  why=$fp_why ;;
        esac
    fi
    add_item "$lvl" "$bytes" "Carpeta" "$why" "$path"
done < "$WORK/dirs.sorted"

# --- 3) Qué padres ya están explicados por un hijo clasificado. Evita
# reportar como DESCONOCIDO un contenedor entero (~/.var) cuyos hijos
# pesados ya tienen regla: lo desconocido se reporta en su propio nivel.
declare -A EXPLAINED=()
while IFS=$'\t' read -r _lvl _bytes _tipo _why path; do
    p=${path%/*}
    while [[ -n $p && $p != "/" ]]; do
        EXPLAINED["$p"]=1
        p=${p%/*}
    done
done < "$WORK/items.tsv"

# --- 4) pasada de cobertura: pesado que ninguna regla explica.
# Independiente y posterior (nunca dentro del bucle principal). Los
# contenedores de caches conocidas no son "desconocidos".
while IFS=$'\t' read -r -d '' _tag _depth bytes path; do
    is_scan_root "$path" && continue
    ancestor_covered "$path" && continue
    [[ -n ${ONPATH[$path]:-} || -n ${EXPLAINED[$path]:-} ]] && continue
    (( bytes >= COV_B )) || continue
    classify "$path" && continue

    lvl="DESCONOCIDO" why="sin regla (pasada de cobertura)"
    if (( bytes >= FP_MIN_BYTES )); then
        fp=$(fingerprint "$path")
        lvl=${fp%%$TAB*}
        why=${fp#*$TAB}
    fi
    add_item "$lvl" "$bytes" "Carpeta" "$why" "$path"
done < "$WORK/dirs.sorted"

# --- 5) archivos grandes
while IFS=$'\t' read -r -d '' _tag bytes path; do
    ancestor_covered "$path" && continue
    if classify "$path"; then
        add_item "$CL" "$bytes" "Archivo" "$CR" "$path"
    else
        magic=""
        magic=$(head -c 4 -- "$path" 2>/dev/null)
        if [[ $magic == $'\x7fELF' ]]; then
            add_item NUNCA "$bytes" "Archivo" "huella: binario ejecutable (ELF)" "$path"
        elif [[ ${path,,} =~ ^/(usr|lib|lib64|bin|sbin|etc|boot|opt|var/lib)/(.*)$ ]]; then
            add_item NUNCA "$bytes" "Archivo" "binario de sistema o programa" "$path"
        else
            add_item DESCONOCIDO "$bytes" "Archivo" "archivo grande sin clasificar" "$path"
        fi
    fi
done < "$WORK/files.sorted"

# Los huérfanos viven en $HOME: solo se revisan si esa ruta entró en el escaneo.
orphan_scan=0
for r in "${ROOTS[@]}"; do
    [[ $r == "/" || $HOME == "$r" || $HOME == "$r"/* ]] && { orphan_scan=1; break; }
done
(( orphan_scan )) && scan_orphans

ELAPSED=$((SECONDS - START))
info "Escaneo y clasificación: ${ELAPSED}s"

# ---------------------------------------------------------------- reporte
info ""
info "=============== RESULTADO ==============="
for cat in SEGURO REVISAR DESCONOCIDO NUNCA; do
    read -r count sum < <(awk -F'\t' -v c="$cat" '$1 == c { n++; b += $2 } END { printf "%d %d\n", n + 0, b + 0 }' "$WORK/items.tsv")
    (( count == 0 )) && continue
    info ""
    info "$cat  -  ${count} elementos, $(gib "$sum") GiB"
    if [[ $cat != NUNCA ]]; then
        awk -F'\t' -v c="$cat" '$1 == c' "$WORK/items.tsv" |
            LC_ALL=C sort -t "$TAB" -k2,2nr |
            head -n 15 |
            while IFS=$'\t' read -r lvl bytes tipo why path; do
                printf '   %8s GiB  [%s]  %s\n' "$(gib "$bytes")" "$why" "$path"
            done
    fi
done
info ""

# CSV (antes de borrar, para que exista aunque la ejecución falle)
csv_escape() { local s=${1//\"/\"\"}; printf '"%s"' "$s"; }
{
    printf 'Nivel,Motivo,GiB,Bytes,Tipo,Ruta\n'
    while IFS=$'\t' read -r lvl bytes tipo why path; do
        printf '%s,%s,%s,%s,%s,%s\n' \
            "$(csv_escape "$lvl")" "$(csv_escape "$why")" "$(gib "$bytes")" \
            "$bytes" "$(csv_escape "$tipo")" "$(csv_escape "$path")"
    done < "$WORK/items.tsv"
} > "$OUT"
info "Se conservan siempre: ~/.cache/opencode, ~/.cache/dsh, ~/.cache/claude*, /tmp/dsh-*,"
info "  ~/.ssh, ~/.gnupg, documentos, Escritorio, juegos y el directorio actual."
info "Reporte completo: $OUT"
info "Para navegar a mano: ncdu -x $HOME   (o la raíz que corresponda)"
info "Nota: en btrfs, borrar no libera hasta que expiren los snapshots (snapper list)."

# ---------------------------------------------------------------- borrado
# Protecciones de borrado, independientes de las reglas de clasificación.
is_protected() {
    local p=$1 r
    for r in "${EXCLUDES[@]}"; do
        [[ $p == "$r" || $p == "$r"/* ]] && return 0
    done
    case "$p" in
        /|/home|/tmp|/var/tmp|/var|/var/lib|/var/log|/var/cache|/usr|/etc|/boot|/opt|/root|/run)
            return 0 ;;
    esac
    [[ $p == "$HOME" ]] && return 0
    for r in "${ROOTS[@]}"; do [[ $p == "$r" ]] && return 0; done
    # no borrar el directorio actual ni sus ancestros
    case "$PWD/" in "$p"/*) return 0 ;; esac
    # claves, repos, documentos, juegos, agentes
    case "$p" in
        "$HOME"/.ssh|"$HOME"/.ssh/*|"$HOME"/.gnupg|"$HOME"/.gnupg/*|"$HOME"/.dsh|"$HOME"/.dsh/*) return 0 ;;
        "$HOME"/.cache/opencode|"$HOME"/.cache/opencode/*|"$HOME"/.cache/dsh|"$HOME"/.cache/dsh/*) return 0 ;;
        "$HOME"/.cache/deepseek*|"$HOME"/.cache/claude*|"$HOME"/.cache/codex*) return 0 ;;
        /tmp/dsh-*|/var/tmp/dsh-*) return 0 ;;
        "$HOME"/Documentos|"$HOME"/Documentos/*|"$HOME"/Documents|"$HOME"/Documents/*) return 0 ;;
        "$HOME"/Escritorio|"$HOME"/Escritorio/*|"$HOME"/Desktop|"$HOME"/Desktop/*) return 0 ;;
        "$HOME"/Imágenes|"$HOME"/Imágenes/*|"$HOME"/Pictures|"$HOME"/Pictures/*) return 0 ;;
        "$HOME"/Vídeos|"$HOME"/Vídeos/*|"$HOME"/Videos|"$HOME"/Videos/*) return 0 ;;
        "$HOME"/Música|"$HOME"/Música/*|"$HOME"/Music|"$HOME"/Music/*) return 0 ;;
        "$HOME"/.local/share/Steam/steamapps/common|"$HOME"/.local/share/Steam/steamapps/common/*) return 0 ;;
    esac
    case "$p" in */.git|*/.git/*) return 0 ;; esac
    [[ -L $p ]] && return 0                      # nunca seguir symlinks
    [[ -e $p ]] || return 0                      # ya no existe
    # punto de montaje: no borrar la raíz de otro dispositivo
    if [[ $(stat -c %d -- "$p" 2>/dev/null) != $(stat -c %d -- "${p%/*}" 2>/dev/null) ]]; then
        return 0
    fi
    return 1
}

contents_mode() {
    case "$1" in
        "$HOME/.cache"|/tmp|/var/tmp) return 0 ;;
    esac
    [[ ${1,,} =~ ^${H}/\.var/app/[^/]+/cache$ ]] && return 0
    return 1
}

avail() { df -B1 --output=avail "$HOME" 2>/dev/null | awk 'NR == 2 { print $1 }'; }

declare -a TARGETS=()
plan_bytes=0
DEL_COUNT=0
FREE_BEFORE=""
FREE_AFTER=""

run_deletion() {
    local free_before free_after delta sign done_count=0 entry path rest bytes
    free_before=$(avail)
    for entry in "${TARGETS[@]}"; do
        path=${entry%%$TAB*}
        rest=${entry#*$TAB}
        bytes=${rest%%$TAB*}

        if contents_mode "$path"; then
            while IFS= read -r -d '' child; do
                is_protected "$child" && continue
                if rm -rf --one-file-system -- "$child" 2>/dev/null; then
                    done_count=$((done_count + 1))
                else
                    printf '  no se pudo: %s\n' "$child"
                fi
            done < <(find "$path" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
        else
            if rm -rf --one-file-system -- "$path" 2>/dev/null; then
                done_count=$((done_count + 1))
            else
                printf '  no se pudo: %s\n' "$path"
            fi
        fi
    done
    free_after=$(avail)
    DEL_COUNT=$done_count
    FREE_BEFORE=$free_before
    FREE_AFTER=$free_after
    info ""
    info "Elementos procesados: ${done_count}."
    if [[ -n $free_before && -n $free_after ]]; then
        delta=$((free_after - free_before))
        sign="+"
        if (( delta < 0 )); then sign="-"; delta=$((-delta)); fi
        info "Libre: $(gib "$free_before") -> $(gib "$free_after") GiB  (${sign}$(gib "$delta"))"
        if (( free_after <= free_before )); then
            info "Aviso: el espacio libre no subió. En btrfs revisá snapshots: snapper list"
        fi
    fi
    if command -v paccache >/dev/null 2>&1; then
        info "Extra: paccache -r -k 2   (paquetes viejos de pacman, mejor que borrarlos a mano)"
    fi
    info ""
}

# ---------------------------------------------------------------- ejecución directa
if (( EXECUTE )); then
    TARGETS=()
    plan_bytes=0
    levels_filter='$1 == "SEGURO"'
    if (( INCLUDE_REVIEW )); then
        levels_filter='$1 == "SEGURO" || $1 == "REVISAR"'
    fi
    while IFS=$'\t' read -r lvl bytes tipo why path; do
        is_protected "$path" && continue
        TARGETS+=("${path}${TAB}${bytes}${TAB}${lvl}")
        plan_bytes=$((plan_bytes + bytes))
    done < <(awk -F'\t' "$levels_filter" "$WORK/items.tsv" |
             LC_ALL=C sort -t "$TAB" -k2,2nr)

    info ""
    info "Se borrarían ${#TARGETS[@]} elementos = $(gib "$plan_bytes") GiB"
    if (( ${#TARGETS[@]} == 0 )); then
        info "Nada que borrar."
        exit 0
    fi
    if (( ! ASSUME_YES )); then
        read -r -p "Escribe BORRAR para confirmar: " ans
        [[ ${ans:-} == "BORRAR" ]] || { info "Cancelado. Nada se borró."; exit 0; }
    fi
    run_deletion
    exit 0
fi

# ---------------------------------------------------------------- interfaz
UI=0
if [[ $UI_MODE == on ]]; then
    UI=1
elif [[ $UI_MODE == auto && -t 0 && -t 1 ]]; then
    UI=1
fi
if [[ $UI_MODE == on && ( ! -t 0 || ! -t 1 ) ]]; then
    die "--ui necesita una terminal interactiva"
fi

# ================================================================ TUI
# Lista con casillas, filtros y totales. Fondo de la terminal; azul solo en el
# título y video inverso para la fila activa.
C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_DIM=$'\033[2m'
C_BLUE=$'\033[34m'
C_REV=$'\033[7m'

TUI_ACTIVE=0
TUI_OLD_STTY=""
TCOLS=100
TLINES=30
LIST_H=20
CURSOR=0
TOP=0
FILTER=""
NOTICE=""
ONLY_BIG=0
GROUP=0
declare -a T_LVL=() T_BYTES=() T_TYPE=() T_OWNER=() T_WHY=() T_PATH=() T_MARK=() VIEW=()
declare -a DISP_KIND=() DISP_KEY=() DISP_IDX=()
declare -A SHOW=([SEGURO]=1 [REVISAR]=1 [DESCONOCIDO]=1 [NUNCA]=0)

tui_restore() {
    (( ${TUI_ACTIVE:-0} )) || return 0
    TUI_ACTIVE=0
    stty "$TUI_OLD_STTY" 2>/dev/null
    tput cnorm 2>/dev/null || printf '\033[?25h'
    tput rmcup 2>/dev/null || printf '\033[?1049l'
}

tui_enter() {
    TUI_OLD_STTY=$(stty -g) || return 1
    tput smcup 2>/dev/null || printf '\033[?1049h'
    tput civis 2>/dev/null || printf '\033[?25l'
    stty -echo -icanon -icrnl min 1 time 0
    TUI_ACTIVE=1
    trap 'tui_restore; cleanup' EXIT
    trap 'tui_restore; exit 130' INT TERM
}

tui_fit() { printf '%s' "${1:0:${2:-$TCOLS}}"; }

tui_fit_left() {
    local s=$1 max=${2:-$TCOLS} start
    if (( ${#s} > max )); then
        start=$(( ${#s} - max + 1 ))
        printf '…%s' "${s:start}"
    else
        printf '%s' "$s"
    fi
}

# Dueno aproximado, como la columna "Dueno" del WPF.
tui_owner() {
    local p=$1 rel app
    case "$p" in
        "$HOME"/*) rel=${p#"$HOME"/} ;;
        /tmp/*|/var/tmp/*) printf '(temporales)'; return ;;
        /*) printf '(sistema)'; return ;;
        *) printf '(otro)'; return ;;
    esac
    case "$rel" in
        .cache/*)       app=${rel#.cache/};       printf '%s' "${app%%/*}" ;;
        .config/*)      app=${rel#.config/};      printf '%s' "${app%%/*}" ;;
        .local/share/*) app=${rel#.local/share/}; printf '%s' "${app%%/*}" ;;
        .local/state/*) app=${rel#.local/state/}; printf '%s' "${app%%/*}" ;;
        .var/app/*)     app=${rel#.var/app/};     printf '%s' "${app%%/*}" ;;
        Proyectos/*|Projects/*|Documentos/*|Descargas/*)
                        app=${rel#*/};            printf '%s' "${app%%/*}" ;;
        *)              app=${rel%%/*};           printf '%s' "$app" ;;
    esac
}

tui_dims() {
    TCOLS=$(tput cols 2>/dev/null || echo 100)
    TLINES=$(tput lines 2>/dev/null || echo 30)
    (( TCOLS < 40 )) && TCOLS=40
    (( TLINES < 10 )) && TLINES=10
    LIST_H=$((TLINES - 7))
    (( LIST_H < 3 )) && LIST_H=3
}

load_tui_items() {
    T_LVL=(); T_BYTES=(); T_TYPE=(); T_OWNER=(); T_WHY=(); T_PATH=(); T_MARK=()
    while IFS=$'\t' read -r _r lvl bytes tipo why path; do
        T_LVL+=("$lvl"); T_BYTES+=("$bytes"); T_TYPE+=("$tipo"); T_WHY+=("$why"); T_PATH+=("$path")
    done < <(awk -F'\t' '{ r = ($1 == "SEGURO" ? 0 : ($1 == "REVISAR" ? 1 : ($1 == "DESCONOCIDO" ? 2 : 3))); print r "\t" $0 }' "$WORK/items.tsv" |
             LC_ALL=C sort -t "$TAB" -k1,1n -k3,3nr)
    local i d
    for i in "${!T_PATH[@]}"; do
        if [[ ${T_TYPE[i]} == "Archivo" ]]; then
            d=$(dirname -- "${T_PATH[i]}")
            if [[ $d == "$HOME" ]]; then T_OWNER[i]="(home)"; else T_OWNER[i]=$(tui_owner "$d"); fi
        else
            T_OWNER[i]=$(tui_owner "${T_PATH[i]}")
        fi
        if [[ ${T_LVL[i]} == "SEGURO" ]]; then T_MARK[i]=1; else T_MARK[i]=0; fi
        [[ ${T_LVL[i]} == "NUNCA" ]] && T_MARK[i]=0
    done
}

rebuild_view() {
    VIEW=()
    local i hay
    for i in "${!T_PATH[@]}"; do
        [[ ${SHOW[${T_LVL[i]}]} == 1 ]] || continue
        if (( ONLY_BIG )) && (( T_BYTES[i] < COV_B )); then continue; fi
        if [[ -n $FILTER ]]; then
            hay="${T_PATH[i],,} ${T_WHY[i],,}"
            [[ $hay == *"$FILTER"* ]] || continue
        fi
        VIEW+=("$i")
    done
    if (( GROUP == 2 )); then
        local tmp="$WORK/vista.$$" r
        : > "$tmp"
        for i in "${VIEW[@]}"; do
            case ${T_LVL[i]} in
                SEGURO)      r=0 ;;
                REVISAR)     r=1 ;;
                DESCONOCIDO) r=2 ;;
                *)           r=3 ;;
            esac
            printf '%s\t%d\t%d\t%d\n' "${T_OWNER[i]}" "$r" "${T_BYTES[i]}" "$i" >> "$tmp"
        done
        VIEW=()
        while IFS=$'\t' read -r _o _r _b i; do VIEW+=("$i"); done < <(LC_ALL=C sort -f -t "$TAB" -k1,1 -k2,2n -k3,3nr "$tmp")
    fi
    (( CURSOR >= ${#VIEW[@]} )) && CURSOR=$((${#VIEW[@]} - 1))
    (( CURSOR < 0 )) && CURSOR=0
}

build_disp() {
    DISP_KIND=(); DISP_KEY=(); DISP_IDX=()
    local v key last="" n b j
    for v in "${VIEW[@]}"; do
        if (( GROUP == 1 )); then key=${T_LVL[v]}
        elif (( GROUP == 2 )); then key=${T_OWNER[v]}
        else key=""; fi
        if (( GROUP )) && [[ $key != "$last" ]]; then
            n=0; b=0
            for j in "${VIEW[@]}"; do
                if (( GROUP == 1 )); then
                    [[ ${T_LVL[j]} == "$key" ]] || continue
                else
                    [[ ${T_OWNER[j]} == "$key" ]] || continue
                fi
                n=$((n + 1)); b=$((b + T_BYTES[j]))
            done
            DISP_KIND+=("H"); DISP_KEY+=("$key"); DISP_IDX+=("$n:$b")
            last=$key
        fi
        DISP_KIND+=("I"); DISP_KEY+=(""); DISP_IDX+=("$v")
    done
}

tui_toggle_group() {
    GROUP=$(( (GROUP + 1) % 3 ))
    case $GROUP in
        0) NOTICE="Sin agrupar" ;;
        1) NOTICE="Agrupado por nivel" ;;
        2) NOTICE="Agrupado por dueño" ;;
    esac
    TOP=0
    rebuild_view
}

tui_toggle_mark() {
    (( ${#VIEW[@]} )) || return 0
    local i=${VIEW[CURSOR]}
    if [[ ${T_LVL[i]} == "NUNCA" ]]; then NOTICE="NUNCA no se borra"; return 0; fi
    if (( ${T_MARK[i]:-0} )); then T_MARK[i]=0; else T_MARK[i]=1; fi
}

tui_mark_level() {
    local lvl=$1 i
    for i in "${VIEW[@]}"; do
        [[ ${T_LVL[i]} == "$lvl" && $lvl != "NUNCA" ]] && T_MARK[i]=1
    done
}

tui_mark_all() {
    local i
    for i in "${VIEW[@]}"; do
        [[ ${T_LVL[i]} != "NUNCA" ]] && T_MARK[i]=1
    done
}

tui_unmark() {
    local i
    for i in "${VIEW[@]}"; do T_MARK[i]=0; done
}

tui_open() {
    (( ${#VIEW[@]} )) || return 0
    local i p d
    i=${VIEW[CURSOR]}
    p=${T_PATH[i]}
    if [[ -d $p ]]; then d=$p; else d=$(dirname -- "$p"); fi
    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$d" >/dev/null 2>&1 &
        NOTICE="Abriendo $d"
    else
        NOTICE="xdg-open no está instalado"
    fi
}

tui_export() {
    local i n=0 f
    f="$HOME/prgedisk-seleccion-$(date +%Y%m%d-%H%M%S).csv"
    {
        printf 'Nivel,Motivo,GiB,Bytes,Tipo,Ruta\n'
        for i in "${!T_PATH[@]}"; do
            (( ${T_MARK[i]:-0} )) || continue
            printf '%s,%s,%s,%s,%s,%s\n' \
                "$(csv_escape "${T_LVL[i]}")" \
                "$(csv_escape "${T_WHY[i]}")" \
                "$(gib "${T_BYTES[i]}")" \
                "${T_BYTES[i]}" \
                "$(csv_escape "${T_TYPE[i]}")" \
                "$(csv_escape "${T_PATH[i]}")"
            n=$((n + 1))
        done
    } > "$f"
    if (( n > 0 )); then
        NOTICE="Exportados $n elementos a $f"
    else
        NOTICE="Nada marcado; se exportó solo el encabezado"
    fi
}

tui_toggle_level() {
    local lvl=$1
    if [[ ${SHOW[$lvl]} == 1 ]]; then SHOW[$lvl]=0; NOTICE="$lvl oculto"; else SHOW[$lvl]=1; NOTICE="$lvl visible"; fi
    rebuild_view
}

tui_search() {
    local s="" k
    tput cnorm 2>/dev/null
    while true; do
        printf '\033[%d;1H\033[K Buscar (Esc cancela): %s' "$TLINES" "$s"
        IFS= read -rsn1 k || break
        case $k in
            ''|$'\r'|$'\n') break ;;
            $'\e') tput civis 2>/dev/null; return 0 ;;
            $'\177'|$'\b') s=${s%?} ;;
            *) [[ $k == [[:print:]] ]] && s+="$k" ;;
        esac
    done
    FILTER=${s,,}
    CURSOR=0; TOP=0
    rebuild_view
    tput civis 2>/dev/null
}

tui_draw() {
    tui_dims
    local cand=0 segbytes=0 marked=0 mbytes=0 i row idx line mark tag size p sep pos chips status cur d1 d2 tipo help dp owner cur_disp d hn hb
    for i in "${!T_PATH[@]}"; do
        [[ ${T_LVL[i]} != "NUNCA" ]] && cand=$((cand + 1))
        [[ ${T_LVL[i]} == "SEGURO" ]] && segbytes=$((segbytes + T_BYTES[i]))
        if (( ${T_MARK[i]:-0} )); then marked=$((marked + 1)); mbytes=$((mbytes + T_BYTES[i])); fi
    done

    build_disp
    cur_disp=-1
    if (( ${#VIEW[@]} )); then
        for d in "${!DISP_KIND[@]}"; do
            [[ ${DISP_KIND[d]} == "I" && ${DISP_IDX[d]} == "${VIEW[CURSOR]}" ]] && { cur_disp=$d; break; }
        done
    fi
    if (( cur_disp >= 0 )); then
        if (( cur_disp < TOP )); then TOP=$cur_disp; fi
        if (( cur_disp >= TOP + LIST_H )); then TOP=$((cur_disp - LIST_H + 1)); fi
    fi
    (( TOP < 0 )) && TOP=0
    if (( ${#DISP_KIND[@]} > 0 && TOP > ${#DISP_KIND[@]} - LIST_H )); then TOP=$((${#DISP_KIND[@]} - LIST_H)); fi
    (( TOP < 0 )) && TOP=0
    (( ${#DISP_KIND[@]} == 0 )) && TOP=0

    printf '\033[H'
    printf '%s%s%s' "$C_BOLD$C_BLUE" " Prgedisk " "$C_RESET"
    printf '%s\033[K\n' "$(tui_fit "· ${ROOTS[*]} · ${cand} candidatos · $(gib "$segbytes") GiB SEGURO" $((TCOLS - 12)))"

    printf -v sep '%*s' "$TCOLS" ''
    printf '%s%s%s\n' "$C_DIM" "${sep// /-}" "$C_RESET"

    for ((row = 0; row < LIST_H; row++)); do
        idx=$((TOP + row))
        if (( idx >= ${#DISP_KIND[@]} )); then printf '\033[K\n'; continue; fi
        if [[ ${DISP_KIND[idx]} == "H" ]]; then
            hn=${DISP_IDX[idx]%%:*}
            hb=${DISP_IDX[idx]#*:}
            if (( hn == 1 )); then
                line=" == ${DISP_KEY[idx]} · 1 elemento · $(gib "$hb") GiB =="
            else
                line=" == ${DISP_KEY[idx]} · $hn elementos · $(gib "$hb") GiB =="
            fi
            printf '%s%s%s\033[K\n' "$C_BOLD" "$(tui_fit "$line")" "$C_RESET"
            continue
        fi
        i=${DISP_IDX[idx]}
        mark="[ ]"
        (( ${T_MARK[i]:-0} )) && mark="[x]"
        [[ ${T_LVL[i]} == "NUNCA" ]] && mark="[-]"
        case ${T_LVL[i]} in
            SEGURO)     tag="SEG" ;;
            REVISAR)    tag="REV" ;;
            DESCONOCIDO) tag="DESC" ;;
            *)          tag="NUNCA" ;;
        esac
        size=$(gib "${T_BYTES[i]}")
        p=${T_PATH[i]}
        [[ $p == "$HOME"/* ]] && p="~${p#"$HOME"}"
        line=$(printf ' %-3s %-5s %8s GiB  %s' "$mark" "$tag" "$size" "$p")
        if (( ${#line} < TCOLS - 3 )); then line+="  ${T_WHY[i]}"; fi
        line=${line:0:$TCOLS}
        if [[ ${DISP_IDX[idx]} == "${VIEW[CURSOR]}" ]]; then
            printf '%s%s%s\033[K\n' "$C_REV" "$line" "$C_RESET"
        elif [[ ${T_LVL[i]} == "NUNCA" ]]; then
            printf '%s%s%s\033[K\n' "$C_DIM" "$line" "$C_RESET"
        else
            printf '%s\033[K\n' "$line"
        fi
    done

    cur=-1
    (( ${#VIEW[@]} )) && cur=${VIEW[CURSOR]}
    if (( cur >= 0 )); then
        i=$cur
        tipo=${T_TYPE[i]:-Carpeta}
        dp=${T_PATH[i]}
        [[ $dp == "$HOME"/* ]] && dp="~${dp#"$HOME"}"
        d1=" Ruta: $dp"
        owner=${T_OWNER[i]:-(archivo)}
        d2=" $tipo · $owner · ${T_LVL[i]} · $(gib "${T_BYTES[i]}") GiB · ${T_WHY[i]}"
        [[ ${T_LVL[i]} == "NUNCA" ]] && d2+=" · no se borra"
        is_protected "${T_PATH[i]}" && d2+=" · protegido"
        printf '%s\033[K\n' "$(tui_fit_left "$d1" "$TCOLS")"
        printf '%s%s%s\033[K\n' "$C_DIM" "$(tui_fit "$d2" "$TCOLS")" "$C_RESET"
    else
        printf '\033[K\n\033[K\n'
    fi

    printf '%s%s%s\n' "$C_DIM" "${sep// /-}" "$C_RESET"

    chips=""
    [[ ${SHOW[SEGURO]} == 1 ]] && chips+="S " || chips+=". "
    [[ ${SHOW[REVISAR]} == 1 ]] && chips+="R " || chips+=". "
    [[ ${SHOW[DESCONOCIDO]} == 1 ]] && chips+="D " || chips+=". "
    [[ ${SHOW[NUNCA]} == 1 ]] && chips+="N" || chips+="."
    if (( ${#VIEW[@]} > 0 )); then pos=$((CURSOR + 1)); else pos=0; fi
    status=" Marcados: $marked ($(gib "$mbytes") GiB) · $pos/${#VIEW[@]} visibles · Filtro: ${FILTER:-(ninguno)} · Niveles: $chips"
    (( ONLY_BIG )) && status+=" · Grande"
    (( GROUP == 1 )) && status+=" · Agrupar: nivel"
    (( GROUP == 2 )) && status+=" · Agrupar: dueño"
    [[ -n $NOTICE ]] && status=" $NOTICE ·$status"
    printf '%s\033[K\n' "$(tui_fit "$status")"
    if (( TCOLS >= 130 )); then
        help=' espacio marca · a SEGURO · A todo · d nada · 1/2/3 nivel · n NUNCA · b grande · g agrupar · / filtro · o abrir · e exportar · Enter borrar · q salir'
    else
        help=' espacio marca · a SEGURO · d nada · g agrupar · / filtro · o abrir · e exportar · Enter borrar · q salir'
    fi
    printf '%s%s%s\033[K' "$C_DIM" "$(tui_fit "$help")" "$C_RESET"
    printf '\033[J'
}

read_key() {
    KEY=""
    local k k2 k3 junk
    IFS= read -rsn1 k || { KEY="quit"; return 1; }
    case $k in
        ''|$'\r'|$'\n') KEY="enter" ;;
        ' ') KEY="space" ;;
        $'\t') KEY="tab" ;;
        $'\e')
            IFS= read -rsn1 -t 0.03 k2 || { KEY="esc"; return 0; }
            if [[ $k2 == '[' || $k2 == 'O' ]]; then
                IFS= read -rsn1 -t 0.03 k3 || { KEY="esc"; return 0; }
                case $k3 in
                    A) KEY="up" ;; B) KEY="down" ;; C) KEY="right" ;; D) KEY="left" ;;
                    H) KEY="home" ;; F) KEY="end" ;;
                    5) IFS= read -rsn1 -t 0.03 junk; KEY="pgup" ;;
                    6) IFS= read -rsn1 -t 0.03 junk; KEY="pgdn" ;;
                    1) IFS= read -rsn1 -t 0.03 junk; KEY="home" ;;
                    4) IFS= read -rsn1 -t 0.03 junk; KEY="end" ;;
                    *) KEY="esc" ;;
                esac
            else
                KEY="esc"
            fi ;;
        *) KEY=$k ;;
    esac
    return 0
}

tui_confirm() {
    local i n=0 b=0 seg=0 rev=0 des=0 ans
    TARGETS=()
    for i in "${!T_PATH[@]}"; do
        (( ${T_MARK[i]:-0} )) || continue
        is_protected "${T_PATH[i]}" && continue
        TARGETS+=("${T_PATH[i]}${TAB}${T_BYTES[i]}${TAB}${T_LVL[i]}")
        b=$((b + T_BYTES[i]))
        case ${T_LVL[i]} in
            SEGURO)  seg=$((seg + 1)) ;;
            REVISAR) rev=$((rev + 1)) ;;
            *)       des=$((des + 1)) ;;
        esac
    done
    n=${#TARGETS[@]}
    if (( n == 0 )); then NOTICE="No hay nada marcado"; return 1; fi
    plan_bytes=$b

    tui_restore
    printf '\n'
    printf '%sBorrar %d elementos = %s GiB%s\n' "$C_BOLD" "$n" "$(gib "$b")" "$C_RESET"
    printf '  SEGURO %d · REVISAR %d · DESCONOCIDO %d\n' "$seg" "$rev" "$des"
    printf '  Se conservan ~/.cache/opencode, ~/.ssh, documentos, juegos y el directorio actual.\n'
    printf '¿Borrar? [s/N]: '
    IFS= read -r ans
    if [[ $ans == s || $ans == S || $ans == y || $ans == Y ]]; then
        run_deletion
        return 0
    fi
    tui_enter
    return 1
}

tui_run() {
    if ! tui_enter; then info "no se pudo iniciar la interfaz"; return 1; fi
    load_tui_items
    rebuild_view
    CURSOR=0; TOP=0; FILTER=""; NOTICE=""

    while true; do
        tui_draw
        read_key || break
        NOTICE=""
        case $KEY in
            up|k)   (( CURSOR > 0 )) && CURSOR=$((CURSOR - 1)) ;;
            down|j) (( CURSOR < ${#VIEW[@]} - 1 )) && CURSOR=$((CURSOR + 1)) ;;
            pgup)   CURSOR=$((CURSOR - LIST_H)); (( CURSOR < 0 )) && CURSOR=0 ;;
            pgdn)   CURSOR=$((CURSOR + LIST_H)); (( CURSOR >= ${#VIEW[@]} )) && CURSOR=$((${#VIEW[@]} - 1)); (( CURSOR < 0 )) && CURSOR=0 ;;
            home)   CURSOR=0 ;;
            end|G)  CURSOR=$((${#VIEW[@]} - 1)); (( CURSOR < 0 )) && CURSOR=0 ;;
            space)  tui_toggle_mark ;;
            a)      tui_mark_level SEGURO ;;
            A)      tui_mark_all ;;
            d)      tui_unmark ;;
            1)      tui_toggle_level SEGURO ;;
            2)      tui_toggle_level REVISAR ;;
            3)      tui_toggle_level DESCONOCIDO ;;
            n)      tui_toggle_level NUNCA ;;
            0)      SHOW[SEGURO]=1; SHOW[REVISAR]=1; SHOW[DESCONOCIDO]=1; ONLY_BIG=0; NOTICE="Filtros restaurados"; rebuild_view ;;
            g)      tui_toggle_group ;;
            b)      ONLY_BIG=$((1 - ONLY_BIG)); if (( ONLY_BIG )); then NOTICE="Solo >= ${COV_GB} GiB"; else NOTICE="Filtro grande off"; fi; rebuild_view ;;
            o)      tui_open ;;
            e)      tui_export ;;
            /)      tui_search ;;
            enter)  if tui_confirm; then return 0; fi ;;
            q|esc)  tui_restore; return 0 ;;
        esac
    done
    tui_restore
    return 0
}

if (( UI )); then
    tui_run
    exit 0
fi

info ""
info "NADA SE BORRÓ. Usá --execute-safe, o corré esto en una terminal para elegir a mano."
