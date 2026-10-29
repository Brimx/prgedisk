# Resultados

Mediciones reales de Prgedisk 1.0. Los números de Linux son de un escaneo en
seco (no se borró nada). Los de Windows vienen de las capturas de WizTree
antes/después de cada limpieza.

## Linux (2026-10-28)

Equipo: CachyOS, home de ~52 GB, 1,16 M rutas.

| Nivel | Elementos | Tamaño |
|---|---:|---:|
| SEGURO | 20 | 40,52 GiB |
| REVISAR | 9 | 19,38 GiB |
| DESCONOCIDO | 0 | 0 |
| NUNCA | 65 | 91,24 GiB |
| Huérfanos | 2 | 0,00 GiB |

Duración: 28 s con la caché de disco caliente, 106 s con la fría.

Elementos más pesados:

| Nivel | Tamaño | Ruta | Motivo |
|---|---:|---|---|
| SEGURO | 15,65 GiB | `~/steam-1222140.log` | log de Proton |
| SEGURO | 15,31 GiB | `~/.cache` | cache del usuario |
| SEGURO | 2,40 GiB | `~/.npm` | cache de herramientas |
| SEGURO | 2,17 GiB | `~/.local/share/Steam/steamapps/shadercache` | se regenera |
| SEGURO | 1,71 GiB | `~/.nuget/packages` | se re-descarga |
| REVISAR | 17,44 GiB | `~/Proyectos/<proyecto>/downloads` | cientos de archivos sueltos |
| REVISAR | 0,41 GiB | `~/.local/share/Trash` | papelera |

El escaneo encontró dos huérfanos: un menú de Cemu que apunta a
`/tmp/.mount_*` y un AppImage de Riff que ya no existe.

El `storage` de Firefox (2,00 GiB) se clasificó NUNCA: es Cache API y datos de
sitios, no cache HTTP. Ese cambio bajó SEGURO de 41,66 a 40,52 GiB.

El reporte completo de un árbol de demostración está en
[`ejemplo-reporte.txt`](ejemplo-reporte.txt).

## Windows

Limpiezas registradas (de `CONTEXTO-LINUX.md`):

| Fecha | Liberado | Nota |
|---|---:|---|
| 2026-07-31 | ~27 GB | Delivery Optimization (8,86 GB), P2P desactivado |
| 2026-08-31 | ~20,8 GB | miniforge3, GRID replay, PSP SDK, dump de SpecOps |
| 2026-10-27 | ~27 GB | Script curado de 19 restos + temporales + restore + DISM |

Estado actual de la partición NTFS de Windows montada aparte (2026-10-28):

| Total | Usado | Libre | Uso |
|---:|---:|---:|---:|
| 279,4 GiB | 211,6 GiB | 67,9 GiB | 76 % |

No hay un log por corrida de Windows; los resultados históricos salen de las
capturas de WizTree antes/después. Guardarlas en
[`capturas/`](capturas/README.md) como `wiztree-antes.png` y
`wiztree-despues.png`.

## Método

- Linux: una pasada de `du -x -a -B1` (metadatos, sin leer contenidos), reglas
  por ruta y huella de contenido. El texto se genera con `--no-ui`; el CSV
  queda en `prgedisk-<fecha>.csv`.
- Windows: CSV de WizTree o escaneo en vivo. Los totales históricos son la
  diferencia de espacio libre antes/después.
- En btrfs, borrar puede no liberar espacio hasta que expiren los snapshots
  (`snapper list`). Medir con `df` y esperar la transacción.

## Reproducir

```bash
prgedisk --no-ui --out reporte.csv
```

Para ver el detalle sin borrar: `prgedisk`. Para una ruta concreta:
`prgedisk /ruta`.
