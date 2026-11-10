#!/bin/bash
# Build and run tb_chip_ctrl (Icarus Verilog 11+) with one set of -D knobs.
#   run_tb.sh <tag> [-DKNOB=value ...]        e.g.  run_tb.sh rd16 -DRDSIZE=0
# Knobs: see the `ifndef list at the top of tb_chip_ctrl.sv (delays, clock, sizes, load).
# Works from the project tree (sim_ch96/) or from a work area with rtl/ next to sim/.
set -u
S=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$S/.." && pwd)
if [ -d "$R/rtl/psram" ]; then
    P="$R/rtl/psram"; B="$R/rtl"                     # inside the BigMig_ch96 tree
else
    P="$R/rtl"; B=${BIGMIG:-/root/BigMig-Emu68A9}/rtl # work area + a BigMig checkout
fi
tag=$1; shift
mkdir -p "$S/out"
iverilog -g2012 "$@" -o "$S/out/$tag.vvp" -s tb_chip_ctrl \
    "$S/tb_chip_ctrl.sv" "$S/tb_models.sv" "$S/aps6404l_model_fix.sv" "$S/dpram_sim.v" \
    "$P/psram_chip_ctrl.sv" "$P/psram_afifo.sv" "$P/psram_dual.sv" "$P/psram_n.sv" \
    "$P/psram_cal3.sv" "$P/psram_dps.sv" \
    "$B/cpu_cache_new.v" "$B/amiga_clk.v" || exit 1
vvp -n "$S/out/$tag.vvp" > "$S/out/$tag.log" 2>&1
echo "$tag: $(grep -h '^RESULT\|^PINS\|TB PASS\|TB FAIL\|TIMEOUT' "$S/out/$tag.log" | tr '\n' ' ')"
