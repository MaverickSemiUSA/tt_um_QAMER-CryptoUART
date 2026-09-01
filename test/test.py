# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, Timer, FallingEdge


# ============================================================
# Design configuration
# ============================================================

CLK_FREQ_HZ = 50_000_000
BAUD_RATE = 9600

# 50 MHz clock -> 20 ns period
CLK_PERIOD_NS = 20

# Number of clock cycles per UART bit
CLKS_PER_BIT = CLK_FREQ_HZ // BAUD_RATE

# Participant testbench key seed
KEY_SEED = 0x55


# ============================================================
# LFSR reference model
# ============================================================

def lfsr_seed(seed):
    """
    Reference model for the participant's LFSR initialization.

    RTL:
        keystream <= {seed, 1'b1};
    """
    return ((seed & 0x7F) << 1) | 1


def lfsr_next(cur):
    """
    Reference model for the participant's LFSR next-state logic.

    RTL:
        fb = keystream[7] ^ keystream[5]
           ^ keystream[4] ^ keystream[3];

        keystream <= {keystream[6:0], fb};
    """

    fb = (
        ((cur >> 7) & 1)
        ^ ((cur >> 5) & 1)
        ^ ((cur >> 4) & 1)
        ^ ((cur >> 3) & 1)
    )

    return ((cur << 1) & 0xFF) | fb


# ============================================================
# UART stimulus
# ============================================================

async def send_uart_byte(dut, data):
    """
    Send one 8-N-1 UART byte through ui_in[0].

    This reproduces the send_uart_byte() task from
    tb_tt_um_crypto_led_demo.v.

    UART format:
        1 start bit
        8 data bits, LSB first
        1 stop bit
    """

    bit_time_ns = CLKS_PER_BIT * CLK_PERIOD_NS

    # --------------------------------------------------------
    # Start bit
    # --------------------------------------------------------
    ui_value = int(dut.ui_in.value)
    ui_value &= 0xFE
    dut.ui_in.value = ui_value

    await Timer(bit_time_ns, unit="ns")

    # --------------------------------------------------------
    # Data bits, LSB first
    # --------------------------------------------------------
    for i in range(8):

        ui_value = int(dut.ui_in.value)
        ui_value &= 0xFE
        ui_value |= (data >> i) & 0x01

        dut.ui_in.value = ui_value

        await Timer(bit_time_ns, unit="ns")

    # --------------------------------------------------------
    # Stop bit / UART idle
    # --------------------------------------------------------
    ui_value = int(dut.ui_in.value)
    ui_value |= 0x01
    dut.ui_in.value = ui_value

    await Timer(bit_time_ns, unit="ns")


# ============================================================
# UART monitor
# ============================================================

async def capture_uart_byte(dut):
    """
    Capture one UART byte from the participant's UART TX output.

    uo_out[0] is exposed as the scalar tb.uart_txd signal in tb.v
    because Cocotb 2.x requires scalar LogicObject handles for
    edge-based triggers.
    """

    bit_time_ns = CLKS_PER_BIT * CLK_PERIOD_NS

    # Wait for UART TXD start bit.
    # UART idle = 1
    # UART start bit = 0
    await FallingEdge(dut.uart_txd)

    # Move to the middle of the first data bit.
    await Timer(int(bit_time_ns * 1.5), unit="ns")

    data = 0

    # Capture 8 data bits, LSB first.
    for i in range(8):
        bit = int(dut.uart_txd.value)
        data |= bit << i

        await Timer(bit_time_ns, unit="ns")

    return data


# ============================================================
# Main Cocotb test
# ============================================================

