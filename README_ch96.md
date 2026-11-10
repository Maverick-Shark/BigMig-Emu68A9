# BigMig-Emu68A9 en Chameleon96 — fase 1 (puntos 1 a 3)

Proyecto de Quartus Prime Lite **17.1** para la Chameleon96 (Cyclone V SE
**5CSEBA6U19I7**), con la chip RAM en el módulo PSRAM dual (2 × APS6404L) en
lugar de la SDRAM.

Este árbol es BigMig-Emu68A9 tal como está en
`3d5d4d19169fa88673bdd926d8d1fced5c9a2cd9` (release 20261019) más los cambios
de este port. Las piezas de la Chameleon96 (marco `sys/` de la placa, top
level, pines, PLL de la PSRAM, controlador QPI y calibración) vienen del port
del Amstrad de teiram, `Amstrad_MiSTer_ch96`, commit `6ca26b71b4a2`.

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
| 5 | mapa de DDR del firmware Emu68-A964 para 512 MB | la Chameleon96 tiene 512 MB de DDR3 y BigMig está hecho para 1 GB |
| 6 | Main_MiSTer / Linux de la Chameleon96 con soporte BigMig | sin él no se carga Emu68 en el núcleo ARM, y en el modo HYBRID_EMU no hay otra CPU |

Con el Main de teiram, el núcleo se carga como un núcleo genérico: verás el
menú del CONF_STR de BigMig, no el menú de Minimig.

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

## Qué cambia respecto a BigMig (DE10-Nano)

| fichero | cambio |
|---|---|
| `BigMig_ch96.qpf/.qsf/.sdc` | proyecto nuevo. Mismas opciones y macros que `BigMig.qsf`, más `MISTER_CHAMELEON96` y `BIGMIG_NO_RTG_ANALOG`. Un solo SDC que sustituye a `sys_top.sdc`, `BigMig.sdc`, `f0e_*.sdc`, `f1_gpu.sdc`, `seam.sdc` y `rtg_scanout.sdc`, con las rutas bajo `sys_top\|` |
| `ch96_top.sv` | top level de la placa (el de teiram), con la PSRAM y los LEDs en el bus loan I/O del HPS |
| `sys/sys_top.v`, `sys/sysmem.sv`, `sys/emu_ports.vh` | fusión a tres bandas sobre la base común de ambos forks (Template_MiSTer `f35083f3b4`), sin conflictos: lo de BigMig (seam AXI, GPU, RTG, ALSA en ddr_svc) más lo de la Chameleon96 (`clk_50m` desde `h2f_user1_clk`, puertos PSRAM, LEDs, scaler en `0x1E800000`). Además, la macro `BIGMIG_NO_RTG_ANALOG` deja fuera la salida RTG analógica nativa |
| `sys/sys.qip`, `sys/arcade_video.v`, `sys/pll_hdmi/pll_hdmi_0002.v`, `sys/pll_q22.qip`, `sys/pins_ch96.tcl` | los de la Chameleon96 de teiram, sin cambios |
| `sys/hps_ch96.tcl` | el de teiram más la ubicación del SPI del HPS (ALSA de BigMig) |
| `BigMig.sv` | todo bajo `ifdef MISTER_CHAMELEON96`: PLL de la PSRAM, `psram_chip_ctrl` como `ram1`, SDRAM aparcada, reset retenido hasta que la PSRAM está calibrada, y estado de la calibración en los LEDs |
| `rtl/pll_psram*` | la PLL de la PSRAM del Amstrad (VCO 640 MHz, 128 MHz más captura con desplazamiento de fase dinámico en C2), renombrada y sin metadatos de IP, para que la acepte Quartus 17 |
| `rtl/psram/` | el controlador de chip RAM (ver abajo) |

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

## Comprobación sin Quartus

Este árbol se ha comprobado sin Quartus, así:

* `tools_ch96/lint_tree.py` lee el `.qsf`, incluidos los `.qip`. Sustituye por
  cajas negras las primitivas de Altera, los átomos del HPS y las tres
  entidades VHDL, y elabora el diseño entero desde `ch96_top` con Verilator.
* Sale **sin errores** con:
  * la configuración del `.qsf`;
  * sin `BIGMIG_NO_RTG_ANALOG`;
  * sin GPU;
  * sin GPU y con la salida RTG analógica;
  * con `MISTER_DISABLE_ALSA`.

Esto no sustituye a Quartus: no cubre el VHDL, ni el ajuste, ni los tiempos, ni
lo que Quartus 17 pueda aceptar de forma distinta. Si Quartus da un error,
pásamelo tal cual.

## Opciones

* `BIGMIG_NO_RTG_ANALOG`: activada. Esta placa no tiene salida analógica; el
  RTG se ve por HDMI, a través del scaler.
* `MISTER_DISABLE_ALSA`: desactivada. BigMig usa ALSA. Si el preloader de la
  Chameleon96 no lleva el SPI del HPS a la FPGA, el átomo se queda quieto y no
  hay audio ALSA. Si diera problemas al compilar, descomenta la línea en el
  `.qsf`.
* `BIGMIG_NO_CHIP_WRITE_RETRY`: activada, igual que en la DE10-Nano.

## Créditos y licencias

* BigMig-Emu68A9 (Ruben Aparicio), Minimig-AGA para MiSTer (Alexey Melnikov y
  sus autores), Template_MiSTer: GPL, según cada fichero.
* Port a la Chameleon96: `ch96_top`, marco `sys/`, PLL y controlador PSRAM v3
  (`psram.sv`, `psram_cal3.sv`, `psram_dps.sv`), de teiram (Amstrad_MiSTer_ch96).
* `psram_chip_ctrl`, `psram_dual`, `psram_afifo`, los scripts y el banco de
  pruebas de este port: GPL-3.0 o posterior, como BigMig.
