#!/bin/bash
# Build the BigMig_ch96 project tree from:
#   BIGMIG   BigMig-Emu68A9 checkout (upstream core, DE10-Nano)
#   AMSTRAD  Amstrad_MiSTer_ch96 checkout (teiram: Chameleon96 framework + PSRAM IP)
#   MERGE    the three-way merged sys_top.v / sysmem.sv / emu_ports.vh
#            (BigMig sys + Chameleon96 sys over Template_MiSTer f35083f3b4)
#   CH96     this port's own files (rtl/psram, new/, tools/, sim/, README)
set -euo pipefail
BIGMIG=${BIGMIG:-/root/BigMig-Emu68A9}
AMSTRAD=${AMSTRAD:-/root/Amstrad_MiSTer_ch96}
SCR=${SCR:-/tmp/claude-0/-home-claude/c79022ff-d811-51fd-b2cf-511d0f90a312/scratchpad}
MERGE=${MERGE:-$SCR/merge}
CH96=${CH96:-$SCR/ch96}
OUT=${1:-$CH96/out/BigMig_ch96}

rm -rf "$OUT"
mkdir -p "$OUT"

# 1. upstream BigMig, as committed
(cd "$BIGMIG" && git archive HEAD) | tar -x -C "$OUT"
# the DE10-Nano project files do not apply to this tree (its sys/ is the Chameleon96 one)
rm -f "$OUT/BigMig.qpf" "$OUT/BigMig.qsf" "$OUT/jtag.cdf"

# 2. framework: merged files + Chameleon96 files
python3 "$CH96/tools/patch_sys_top.py" "$MERGE/merged_sys_top.v" "$OUT/sys/sys_top.v"
cp "$MERGE/merged_sysmem.sv"    "$OUT/sys/sysmem.sv"
cp "$MERGE/merged_emu_ports.vh" "$OUT/sys/emu_ports.vh"
for f in sys.qip arcade_video.v pll_q22.qip pll_hdmi/pll_hdmi_0002.v; do
    cp "$AMSTRAD/sys/$f" "$OUT/sys/$f"
done
cp "$CH96/new/sys/pins_ch96.tcl" "$CH96/new/sys/hps_ch96.tcl" "$OUT/sys/"

# 3. project, top level, PSRAM PLL, chip RAM controller
cp "$CH96/new/BigMig_ch96.qpf" "$CH96/new/BigMig_ch96.qsf" "$CH96/new/BigMig_ch96.sdc" \
   "$CH96/new/ch96_top.sv" "$OUT/"
mkdir -p "$OUT/rtl/pll_psram" "$OUT/rtl/psram"
cp "$CH96/new/rtl/pll_psram.v" "$CH96/new/rtl/pll_psram.qip" "$OUT/rtl/"
cp "$CH96/new/rtl/pll_psram/pll_psram_0002.v" "$OUT/rtl/pll_psram/"
cp "$CH96/rtl/psram_chip_ctrl.sv" "$CH96/rtl/psram_afifo.sv" "$CH96/rtl/psram_dual.sv" \
   "$CH96/rtl/psram_n.sv" "$CH96/rtl/psram_cal3.sv" "$CH96/rtl/psram_dps.sv" "$OUT/rtl/psram/"

# 4. BigMig.sv
python3 "$CH96/tools/patch_bigmig_sv.py" "$OUT/BigMig.sv" "$OUT/BigMig.sv"

# 5. simulation, tools, notes
mkdir -p "$OUT/sim_ch96" "$OUT/tools_ch96"
cp "$CH96/sim/tb_chip_ctrl.sv" "$CH96/sim/tb_models.sv" "$CH96/sim/aps6404l_model_fix.sv" \
   "$CH96/sim/dpram_sim.v" "$CH96/sim/run_tb.sh" "$OUT/sim_ch96/"
cp "$CH96/tools/patch_bigmig_sv.py" "$CH96/tools/patch_sys_top.py" "$CH96/tools/make_tree.sh" \
   "$CH96/tools/mk_psram_n.py" "$CH96/tools/lint_tree.py" "$OUT/tools_ch96/"
[ -f "$CH96/new/README_ch96.md" ] && cp "$CH96/new/README_ch96.md" "$OUT/"
echo "tree: $OUT"

# 6. review diff against upstream BigMig (files that exist in both; CR/LF ignored)
(cd "$OUT/.." && diff -ruN --strip-trailing-cr \
    -x .git -x sim_ch96 -x tools_ch96 -x README_ch96.md -x 'BigMig_ch96.*' -x ch96_top.sv \
    -x psram -x pll_psram -x pll_psram.v -x pll_psram.qip -x hps_ch96.tcl -x pins_ch96.tcl -x pll_q22.qip \
    -x BigMig.qpf -x BigMig.qsf -x jtag.cdf \
    "$BIGMIG" "$(basename "$OUT")" | sed "s#$BIGMIG#a#g" > "$OUT/tools_ch96/bigmig_20261019_vs_ch96.diff") || true
echo "diff: $OUT/tools_ch96/bigmig_20261019_vs_ch96.diff ($(wc -l < "$OUT/tools_ch96/bigmig_20261019_vs_ch96.diff") lines)"