@cocotb.test()
async def test_project(dut):

    dut._log.info("========================================")
    dut._log.info("Start CryptoUART test")
    dut._log.info("========================================")

    # ========================================================
    # Clock
    # ========================================================

    dut._log.info("Starting 50 MHz clock")

    clock = Clock(
        dut.clk,
        CLK_PERIOD_NS,
        unit="ns"
    )

    cocotb.start_soon(clock.start())


    # ========================================================
    # Initial conditions / Reset
    # ========================================================

    dut._log.info("Applying reset")

    dut.ena.value = 1

    dut.uio_in.value = 0

    # ui_in:
    #
    # [7:1] = KEY_SEED
    # [0]   = UART idle high
    #
    # KEY_SEED = 7'h55
    #
    # Therefore:
    #
    # ui_in = {7'h55, 1'b1}
    #
    dut.ui_in.value = ((KEY_SEED & 0x7F) << 1) | 1

    # Assert active-low reset
    dut.rst_n.value = 0

    # Match participant testbench:
    #
    # repeat (5) @(posedge clk);
    #
    await ClockCycles(dut.clk, 5)

    # Release reset
    dut.rst_n.value = 1

    # Match participant testbench:
    #
    # repeat (5) @(posedge clk);
    #
    await ClockCycles(dut.clk, 5)


    # ========================================================
    # LFSR reference values
    # ========================================================

    key0 = lfsr_seed(KEY_SEED)
    key1 = lfsr_next(key0)

    dut._log.info(
        f"KEY_SEED = 0x{KEY_SEED:02X}"
    )

    dut._log.info(
        f"LFSR key0 = 0x{key0:02X}"
    )

    dut._log.info(
        f"LFSR key1 = 0x{key1:02X}"
    )


    # ========================================================
    # Character 1: 'A' = 0x41
    # ========================================================

    dut._log.info(
        "Testing character 1: 0x41 ('A')"
    )

    # Start sending the UART byte.
    #
    # The participant Verilog testbench does:
    #
    # fork
    #     send_uart_byte(8'h41);
    #     capture_uart_byte(plain_capture);
    # join
    #
    # We reproduce the same concurrent behavior.

    send_task = cocotb.start_soon(
        send_uart_byte(dut, 0x41)
    )

    # Capture plaintext echo
    plain_capture = await capture_uart_byte(dut)

    # Wait for UART input task to finish
    await send_task


    # --------------------------------------------------------
    # Check plaintext echo #1
    # --------------------------------------------------------

    assert plain_capture == 0x41, (
        f"FAIL: plaintext echo #1 got "
        f"0x{plain_capture:02X}, expected 0x41"
    )

    dut._log.info(
        "PASS: plaintext echo #1 correct (0x41)"
    )


    # ========================================================
    # Capture ciphertext #1
    # ========================================================

    cipher_capture = await capture_uart_byte(dut)

    expected_cipher1 = 0x41 ^ key0

    assert cipher_capture == expected_cipher1, (
        f"FAIL: ciphertext #1 got "
        f"0x{cipher_capture:02X}, expected "
        f"0x{expected_cipher1:02X}"
    )

    dut._log.info(
        f"PASS: ciphertext #1 correct "
        f"(0x{cipher_capture:02X})"
    )


    # ========================================================
    # Check live ciphertext and LED state
    # ========================================================

    # Match participant testbench:
    #
    # repeat (5) @(posedge clk);
    #
    await ClockCycles(dut.clk, 5)


    # --------------------------------------------------------
    # Check uio_out
    # --------------------------------------------------------

    uio_out = int(dut.uio_out.value)

    assert uio_out == cipher_capture, (
        f"FAIL: uio_out live cipher byte mismatch: "
        f"0x{uio_out:02X} vs 0x{cipher_capture:02X}"
    )

    dut._log.info(
        f"PASS: uio_out live cipher byte correct "
        f"(0x{uio_out:02X})"
    )


    # --------------------------------------------------------
    # Check LED state after character 1
    #
    # uo_out mapping:
    #
    # uo_out[1] = LED[0]
    # uo_out[2] = LED[1]
    # uo_out[3] = LED[2]
    # uo_out[4] = LED[3]
    #
    # Expected:
    #
    # uo_out[4:1] = 0001
    # --------------------------------------------------------

    uo_value = int(dut.uo_out.value)

    led_state = (uo_value >> 1) & 0x0F

    assert led_state == 0b0001, (
        f"FAIL: LED state after char 1 should be 0001, "
        f"got {led_state:04b}"
    )

    dut._log.info(
        "PASS: LED state after char 1 is 0001"
    )


    # ========================================================
    # Character 2: 'B' = 0x42
    # ========================================================

    dut._log.info(
        "Testing character 2: 0x42 ('B')"
    )

    # Start sending second byte
    send_task = cocotb.start_soon(
        send_uart_byte(dut, 0x42)
    )

    # Capture plaintext echo
    plain_capture = await capture_uart_byte(dut)

    # Wait for sender to finish
    await send_task


    # --------------------------------------------------------
    # Check plaintext echo #2
    # --------------------------------------------------------

    assert plain_capture == 0x42, (
        f"FAIL: plaintext echo #2 got "
        f"0x{plain_capture:02X}, expected 0x42"
    )

    dut._log.info(
        "PASS: plaintext echo #2 correct (0x42)"
    )


    # ========================================================
    # Capture ciphertext #2
    # ========================================================

    cipher_capture = await capture_uart_byte(dut)

    expected_cipher2 = 0x42 ^ key1

    assert cipher_capture == expected_cipher2, (
        f"FAIL: ciphertext #2 got "
        f"0x{cipher_capture:02X}, expected "
        f"0x{expected_cipher2:02X}"
    )

    dut._log.info(
        f"PASS: ciphertext #2 correct "
        f"(0x{cipher_capture:02X})"
    )


    # ========================================================
    # Check LED state after character 2
    # ========================================================

    # Match participant testbench:
    #
    # repeat (5) @(posedge clk);
    #
    await ClockCycles(dut.clk, 5)


    uo_value = int(dut.uo_out.value)

    led_state = (uo_value >> 1) & 0x0F

    assert led_state == 0b0011, (
        f"FAIL: LED state after char 2 should be 0011, "
        f"got {led_state:04b}"
    )

    dut._log.info(
        "PASS: LED state after char 2 is 0011"
    )


    # ========================================================
    # Check uio_oe
    # ========================================================

    uio_oe = int(dut.uio_oe.value)

    assert uio_oe == 0xFF, (
        f"FAIL: uio_oe should be 0xFF, "
        f"got 0x{uio_oe:02X}"
    )

    dut._log.info(
        "PASS: uio_oe is constant 0xFF"
    )


    # ========================================================
    # Final result
    # ========================================================

    dut._log.info("========================================")
    dut._log.info("=== ALL CHECKS PASSED ===")
    dut._log.info("========================================")
