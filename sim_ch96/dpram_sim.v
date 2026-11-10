`timescale 1ns/1ps
// Simulation stand-in for BigMig's rtl/bram.vhd "dpram" (altsyncram, true dual
// port, registered address, unregistered output, power-up zero). Only used by
// the testbenches; Quartus compiles the VHDL original.
module dpram #(
    parameter integer addr_width = 8,
    parameter integer data_width = 8,
    parameter         mem_init_file = " "
) (
    input                       clock,
    input      [addr_width-1:0] address_a,
    input      [data_width-1:0] data_a,
    input                       enable_a,
    input                       wren_a,
    output     [data_width-1:0] q_a,
    input                       cs_a,
    input      [addr_width-1:0] address_b,
    input      [data_width-1:0] data_b,
    input                       enable_b,
    input                       wren_b,
    output     [data_width-1:0] q_b,
    input                       cs_b
);
    reg [data_width-1:0] mem [0:(1<<addr_width)-1];
    reg [addr_width-1:0] ra = 0, rb = 0;
    integer i;
    initial for (i = 0; i < (1<<addr_width); i = i + 1) mem[i] = {data_width{1'b0}};
    wire ea = (enable_a === 1'bz) ? 1'b1 : enable_a;
    wire eb = (enable_b === 1'bz) ? 1'b1 : enable_b;
    wire ca = (cs_a === 1'bz) ? 1'b1 : cs_a;
    wire cb = (cs_b === 1'bz) ? 1'b1 : cs_b;
    always @(posedge clock) begin
        if (ea) begin
            if (wren_a & ca) mem[address_a] <= data_a;
            ra <= address_a;
        end
        if (eb) begin
            if (wren_b & cb) mem[address_b] <= data_b;
            rb <= address_b;
        end
    end
    assign q_a = ca ? mem[ra] : {data_width{1'b1}};
    assign q_b = cb ? mem[rb] : {data_width{1'b1}};
endmodule
