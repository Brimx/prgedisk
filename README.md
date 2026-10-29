# Prgedisk

Clasificador de disco con criterios explícitos: **SEGURO**, **REVISAR**,
**DESCONOCIDO** y **NUNCA**. Ante la duda, no borrar. Un falso negativo cuesta
2 GB; un falso positivo cuesta una instalación rota o datos perdidos.

Versión actual: **1.0**. Repositorio:
[github.com/Brimx/prgedisk](https://github.com/Brimx/prgedisk).

Hay dos ports del mismo motor:

```
prgedisk/
├── README.md
├── LICENSE                   MIT
├── CRITERIOS.md              contrato de niveles, protecciones y reglas
├── docs/
│   ├── RESULTADOS.md         mediciones reales Linux y Windows
│   ├── ejemplo-reporte.txt   salida de texto de un árbol de demo
│   └── capturas/             WizTree antes/después (las agrega el autor)
├── linux/
│   ├── escaner.sh            escáner + TUI (bash, sin WizTree)
│   ├── instalar.sh           deja el comando `prgedisk`
│   ├── REVISION-LINUX.md     hallazgos del original y decisiones del port
│   └── CONTEXTO-LINUX.md     traspaso y criterios específicos de Linux
└── windows/
    ├── instalar.ps1          deja los comandos `prgedisk` y `prgedisk-ui`
    ├── Abrir-Prgedisk.cmd    lanza la GUI (doble clic)
    ├── escaner.ps1           motor CLI
    ├── escaner-wpf.ps1       GUI WPF
    ├── escaner-gui.ps1       GUI WinForms
    ├── limpiar-win.ps1       limpiador curado por fases
    ├── reglas.json           reglas del port Windows (referencia)
    ├── CAMBIOS-WINDOWS.md    parche para que el CSV sea opcional
    └── backup-20261028/      originales de los .ps1 antes del parche
```

## Instalación

### Linux

```bash
cd linux
./instalar.sh          # copia en ~/.local/bin/prgedisk
# abrir una terminal nueva (o recargar fish)
prgedisk
```

El instalador copia el script a `~/.local/bin/prgedisk`, así que el comando
sigue funcionando si movés la carpeta. Para actualizarlo tras cambiar el repo,
volvé a correr `./instalar.sh`. Desinstalar:

```bash
./instalar.sh --uninstall
```

### Windows

```powershell
cd windows
.\instalar.ps1
# abrir una terminal NUEVA
prgedisk        # consola
prgedisk-ui     # ventana WPF
```

Copia los scripts a `%LOCALAPPDATA%\Prgedisk`, crea los shims `.cmd`, agrega
esa carpeta al `PATH` del usuario y deja un acceso directo `Prgedisk` en el
escritorio que abre la ventana WPF. Desinstalar:

```powershell
.\instalar.ps1 -Uninstall
```

## Linux

```bash
prgedisk                    # escanea el home y abre la TUI
prgedisk /ruta              # escanea esa ruta (o varias)
prgedisk --no-ui            # solo reporte + CSV
prgedisk --execute-safe     # batch: borra lo SEGURO
prgedisk --help             # opciones y ejemplos
prgedisk --version          # prgedisk 1.0
```

- No necesita WizTree: recorre el disco con `du` (una pasada).
- La TUI trae casillas, filtros por nivel (`1` `2` `3` `n`), búsqueda (`/`),
  solo grandes (`b`), agrupado por nivel o dueño (`g`), detalle con ruta
  completa, abrir carpeta (`o`), exportar lo marcado (`e`) y total en vivo.
- Detecta huérfanos de autostart/menú (`.desktop` con `Exec` inexistente) y los
  marca SEGURO; se borran solo con `--execute-safe` o marcándolos.
- Solo toca cache HTTP y caches de código. El almacenamiento de sitios
  (`storage`, `IndexedDB`, `Local Storage`, `CacheStorage`) es NUNCA.
- `ncdu` sigue sirviendo para explorar a mano.
- Detalles y límites: `linux/REVISION-LINUX.md`.

### Reglas propias

La mayoría de apps nuevas no necesitan reglas: su cache cae en `~/.cache`
(SEGURO) y sus datos en `~/.config`/`~/.local/share` (NUNCA). Solo las
excepciones necesitan una regla.

```bash
prgedisk --explain ~/.cache/mi-app   # muestra qué regla gana y por qué
```

- `~/.config/prgedisk/reglas.conf`: `NIVEL|regex|motivo`, se evalúan antes
  que las internas. Formato y ejemplos en `linux/reglas.ejemplo.conf`.
- `~/.config/prgedisk/exclusiones.conf`: una ruta por línea; protege esa ruta
  y todo lo de adentro, aunque esté bajo una cache SEGURO. Ejemplo en
  `linux/exclusiones.ejemplo.conf`.

## Windows

```powershell
prgedisk                    # CSV de WizTree si existe; si no, vivo
prgedisk C:\ruta            # escanea esa ruta (en vivo)
prgedisk -Live              # fuerza escaneo en vivo
prgedisk --help
prgedisk --version
prgedisk-ui                 # GUI; el botón Escanear cae a vivo si no hay CSV
```

- El CSV de WizTree ya es **opcional** (`windows/CAMBIOS-WINDOWS.md`).
- El escaneo en vivo tarda minutos y usa tamaños lógicos.
- `limpiar-win.ps1` es el limpiador por fases; solo informa salvo `-Execute`.
- El instalador deja un acceso directo en el escritorio para quien no usa
  terminal.

## Resultados

- **Linux (2026-10-28, seco):** 40,52 GiB SEGURO, 19,38 GiB REVISAR,
  91,24 GiB NUNCA, 0 DESCONOCIDO, 2 huérfanos, 1,16 M rutas (28-106 s).
- **Windows:** ~27 GB (jul), ~20,8 GB (ago), ~27 GB (oct), según las capturas
  de WizTree.

El detalle, el método y un reporte de texto de ejemplo están en
[`docs/RESULTADOS.md`](docs/RESULTADOS.md) y
[`docs/ejemplo-reporte.txt`](docs/ejemplo-reporte.txt).

## Criterio compartido

`CRITERIOS.md` define qué es cada nivel y qué está prohibido tocar (claves,
documentos, juegos, bases de datos, configuración). Cualquier implementación
nueva debe respetarlo; la UI puede cambiar.

## Seguridad

- NUNCA no se borra por diseño (claves, `.git`, documentos, juegos, DBs).
- DESCONOCIDO no se borra por defecto; en Linux se marca a mano.
- En Linux se conservan siempre `~/.cache/opencode`, `~/.cache/dsh`,
  `~/.cache/claude*`, `/tmp/dsh-*` y el directorio actual.
- En btrfs, borrar puede no liberar espacio hasta que expiren los snapshots
  (`snapper list`).

## Publicar en un repo

La herramienta está lista para versionarse, pero antes de hacerla pública:

- Licencia: MIT (`LICENSE`). Si preferís Apache-2.0, se cambia.
- Revisar rutas personales: `windows/limpiar-win.ps1` está curado para este
  equipo y `C:\Games` es una convención del autor. Los documentos mencionan el
  hardware y rutas concretas.
- `.gitignore` ya excluye los reportes que genera el propio prgedisk.
- Primer paso local: `git init && git add . && git commit -m "prgedisk 1.0"`.
  Remoto: `git remote add origin https://github.com/Brimx/prgedisk.git`.
  El push lo hacés con tus credenciales.
