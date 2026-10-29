# Prgedisk — contexto para Linux

Documento de traspaso. Consolida lo aprendido construyendo la herramienta en
Windows, para no repetir el mismo trabajo al portar a Linux.

Si vienes a retomar el proyecto: lee este archivo y `../CRITERIOS.md`. Con esos dos
tienes todo el criterio. El código es reemplazable; el criterio no.

---

## 1. Qué se construyó (y por qué importa)

Tres piezas, en orden de valor real:

| Pieza | Archivo | Valor |
|---|---|---|
| **Criterio** | `CRITERIOS.md` | El activo principal. Sin esto, el código clasifica al azar |
| **Reglas como datos** | `reglas.json` | 44 reglas ordenadas, primer match gana, NUNCA primero |
| **Motor + UI** | `escaner-wpf.ps1` | Implementación de referencia |

El principio que se repitió una y otra vez: **el nombre miente, el contenido no**.
Y: **ante la duda, no borrar**. Un falso negativo cuesta 2 GB; un falso positivo
cuesta una instalación rota o datos perdidos.

---

## 2. Los cuatro niveles

| Nivel | Definición operativa | Se borra |
|---|---|---|
| **SEGURO** | Se regenera o re-descarga. No es dato del usuario | Automático |
| **REVISAR** | Es caché o resto real, pero depende del uso | Solo si el usuario marca |
| **DESCONOCIDO** | Archivo/carpeta pesada sin regla. **No se sabe qué es** | Nunca por defecto |
| **NUNCA** | Dato, binario, configuración o base de datos | Bloqueado por diseño |

`DESCONOCIDO` existe porque mezclar "no sé qué es esto" con "esto es caché"
hace que el usuario borre por reflejo.

---

## 3. Las dos ideas que valieron todo el trabajo

### 3.1 Pasada de cobertura (buscar por peso, no solo por regla)

Después de clasificar con las reglas, hacer una segunda pasada: recorrer el árbol
y **reportar cualquier carpeta de más de 1 GiB que ninguna regla explique**.
Jerárquico: reportar el padre y no sus hijos.

Esto es exactamente la diferencia con el "Liberador de espacio" de Windows y con
`ncdu`. Ellos solo miran rutas conocidas; esto encuentra lo que crece en lugares
inesperados. Fue lo que descubrió carpetas que los scripts curados nunca iban a
conocer.

Implementación fragile que hay que evitar: **no** meterlo dentro del bucle
principal (suprime los hijos si el padre no tiene regla). Debe ser una pasada
independiente y posterior.

### 3.2 Huella de contenido (fingerprint)

Clasificar por lo que hay adentro, no por el nombre de la carpeta. Evidencia y
veredicto:

| Evidencia | Veredicto |
|---|---|
| `unins000.exe` / `uninstall.exe` / `uninst.exe` | NUNCA — app instalada |
| `<nombre-de-carpeta>.exe` presente | NUNCA — es la aplicación |
| `.db`, `.sqlite`, `.mdf`, `.ldb` | NUNCA — base de datos |
| `.pak`, `.psarc`, `.pck`, `.assets` | NUNCA — assets de juego |
| >40% de archivos son `.dll` | NUNCA — bibliotecas |
| `.msi` o `setup.exe` | REVISAR — instalador empaquetado |
| >40% son `.log`/`.tmp`/`.dmp` | **SEGURO** — logs |
| +200 archivos sin ningún `.exe` | REVISAR — caché probable |
| solo subcarpetas | DESCONOCIDO — revisar a mano |

Casos que la huella resolvió y el nombre habría fallado:
- `Ghost of Tsushima\cache_pc` → 52,8 GiB **de assets**, no caché
- `CapCut\Apps\9.5.0.4050` → contenía `CapCut.exe`: la app, no instaladores
- `Firefox\updated` → versión anterior del navegador, no configuración

Lección de implementación: usar `-ErrorAction SilentlyContinue`. Un enlace roto
dentro de las 28 carpetas de extensiones de VS Code hacía que la función lanzara
excepción y devolviera `null` en silencio.

---

## 4. En Linux cambia todo (para bien)

En Windows se escanea porque no hay estándar: `AppData` tiene tres ramas,
`ProgramData`, dos `Program Files`, y cada app inventa su estructura.

En Linux el estándar es explícito:

