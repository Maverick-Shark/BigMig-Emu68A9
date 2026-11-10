#============================================================================
# HPS interface atoms of the MiSTer framework on the Chameleon96
#
# The MiSTer design instantiates raw Cyclone V HPS atoms; HPS_LOCATION puts
# the uart and i2c peripheral interfaces where the Chameleon96 preloader
# handoff has them (teiram, hps-ch96/hps.sopcinfo).
#
# BigMig keeps the MiSTer ALSA path (HPS SPI master atom), which the Amstrad
# ch96 port leaves out. The location below is the standard MiSTer one; if the
# board's preloader does not route SPIM to the FPGA the atom is simply idle
# (no ALSA audio). Define MISTER_DISABLE_ALSA to leave it out entirely.
#============================================================================

set_instance_assignment -name HPS_LOCATION HPSINTERFACEPERIPHERALUART_X52_Y67_N111 -entity sys_top -to uart
set_instance_assignment -name HPS_LOCATION HPSINTERFACEPERIPHERALI2C_X52_Y60_N111 -entity sys_top -to hdmi_i2c
set_instance_assignment -name HPS_LOCATION HPSINTERFACEPERIPHERALSPIMASTER_X52_Y72_N111 -entity sys_top -to spi
