#============================================================================
# BigMig-Emu68A9 on Chameleon96 -- timing constraints (Quartus 17.1)
#
# Replaces sys/sys_top.sdc (taken out of sys/sys.qip for this board) and the
# DE10-Nano project's BigMig.sdc, f0e_*.sdc, f1_gpu.sdc, sys/seam.sdc and
# sys/rtg_scanout.sdc. The top level is ch96_top, so every register path of
# the framework starts with "sys_top|".
#============================================================================

#---------------------------------------------------------------- root clocks
# No FPGA oscillator on this board: the 50 MHz reference is the HPS
# h2f_user1_clk (sys_top's clk_50m output).
create_clock -period "50.0 MHz"  [get_pins -compatibility_mode *|h2f_user1_clk] -name h2f_user1_clk
create_clock -period "100.0 MHz" [get_pins -compatibility_mode *|h2f_user0_clk]
create_clock -period "10.0 MHz"  [get_pins -compatibility_mode *|hdmi_i2c|out_clk] -name hdmi_sck
# ALSA (HPS SPI master atom); harmless when MISTER_DISABLE_ALSA leaves the atom out
create_clock -period "100.0 MHz" [get_pins -compatibility_mode -nowarn *|spi|sclk_out] -name spi_sck

derive_pll_clocks
derive_clock_uncertainty

#---------------------------------------------------------------- clock groups
# emu|pll       : clk_114 / clk_sys (chipset, chip RAM front end)
# pll_hdmi      : video out, pll_audio: audio
# gpu_pll       : BigMig GPU
# pll_psram     : PSRAM controller (C1), capture clock (C2), 64 MHz aux (C0)
# Everything crossing between these groups goes through synchronisers.
# (groups are only listed when their clocks exist, e.g. no spi_sck without ALSA)
set ch96_groups {}
foreach ch96_pat [list \
    {*|pll|pll_inst|altera_pll_i|*[*].*|divclk} \
    {*|pll_hdmi|pll_hdmi_inst|altera_pll_i|*[*].*|divclk} \
    {*|pll_audio|pll_audio_inst|altera_pll_i|*[*].*|divclk} \
    {*|pll_psram|pll_inst|altera_pll_i|*[*].*|divclk} \
    {*|gpu_pll|altera_pll_i|*[*].*|divclk} \
    {spi_sck} \
    {hdmi_sck} \
    {*|h2f_user0_clk} \
    {h2f_user1_clk} ] {
  set ch96_c [get_clocks -nowarn $ch96_pat]
  if { [get_collection_size $ch96_c] > 0 } { lappend ch96_groups -group $ch96_c }
}
set_clock_groups -exclusive {*}$ch96_groups

#---------------------------------------------------------------- PSRAM
# teiram's v3 capture scheme: the read capture clock (pll_psram C2) is moved
# by the dynamic phase shift during calibration, so TimeQuest cannot judge the
# capture -> clk_ram retiming. The capture window is built with >= 0.3 T setup
# and >= 0.15 T hold margin and psram_cal3 verifies it on both chips at boot.
set psram_cap [get_clocks -nowarn {*|pll_psram|pll_inst|altera_pll_i|*[2].*|divclk}]
if { [get_collection_size $psram_cap] > 0 } {
  set_false_path -from $psram_cap
  set_false_path -to   $psram_cap
}

# chip RAM queue crossings (psram_afifo): gray pointers through two flops, and
# keep the queue storage and the pointers close to their readers so the data
# has settled long before the synchronised pointer says it is there.
set_net_delay -max 2.5 -from [get_registers -nowarn {*|ram1|u_req_q|wgray[*] *|ram1|u_req_q|rgray[*] *|ram1|u_rsp_q|wgray[*] *|ram1|u_rsp_q|rgray[*]}] \
                       -to   [get_registers -nowarn {*|ram1|u_req_q|*|wg_r1[*] *|ram1|u_req_q|*|rg_w1[*] *|ram1|u_rsp_q|*|wg_r1[*] *|ram1|u_rsp_q|*|rg_w1[*]}]
