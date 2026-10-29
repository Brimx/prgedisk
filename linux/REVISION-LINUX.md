# Revisión de Prgedisk y port a Linux (`escaner.sh`)

Fecha: 2026-10-28 · Versión: 1.0 · Base: `escaner.ps1`, `escaner-wpf.ps1`, `escaner-gui.ps1`,
`reglas.json`, `CRITERIOS.md`, `CONTEXTO-LINUX.md`. Windows queda en
`../windows/`; ver `../windows/CAMBIOS-WINDOWS.md`.

## 1. Resumen

El port está en `escaner.sh` (bash 5 + coreutils). Hace lo mismo que el motor de
Windows —cuatro niveles, primer match, pasada de cobertura y huella de
contenido— y **no necesita WizTree ni ningún CSV**: recorre el árbol con `du` en
una sola pasada. `ncdu` queda para navegar a mano, no como entrada.

En una terminal, al terminar el escaneo abre una TUI propia (sin whiptail ni
dependencias): lista con casillas, filtros por nivel, búsqueda de texto,
agrupado por nivel o dueño, huérfanos de autostart, total marcado en vivo y
confirmación. El escaneo muestra progreso (`N rutas leídas ·
Ms`) para que no parezca colgado.

Pruebas: árbol falso (clasificación, borrado, symlinks, CSV), TUI en un pty
(búsqueda, filtros, detalle, exportar, marcar/borrar) y un escaneo real seco de
`$HOME` → **39,32 GiB SEGURO, 19,38 GiB REVISAR, 92,29 GiB NUNCA, 0
DESCONOCIDO**, 2 huérfanos (28-106 s según el caché de disco). No se borró
nada.

## 2. Hallazgos del original

