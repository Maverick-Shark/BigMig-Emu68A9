#============================================================================
# HPS interface atoms of the MiSTer framework on the Chameleon96
#
# The MiSTer design instantiates raw Cyclone V HPS atoms; HPS_LOCATION puts
# the uart and i2c peripheral interfaces where the Chameleon96 preloader
# handoff has them (teiram, hps-ch96/hps.sopcinfo).
#
# The SPI master location is only used without MISTER_DISABLE_ALSA (the
# BigMig_ch96 default disables ALSA: the hps-ch96 preloader muxes both SPI
# masters to HPS pins). Quartus ignores it, with a warning, when the atom is absent.
#============================================================================

set_instance_assignment -name HPS_LOCATION HPSINTERFACEPERIPHERALUART_X52_Y67_N111 -entity sys_top -to uart
set_instance_assignment -name HPS_LOCATION HPSINTERFACEPERIPHERALI2C_X52_Y60_N111 -entity sys_top -to hdmi_i2c
set_instance_assignment -name HPS_LOCATION HPSINTERFACEPERIPHERALSPIMASTER_X52_Y72_N111 -entity sys_top -to spi