set_net_delay -max 3.0 -from [get_registers -nowarn {*|ram1|u_req_q|mem* *|ram1|u_rsp_q|mem*}]
# calibration status / queue resets into the chipset clock (quasi-static)
set_false_path -to [get_registers -nowarn {*|ram1|cd_s[0] *|ram1|cf_s[0] *|ram1|cc_s1[*]}]
set_false_path -to [get_registers -nowarn {*|ram1|qr_s[*] *|ram1|qr_r[*] *|ram1|ini_r[*]}]
# PSRAM PLL alive divider -> LED logic
set_false_path -to [get_registers -nowarn {*|emu|ram_aux_s[0]}]

#---------------------------------------------------------------- BigMig core (was BigMig.sdc)
set_multicycle_path -from {sys_top|emu|amiga_clk|cck*} -to {sys_top|emu|ram1|*} -setup 2
set_multicycle_path -from {sys_top|emu|amiga_clk|cck*} -to {sys_top|emu|ram1|*} -hold 1
set_multicycle_path -from {sys_top|emu|minimig|*} -to {sys_top|emu|ram1|*} -setup 2
set_multicycle_path -from {sys_top|emu|minimig|*} -to {sys_top|emu|ram1|*} -hold 1

if {[get_collection_size [get_registers -nowarn {sys_top|emu|u_chip_write_retry|*}]] > 0} {
set_multicycle_path -from {sys_top|emu|amiga_clk|cck*} -to {sys_top|emu|u_chip_write_retry|*} -setup 2
set_multicycle_path -from {sys_top|emu|amiga_clk|cck*} -to {sys_top|emu|u_chip_write_retry|*} -hold 1
set_multicycle_path -from {sys_top|emu|minimig|*}      -to {sys_top|emu|u_chip_write_retry|*} -setup 2
set_multicycle_path -from {sys_top|emu|minimig|*}      -to {sys_top|emu|u_chip_write_retry|*} -hold 1
}

set_multicycle_path -from {sys_top|emu|ram1|*} -to {sys_top|emu|u_hybrid_bridge|*} -setup 2
set_multicycle_path -from {sys_top|emu|ram1|*} -to {sys_top|emu|u_hybrid_bridge|*} -hold 1
set_false_path -from {sys_top|emu|u_hybrid_bridge|cp_*} -to {sys_top|emu|ram1|*}

set_false_path -from {sys_top|emu|minimig|USERIO1|cpu_config*}
set_false_path -from {sys_top|emu|minimig|USERIO1|ide_config*}
set_false_path -from {sys_top|emu|minimig|USERIO1|bootrom}
set_false_path -from {sys_top|emu|minimig|CPU1|halt}

if {[get_collection_size [get_registers -nowarn {*Hq2x*}]] > 0} {
set_multicycle_path -to {*Hq2x*} -setup 2
set_multicycle_path -to {*Hq2x*} -hold 1
}

set_multicycle_path -from [get_clocks { *|pll|pll_inst|altera_pll_i|*[0].*|divclk}] -to {sys_top|ascal|*} -setup 2
set_multicycle_path -from [get_clocks { *|pll|pll_inst|altera_pll_i|*[0].*|divclk}] -to {sys_top|ascal|*} -hold 1

#---------------------------------------------------------------- BigMig (was f0e_cdc / f0e_l1e / f0e_ovc)
set f0e_c1 [get_clocks {sys_top|emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[1].output_counter|divclk}]
set_multicycle_path -hold -end 1 -from $f0e_c1 \
    -to [get_registers {sys_top|emu|video_mixer|gamma|R_in[*] sys_top|emu|video_mixer|gamma|G_in[*] sys_top|emu|video_mixer|gamma|B_in[*] sys_top|emu|video_mixer|gamma|gamma_index[*]}]
