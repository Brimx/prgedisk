# Cambios en los `.ps1` (2026-10-28)

Objetivo: que Prgedisk en Windows **no dependa del CSV de WizTree**. Si hay
CSV lo sigue usando (es mucho más rápido); si no, escanea en vivo.

## Qué cambió

### `escaner.ps1` (CLI)

- Si no encuentra `WizTree_*.csv` en Documentos, ya no aborta: pasa a escaneo en
  vivo automáticamente y lo avisa en pantalla.
- `-Live` sigue forzando el escaneo en vivo.
- `Get-EntriesLive` reescrito:
  - **una sola raíz** (`C:\`): antes empujaba también `C:\Users\santi`, que ya
    está dentro de `C:\`, y recorría el perfil dos veces.
  - **tamaños acumulados**: antes sumaba solo los archivos directos de cada
    carpeta; ahora devuelve el total con subcarpetas, comparable al CSV.
  - salta *junctions* y symlinks (evita bucles tipo `C:\Users\All Users`).
  - mantiene la poda de `WinSxS`, `Games`, `WindowsApps`, `System Volume
    Information`, `$Recycle.Bin` y OneDrive.

### `escaner-wpf.ps1` y `escaner-gui.ps1`

- `Invoke-Scan` acepta `-AllowLive`: si no hay CSV, hace el escaneo en vivo en
  vez de lanzar el error "No hay CSV de WizTree".
- El botón **Escanear** usa `-AllowLive`, así que sin CSV funciona igual.
- El arranque de la ventana **no** hace el escaneo en vivo: si no hay CSV,
  muestra "Sin datos: pulsa Escanear" y no se congela al abrir.
- La GUI sigue respetando el checkbox "Escaneo en vivo (lento)".
- Ambas comparten la misma función `Get-EntriesLive` corregida.

## Comandos instalados

Después de `instalar.ps1` y de abrir una terminal nueva:

```powershell
prgedisk                     # consola, home
prgedisk C:\ruta             # consola, esa ruta (fuerza escaneo en vivo)
prgedisk --help
prgedisk --version           # prgedisk 1.0
prgedisk-ui                  # ventana WPF
```

`--help` y `--version` los traduce el shim `prgedisk.cmd` a `-Help` y
`-Version`. Si ya tenías instalada una versión anterior, volvé a correr
`instalar.ps1` para regenerar el shim.

## Cómo se usa

```powershell
# CLI: CSV si existe; si no, vivo
.\escaner.ps1

# forzar vivo
.\escaner.ps1 -Live

# sin ventana (prueba): usa vivo si no hay CSV
.\escaner-wpf.ps1 -SelfTest
.\escaner-gui.ps1 -SelfTest
```

En la WPF/GUI: pulsar **Escanear** sin CSV dispara el escaneo en vivo.

## Límites

- El escaneo en vivo tarda minutos (recorre el disco con .NET, no con WizTree) y
  la ventana se queda bloqueada mientras dura. El CSV sigue siendo la vía rápida.
- Los tamaños en vivo son **lógicos** (tamaño de archivo), no asignados en disco
  como los del CSV. En NTFS con compresión o sparse pueden diferir.
- Las carpetas podadas (juegos, WinSxS, WindowsApps, OneDrive) no aportan su
  tamaño al padre en modo vivo, a diferencia del CSV.
- Probado sintaxis y la función en vivo con PowerShell 7.6 sobre Linux; **no se
  ejecutó en Windows**. Antes de confiar, correr una pasada sin borrar.

## Respaldos

Los originales están en `backup-20261028/` (`escaner.ps1`, `escaner-wpf.ps1`,
`escaner-gui.ps1`) por si hay que volver atrás.
