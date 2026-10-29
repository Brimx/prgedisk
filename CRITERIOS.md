# Criterios de limpieza — equipo ASUS Vivobook S14 (santi)

Documento de referencia. Consolida las decisiones tomadas en los registros
`limpieza_disco_c_2026-07-31.txt`, `limpieza_disco_c_2026-08-31.txt`, lo pedido
en la sesión de octubre 2026, y los criterios técnicos agregados después.

Sirve de contrato: cualquier implementación (PowerShell, Rust, Python) debe
respetar esto. La UI puede cambiar; estos criterios no.

---

## 1. Contexto del equipo

| Dato | Valor |
|---|---|
| Equipo | ASUS Vivobook S14 S5406SA |
| CPU/GPU | Intel Core Ultra 5 226V (Lunar Lake, NPU) + Arc 130V |
| RAM | 15,52 GiB **soldada** (sin upgrade posible) |
| Disco | WD PC SN5000S 512 GB → 477 GiB útiles |
| Particiones | C: NTFS 279,4 GiB · btrfs 191,7 GiB (CachyOS) · EFI · Recovery |
| SO | Windows 11 Pro 26H2 |
| Uso real | Desarrollo y personalización en Linux (CachyOS + Hyprland) |
| Windows es | Consola de juegos + C# para la universidad |

Consecuencia: Windows no es el entorno de trabajo. Todo lo que sea toolchain,
IDE o runtime excepto lo que exige la universidad es candidato a salir.

---

## 2. Los tres niveles y por qué existen

| Nivel | Definición operativa | Se borra |
|---|---|---|
| **SEGURO** | Se puede regenerar o re-descargar sin pérdida. No es dato del usuario. | Automático |
| **REVISAR** | Es caché o resto real, pero la decisión depende del uso. | Solo si el usuario marca |
| **DESCONOCIDO** | Archivo grande sin regla. **No se sabe qué es.** | Nunca por defecto |
| **NUNCA** | Dato, binario, configuración o base de datos. | Bloqueado por diseño |

Principio rector: **ante la duda, no borrar**. Un falso negativo cuesta 2 GB;
un falso positivo cuesta una instalación rota o datos perdidos.

`DESCONOCIDO` existe porque separar "no sé qué es esto" de "esto es caché" evita
que el usuario borre por reflejo. Si algo no encaja en una regla, se investiga
antes de tocarlo.

---

## 3. Protecciones absolutas (NUNCA)

### 3.1 Sistema y sistema de archivos
- `C:\$MFT`, `C:\$LogFile`, `C:\$Bitmap`, `C:\$UpCase`, `C:\$Boot` — metadatos NTFS.
  Borrar el MFT deja el volumen irrecuperable. *(Detectado como falso positivo el
  2026-10-27; era la categoría REVISAR. Bug crítico corregido.)*
- `C:\Windows\WinSxS`, `System32`, `SysWOW64`, `assembly`, `servicing`, `Installer`
- `C:\System Volume Information`, `C:\Recovery`, `$Recycle.Bin`
- `hiberfil.sys`, `pagefile.sys`, `swapfile.sys` — memoria virtual
- `C:\ProgramData\Microsoft\Windows\AppRepository` — base de datos de apps

### 3.2 Datos del usuario
- Documentos, OneDrive (contenido), Escritorio, Imágenes, Videos, Música
- Partidas guardadas: `Saved Games`, `My Games`, `saves/`
- `C:\Users\santi\.ssh`, `.gnupg` — claves
- `.git` — historial de repos

### 3.3 Herramientas de desarrollo (estado, no caché)
- `~/.local/share/opencode` — base de datos y sesiones de opencode
- `~/.config/opencode` — configuración
- `~/.opencode-mem` — memoria del agente
- `~/.codex`, `~/.bun`, `~/.claude`, `~/.gemini` — datos de CLI
- `%LOCALAPPDATA%\Programs\opencode-desktop` — la app v2 (se conserva)

