#!/usr/bin/env bash
# Instala el escáner como comando `prgedisk` en ~/.local/bin.
# Uso: ./instalar.sh            instala/actualiza
#      ./instalar.sh --uninstall
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SRC="$HERE/escaner.sh"
BIN="${XDG_BIN_HOME:-$HOME/.local/bin}"
DEST="$BIN/prgedisk"

[[ -f $SRC ]] || { echo "error: no encuentro $SRC" >&2; exit 1; }

if [[ ${1:-} == "--uninstall" ]]; then
    rm -f -- "$DEST"
    echo "Quitado: $DEST"
    exit 0
fi

mkdir -p "$BIN"

chmod +x "$SRC"
rm -f -- "$DEST"
install -m 755 "$SRC" "$DEST"

echo "Instalado: $DEST (copia)"
echo "  Para actualizar tras cambiar el repo: volvé a correr ./instalar.sh"
if [[ ":$PATH:" == *":$BIN:"* ]]; then
    echo "Listo. Abrí una terminal y ejecutá:"
    echo "  prgedisk            (escanea el home)"
    echo "  prgedisk /ruta      (escanea esa ruta)"
    echo "  prgedisk --help     (opciones y ejemplos)"
    echo "  prgedisk --version"
else
    echo "Aviso: $BIN no está en PATH."
    echo "  fish:  fish_add_path $BIN"
    echo "  bash:  export PATH=\"$BIN:\$PATH\"  (agregalo a ~/.bashrc)"
fi
