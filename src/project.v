`default_nettype none

module tt_um_crypto_led_demo #(
    parameter CLK_FREQ_HZ = 50_000_000,
    parameter BAUD_RATE   = 9600
) (
    input  wire [7:0] ui_in,    // [0]=UART_RXD, [7:1]=KEY_SEED (sampled at reset)
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,   // unused
    output wire [7:0] uio_out,  // live ciphertext byte
    output wire [7:0] uio_oe,   // fixed: 8'hFF
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n     // async active-low
);

    wire uart_rxd_pin = ui_in[0];
    wire [6:0] key_seed = ui_in[7:1];

    // ---------------------------------------------------------------
    // UART RX
    // ---------------------------------------------------------------
    wire [7:0] rx_byte;   // holds the last received byte until the next one
    wire       rx_valid;
    wire       rx_frame_err;

    uart_rx #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ),
        .BAUD_RATE   (BAUD_RATE)
    ) u_uart_rx (
        .clk       (clk),
        .rst_n     (rst_n),
        .rxd       (uart_rxd_pin),
        .rx_data   (rx_byte),
        .rx_valid  (rx_valid),
        .frame_err (rx_frame_err)
    );

    // ---------------------------------------------------------------
    // UART TX (shared by both the plaintext echo and the ciphertext byte)
    // ---------------------------------------------------------------
    wire       tx_start;
    wire [7:0] tx_data;
    wire       tx_busy;
    wire       uart_txd;

    uart_tx #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ),
        .BAUD_RATE   (BAUD_RATE)
    ) u_uart_tx (
        .clk      (clk),
        .rst_n    (rst_n),
        .tx_start (tx_start),
        .tx_data  (tx_data),
        .tx_busy  (tx_busy),
        .txd      (uart_txd)
    );

    // ---------------------------------------------------------------
    // Keystream generator - one shift per character received
    // ---------------------------------------------------------------
    wire [7:0] keystream;

    lfsr8 u_lfsr (
        .clk       (clk),
        .rst_n     (rst_n),
        .seed      (key_seed),
        .advance   (rx_valid),
        .keystream (keystream)
    );

    // ---------------------------------------------------------------
    // Echo + encrypt sequencer (Moore FSM: tx_start/tx_data are pure
    // functions of `state`, so uart_tx always samples them the cycle
    // this FSM actually intends them, with no extra registration lag
    // that could race the tx_busy poll below).
    //
    //   S_IDLE        : wait for rx_valid; latch cipher byte + LEDs
    //   S_START_PLAIN : tx_start=1, tx_data=rx_byte (plaintext echo)
    //   S_WAIT_PLAIN  : wait for that frame to finish (tx_busy falls)
    //   S_START_CIPH  : tx_start=1, tx_data=cipher_reg
    //   S_WAIT_CIPH   : wait for that frame to finish, then back to idle
    //
    // A character arriving while not in S_IDLE is not captured (no
    // input FIFO) - fine for interactive typing: a full double UART
    // frame is a couple of ms at 9600 baud, far faster than anyone types.
    // ---------------------------------------------------------------
    localparam S_IDLE        = 3'd0;
    localparam S_START_PLAIN = 3'd1;
    localparam S_WAIT_PLAIN  = 3'd2;
    localparam S_START_CIPH  = 3'd3;
    localparam S_WAIT_CIPH   = 3'd4;

    reg [2:0] state;
    reg [7:0] cipher_reg;
    reg       cipher_valid;   // 1-cycle strobe: cipher_reg / uio_out just went live

    // LED activity: accumulates bit-by-bit across a group of 4 characters,
    // ending with all four on together, then restarts on the next group.
    reg [1:0] char_cnt;
    reg [3:0] led_reg;

    assign tx_start = (state == S_START_PLAIN) || (state == S_START_CIPH);
    assign tx_data  = (state == S_START_PLAIN) ? rx_byte : cipher_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            cipher_reg   <= 8'h00;
            cipher_valid <= 1'b0;
            char_cnt     <= 2'd0;
            led_reg      <= 4'b0000;
        end else begin
            cipher_valid <= 1'b0;   // default: 1-cycle pulse

            case (state)

                S_IDLE: begin
                    if (rx_valid) begin
                        cipher_reg <= rx_byte ^ keystream;

                        // LED build-up: fresh group starts at char_cnt==0,
                        // otherwise accumulate the next bit; wraps 0..3.
                        if (char_cnt == 2'd0)
                            led_reg <= 4'b0001;
                        else
                            led_reg <= led_reg | (4'b0001 << char_cnt);
                        char_cnt <= char_cnt + 1'b1;

                        state <= S_START_PLAIN;
                    end
                end

                S_START_PLAIN: state <= S_WAIT_PLAIN;

                S_WAIT_PLAIN: begin
                    if (!tx_busy)
                        state <= S_START_CIPH;
                end

                S_START_CIPH: begin
                    cipher_valid <= 1'b1;   // uio_out is live starting now
                    state        <= S_WAIT_CIPH;
                end

                S_WAIT_CIPH: begin
                    if (!tx_busy)
                        state <= S_IDLE;
                end

                default: state <= S_IDLE;

            endcase
        end
    end

    // ---------------------------------------------------------------
    // Output mapping
    // ---------------------------------------------------------------
    assign uo_out[0] = ena ? uart_txd     : 1'b1;
    assign uo_out[1] = ena ? led_reg[0]   : 1'b0;
    assign uo_out[2] = ena ? led_reg[1]   : 1'b0;
    assign uo_out[3] = ena ? led_reg[2]   : 1'b0;
    assign uo_out[4] = ena ? led_reg[3]   : 1'b0;
    assign uo_out[5] = ena ? rx_valid     : 1'b0;   // RX strobe
    assign uo_out[6] = ena ? tx_busy      : 1'b0;
    assign uo_out[7] = ena ? cipher_valid : 1'b0;   // cipher-ready strobe

    assign uio_out = ena ? cipher_reg : 8'h00;      // live ciphertext byte
    assign uio_oe  = 8'hFF;                         // fixed direction, always driving

    wire _unused = &{uio_in, rx_frame_err, 1'b0};

endmodule


// ============================================================================
// UART RX
// ============================================================================

module uart_rx #(
    parameter CLK_FREQ_HZ = 50_000_000,
    parameter BAUD_RATE   = 9600
) (
    input  wire       clk,
    input  wire       rst_n,   // async active-low reset

    input  wire       rxd,

    output reg  [7:0] rx_data,
    output reg         rx_valid,  // 1-cycle pulse: new byte captured
    output reg         frame_err  // 1-cycle pulse, coincides with rx_valid
);

    localparam integer CLKS_PER_BIT = CLK_FREQ_HZ / BAUD_RATE;
    localparam integer CNT_WIDTH    = $clog2(CLKS_PER_BIT + 1);
    localparam integer HALF_BIT     = CLKS_PER_BIT / 2;

    reg rxd_meta, rxd_sync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset to 0, not the true idle-high (1) level: this PDK's
            // std-cell library only provides an async-reset-to-0 DFF
            // ($_DFF_PN0_) - no async-preset-to-1 cell exists, so resetting
            // these to 1 leaves them unmapped after synthesis. A one-cycle
            // low glitch here is harmless: the real rxd level (idle-high)
            // propagates through within 2-3 cycles, and if that transient
            // is briefly read as a false start bit, the half-bit confirm
            // check in the S_START state below rejects it and returns to
            // S_IDLE on its own.
            rxd_meta <= 1'b0;
            rxd_sync <= 1'b0;
        end else begin
            rxd_meta <= rxd;
            rxd_sync <= rxd_meta;
        end
    end

    localparam S_IDLE  = 2'b00;
    localparam S_START = 2'b01;
    localparam S_DATA  = 2'b10;
    localparam S_STOP  = 2'b11;

    reg [1:0]           state;
    reg [CNT_WIDTH-1:0] clk_cnt;
    reg [2:0]           bit_idx;
    reg [7:0]           shift;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            clk_cnt   <= 0;
            bit_idx   <= 3'b000;
            shift     <= 8'h00;
            rx_data   <= 8'h00;
            rx_valid  <= 1'b0;
            frame_err <= 1'b0;
        end else begin
            rx_valid  <= 1'b0;
            frame_err <= 1'b0;

            case (state)

                S_IDLE: begin
                    clk_cnt <= 0;
                    if (!rxd_sync)               // possible start bit
                        state <= S_START;
                end

                S_START: begin
                    if (clk_cnt == HALF_BIT[CNT_WIDTH-1:0]) begin
                        if (!rxd_sync) begin      // confirmed, now centered
                            clk_cnt <= 0;
                            bit_idx <= 3'b000;
                            state   <= S_DATA;
                        end else begin
                            state <= S_IDLE;      // glitch
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                S_DATA: begin
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt <= 0;
                        shift   <= {rxd_sync, shift[7:1]};
                        if (bit_idx == 3'd7)
                            state <= S_STOP;
                        else
                            bit_idx <= bit_idx + 1'b1;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                S_STOP: begin
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        rx_data   <= shift;
                        rx_valid  <= 1'b1;
                        frame_err <= ~rxd_sync;   // stop bit should be 1
                        state     <= S_IDLE;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                default: state <= S_IDLE;

            endcase
        end
    end

endmodule


// ============================================================================
// UART TX
// ============================================================================

module uart_tx #(
    parameter CLK_FREQ_HZ = 50_000_000,
    parameter BAUD_RATE   = 9600
) (
    input  wire       clk,
    input  wire       rst_n,     // async active-low

    input  wire       tx_start, // 1-cycle pulse: latch tx_data and go, ignored while tx_busy
    input  wire [7:0] tx_data,

    output reg        tx_busy,
    output reg        txd
);

    localparam integer CLKS_PER_BIT = CLK_FREQ_HZ / BAUD_RATE;
    localparam integer CNT_WIDTH    = $clog2(CLKS_PER_BIT + 1);

    localparam S_IDLE  = 2'b00;
    localparam S_START = 2'b01;
    localparam S_DATA  = 2'b10;
    localparam S_STOP  = 2'b11;

    reg [1:0]           state;
    reg [CNT_WIDTH-1:0] clk_cnt;
    reg [2:0]           bit_idx;
    reg [7:0]           shift;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= S_IDLE;
            clk_cnt <= 0;
            bit_idx <= 3'b000;
            shift   <= 8'h00;
            // Reset to 0, not the true idle-high (1) level: this PDK's
            // std-cell library only provides an async-reset-to-0 DFF
            // ($_DFF_PN0_) - resetting to 1 needs $_DFF_PN1_, which isn't
            // available and leaves the cell unmapped. txd only reads 0
            // while rst_n is actually held low; the S_IDLE branch below
            // drives it back to the correct idle-high 1 on the very first
            // clock edge after reset releases.
            txd     <= 1'b0;
            tx_busy <= 1'b0;
        end else begin
            case (state)

                S_IDLE: begin
                    txd     <= 1'b1;
                    tx_busy <= 1'b0;
                    if (tx_start) begin
                        shift   <= tx_data;
                        state   <= S_START;
                        clk_cnt <= 0;
                        tx_busy <= 1'b1;
                    end
                end

                S_START: begin
                    txd <= 1'b0;   // start bit
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt <= 0;
                        bit_idx <= 3'b000;
                        state   <= S_DATA;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                S_DATA: begin
                    txd <= shift[0];
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt <= 0;
                        shift   <= {1'b0, shift[7:1]};
                        if (bit_idx == 3'd7)
                            state <= S_STOP;
                        else
                            bit_idx <= bit_idx + 1'b1;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                S_STOP: begin
                    txd <= 1'b1;   // stop bit
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt <= 0;
                        state   <= S_IDLE;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                default: state <= S_IDLE;

            endcase
        end
    end

endmodule


// ============================================================================
// LFSR8
// ============================================================================

module lfsr8 (
    input  wire       clk,
    input  wire       rst_n,     // async active-low
    input  wire [6:0] seed,      // sampled once, one cycle after reset releases
    input  wire       advance,   // 1-cycle pulse: shift to the next byte
    output reg  [7:0] keystream
);

    reg loaded;

    wire fb = keystream[7] ^ keystream[5] ^ keystream[4] ^ keystream[3];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            keystream <= 8'h00;   // constant reset - maps to a plain async-clear DFF
            loaded    <= 1'b0;
        end else if (!loaded) begin
            keystream <= {seed, 1'b1};   // synchronous seed load, first cycle out of reset
            loaded    <= 1'b1;
        end else if (advance) begin
            keystream <= {keystream[6:0], fb};
        end
    end

endmodule

`default_nettype wire