| # | Hallazgo | Evidencia | Impacto | Estado |
|---|---|---|---|---|
| 1 | Dependencia de WizTree: sin CSV aborta o exige `-Live` | `escaner.ps1:27-36`, `:185-197`; `escaner-wpf.ps1:162-166` | En Linux no hay WizTree: el motor queda inservible tal cual | Eliminada en Linux (`du`). También parcheada en los `.ps1`: ver `../windows/CAMBIOS-WINDOWS.md` |
| 2 | `-Live` escanea `C:\` y `C:\Users\santi` (raíces anidadas) sin set de visitados | `escaner.ps1:143-145`, `:183` | Recorre el perfil dos veces y duplica ítems; `Test-Covered` solo mira ancestros, no la ruta misma (`:205-214`) | Corregido: una sola raíz y dedupe de raíces anidadas |
| 3 | En `-Live` el tamaño de cada carpeta suma solo sus archivos directos | `escaner.ps1:159-172` | `MinMB` y los totales no significan lo mismo que en modo CSV; una carpeta con subcarpetas grandes no aparece | Corregido: `du` entrega tamaño acumulado |
| 4 | Reglas SEGURO inalcanzables por orden | NUNCA `AppData\Roaming\<app>\<x>` en `escaner.ps1:62-64` gana antes de SEGURO `Roaming\<app>\Cache` en `:75-76`; NUNCA `Local\Packages\<app>` en `:64` gana antes de UWP `LocalCache` en `:71-72` | No es inseguro, pero desactiva reglas y desinfla el ahorro esperado | Reordenado: NUNCA duras → SEGURO específicas → REVISAR → NUNCA de cierre. Un NUNCA que solo contiene una cache no tapa a sus hijos (`ONPATH`) |
| 5 | La pasada de cobertura no está en `escaner.ps1` | `:217-226`; `:220` descarta toda carpeta sin regla | La idea "el activo principal" (`CONTEXTO-LINUX.md:43-53`) no se cumple en el motor de referencia | Implementada como pasada independiente y posterior, sin heurística de profundidad |
| 6 | La cobertura de la GUI exige profundidad ≥ 6 | `escaner-wpf.ps1:213-214` | Una carpeta de 50 GB a profundidad 5 nunca se reporta | Sin filtro de profundidad ni de nombre; se reporta el padre y se deduplican hijos |
| 7 | Huella con muestra sesgada: primeros 500 hijos sin orden | `escaner-wpf.ps1:91` | Un directorio con miles de archivos pequeños y un asset grande puede dar veredicto por azar | Se mantiene el tope de 500, pero solo se aplica a REVISAR y a candidatos de cobertura, nunca a SEGURO/NUNCA |
| 8 | `reglas.json` no lo lee ningún script | Las tres implementaciones declaran `$Rules = @(...)` propio (`escaner.ps1:44`, `escaner-wpf.ps1:29`, `escaner-gui.ps1:29`) | Tres copias divergen; el "contrato" del JSON es decorativo | En el port hay **una sola** lista de reglas |
| 9 | El borrado de `%TEMP%` solo excluye `dsh-*` | `escaner.ps1:320-323` | En Linux el runtime del agente también vive en `~/.cache/opencode`; borrarlo rompe la sesión | `is_protected` excluye `~/.cache/{opencode,dsh,claude,codex,deepseek}` y `/tmp/dsh-*` |
| 10 | `Remove-Item -Recurse` no distingue punto de montaje ni symlink | `escaner.ps1:314-330` | En Linux un bind mount se puede atravesar; un symlink mal manejado borra el destino | `rm --one-file-system`, chequeo de `st_dev` contra el padre, nunca seguir symlinks |
| 11 | El tamaño borrado viene del CSV (puede tener horas) | `escaner.ps1:193-196` avisa si el CSV es viejo | Se reporta un ahorro que ya no existe | Escaneo y borrado en la misma sesión; `df` antes/después |
| 12 | Las extensiones de usuario (`.zip`, `.iso`) como NUNCA aplican también dentro de caches | `escaner.ps1:65` | Un `.zip` en `~/.cache` queda NUNCA por orden | Las extensiones de usuario se evalúan después de las caches |

## 3. Decisiones del port

| Tema | Windows | Linux |
|---|---|---|
| Entrada | CSV de WizTree o `-Live` | `du` (siempre). `ncdu -x` para explorar |
| Niveles | SEGURO / REVISAR / DESCONOCIDO / NUNCA | Igual |
| Criterio | Primer match, NUNCA primero | Igual, con NUNCA de cierre para no tapar caches concretas |
| Cobertura | Carpeta > 1 GiB sin regla | Igual, más `EXPLAINED`: un padre cuyos hijos pesados ya tienen regla no se reporta como desconocido |
| Huella | `.exe`, `.dll`, `.msi`, `.db`, assets | `.git`, `.db/.sqlite`, assets, `.so/.a`, mayoría de logs, +200 archivos, ELF |
| Interfaz | WPF con casillas (o `-ExecuteSafe` en CLI) | TUI propia con casillas, filtros y búsqueda, o `--execute-safe` para batch |
| Borrado | `Remove-Item` | `rm -rf` con `--one-file-system`; los roots de cache (`~/.cache`, `/tmp`, `/var/tmp`, `~/.var/app/*/cache`) se vacían por contenido |
| Confirmación | `BORRAR` | TUI pide `s`; batch pide `BORRAR`; `--yes` sin confirmación |
| Salida | CSV en el Escritorio | CSV `~/prgedisk-<fecha>.csv` |
| Huérfanos | Claves Run rotas del registro | `.desktop` de autostart/menú con `Exec`/`TryExec` inexistente |

Parámetros equivalentes: `--min-mb` (`-MinMB`), `--min-file-mb` (`-MinFileMB`),
`--out` (`-Out`), `--execute-safe` (`-ExecuteSafe`), `--include-review`
(`-IncludeReview`), `--yes` (`-Yes`). Añadidos: `--root` (repetible),
`--coverage-gb`, `--ui`, `--no-ui`.

## 4. Uso

```bash
cd linux
./instalar.sh                   # deja el comando `prgedisk` en ~/.local/bin
prgedisk                       # desde cualquier carpeta
prgedisk /ruta                 # escanea esa ruta
prgedisk --help                # opciones y ejemplos
prgedisk --version             # prgedisk 1.0

./escaner.sh                    # equivalente sin instalar
./escaner.sh --no-ui            # solo reporte + CSV
./escaner.sh --root /           # todo el sistema (sudo para /var y /root)
./escaner.sh --min-file-mb 200  # solo archivos gordos
./escaner.sh --execute-safe     # batch: borra SEGURO, pide "BORRAR"
./escaner.sh --execute-safe --include-review
./escaner.sh --execute-safe --yes

./escaner.sh --explain ~/.cache/JetBrains   # ¿qué regla gana y por qué?
```

El instalador copia `escaner.sh` a `~/.local/bin/prgedisk`: el comando sigue
funcionando si movés la carpeta. Para actualizar tras cambiar el repo, volvé a
correr `./instalar.sh`. Desinstalar: `./instalar.sh --uninstall`.

Después de borrar mucho, en btrfs:

```bash
sudo btrfs filesystem usage /
snapper list
```

## 5. Qué no se toca

- `~/.cache/opencode`, `~/.cache/dsh`, `~/.cache/claude*`, `/tmp/dsh-*`
- `~/.ssh`, `~/.gnupg`, cualquier `.git`, `.hg`, `.svn`
- Documentos, Escritorio, Imágenes, Vídeos, Música
- Juegos (`~/.steam`, `steamapps/common`, `~/Games` y bibliotecas en
  `/mnt`/`/media`), prefijos Wine/Bottles
- Configuración (`~/.config`) y datos (`~/.local/share`) salvo caches explícitas
- El directorio actual y sus ancestros

## 6. Caché de navegador: qué se puede borrar

La regla no es "la carpeta se llama cache". Es por ruta y por tipo:

| Evidencia | Veredicto |
|---|---|
| `~/.cache/**` | SEGURO: XDG dice que es descartable |
| `cache2`, `startupCache`, `Cache`, `Code Cache`, `GPUCache`, `DawnCache`, `ShaderCache` | SEGURO: cache HTTP o código compilado |
| `storage/default/**` (Firefox) | NUNCA: Cache API, IndexedDB, Local Storage del sitio |
| `IndexedDB`, `Local Storage`, `Session Storage`, `Service Worker`, `CacheStorage` | NUNCA: datos del sitio, aunque el nombre diga cache |
| `sessionstore-backups` | NUNCA: sesión |
| carpeta pesada sin regla | DESCONOCIDO / REVISAR, nunca SEGURO |

La primera versión del port tenía una regla de navegador demasiado ancha y
marcaba `.../storage/default/https+++web.whatsapp.com/cache` como SEGURO. Eso
es **Cache API del sitio**, no cache HTTP: puede contener datos de la sesión de
la página. Corregido. El WPF ya lo hacía bien: solo `Cache`, `Code Cache`,
`GPUCache` y `DawnWebGPUCache`, nunca el perfil.

Si querés borrar datos de un sitio (sesión, IndexedDB, Cache API), se hace
desde el navegador, no desde este prgedisk. Prgedisk solo toca cache HTTP
y caches de código.

### `~/.cache` desglosada

`~/.cache` no se reporta como un bloque: se clasifica cada hijo directo
(`~/.cache/JetBrains`, `~/.cache/pip`, etc.) y los archivos sueltos de la raíz
desde 20 MB. `A` marca todo lo visible para vaciarla entera; también se puede
desmarcar una app concreta. `is_cache_root` excluye la raíz de la cobertura
para que sus hijos se vean.

### Juegos: la ruta manda

`cache_pc` dentro de `~/Games`, `~/.steam/steamapps/common` o una biblioteca
en `/mnt`/`/media` es **NUNCA por ruta**. En `steamapps/compatdata` el prefijo
es NUNCA (datos de Steam), pero una cache interna puede quedar REVISAR a
propósito. Fuera de esas raíces, un `cache_pc` cae en REVISAR y la huella lo
sube a NUNCA si adentro hay `.psarc`, `.pak`, `.pck`, `.uasset`, etc. Nunca es
SEGURO. Es el mismo principio que `C:\Games` en Windows y el caso Ghost of
Tsushima (`CRITERIOS.md:72-78`).

## 7. Interfaz

Fondo de la terminal (sin relleno de color). Azul solo en el título, video
inverso para la fila activa, gris tenue para el chrome y para NUNCA.

```
 Prgedisk · /home/santi · 35 candidatos · 40.52 GiB SEGURO
 ----------------------------------------------------------------------
 [x] SEG     15.65 GiB  ~/steam-1222140.log          logs, dumps y temporales
 [x] SEG     15.31 GiB  ~/.cache                      cache del usuario
 [ ] REV     17.44 GiB  ~/Proyectos/Melomaniac/downloads  huella: cientos...
 ...
 Ruta: ~/steam-1222140.log
 Archivo · (archivo) · SEGURO · 15.65 GiB · logs, dumps y temporales
 ----------------------------------------------------------------------
 Marcados: 26 (40.5 GiB) · 1/35 visibles · Filtro: (ninguno) · Niveles: S R D .
 espacio marca · a SEGURO · A todo · d nada · 1/2/3 nivel · n NUNCA · b grande · / filtro · o abrir · e exportar · Enter borrar · q salir
```

El panel de dos líneas muestra la **ruta completa** del elemento bajo el cursor
(con `~` para el home), su tipo, dueño aproximado, nivel, tamaño y motivo. La
ruta se recorta por la izquierda solo si no entra.

| Tecla | Acción |
|---|---|
| `↑` `↓` / `k` `j` | mover cursor |
| `PgUp` `PgDn` / `Home` `End` | desplazarse |
| `espacio` | marcar / desmarcar |
| `a` | marcar todo lo SEGURO visible |
| `A` | marcar todo lo visible (salvo NUNCA) |
| `d` | desmarcar lo visible |
| `1` `2` `3` | mostrar/ocultar SEGURO / REVISAR / DESCONOCIDO |
| `n` | mostrar/ocultar NUNCA (no se puede marcar) |
| `b` | solo elementos >= 1 GiB |
| `g` | agrupar: sin agrupar → por nivel → por dueño |
| `0` | restaurar filtros de nivel y tamaño |
| `/` | buscar por ruta o motivo; vacío borra el filtro |
| `o` | abrir la carpeta del elemento (o su carpeta madre) con `xdg-open` |
| `e` | exportar lo marcado a `~/prgedisk-seleccion-<fecha>.csv` |
| `Enter` | confirmar y borrar lo marcado |
| `q` / `Esc` | salir sin borrar |

Con `g` se cicla sin agrupar → por nivel → por dueño. Los encabezados muestran
cantidad y GiB del grupo; el cursor solo se posa en elementos, no en
encabezados. Al confirmar se restaura la terminal y aparece un resumen
(`Borrar N elementos = X GiB`, desglose por nivel) pidiendo `s` para ejecutar.
NUNCA nunca entra en la lista de marcados.

### Paridad con la GUI de Windows

| Función | WPF | TUI Linux |
|---|---|---|
| Casillas, marcar/desmarcar | sí | sí |
| Filtros por nivel | sí | `1` `2` `3` `n` |
| Buscar | sí | `/` |
| Solo > 1 GiB | sí | `b` |
| Total marcado en vivo | sí | sí |
| Detalle y ruta completa | columnas | panel de dos líneas |
| Dueño | columna | en el detalle |
| Abrir carpeta | Explorer | `o` (xdg-open) |
| Exportar selección | sí | `e` |
| Agrupar | sí (por programa) | sí (`g`: nivel o dueño) |
| Tri-estado por grupo | sí | pendiente (marcar todo/visible, no por grupo) |
| Ordenar por columna | sí | **pendiente** (orden fijo por nivel y tamaño) |
| Huérfanos | sí (registro Run) | sí (`.desktop` de autostart/menú) |

## 8. Límites conocidos

- La huella mira hasta 500 entradas y 2 niveles: es una muestra, no un censo.
- Nombres con tabulador o salto de línea rompen el formato interno (raro; el
  resto de nombres con espacios, comas y comillas funciona y el CSV los escapa).
- La TUI agrupa por nivel y por dueño, pero no tiene encabezados colapsables ni
  tri-estado por grupo; el orden es fijo.
- Los huérfanos cubren `.desktop` de usuario (`~/.config/autostart`,
  `~/.local/share/applications`). No revisa systemd ni `/etc/xdg/autostart`, y
  omite `sh -c`, Flatpak y Snap porque no puede validar el binario real.
- La búsqueda de la TUI lee byte a byte: sirve para texto ASCII; las tildes en
  el filtro no se escriben bien (los nombres con tildes se ven, solo el filtro
  se limita a ASCII). Los filtros por nivel no tienen ese límite.
- `o` depende de `xdg-open`; si no está, la TUI lo avisa.
- No implementa cuarentena ni "memoria de decisiones" (pendientes 1 y 3 de
  `CONTEXTO-LINUX.md:204-215`).
- Las reglas cubren este equipo (CachyOS + Hyprland + Steam + Flatpak). En otra
  máquina conviene revisar primero la salida en seco.

## 9. Pruebas ejecutadas

1. `bash -n` y `--help`.
2. Árbol falso: `.cache`, `.config`, Steam, Flatpak, `node_modules`, papelera,
   documento, juego, prefijos Wine, desconocido de `.so` (1,5 GB) y de `.log`
   (1,2 GB).
3. Borrado `--execute-safe`: eliminó caches, conservó `~/.cache/opencode`,
   `settings.json`, `game.pak`, `prefix.bin` y la carpeta desconocida.
4. `--include-review`: eliminó `node_modules`, papelera e instalador; conservó
   documentos, DB y binarios.
5. Symlink dentro de `~/.cache` hacia un directorio externo: ni el enlace ni el
   destino se tocaron.
6. CSV con comas y comillas en la ruta: escapado correcto.
7. Caches de navegador: `startupCache` y `Cache` de Chromium dan SEGURO;
   `storage/default/.../cache`, `Service Worker` y `Local Storage` dan NUNCA.
8. TUI en pty: render de la lista, `n`/`1` para niveles, `/node` para buscar,
   `b` para solo grandes, `e` exporta lo marcado, `o` abre la carpeta (probado
   con un `xdg-open` de prueba), marcar un REVISAR con espacio, confirmar con
   `s` y borrar solo ese ítem. `q` sale sin tocar nada.
9. Cache: `~/.cache/JetBrains`, `~/.cache/pip` y `~/.cache/loose.bin` se
   reportan por separado; `~/.cache/opencode` sigue NUNCA y sobrevive al
   borrado. Un archivo suelto de 25 MB en la raíz de `.cache` aparece.
10. Juegos: `~/Games/ghost/cache_pc` → NUNCA por ruta; `~/Apps/ghost/cache_pc`
   → REVISAR y la huella lo sube a NUNCA por el `.psarc`. El filtro `steamapps/
   compatdata` no se marcó entero para no perder las caches de los prefijos.
10. Huérfanos: autostart roto y menú roto detectados; `--execute-safe` los
    borra y conserva el `.desktop` sano y el que usa `sh -c`.
11. Agrupado en pty: `g` muestra encabezados por nivel y por dueño con cantidad
    y GiB; el cursor sigue moviéndose solo por elementos y el detalle cambia.
12. Escaneo real seco de `$HOME` (sin borrar): 1,16 M rutas,
    40,52 GiB SEGURO (15,65 GiB son `~/steam-1222140.log`), 19,38 GiB REVISAR,
    91,24 GiB NUNCA, 0 DESCONOCIDO, 2 huérfanos (un menú de Cemu que apunta a
    `/tmp/.mount_*` y un AppImage de Riff que ya no existe). El `storage` de
    Firefox (2,00 GiB) pasó de SEGURO a NUNCA. La TUI se abrió y se salió sin
    borrar.

## 10. Reglas propias y exclusiones

No hace falta una regla por programa. El diseño cubre lo nuevo por convención:

| Caso | Qué pasa sin regla |
|---|---|
| Cache nueva en `~/.cache` | SEGURO automático |
| Datos en `~/.config` o `~/.local/share` | NUNCA / no se toca |
| Carpeta pesada desconocida | DESCONOCIDO (nunca se borra) |
| Carpeta con nombre "cache" fuera de una raíz de juego | REVISAR + huella |

Solo las excepciones necesitan una regla. Se agregan sin tocar el código:

- `~/.config/prgedisk/reglas.conf`: líneas `NIVEL|regex|motivo`. Se evalúan
  antes que las internas, así que pueden proteger (`NUNCA`) o marcar una cache
  concreta (`SEGURO`). `$HOME` se expande dentro de la regex.
- `~/.config/prgedisk/exclusiones.conf`: rutas (una por línea, `~` permitido).
  Se evalúan antes que todo y también se respetan al vaciar una cache por
  contenido: `~/.cache/mi-app` sobrevive aunque `~/.cache` sea SEGURO.

`prgedisk --explain RUTA` muestra nivel, motivo y origen (`builtin`, `usuario`
o `exclusión`). Ejemplos listos en `linux/reglas.ejemplo.conf` y
`linux/exclusiones.ejemplo.conf`.

Buscar más reglas no es el objetivo: cada SEGURO de más es un riesgo. La pasada
de cobertura y la huella encuentran lo desconocido; lo que no se entiende queda
en DESCONOCIDO y se revisa a mano (o con `ncdu`).
