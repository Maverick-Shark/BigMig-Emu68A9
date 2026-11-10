#============================================================================
# Chameleon96 FPGA pin assignments.
# LCD/I2S/I2C are 1.8V; the RF LEDs (Y19/Y20) sit on the 2.5V bank and use
# the bank default IO standard (mirrors hps-ch96 reference design).
#============================================================================

set_location_assignment PIN_AA6  -to LCD_R[4]
set_location_assignment PIN_AA7  -to LCD_R[3]
set_location_assignment PIN_AB7  -to LCD_R[2]
set_location_assignment PIN_Y5   -to LCD_R[1]
set_location_assignment PIN_W6   -to LCD_R[0]
set_location_assignment PIN_Y11  -to LCD_G[5]
set_location_assignment PIN_AB9  -to LCD_G[4]
set_location_assignment PIN_AB8  -to LCD_G[3]
set_location_assignment PIN_AA8  -to LCD_G[2]
set_location_assignment PIN_AA5  -to LCD_G[1]
set_location_assignment PIN_AB5  -to LCD_G[0]
set_location_assignment PIN_U6   -to LCD_B[4]
set_location_assignment PIN_V5   -to LCD_B[3]
set_location_assignment PIN_V6   -to LCD_B[2]
set_location_assignment PIN_W7   -to LCD_B[1]
set_location_assignment PIN_W8   -to LCD_B[0]

set_location_assignment PIN_Y8   -to LCD_DE
set_location_assignment PIN_V10  -to LCD_HSYNC
set_location_assignment PIN_V7   -to LCD_VSYNC
set_location_assignment PIN_AB10 -to LCD_PIXEL_CLK

set_location_assignment PIN_V11  -to I2S_MCLK
set_location_assignment PIN_W11  -to I2S_TXC
set_location_assignment PIN_AA11 -to I2S_TXD
set_location_assignment PIN_V9   -to I2S_TXFS

set_location_assignment PIN_U7   -to I2C2_SCL
set_location_assignment PIN_U10  -to I2C2_SDA

set_location_assignment PIN_Y19  -to LED_YELLOW
set_location_assignment PIN_Y20  -to LED_BLUE

set_instance_assignment -name IO_STANDARD "1.8 V" -to LCD_R[*]
set_instance_assignment -name IO_STANDARD "1.8 V" -to LCD_G[*]
set_instance_assignment -name IO_STANDARD "1.8 V" -to LCD_B[*]
set_instance_assignment -name IO_STANDARD "1.8 V" -to LCD_DE
set_instance_assignment -name IO_STANDARD "1.8 V" -to LCD_HSYNC
set_instance_assignment -name IO_STANDARD "1.8 V" -to LCD_VSYNC
set_instance_assignment -name IO_STANDARD "1.8 V" -to LCD_PIXEL_CLK
set_instance_assignment -name IO_STANDARD "1.8 V" -to I2S_MCLK
set_instance_assignment -name IO_STANDARD "1.8 V" -to I2S_TXC
set_instance_assignment -name IO_STANDARD "1.8 V" -to I2S_TXD
set_instance_assignment -name IO_STANDARD "1.8 V" -to I2S_TXFS
set_instance_assignment -name IO_STANDARD "1.8 V" -to I2C2_SCL
set_instance_assignment -name IO_STANDARD "1.8 V" -to I2C2_SDA

set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to I2C2_SCL
set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to I2C2_SDA

set_instance_assignment -name FAST_OUTPUT_REGISTER ON -to LCD_PIXEL_CLK
set_instance_assignment -name FAST_OUTPUT_REGISTER ON -to LCD_R[*]
set_instance_assignment -name FAST_OUTPUT_REGISTER ON -to LCD_G[*]
set_instance_assignment -name FAST_OUTPUT_REGISTER ON -to LCD_B[*]
set_instance_assignment -name FAST_OUTPUT_REGISTER ON -to LCD_DE
set_instance_assignment -name FAST_OUTPUT_REGISTER ON -to LCD_HSYNC
set_instance_assignment -name FAST_OUTPUT_REGISTER ON -to LCD_VSYNC
