# Prgedisk

[**English**](README.md) · [Español](README.es.md)

<p align="center">
  <a href="https://github.com/Brimx/prgedisk/tree/v1.0"><img alt="version 1.0" src="https://img.shields.io/badge/version-1.0-blueviolet?style=for-the-badge&amp;labelColor=1f2328"></a>
  <a href="https://github.com/Brimx/prgedisk/blob/main/LICENSE"><img alt="license MIT" src="https://img.shields.io/badge/license-MIT-green?style=for-the-badge&amp;labelColor=1f2328"></a>
  <img alt="Linux" src="https://img.shields.io/badge/platform-Linux-FCC624?style=for-the-badge&amp;logo=linux&amp;logoColor=black">
  <img alt="Windows" src="https://img.shields.io/badge/platform-Windows-0078D4?style=for-the-badge&amp;logo=windows&amp;logoColor=white">
  <img alt="bash 4.4+" src="https://img.shields.io/badge/shell-bash%204.4%2B-4EAA25?style=for-the-badge&amp;logo=gnubash&amp;logoColor=white">
  <img alt="PowerShell 5.1+" src="https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?style=for-the-badge&amp;logo=powershell&amp;logoColor=white">
  <a href="https://github.com/Brimx/prgedisk"><img alt="docs ES and EN" src="https://img.shields.io/badge/docs-ES%20%7C%20EN-purple?style=for-the-badge&amp;labelColor=1f2328"></a>
</p>

<p align="center">
  <a href="https://github.com/Brimx/prgedisk"><img alt="GitHub" height="32" src="https://img.shields.io/badge/GitHub-Brimx%2Fprgedisk-181717?style=social&amp;logo=github"></a>
  <img alt="version 1.0" height="32" src="https://img.shields.io/badge/version-1.0-blueviolet?style=social">
  <img alt="license MIT" height="32" src="https://img.shields.io/badge/license-MIT-green?style=social">
  <img alt="docs ES and EN" height="32" src="https://img.shields.io/badge/docs-ES%20%7C%20EN-lightgrey?style=social">
</p>

A disk cleaner with explicit criteria: **SEGURO** (safe), **REVISAR** (review),
**DESCONOCIDO** (unknown) and **NUNCA** (never). When in doubt, don't delete.
A false negative costs 2 GB; a false positive costs a broken install or lost
data.