| Ruta | Contenido por convención |
|---|---|
| `~/.cache/` | **Cache por definición.** Casi todo borrable |
| `~/.local/share/` | Datos persistentes (DBs, sesiones) — no tocar |
| `~/.config/` | Configuración — no tocar |
| `~/.local/state/` | Estado — revisar |
| `/tmp`, `/var/tmp` | Temporales |
| `~/.var/app/` | Datos y cache de Flatpaks |
| `~/.steam/`, `~/.local/share/Steam/` | Juegos |

**Consecuencia: `~/.cache` siendo cache por spec elimina el 80% de la ambigüedad
que costó 44 reglas en Windows.** La tabla puede bajar a ~12 reglas.

### Herramientas que ya existen y conviene usar antes que escribir

```bash
du -sh ~/.cache/* | sort -h        # la pasada de cobertura, versión shell
ncdu ~/.cache                      # navegador TUI, borra con 'd'
xdg-cache-clean                    # ejecuta el cache-clean de cada app
paccache -r -k 2                   # Arch/CachyOS: paquetes viejos, deja 2
paccache -ruk0                     # paquetes desinstalados
yay -Sc                            # cache de compilación de AUR
journalctl --vacuum-size=200M
```

### Tabla de reglas propuesta (~12 en vez de 44)

```
~/.cache/**                                 -> SEGURO
~/.cache/<app>/                             -> SEGURO salvo lista blanca
/tmp/**, /var/tmp/**                        -> SEGURO
~/.local/state/**                           -> REVISAR
~/.local/share/Steam/steamapps/downloading  -> SEGURO
/var/cache/pacman/pkg/<viejos>              -> REVISAR (paccache lo hace mejor)
~/.local/share/**, ~/.config/**             -> NUNCA
~/.ssh/**, ~/.gnupg/**                      -> NUNCA
~/.cache/opencode  (o el agente que uses)   -> NUNCA (es el runtime del agente)
```

### Trampa de btrfs en CachyOS

Antes y después de borrar mucho:

```bash
sudo btrfs filesystem usage /
snapper list
```

Con snapshots de snapper, **borrar archivos puede no devolver espacio hasta que
expiren los snapshots**. Te ahorrará la confusión de "borré 20 GB y sigue igual".

---

## 5. Arquitectura para el port

El motor no debe saber que existe una ventana.

```
crate prgedisk-core
    reglas.json   <- fuente de verdad compartida, ya escrita
    rules.rs      <- serde: carga y ordena (primer match gana)
    scan.rs       <- walkdir/jwalk + rayon para "en vivo"
    classify.rs   <- reglas + pasada de cobertura + huella
    model.rs      <- Item { nivel, motivo, ruta, tipo, bytes }

crate prgedisk-tui   <- ratatui + crossterm
crate prgedisk-gui   <- egui/eframe (opcional)
```

Crates: `ratatui`, `crossterm`, `egui`/`eframe`, `serde`/`serde_json`,
`walkdir`, `jwalk`, `rayon`.

Por qué Rust aquí tiene más sentido que en Windows: la TUI (`ratatui`) y la GUI
(`egui`) comparten el mismo `core`, así que el motor se escribe una vez. Y para
recorrer árboles, `jwalk` + `rayon` con poda es lo que hace lento a `du`.

**egui resuelve el problema de Tkinter:** sin virtualización, una lista de miles
de filas se congela. `ScrollArea::show_rows` solo dibuja el viewport, así que 10
o 100.000 filas cuestan lo mismo por frame.

Comparativa de UI (Windows):

| Stack | Binario | Arranque | Nota |
|---|---|---|---|
| WPF | nativo, .NET | instantáneo | Carga desde `.ps1` sin compilar. Es lo que usa WinUtil |
| WinUI 3 | requiere Windows App SDK | — | Pesado para una herramienta ligera, obliga a empaquetar |
| egui | 3-5 MB | instantáneo | Ideal para Linux, doble uso TUI/GUI |

---

## 6. Errores cometidos (no repetirlos)

Registro honesto, cada uno costó una iteración:

