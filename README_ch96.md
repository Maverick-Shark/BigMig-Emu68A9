# BigMig-Emu68A9 en Chameleon96 — fase 1 (puntos 1 a 3)

Proyecto de Quartus Prime Lite **17.1** para la Chameleon96 (Cyclone V SE
**5CSEBA6U19I7**), con la chip RAM en el módulo PSRAM dual (2 × APS6404L) en
lugar de la SDRAM.

Este árbol es BigMig-Emu68A9 tal como está en
`3d5d4d19169fa88673bdd926d8d1fced5c9a2cd9` (release 20261019) más los cambios
de este port. Las piezas de la Chameleon96 (marco `sys/` de la placa, top
level, pines, PLL de la PSRAM, controlador QPI y calibración) vienen del port
del Amstrad de teiram, `Amstrad_MiSTer_ch96`, commit `6ca26b71b4a2`. Después
se han contrastado con su plantilla de núcleos, `Template_MiSTer_ch96` (commit
`023c7cb`), y con el mapa de la DDR3 de la placa (ver
[Memoria DDR3](#memoria-ddr3-de-la-chameleon96)).

## Qué funciona y qué no, en esta fase

Esta fase sirve para la puesta en marcha de la parte FPGA:

* compila en Quartus 17.1;
* arranca en la placa, calibra la PSRAM y muestra el resultado en los LEDs;
* da imagen por HDMI y abre el OSD.

**El Amiga todavía no puede arrancar.** Faltan tres cosas, que son los
puntos siguientes del plan:

| punto | qué | por qué hace falta |
|---|---|---|
| 4 | adelanto de la DMA de Agnus (y de las lecturas de la CPU por el bus de chip) | una lectura de PSRAM no cabe en el slot de 140 ns en que el chipset espera el dato (ver más abajo) |
| 5 | llevar a `0x10000000–0x1C000000` todo lo que el firmware Emu68-A964 y el Main de BigMig ponen en la DDR | en la DE10-Nano ocupa `0x23800000–0x40000000`, que en la Chameleon96 no existe: el controlador de 512 MB pliega esas direcciones sobre la memoria de Linux (ver [Memoria DDR3](#memoria-ddr3-de-la-chameleon96)) |
| 6 | Main de BigMig (`MiSTer_BigMig`) para la Chameleon96, y comprobar su U-Boot y su Linux | sin él no se carga Emu68 en el núcleo ARM 1, y en el modo HYBRID_EMU no hay otra CPU (ver [Punto 6](#punto-6-main-u-boot-y-linux)) |

Con el Main de teiram, el núcleo se carga como un núcleo genérico: verás el
menú del CONF_STR de BigMig, no el menú de Minimig.

Orden para seguir:

1. Compila y prueba en la placa (las dos secciones siguientes). Con el informe
   de PLL, el estado de D5 y lo que marcan D7 y D6 se hace el punto 4.
2. Mientras tanto, la prueba del `.txt` del [punto 6](#punto-6-main-u-boot-y-linux),
   que no necesita BigMig.
3. El punto 5 se puede preparar ya sobre el código de Emu68-A964, que es
   público. El lado del Main necesita el código de `MiSTer_BigMig`.

## Compilar

1. Abre `BigMig_ch96.qpf` en Quartus Prime Lite 17.1.
2. *Processing → Start Compilation*.
3. El resultado es `output_files/BigMig_ch96.rbf`.

Antes de copiarlo a la placa, mira estos tres informes:

* **Fitter → Resource Section → PLL Usage**: la PLL `pll_psram` tiene que
  salir con VCO de 640 MHz, tres contadores, y la salida 2 (captura) con fase de
  1172 ps en el **contador C2**. Si la salida 2 no está en C2, la calibración
  mueve el reloj equivocado; avísame con ese informe.
* **Fitter → Resource Usage Summary**: el 5CSEBA6 de la Chameleon96 tiene los
  mismos recursos que el de la DE10-Nano. Si no cabe, quita la GPU para la
  puesta en marcha: comenta las macros `BIGMIG_GPU*` y la línea
  `rtl/gpu/bigmig/quartus/bm_gpu.qip` del `.qsf`.
* **TimeQuest**: el SDC es `BigMig_ch96.sdc`. Las rutas entre el reloj de la
  PSRAM (128 MHz) y el del chipset (113,5 MHz) pasan por colas con punteros Gray
  y están cortadas a propósito. Las del reloj de captura (C2 de `pll_psram`)
  también: el margen de captura lo comprueba la calibración, no TimeQuest.

## Probar en la placa

Copia el `.rbf` a la tarjeta como cualquier núcleo de la Chameleon96 y cárgalo
desde el menú.

| LED | durante la calibración | calibrada bien (unos 9 s) | si falla | después |
|---|---|---|---|---|
| D5 (user) | parpadeo rápido, unos 4 Hz | encendido fijo | parpadeo lento, 1 Hz, para siempre | disquetera |
| D6 (disk) | apagado | c\*[1] | apagado | disco duro |
| D7 (power) | apagado | c\*[2] | apagado | power |
| D8 | enganche del vídeo en baja latencia (`vsync_adjust=2`), del marco MiSTer | | | |
| amarillo | hay vídeo (HDMI DE) | | | |
| azul | siempre encendido | | | |

El parpadeo rápido de D5 lo genera la propia PLL de la PSRAM. Si D5 no
parpadea nunca, esa PLL no está funcionando.

**Apunta qué marcan D7 y D6** con la calibración buena. Es el dato que
necesito para decidir cómo hacer el punto 4:

| D7 D6 | c\* | lectura de 16 bits | lectura de 64 bits |
|---|---|---|---|
| apagado, apagado | 0–1 | 22 ciclos | 28 ciclos |
| apagado, encendido | 2–3 | 24 | 30 |
| encendido, apagado | 4–5 | 26 | 32 |
| encendido, encendido | 6–7 | 28 | 34 |

(ciclos de 128 MHz, desde que el controlador lanza la orden hasta el dato)

Si tienes SignalTap, el estado completo de la calibración está en
`sys_top|emu|ram1|u_dual|cal|status[63:0]`. Bits:

* [9:0] ancho del ojo común
* [19:10] y [29:20] ojo de cada chip
* [32:30] c\*
* [39:33] s\*
* [49:40] margen
* [50] done, [51] busy, [52] fail
* [62:55] número de cambios de `clk_det`

Es el mismo formato que el `psram.stp` del Amstrad.

**Ventilador.** El núcleo saca por el pin del ventilador el mismo PWM que la
plantilla de teiram: 50 % a unos 48 Hz. Solo llega al ventilador con el
preloader de `hps-ch96` desde el commit `97e5fe4` (11-11-2026), que presta ese
pin (TRACE_D0, loan I/O 49) a la FPGA. Con un preloader anterior el pin sigue
siendo del HPS y no pasa nada más.

## Qué cambia respecto a BigMig (DE10-Nano)

| fichero | cambio |
|---|---|
| `BigMig_ch96.qpf/.qsf/.sdc` | proyecto nuevo. Mismas opciones y macros que `BigMig.qsf`, más `MISTER_CHAMELEON96`, `BIGMIG_NO_RTG_ANALOG` y `MISTER_DISABLE_ALSA` (ver [Opciones](#opciones)). Un solo SDC que sustituye a `sys_top.sdc`, `BigMig.sdc`, `f0e_*.sdc`, `f1_gpu.sdc`, `seam.sdc` y `rtg_scanout.sdc`, con las rutas bajo `sys_top\|` |
| `ch96_top.sv` | top level de la placa (el de teiram), con la PSRAM, los LEDs y el ventilador (loan I/O 49, como en `Template_MiSTer_ch96`) en el bus loan I/O del HPS |
| `sys/sys_top.v`, `sys/sysmem.sv`, `sys/emu_ports.vh` | fusión a tres bandas sobre la base común de ambos forks (Template_MiSTer `f35083f3b4`), sin conflictos: lo de BigMig (seam AXI, GPU, RTG, ALSA en ddr_svc) más lo de la Chameleon96 (`clk_50m` desde `h2f_user1_clk`, puertos PSRAM, LEDs, scaler en `0x1E800000`). Encima, tres cambios: `BIGMIG_NO_RTG_ANALOG` deja fuera la salida RTG analógica nativa; la salida `FAN_PWM` del ventilador; y con `MISTER_CHAMELEON96` las direcciones de la GPU en la DDR quedan fijadas dentro de `0x10000000–0x1FFFFFFF` |
| `sys/sys.qip`, `sys/arcade_video.v`, `sys/pll_hdmi/pll_hdmi_0002.v`, `sys/pll_q22.qip`, `sys/pins_ch96.tcl` | los de la Chameleon96 de teiram, sin cambios (iguales en el Amstrad y en la plantilla) |
| `sys/hps_ch96.tcl` | el de teiram más la ubicación del SPI del HPS, que solo se usa si se quita `MISTER_DISABLE_ALSA` |
| `BigMig.sv` | todo bajo `ifdef MISTER_CHAMELEON96`: PLL de la PSRAM, `psram_chip_ctrl` como `ram1`, SDRAM aparcada, reset retenido hasta que la PSRAM está calibrada, y estado de la calibración en los LEDs |
| `rtl/pll_psram*` | la PLL de la PSRAM del Amstrad (VCO 640 MHz, 128 MHz más captura con desplazamiento de fase dinámico en C2), renombrada y sin metadatos de IP, para que la acepte Quartus 17 |
| `rtl/psram/` | el controlador de chip RAM (ver abajo) |
| `tools_ch96/`, `sim_ch96/` | los scripts que generan este árbol desde BigMig y el Amstrad, el lint y el banco de pruebas del controlador |

`BigMig.qpf/.qsf` y `jtag.cdf` de la DE10-Nano no están en este árbol, porque
su `sys/` ya es el de la Chameleon96. Para la DE10-Nano usa el repositorio
original.

## Controlador de chip RAM (`rtl/psram/`)

`psram_chip_ctrl` sustituye a `sdram_ctrl` y conserva sus puertos:

* puerto de chip de 16 bits, más `chip48` para las lecturas de 64 bits de AGA;
* puerto de CPU con `cpu_cache_new` (el Via-B de Emu68) y el buffer de
  escritura, con `ramready` y `write_busy` iguales que antes.

Por eso en `BigMig.sv` solo cambia la instancia. La carga de la ROM desde el
HPS entra por el puerto de chip como cualquier escritura.

* **Organización**: los dos APS6404L funcionan en paralelo. El chip A guarda
  D15..D8 y el B guarda D7..D0, en la misma dirección de byte. Los 16 MB del
  bus de chip caben justos en los 2 × 8 MB.
* **Reloj**: la PSRAM tiene su propia PLL a 128 MHz. La conversión de PAL a
  NTSC de la PLL principal no la afecta ni obliga a recalibrar.
* **Orden**: todas las peticiones van por una sola cola, en orden. Una lectura
  posterior siempre ve una escritura anterior. La caché se espía en el slot de
  la escritura de chip, como en `sdram_ctrl`. Si una escritura de chip cae en
  la línea de un relleno de caché que aún está en vuelo, se mezcla con el dato
  antes de entregarlo.
* **Ficheros**:
  * `psram_n.sv` es el `psram.sv` de teiram con una trama de 4 bytes, generado
    por `tools_ch96/mk_psram_n.py`;
  * `psram_cal3.sv` y `psram_dps.sv` son los de teiram tal cual;
  * `psram_dual.sv` y `psram_afifo.sv` son nuevos.

### Latencias (simulación, Icarus)

`sim_ch96/` tiene el banco de pruebas. Usa dos modelos APS6404L con retardos de
placa, `amiga_clk` real, el tráfico del chipset por slots de 7 MHz y el
protocolo Via-B del puente híbrido. Comprueba cada lectura de chip, cada
lectura de CPU y el contenido final de los dos chips. Todas las pasadas
terminaron sin errores. Las de abajo además barren tamaños, carga y retardos.

Latencia desde el inicio del slot de 7 MHz hasta que `chipRD` tiene el dato,
con la cola vacía:

| lectura | c\* | latencia |
|---|---|---|
| 16 bits | 1 | 242–251 ns |
| 16 bits | 3 | 251–260 ns |
| 32 bits | 1 | 251–260 ns |
| 64 bits | 0–1 | 286–295 ns |
| 64 bits | 2–3 | 304–313 ns |

El chipset de Minimig espera el dato al final del mismo slot, a unos 138 ns:
**ninguna lectura llega**. Por eso en esta fase las lecturas del chipset
devuelven el dato correcto, pero tarde. Las de la CPU (Via-B) esperan y
funcionan bien.

Con el adelanto del punto 4 el chipset daría la dirección un slot antes, y el
margen sería de unos 279 ns:

* entran las lecturas de 16 y 32 bits (OCS/ECS y AGA con FMODE 0, 1 y 2);
* **no entran las de 64 bits** (AGA con FMODE 3).

Para FMODE 3 hará falta, además, adelantar un CCK entero las lecturas de
bitplanes, o bien quitar el cruce de reloj, que cuesta unos 40 ns. Para elegir
entre las dos necesito saber el c\* de tu placa.

Ejecutar (Icarus Verilog 11 o posterior):

```sh
cd sim_ch96
./run_tb.sh base                          # 64 bits, retardos por defecto
./run_tb.sh rd16 -DRDSIZE=0               # lecturas de chip de 16 bits
./run_tb.sh lento -DDFWD_NS=5.0 -DDBACK_NS=5.0 -DTACLK_NS=5.5
```

El resultado queda en `sim_ch96/out/<nombre>.log`. Cada pasada imprime también
los tiempos medidos en los pines de cada chip (tSP, tHD, tCSP, tCHD).

### Revisión del módulo (APS6404L-SQN) y polaridad de SCLK

Contrastado con la hoja de datos del APS6404L-SQN (1,8 V, v3.6):

| supuesto | hoja de datos | estado |
|---|---|---|
| lectura EBh en QPI con 6 ciclos de espera | 6 | correcto |
| escritura 02h sin espera, hasta 144 MHz | sí | correcto |
| 128 MHz dentro de límites | máximo 144 MHz (tCLK ≥ 7 ns) | correcto |
| tCPH ≥ 18 ns, tCEM ≤ 8 µs | 18 ns; 8 µs (4 µs en grado extendido) | correcto: 23,4 ns y 0,19 µs medidos |
| tACLK 2–5,5 ns, tKOH 1,5 ns | igual | correcto |
| ráfagas dentro de la página de 1 KB | envolvente de 1 KB por defecto | correcto: nunca se cruza |
| por encima de 84 MHz hay que ajustar el muestreo | recomendado por el fabricante | correcto: es lo que hace la calibración |
| arranque: 150 µs y reset 66h/99h, luego 35h | igual, tRST 50 ns | correcto |
| **retención de entrada** tHD ≥ 2 ns y tCHD ≥ 3 ns | sí | **no estaba comprobado** |

El último punto es el único fallo de la revisión. El controlador v3 de teiram
saca SCLK directamente del reloj y cambia CE# y SIO en ese mismo flanco de
subida. La retención que ve el chip es solo la diferencia de retardo entre
los pines de datos y el de SCLK, que depende de cada compilación y que Quartus
no acota en los pines loan I/O. El modelo de simulación no la comprobaba.

Con el banco ampliado:

| SCLK | funciona si los datos llegan… | cumple la hoja de datos si llegan… |
|---|---|---|
| normal (por defecto, como el Amstrad) | después de SCLK (0 a 7,8 ns) | entre 3,0 y 5,3 ns después |
| invertido (`PSRAM_SCLK_INV`) | entre 3,9 ns antes y 3,9 ns después | entre 0,9 ns antes y 1,4 ns después |

Con SCLK normal, si CE# llega antes que SCLK el chip cuenta un flanco de más y
no funciona nada. El valor por defecto sigue siendo el de teiram porque está
probado en esta placa, pero con otra compilación. Si la calibración falla (D5
en parpadeo lento), descomenta `PSRAM_SCLK_INV` en el `.qsf` y vuelve a
compilar.

También se corrigió el modelo: mantenía el nivel de reposo en el bus durante
tACLK tras bajar CE#, lo que producía los avisos "tSP violation" de antes y
hacía fallar en falso el modo invertido.

## Memoria DDR3 de la Chameleon96

### La placa

* 512 MB de DDR3 de **16 bits** a 400 MHz: 1,6 GB/s de pico, la mitad que la
  DE10-Nano (1 GB, 32 bits). La comparten los dos núcleos ARM y la FPGA.
* Linux usa `0x00000000–0x0FFFFFFF`. `0x10000000–0x1FFFFFFF` está reservado
  en el device tree (`no-map`): Linux no lo toca, y es lo único que pueden
  usar la FPGA, el Main y Emu68.
* El controlador solo decodifica los bits de 512 MB. Una dirección más alta
  no da error: se repite sobre la memoria de Linux. Así corrompía Linux el
  ao486 original.

Qué hay en la zona reservada y qué queda para BigMig. Solo se carga un `.rbf`
a la vez, así que lo que usan otros núcleos no cuenta:

| zona | tamaño | qué es | con BigMig |
|---|---|---|---|
| `0x10000000–0x1C000000` | 192 MB | ventana del ao486 y sombra GCR del C64 (`0x1B800000`), de otros núcleos | **libre** |
| `0x1C000000–0x1CFFF000` | 16 MB | framebuffer de los arcade y base de `sdram_on_ddr`, de otros núcleos | libre: BigMig no usa ninguno de los dos |
| `0x1CFFF000–0x1D000000` | 4 KB | paleta del LFB del Main | ocupada |
| `0x1D000000–0x1E7B8000` | 23,7 MB | LFB del Main (menú, terminal de Linux) | ocupado |
| `0x1E800000–0x20000000` | 24 MB | buffers del scaler (`ascal`) | ocupado siempre |

### Lado FPGA: correcto

En la FPGA no queda ninguna dirección de la DE10-Nano. Quién toca la DDR:

| quién | puerto | dirección | estado |
|---|---|---|---|
| scaler (`ascal`): sus buffers | vbuf (128 bits) | `0x1E800000`, fija en `sys_top` | correcta: es la de la plantilla de la Chameleon96 |
| scaler: framebuffer RTG (`MISTER_FB`) | vbuf | `FB_BASE`, la escribe el driver RTG del Amiga en `rtg.v` | solo lee. Con el punto 5 apuntará a la VRAM RTG nueva |
| scaler: LFB del Main | vbuf | la que fija el Main (`0x1D000000` en el de teiram) | solo lee |
| `ddr_svc`: paleta del LFB y ALSA | ram2 | 4 KB por debajo del LFB; ALSA, el búfer de Linux | solo lee; ALSA fuera (`MISTER_DISABLE_ALSA`) |
| GPU de BigMig | ram1 (64 bits) | la que le da el firmware | **escribe**. Con `MISTER_CHAMELEON96` queda fijada dentro de `0x10000000–0x1FFFFFFF` |
| RTG analógico (`rtg_ddr_reader`) | ram2 | `FB_BASE` | fuera (`BIGMIG_NO_RTG_ANALOG`) |

La guarda de la GPU fuerza a `0001` los cuatro bits altos de la dirección de
byte. Con una dirección equivocada (por ejemplo, la de la DE10-Nano) la GPU
puede estropear la imagen, pero no la memoria de Linux. Con el firmware del
punto 5 no cambia nada.

### Lado Emu68 y Main: hay que moverlo (punto 5)

En la DE10-Nano todo esto está en `0x23800000–0x40000000` (456 MB). La
propuesta lo lleva a `0x10000000–0x1C000000` (192 MB) con el mismo orden y las
mismas distancias internas, para que el cambio sea solo de constantes. Cumple
las comprobaciones `#if … #error` de `amiga_memmap.h`.

| qué | constantes | DE10-Nano | tamaño | Chameleon96 | tamaño |
|---|---|---|---|---|---|
| VRAM de la ZZ9000 | `ZZ9000_VRAM_PHYS`, `ZZ9000_BACKING_BYTES` | `0x23800000` | 64 MB | `0x10000000` | 32 MB |
| VRAM RTG de MiSTer (los 8 MB de arriba de la anterior) | `RTGVRAM_DDR_BASE`, `FB_BASE` del driver | `0x27000000` | 8 MB | `0x11800000` | 8 MB |
| HDFBOX, buzón y SHARE | `HDFBOX_DDR_BASE`, `SHARE_MBOX_DDR`, `SHARE_DDR_BASE` (= `SHMEM_ADDR` del Main) | `0x27FF2000`, `0x27FF3000`, `0x27FF4000` | 16 KB | `0x127F2000`, `0x127F3000`, `0x127F4000` | 16 KB |
| `Emu68.img` (carga y entrada del núcleo 1) | `EMU68_IMG_LOAD`, `CPU_RAM_BASE` | `0x28000000` | 8 MB | `0x12800000` | 8 MB |
| anillos de red, AHI y MHI (dentro de la anterior) | `ZZNET_*`, `UAESND_*`, `MHI_*` | `0x28610000–0x28670000` | | `0x12E10000–0x12E70000` | |
| Fast RAM Zorro II | `FASTRAM_DDR_BASE` | `0x28800000` | 8 MB | `0x13000000` | 8 MB |
| heap 2 de A3D y arena de MiniGL | `A3D_HEAP2_DDR_BASE`, `A3D_MGLC_ARENA_DDR_BASE` | `0x29200000`, `0x29E00000` | 14 MB | `0x13A00000`, `0x14600000` | 14 MB |
| Fast RAM Zorro III | `Z3FAST_DDR_BASE`, `Z3FAST_SIZE_MB` | `0x2A000000` | 256 MB | `0x14800000` | **64 MB** |
| pool del JIT | `JITPOOL_DDR_BASE`, `JITPOOL_SIZE_MB` | `0x3A000000` | 64 MB | `0x18800000` | **24 MB** |
| ROM de BigMigHD, DTREE y FPresident | `BIGMIGHD_ROM_DDR_BASE`, `DTREE_ROM_DDR_BASE`, `FPRESIDENT_ROM_DDR_BASE` | `0x3E100000` | 4 MB | `0x1A100000` | 4 MB |
| heap de A3D | `A3D_HEAP_DDR_BASE` | `0x3E500000` | 16 MB | `0x1A500000` | 16 MB |
| ROM extendida | `EXTROM_DDR_BASE` | `0x3F600000` | 512 KB | `0x1B600000` | 512 KB |
| Kickstart | `ROM_DDR_BASE`, `KICKSTART_DDR` | `0x3F700000`, `0x3F780000` | 1 MB | `0x1B700000`, `0x1B780000` | 1 MB |
| núcleo de Emu68 y tlsf | `EMU68_KERNEL_DDR`, `CPU_RAM_TOP` | `0x3F800000`, tope `0x40000000` | 8 MB | `0x1B800000`, tope `0x1C000000` | 8 MB |

Notas:

* Las tres páginas compartidas siguen en el mismo mega (`0x127xxxxx`), porque
  el firmware las mapea con una sola sección de 1 MB.
* Los anillos siguen en `Emu68.img + 0x610000`; su sección pasa de
  `mmu_table[0x286]` a `mmu_table[0x12E]`.
* El firmware mapea `CPU_RAM_BASE…CPU_RAM_TOP` con VA = PA, así que el 68k verá
  esa zona en `0x12800000–0x1BFFFFFF`. Hay que comprobar que no choca con nada
  del espacio Amiga (Fast Z3 en `0x40000000`, VRAM RTG del 68k en
  `0x02000000`).

Variantes:

* **A**: VRAM de la ZZ9000 de 64 MB, como ahora. Quedan 32 MB de Fast Z3 y
  24 MB de JIT.
* **B** (la de la tabla): VRAM de 32 MB (24 MB para la ZZ9000 y 8 MB para el
  RTG de MiSTer), 64 MB de Fast Z3 y 24 MB de JIT.
* **C**: A o B, subiendo el tope a `0x1CF00000` (15 MB más), por ejemplo para
  el JIT. No se puede pasar de ahí: en `0x1CFFF000` está la paleta del LFB. Si
  la Fast Z3 se anuncia por autoconfig, su tamaño tiene que ser potencia de 2.

Ficheros que hay que cambiar:

* **Emu68-A964** (código público):
  * `src/pistorm/amiga_memmap.h`: todas las direcciones de la tabla,
    `Z3FAST_SIZE_MB` y `JITPOOL_SIZE_MB`, y las comprobaciones de DTREE y
    FPresident, que llevan `0x3F600000u` escrito a mano en vez de
    `EXTROM_DDR_BASE`;
  * `src/de10nano/start_de10nano.c`: `CPU_RAM_BASE`, `CPU_RAM_TOP` y la sección
    `0x286` de los anillos;
  * `src/de10nano/zz9000_board.c`: `ZZ9000_VRAM_PHYS` y, con la variante B,
    `ZZ9000_BACKING_BYTES`.

  Mejor con una macro de placa (p. ej. `CHAMELEON96`) que cambiando los números
  de la DE10-Nano. Ojo: los `0x3F800000` de `agent3d/a3d_draw.c` son el 1,0 en
  coma flotante, no direcciones.
* **Main de BigMig**: `SHMEM_ADDR` y las otras dos páginas compartidas, la carga
  de `Emu68.img`, de la Kickstart, de la ROM extendida y de las ROM de
  BigMigHD, DTREE y FPresident, y los anillos de red, AHI y MHI.
* **Driver RTG del Amiga**: su `FB_BASE` (= `RTGVRAM_DDR_BASE`).

## Punto 6: Main, U-Boot y Linux

Lo que hay que resolver o comprobar para que el Main de BigMig funcione en la
Chameleon96:

1. **El código del Main de BigMig.** `MiSTer_BigMig` se publica compilado, y
   el fork `Main_MiSTer` de raparici solo tiene el upstream. Para la
   Chameleon96 hay que juntar sus cambios con los del Main de teiram
   (`Main_MiSTer_ch96`, macro `CHAMELEON96`: `FB_ADDR 0x1D000000`, scaler en
   `0x1E800000`) y con el punto 5. Hay que pedírselo a raparici.
2. **El `.txt` de BigMig (`maxcpus=1`).** Al cargar BigMig, el Main escribe el
   entorno de U-Boot en `0x1FFFF000` con el `.txt` y reinicia; U-Boot vuelve a
   cargar el `.rbf` y arranca Linux con esos argumentos. El Main de teiram
   tiene ese código (`make_env`), pero hay que probar que el U-Boot de la
   Chameleon96 lo usa, incluida la segunda línea del `.txt` (`scrtest`,
   `$mmc_boot`, `$loadaddr`). Se puede probar sin BigMig: copia un núcleo
   cualquiera de la Chameleon96 como `Prueba.rbf` y, a su lado, el `.txt` de
   BigMig como `Prueba.txt`. Al cargarlo, la placa tiene que reiniciar y
   volver con ese núcleo, y en Linux `cat /proc/cmdline` tiene que mostrar
   `maxcpus=1 sidecar=1` y `nproc` tiene que dar 1.
3. **El puente HPS→FPGA.** La costura de BigMig está en `0xC0000000`, en el
   puente h2f. En la DE10-Nano el Main lo abre (`do_bridge`: registro `remap`
   del NIC-301 a `0x19`); el Main de teiram se salta esa escritura con
   `CHAMELEON96`. Sin ella Emu68 no ve el bus del Amiga. Hay que saber por qué
   la quitó teiram y, si U-Boot no deja el puente abierto, hacerla en el Main
   de BigMig.
4. **Audio de AHI y MHI.** Va del Main a ALSA y de ahí a la FPGA. En la
   Chameleon96 no hay ALSA (ver [Opciones](#opciones)). Hace falta otro
   camino: por ejemplo, que el Main deje las muestras en un anillo de la zona
   reservada y la FPGA las lea por ram2, con la dirección y los punteros por
   `hps_io` en vez de por SPI. Paula y el audio de CD no dependen de esto.
5. **Linux.** BigMig está validado con Linux 5.15.1-MiSTer y aún no con 6.x.
   Mira con `uname -r` qué kernel lleva la Chameleon96.
6. **Ancho de banda.** El JIT, la Fast RAM y las texturas de Emu68 están en la
   DDR, que aquí rinde la mitad. Habrá que medirlo. Si el vídeo o Emu68 se
   resienten, el controlador tiene prioridades por puerto (`MPPRIORITY`,
   `MPWEIGHT`).

## Comprobación sin Quartus

Este árbol se ha comprobado sin Quartus, así:

* `tools_ch96/lint_tree.py` lee el `.qsf`, incluidos los `.qip`. Sustituye por
  cajas negras las primitivas de Altera, los átomos del HPS y las tres
  entidades VHDL, y elabora el diseño entero desde `ch96_top` con Verilator.
* Sale **sin errores** con:
  * la configuración del `.qsf`;
  * con ALSA (sin `MISTER_DISABLE_ALSA`);
  * sin GPU;
  * con la salida RTG analógica (sin `BIGMIG_NO_RTG_ANALOG`);
  * con `PSRAM_SCLK_INV`.
* Los únicos avisos son los 11 que ya tiene BigMig (5 sin GPU); ninguno en el
  código nuevo.
* El script pasa `-fno-gate` a Verilator. La versión 5.020 aborta en esa
  optimización con `rtl/rtg_hdmi_osd_sprite.v`, que es de BigMig y no cambia
  en este port. Es una pasada de optimización: las comprobaciones son las
  mismas.

Esto no sustituye a Quartus: no cubre el VHDL, ni el ajuste, ni los tiempos, ni
lo que Quartus 17 pueda aceptar de forma distinta. Si Quartus da un error,
pásamelo tal cual.

## Opciones

* `BIGMIG_NO_RTG_ANALOG`: activada. Esta placa no tiene salida analógica; el
  RTG se ve por HDMI, a través del scaler.
* `MISTER_DISABLE_ALSA`: **activada**, como en `Template_MiSTer_ch96`. El
  preloader de la Chameleon96 (`hps-ch96`) lleva SPIM0 y SPIM1 a pines del HPS,
  así que el SPI de Linux no llega a la FPGA y ALSA no puede funcionar. El
  precio: el audio de AHI y MHI de BigMig, que sale por ALSA, no suena (ver
  [punto 6](#punto-6-main-u-boot-y-linux)). Quítala solo con un preloader que
  lleve un SPI a la FPGA.
* `PSRAM_SCLK_INV`: desactivada (ver
  [la revisión del módulo](#revisión-del-módulo-aps6404l-sqn-y-polaridad-de-sclk)).
* `BIGMIG_NO_CHIP_WRITE_RETRY`: activada, igual que en la DE10-Nano.

## Créditos y licencias

* BigMig-Emu68A9 (Ruben Aparicio), Minimig-AGA para MiSTer (Alexey Melnikov y
  sus autores), Template_MiSTer: GPL, según cada fichero.
* Port a la Chameleon96: `ch96_top`, marco `sys/`, PLL y controlador PSRAM v3
  (`psram.sv`, `psram_cal3.sv`, `psram_dps.sv`), de teiram (Amstrad_MiSTer_ch96);
  el ventilador y las opciones por defecto, de su `Template_MiSTer_ch96`.
* `psram_chip_ctrl`, `psram_dual`, `psram_afifo`, los scripts y el banco de
  pruebas de este port: GPL-3.0 o posterior, como BigMig.