set_false_path -from [get_registers {*_osd|infoh[*]}] -to [get_registers {*_osd|osd_hcnt2[*]}]
set_false_path -to [get_registers {*u_rtg_hdmi_osd_sprite|hmin_s[*] *u_rtg_hdmi_osd_sprite|hmax_s[*] *u_rtg_hdmi_osd_sprite|vmin_s[*] *u_rtg_hdmi_osd_sprite|vmax_s[*]}]
if { [string equal "quartus_fit" $::TimeQuestInfo(nameofexecutable)] } {
  set f0e_hdmi [get_clocks {sys_top|pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]
  set_clock_uncertainty -setup -add -from $f0e_hdmi -to $f0e_hdmi 0.8
}

#---------------------------------------------------------------- RTG HDMI mouse pointer (was sys/rtg_scanout.sdc)
set_false_path -to [get_registers -nowarn {*u_rtg_hdmi_osd_sprite|*_a}]
set_false_path -to [get_registers -nowarn {*u_rtg_hdmi_osd_sprite|*_a[*]}]
set_false_path -to [get_registers -nowarn {*u_rtg_hdmi_osd_sprite|*_m}]
set_false_path -to [get_registers -nowarn {*u_rtg_hdmi_osd_sprite|*_m[*]}]
set_multicycle_path -setup -to [get_registers -nowarn {*u_rtg_hdmi_osd_sprite|p_*}] 2
set_multicycle_path -hold  -to [get_registers -nowarn {*u_rtg_hdmi_osd_sprite|p_*}] 1

#---------------------------------------------------------------- GPU (was f1_gpu.sdc)
set f1_gpu_clk [get_clocks -nowarn {sys_top|gpu_pll|altera_pll_i|*[0].*|divclk}]
if { [get_collection_size $f1_gpu_clk] > 0 } {
  set_net_delay -max 1.5  -from [get_registers {sys_top|u_gpu|regs|req_t}]   -to [get_registers {sys_top|u_gpu|regs|req_s[0]}]
  set_net_delay -max 1.5  -from [get_registers {sys_top|u_gpu|regs|ack_t}]   -to [get_registers {sys_top|u_gpu|regs|ack_s[0]}]
  set_net_delay -max 1.5  -from [get_registers {sys_top|u_gpu|regs|g_alive}] -to [get_registers {sys_top|u_gpu|regs|alive_s[0]}]
  set_net_delay -max 10.0 -from [get_registers {sys_top|u_gpu|regs|a_h[*] sys_top|u_gpu|regs|d_h[*] sys_top|u_gpu|regs|rd_h}] \
                          -to   [get_registers {sys_top|u_gpu|regs|ga[*] sys_top|u_gpu|regs|dg[*] sys_top|u_gpu|regs|wg}]
  set_net_delay -max 10.0 -from [get_registers {sys_top|u_gpu|regs|rd_g[*]}] -to [get_registers {sys_top|u_gpu|regs|rdata[*]}]
  if { [string equal "quartus_fit" $::TimeQuestInfo(nameofexecutable)] } {
    set f1_c0 [get_clocks {sys_top|emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]
    set_clock_uncertainty -setup -add -from $f1_c0 -to $f1_c0 0.6
  }
}

#---------------------------------------------------------------- Emu68 seam (was sys/seam.sdc + f0e_seam.sdc)
set AXI_PERIOD  10.0
set SYNC_PERIOD 35.0

set_false_path -from [get_registers {sys_top|emu|u_axi_seam_slave|u_seam_engine|req_tgl}] \
               -to   [get_registers {sys_top|emu|u_axi_seam_slave|u_seam_engine|req_sync[0]}]
set_false_path -from [get_registers {sys_top|emu|u_axi_seam_slave|u_seam_engine|done_tgl_sync}] \
               -to   [get_registers {sys_top|emu|u_axi_seam_slave|u_seam_engine|done_sync[0]}]
set_max_delay -from [get_registers {sys_top|emu|u_axi_seam_slave|u_seam_engine|live_addr[*] \
                                    sys_top|emu|u_axi_seam_slave|u_seam_engine|live_wdata[*] \
                                    sys_top|emu|u_axi_seam_slave|u_seam_engine|live_ctrl[*]}] \
              -to   [get_clocks {*|pll|pll_inst|altera_pll_i|*[*].*|divclk}] $AXI_PERIOD
set_max_delay -from [get_registers {sys_top|emu|u_axi_seam_slave|u_seam_engine|readdata_sync[*] \
                                    sys_top|emu|u_axi_seam_slave|u_seam_engine|readdata_hi_s[*]}] \
              -to   [get_clocks {*|h2f_user0_clk}] $AXI_PERIOD
set_false_path -from [get_registers {sys_top|emu|u_hybrid_bridge|cerr}] \
               -to   [get_registers {sys_top|emu|u_axi_seam_slave|cerr_sync[0]}]
set_false_path -from [get_registers {sys_top|emu|u_axi_seam_slave|srst_lvl}] \
               -to   [get_registers {sys_top|emu|u_hybrid_bridge|srst_sync[0] \
                                     sys_top|emu|u_axi_seam_slave|u_seam_engine|srst_sync[0] \
                                     sys_top|emu|u_axi_seam_slave|crst_sync[0]}]
set_max_delay -from [get_registers {sys_top|emu|u_axi_seam_slave|u_seam_ipl|ipl_src[*]}] \
              -to   [get_clocks {*|h2f_user0_clk}] $AXI_PERIOD
set_false_path -from [get_registers {sys_top|emu|u_axi_seam_slave|u_seam_ipl|rst_src}] \
               -to   [get_registers {sys_top|emu|u_axi_seam_slave|u_seam_ipl|rst_m1}]
set_net_delay -max $AXI_PERIOD  -from [get_registers {sys_top|emu|u_axi_seam_slave|u_seam_engine|live_addr[*] sys_top|emu|u_axi_seam_slave|u_seam_engine|live_wdata[*] sys_top|emu|u_axi_seam_slave|u_seam_engine|live_ctrl[*]}] -to [get_registers {sys_top|emu|u_hybrid_bridge|*}]
set_net_delay -max $AXI_PERIOD  -from [get_registers {sys_top|emu|u_axi_seam_slave|u_seam_engine|live_ctrl[*]}] -to [get_registers {sys_top|emu|u_axi_seam_slave|u_seam_engine|sstate* sys_top|emu|u_axi_seam_slave|u_seam_engine|word_sel* sys_top|emu|u_axi_seam_slave|u_seam_engine|readdata_hi_s[*] sys_top|emu|u_axi_seam_slave|u_seam_engine|hreq*}]
set_net_delay -max $AXI_PERIOD  -from [get_registers {sys_top|emu|u_axi_seam_slave|u_seam_engine|readdata_sync[*] sys_top|emu|u_axi_seam_slave|u_seam_engine|readdata_hi_s[*]}] -to [get_registers {sys_top|emu|u_axi_seam_slave|u_seam_engine|rdata_axi[*] sys_top|emu|u_axi_seam_slave|u_seam_engine|rdata_hi_axi[*]}]
set_net_delay -max $AXI_PERIOD  -from [get_registers {sys_top|emu|u_axi_seam_slave|u_seam_ipl|ipl_src[*]}] -to [get_registers {sys_top|emu|u_axi_seam_slave|u_seam_ipl|ipl_m1[*]}]
set_net_delay -max 1.5 -from [get_registers {sys_top|emu|u_axi_seam_slave|u_seam_engine|req_tgl}] \
                       -to   [get_registers {sys_top|emu|u_axi_seam_slave|u_seam_engine|req_sync[0]}]
set_net_delay -max 1.5 -from [get_registers {sys_top|emu|u_axi_seam_slave|u_seam_engine|done_tgl_sync}] \
                       -to   [get_registers {sys_top|emu|u_axi_seam_slave|u_seam_engine|done_sync[0]}]

#---------------------------------------------------------------- MiSTer framework (was sys/sys_top.sdc)
set_false_path -to   [get_ports -nowarn {LED_*}]

set_false_path -to   {sys_top|cfg[*]}
set_false_path -from {sys_top|cfg[*]}
set_false_path -from {sys_top|VSET[*]}
set_false_path -to   {sys_top|wcalc[*] sys_top|hcalc[*]}
set_false_path -to   {sys_top|hdmi_width[*] sys_top|hdmi_height[*]}
set_false_path -to   {sys_top|deb_* sys_top|btn_en sys_top|btn_up}

set_multicycle_path -to {*_osd|osd_vcnt*} -setup 2
set_multicycle_path -to {*_osd|osd_vcnt*} -hold 1

set_false_path -to   {*_osd|v_cnt*}
set_false_path -to   {*_osd|v_osd_start*}
set_false_path -to   {*_osd|v_info_start*}
set_false_path -to   {*_osd|h_osd_start*}
set_false_path -from {*_osd|v_osd_start*}
set_false_path -from {*_osd|v_info_start*}
set_false_path -from {*_osd|h_osd_start*}
set_false_path -from {*_osd|rot*}
set_false_path -from {*_osd|dsp_width*}
set_false_path -to   {*_osd|half}

set_false_path -to   {sys_top|WIDTH[*] sys_top|HFP[*] sys_top|HS[*] sys_top|HBP[*] sys_top|HEIGHT[*] sys_top|VFP[*] sys_top|VS[*] sys_top|VBP[*]}
set_false_path -from {sys_top|WIDTH[*] sys_top|HFP[*] sys_top|HS[*] sys_top|HBP[*] sys_top|HEIGHT[*] sys_top|VFP[*] sys_top|VS[*] sys_top|VBP[*]}
set_false_path -to   {sys_top|FB_BASE[*] sys_top|FB_WIDTH[*] sys_top|FB_HEIGHT[*] sys_top|LFB_HMIN[*] sys_top|LFB_HMAX[*] sys_top|LFB_VMIN[*] sys_top|LFB_VMAX[*]}
set_false_path -from {sys_top|FB_BASE[*] sys_top|FB_WIDTH[*] sys_top|FB_HEIGHT[*] sys_top|LFB_HMIN[*] sys_top|LFB_HMAX[*] sys_top|LFB_VMIN[*] sys_top|LFB_VMAX[*]}
set_false_path -to   {sys_top|vol_att[*] sys_top|scaler_flt[*] sys_top|led_overtake[*] sys_top|led_state[*]}
set_false_path -from {sys_top|vol_att[*] sys_top|scaler_flt[*] sys_top|led_overtake[*] sys_top|led_state[*]}
set_false_path -from {sys_top|aflt_* sys_top|acx* sys_top|acy* sys_top|areset* sys_top|arc*}
set_false_path -from {sys_top|arx* sys_top|ary*}
set_false_path -from {sys_top|vs_line*}
set_false_path -from {sys_top|ColorBurst_Range* sys_top|PhaseInc* sys_top|pal_en sys_top|cvbs sys_top|yc_en}

set_false_path -from {sys_top|ascal|o_ihsize*}
set_false_path -from {sys_top|ascal|o_ivsize*}
set_false_path -from {sys_top|ascal|o_format*}
set_false_path -from {sys_top|ascal|o_hdown}
set_false_path -from {sys_top|ascal|o_vdown}
set_false_path -from {sys_top|ascal|o_hmin* sys_top|ascal|o_hmax* sys_top|ascal|o_vmin* sys_top|ascal|o_vmax* sys_top|ascal|o_vrrmax* sys_top|ascal|o_vrr}
set_false_path -from {sys_top|ascal|o_hdisp* sys_top|ascal|o_vdisp*}
set_false_path -from {sys_top|ascal|o_htotal* sys_top|ascal|o_vtotal*}
set_false_path -from {sys_top|ascal|o_hsstart* sys_top|ascal|o_vsstart* sys_top|ascal|o_hsend* sys_top|ascal|o_vsend*}
set_false_path -from {sys_top|ascal|o_hsize* sys_top|ascal|o_vsize*}

set_false_path -from {sys_top|mcp23009|flg_*}
set_false_path -to   {sys_top|sysmem|fpga_interfaces|clocks_resets|f2h*}