| Error | Consecuencia | Arreglo |
|---|---|---|
| Regla `\.(msi\|exe)$` a secas | Marcaba `libcef.dll`, `codex.exe` como "instalador" | Instalador solo en `Downloads`/`Escritorio`; `.exe/.dll/sys` → NUNCA |
| `NUNCA` genérico sobre `Program Files\|Windows\|ProgramData` | Se comió `Windows\Temp`, `ProgramData\Package Cache` | Solo como fallback de archivos sin regla |
| Sin protección de metadatos NTFS | Ofrecía borrar `C:\$MFT` → volumen irrecuperable | Regla `^c:\\\$` → NUNCA |
| Pasada de cobertura dentro del bucle principal | `C:\Users` sin regla suprimió todo su contenido | Pasada independiente y posterior |
| Regla duplicada por ancestro | Doble conteo: `.vscode\extensions` dentro de `.vscode` | Dedupe antes de medir |
| `CollectionViewSource.View` antes de setear `Source` | `ItemsSource` quedó en `null`, lista siempre vacía | Reasignar `ItemsSource` en cada refresco |
| Test contaba `Source.Count` | Decía "34 filas" con el grid vacío | Medir `dg.Items.Count` |
| `Dispatcher.Invoke([action]{}, 'Background')` | Excepción al pulsar Escanear | Eliminada |
| Bordes de docking en WinForms | `Fill` se dibujaba encima de los encabezados | Añadir el `Fill` primero |
| `Get-ChildItem -ErrorAction Stop` en fingerprint | Excepción con un enlace roto; devolvía `null` | `SilentlyContinue` |
| Script en UTF-8 sin BOM con tildes | PowerShell 5.1 lo lee como ANSI y rompe el parser | ASCII puro, o guardar con BOM |
| Borrar todo TEMP sin excluir el sandbox del agente | Rompió la sesión: `%TEMP%\dsh-*` es su directorio de trabajo | Excluir `dsh-*` y `~/.dsh` |

---

## 7. Lo que quedó pendiente (aún útil en Linux)

1. **Cuarentena** en vez de borrado — mover a `<fecha>/` conservando la
   estructura de rutas, con botón restaurar. Es el único cambio que da derecho a
   equivocarse.
2. **Lista de exclusiones editable** (texto plano), para proteger rutas sin
   tocar código.
3. **Memoria de decisiones** — un ítem ya rechazado queda bloqueado la próxima
   vez. Sin ML: un JSON de "esto ya lo decidí".
4. **Agrupar por dueño/programa** con encabezados colapsables y checkbox
   tri-estado. En WPF era `CollectionViewSource` + `PropertyGroupDescription`.
5. **Auto-elevación** (Windows) y que el historial se escriba solo.

---

## 8. Regla de oro para agregar una regla nueva

Antes de marcar algo como SEGURO, responder:

1. **¿Se regenera?** Si el sistema o la app lo recrea solo → SEGURO.
2. **¿Está en una ruta de datos?** Si vive dentro de un perfil o directorio de
   usuario → mínimo REVISAR.
3. **¿El nombre coincide con el contenido?** `cache_pc` no es caché. `Apps\` no
   son instaladores. Verificar qué hay dentro antes de clasificar por nombre.
4. **¿Qué pasa si me equivoco?** "Se reinstala" → SEGURO.
   "Reinstalo el juego/IDE/sistema" → NUNCA.

---

## 9. Historial de uso (Windows)

| Fecha | Liberado | Nota |
|---|---|---|
| 2026-07-31 | ~27 GB | Delivery Optimization (8,86 GB) el mayor. P2P desactivado |
| 2026-08-31 | ~20,8 GB | miniforge3, GRID replay, PSP SDK, dump de SpecOps |
| 2026-10-27 | ~27 GB | Script curado de 19 restos + temporales + restore + DISM |

---

## 10. Cómo retomar en Linux

```bash
# 1. Ver qué hay de verdad
du -sh ~/.cache/* | sort -h
sudo btrfs filesystem usage /

# 2. Lo que ya existe, antes de escribir nada
ncdu ~/.cache
paccache -r -k 2

# 3. Solo entonces: portar, empezando por el motor
#    - cargar reglas.json (o la tabla de ~12 reglas de la sección 4)
#    - pasada de cobertura (sección 3.1)
#    - huella de contenido (sección 3.2)
```

El orden importa: medir, entender, y recién escribir. Es lo que faltó en las
primeras iteraciones en Windows, que solo terminaron cuando el disco real las
puso a prueba.
