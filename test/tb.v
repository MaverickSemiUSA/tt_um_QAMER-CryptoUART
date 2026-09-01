`default_nettype none
`timescale 1ns / 1ps

/*
 * Tiny Tapeout Cocotb testbench wrapper.
 *
 * The participant RTL in src/project.v is not modified.
 */

module tb ();

  // Dump the signals to an FST file.
  initial begin
    $dumpfile("tb.fst");
    $dumpvars(0, tb);
    #1;
  end

  // ------------------------------------------------------------
  // Tiny Tapeout interface
  // ------------------------------------------------------------

  reg clk;
  reg rst_n;
  reg ena;
  reg [7:0] ui_in;
  reg [7:0] uio_in;

  wire [7:0] uo_out;
  wire [7:0] uio_out;
  wire [7:0] uio_oe;

  // Scalar alias for UART TX.
  // Cocotb 2.x requires scalar LogicObject for FallingEdge().
  wire uart_txd;

  assign uart_txd = uo_out[0];

  // ------------------------------------------------------------
  // Participant design
  // ------------------------------------------------------------

  tt_um_crypto_led_demo user_project (
      .ui_in  (ui_in),
      .uo_out (uo_out),
      .uio_in (uio_in),
      .uio_out(uio_out),
      .uio_oe (uio_oe),
      .ena    (ena),
      .clk    (clk),
      .rst_n  (rst_n)
  );

endmodule

`default_nettype wire