Current version: **1.0**. Repository:
[github.com/Brimx/prgedisk](https://github.com/Brimx/prgedisk).

The scanner prints its levels in Spanish; this README maps them. Two ports
share the same engine:

```
prgedisk/
├── README.md                 English
├── README.es.md              Español
├── LICENSE                   MIT
├── resources/
│   ├── antes.png             WizTree before cleaning Windows
│   └── despues.png           WizTree after
├── CRITERIOS.md              levels, protections and rules (Spanish)
├── docs/
│   ├── RESULTADOS.md         real Linux and Windows measurements (Spanish)
│   └── ejemplo-reporte.txt   text report from a demo tree
├── linux/
│   ├── escaner.sh            scanner + TUI (bash, no WizTree)
│   ├── instalar.sh           installs the `prgedisk` command
│   ├── REVISION-LINUX.md     port findings and decisions
│   └── CONTEXTO-LINUX.md     Linux handover notes
└── windows/
    ├── instalar.ps1          installs `prgedisk` and `prgedisk-ui`
    ├── Abrir-Prgedisk.cmd    launches the GUI (double click)
    ├── escaner.ps1           CLI engine
    ├── escaner-wpf.ps1       WPF GUI
    ├── escaner-gui.ps1       WinForms GUI
    ├── limpiar-win.ps1       curated phase cleaner (personal)
    ├── reglas.json           Windows rule reference
    ├── CAMBIOS-WINDOWS.md    optional WizTree CSV changes
    └── backup-20261028/      original .ps1 files before the patch
```

## Installation

### Linux

```bash
cd linux
./instalar.sh          # copies to ~/.local/bin/prgedisk
# open a new terminal (or reload fish)
prgedisk
```

The installer copies the script to `~/.local/bin/prgedisk`, so the command
keeps working if you move the repository. Re-run `./instalar.sh` after updating
the repo. Uninstall:

```bash
./instalar.sh --uninstall
```

### Windows

```powershell
cd windows
.\instalar.ps1
# open a NEW terminal
prgedisk        # console
prgedisk-ui     # WPF window
```

It copies the scripts to `%LOCALAPPDATA%\Prgedisk`, creates the `.cmd` shims,
adds that folder to the user `PATH`, and places a `Prgedisk` desktop shortcut
that opens the WPF window. Uninstall:

```powershell
.\instalar.ps1 -Uninstall
```

## Linux

```bash
prgedisk                    # scan home and open the TUI
prgedisk /path              # scan that path (or several)
prgedisk --no-ui            # report + CSV only
prgedisk --execute-safe     # batch: delete SEGURO
prgedisk --help             # options and examples
prgedisk --version          # prgedisk 1.0
```

- No WizTree needed: walks the disk with `du` in a single pass.
- The TUI has checkboxes, level filters (`1` `2` `3` `n`), text search (`/`),
  large-only (`b`), grouping by level/owner (`g`), full-path detail, open folder
  (`o`), export selection (`e`), and a live marked total.
- Detects autostart/menu orphans (`.desktop` with a missing `Exec`) and marks
  them SEGURO; they are deleted only with `--execute-safe` or by selecting them.
- `~/.cache` is broken down per application: each cache can be selected or
  deselected separately. `A` marks everything visible if you want to clear it
  all.
- Only touches HTTP and compiled caches. Site storage (`storage`, `IndexedDB`,
  `Local Storage`, `CacheStorage`) is NUNCA.
- `ncdu` is still useful for manual browsing.
- Details and limits: `linux/REVISION-LINUX.md`.

### How to delete

- In the TUI: `space` marks, `Enter` opens the summary, then type `s` + `Enter`
  to confirm. `q` or `Esc` exits without deleting.
- Batch: `prgedisk --execute-safe` deletes SEGURO; add `--include-review` for
  REVISAR. Confirm by typing `BORRAR`, or use `--yes`.

### Custom rules

Most new apps need no rules: their cache goes to `~/.cache` (SEGURO) and their
data to `~/.config`/`~/.local/share` (NUNCA). Only exceptions need a rule.

```bash
prgedisk --explain ~/.cache/my-app   # shows which rule wins and why
```

- `~/.config/prgedisk/reglas.conf`: `NIVEL|regex|reason`, evaluated before the
  built-in rules. Format and examples in `linux/reglas.ejemplo.conf`.
- `~/.config/prgedisk/exclusiones.conf`: one path per line; protects that path
  and everything below it, even inside a SEGURO cache. Example in
  `linux/exclusiones.ejemplo.conf`.

## Windows

```powershell
prgedisk                    # WizTree CSV if present; otherwise live
prgedisk C:\path            # scan that path (live)
prgedisk -Live              # force a live scan
prgedisk --help
prgedisk --version
prgedisk-ui                 # GUI; Escanear falls back to live without a CSV
```

- The WizTree CSV is now **optional** (`windows/CAMBIOS-WINDOWS.md`).
- Live scanning takes minutes and uses logical sizes.
- `limpiar-win.ps1` is the phase cleaner; report-only unless `-Execute`.
- The installer creates a desktop shortcut for people who don't use a terminal.

## Results

- **Linux (2026-10-28, dry run):** 39.32 GiB SEGURO, 19.38 GiB REVISAR,
  92.29 GiB NUNCA, 0 DESCONOCIDO, 2 orphans, 1.16 M paths (28-106 s).
- **Windows:** ~27 GB (Jul), ~20.8 GB (Aug), ~27 GB (Oct), per the WizTree
  captures.

Details, method and a sample text report:
[`docs/RESULTADOS.md`](docs/RESULTADOS.md) and
[`docs/ejemplo-reporte.txt`](docs/ejemplo-reporte.txt).

| Before | After |
|---|---|
| ![WizTree before](https://raw.githubusercontent.com/Brimx/prgedisk/main/resources/antes.png) | ![WizTree after](https://raw.githubusercontent.com/Brimx/prgedisk/main/resources/despues.png) |

## Shared criteria

`CRITERIOS.md` defines each level and what must never be touched (keys,
documents, games, databases, configuration). Any new implementation must
respect it; the UI can change.

## Safety

- NUNCA is never deleted by design (keys, `.git`, documents, games, DBs).
- DESCONOCIDO is not deleted by default; on Linux you have to select it.
- Linux always preserves `~/.cache/opencode`, `~/.cache/dsh`,
  `~/.cache/claude*`, `/tmp/dsh-*` and the current directory.
- On btrfs, deleting may not free space until snapshots expire
  (`snapper list`).

## Repository

Code, results and captures:
[github.com/Brimx/prgedisk](https://github.com/Brimx/prgedisk). MIT license.