### 3.4 Juegos
- `C:\Games\**` — todo
- `Steam\steamapps\common\**` — todo
- Extensiones de assets: `.psarc`, `.pak`, `.mpk`, `.pck`, `.vpk`, `.bsa`, `.ba2`
- **Caso emblemático:** `Ghost of Tsushima\cache_pc` (52,8 GiB) se llama "cache"
  pero contiene los assets del juego en `.psarc`. Borrarlo destruye la instalación.
  La protección es por ruta (`C:\Games` gana antes de la regla de caché), no por suerte.

### 3.5 Stack que se conserva a propósito
- Visual Studio 2026 Community + dotnet SDK 10 — **requisito de la universidad (C#)**
- Microsoft Office, Node.js, Python 3.14
- MyASUS (`B9ECED6F.ASUSPCAssistant`) — drivers
- Ghost of Tsushima, Blood Strike, Geometry Dash, Steam
- CapCut (la app), Obsidian (la app y sus vaults), JDownloader, opencode desktop

---

## 4. Criterios heredados de los registros de julio y agosto

| Decisión | Motivo registrado |
|---|---|
| `D:` es CachyOS — **no tocar** | Partición Linux |
| Hibernación desactivada, pagefile se queda | Es memoria virtual, no hibernación |
| Delivery Optimization **desactivado** (P2P) | Fue 8,86 GB. Desactivado el 31/07, sigue en 0 |
| Cachés de Edge: solo `Cache`, `Code Cache`, `GPUCache`, `DawnWebGPUCache` | Nunca el perfil: marcadores y claves intactos |
| WhatsApp: solo `LocalCache` | Los chats no se tocan |
| VS Code: solo caches (`CachedExtensionVSIXs`, `CachedData`, `Cache`, `GPUCache`, `blob_storage`) | Configuración y extensiones se respetan |
| `ms-playwright` | Se reinstala con `npx playwright install` |
| `SoftwareDistribution\Download` | Deteniendo `wuauserv` y `bits` primero |
| Bloatware ASUS/Tecas vía `Remove-AppxPackage -AllUsers` | Estaba en la cuenta oculta `WsiAccount`. No volvió |
| **WinSxS: `StartComponentCleanup` SIN `/ResetBase`** | Textual: "para no romper updates" |
| Shadow copies a **2 GB** de máximo | Estaba en 6,59 GB por defecto |
| Modelos de IA `WindowsWorkload.*` — **no tocar** | Vuelven con cada update; son parte de la imagen. Recall ya está desactivado |
| `C:\eSupport` (drivers ASUS) — **no tocar** | Decisión explícita del usuario |
| Debloaters (Optimizer, Win11Debloat) — **no usar** | Experiencias malas previas; rompen MyASUS/NPU en Copilot+ PC. Revisión manual |
| Saves de juegos (Codemasters, Sony) | Son datos |

---

## 5. Criterios pedidos en esta sesión

| Elemento | Decisión |
|---|---|
| CapCut `User Data\Cache` | **Borrar** |
| CapCut `Apps\9.5.0.4050` | **Conservar** — contiene `CapCut.exe`, es la aplicación |
| Geometry Dash, JDownloader | **Conservar** |
| opencode CLI (npm `opencode-ai` v1.18.32) y cachés | **Borrar** |
| opencode base de datos, config, `.opencode-mem`, app desktop v2.2.0 | **Conservar** |
| Firefox `\updated` | **Borrar** — archivos de la versión anterior, no el perfil |
| Obsidian `installer.exe` | **Borrar** — la app (`Programs\Obsidian`) y los vaults no |
| Python 3.11 | **Borrar**; se conserva 3.14 |
| Node.js | **Conservar**; solo se limpia `npm-cache` |
| Edge | **No desinstalar** — vuelve con cada update y WebView2 depende de sus binarios. Solo se quita el autostart |
| Servicios ASUS | A `Manual`: `ASUSSoftwareManager`, `ASUSSystemAnalysis`, `ASUSSystemDiagnosis`, `AsusAppService` |
| Servicios ASUS a conservar | `ASUSOptimization` (ventilador), `AsusPTPService` (touchpad), `ASUSSwitch` (teclas Fn) |
| Detroit Become Human `ShaderCache` | **Borrar** — se recompila |
| Instaladores ya usados | **Borrar** |
| Registros huérfanos | **Borrar** — autostart cuyo `.exe` no existe; entrada de desinstalación cuya ruta no existe |

---

## 6. Criterios técnicos agregados (con la evidencia que los motivó)

| Regla | Por qué |
|---|---|
| `\\.(exe\|dll\|sys\|ocx\|node\|pyd)$` → NUNCA | Un `.exe` dentro de una carpeta de programa **es el programa**, no un instalador. La regla vieja lo etiquetaba como "instalador" y ofrecía borrar `libcef.dll`, `codex.exe` |
| Instalador → solo si está en `Downloads` o `Escritorio` | Un `.msi` en `Package Cache` es caché; un `.exe` en `Programs\` es la app |
| `dsh-*` en TEMP y `~/.dsh` → NUNCA | La limpieza de TEMP borró el directorio del sandbox de DSH y rompió la sesión del agente |
| NUNCA sobre `Program Files\|Windows\|ProgramData` **solo como fallback de archivos** | Aplicado como regla general se comió caches legítimos (`Windows\Temp`, `ProgramData\Package Cache`) |
| Binarios de navegador (`Edge`, `EdgeCore`, `EdgeWebView`) → NUNCA | Se ofrecían como candidatos de borrado |

---

## 7. Regla de oro para agregar una regla nueva

Antes de marcar algo como SEGURO, responder:

1. **¿Se regenera?** Si Windows/app lo recrea solo → SEGURO.
2. **¿Está en una ruta de datos?** Si vive dentro de un perfil de app o de un
   directorio de usuario → mínimo REVISAR.
3. **¿El nombre coincide con el contenido?** `cache_pc` no es caché. `Apps\` no
   son instaladores. Verificar qué hay dentro antes de clasificar por nombre.
4. **¿Qué pasa si me equivoco?** Si la respuesta es "se reinstala" → SEGURO.
   Si es "reinstalo el juego/IDE/sistema" → NUNCA.

---

## 8. Contrato para el port a Rust + egui

El motor y la UI deben estar separados. El motor no sabe de ventanas.

```
crate prgedisk-core
    rules.rs      -> tabla de reglas cargada de reglas.json (serde)
    scan.rs       -> WizTree CSV (fast) | walkdir/ignore (live)
    classify.rs   -> primer match gana; NUNCA primero
    model.rs      -> Item { nivel, motivo, ruta, tipo, bytes, reg_path, reg_name }
crate prgedisk-gui   (egui/eframe)
    tabla virtualizada: ScrollArea::show_rows (solo dibuja lo visible)
    filtros por nivel, busqueda incremental, casillas
```

Notas técnicas:
- `reglas.json` es la fuente de verdad compartida; ambos frontends lo leen.
- Carga del CSV de WizTree: 159 MB / 932k filas. Con `csv` + `serde` es ~0,5 s.
  En modo live el cuello es el I/O del disco, no el lenguaje.
- Para tamaños de directorio en modo live: `rayon` + `jwalk`, con poda de
  `C:\Games`, `WinSxS`, `WindowsApps`, `System Volume Information`.
- Borrado: misma semántica que PowerShell — `\temp$` borra contenido (excluyendo
  `dsh-*`), registro usa `remove_value` o `delete_subkey`.
- egui resuelve el problema de Tkinter: sin async, con 100k filas la lista se
  congela; `show_rows` solo pinta el viewport.

---

## 9. Historial

| Fecha | Liberado | Nota |
|---|---|---|
| 2026-07-31 | ~27 GB | Delivery Optimization (8,86 GB) fue el mayor. P2P desactivado |
| 2026-08-31 | ~20,8 GB | Fase 2: miniforge3, GRID replay, PSP SDK, dump de SpecOps |
| 2026-10-27 | ~27 GB | Script curado + 19 restos. Efecto colateral: borró el TEMP del sandbox de DSH |
| 2026-10-27 | — | Motor de reglas + GUI con selección por casillas |
