`default_nettype none
`timescale 1ns / 1ps

/*
 * Tiny Tapeout Cocotb testbench wrapper.
 *
 * This testbench instantiates the participant's top-level module and
 * provides convenient signals for the Cocotb test.py.
 *
 * The participant RTL in src/project.v is not modified.
 */

module tb ();

  // Dump the signals to an FST file.
  // You can view the waveform with GTKWave or Surfer.
  initial begin
    $dumpfile("tb.fst");
    $dumpvars(0, tb);
    #1;
  end

  // Wire up the inputs and outputs:
  reg clk;
  reg rst_n;
  reg ena;
  reg [7:0] ui_in;
  reg [7:0] uio_in;
  wire [7:0] uo_out;
  wire [7:0] uio_out;
  wire [7:0] uio_oe;

  // Instantiate the participant's Tiny Tapeout top module.
  tt_um_crypto_led_demo user_project (
      .ui_in  (ui_in),       // Dedicated inputs
      .uo_out (uo_out),      // Dedicated outputs
      .uio_in (uio_in),      // IOs: Input path
      .uio_out(uio_out),     // IOs: Output path
      .uio_oe (uio_oe),      // IOs: Enable path
      .ena    (ena),         // Enable
      .clk    (clk),         // Clock
      .rst_n  (rst_n)        // Active-low reset
  );

endmodule

`default_nettype wire
