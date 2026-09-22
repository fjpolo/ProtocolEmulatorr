# Task 11 — Hardware FIFO Handshaking & Status Flags

## Summary

Establishes a dedicated **Hardware FIFO Handshaking & Status Architecture** in the OmniBus microcode engine, replacing static register sampling with cycle-accurate handshaking, pop/push strobes, conditional branches, and non-blocking vs blocking flow control.

---

## 1. Hardware Interface Ports

```verilog
// Hardware FIFO Control & Handshaking Interface
input   wire        i_tx_valid, // 1 when valid data byte is waiting in TX FIFO
output  reg         o_tx_pop,   // 1-cycle active-high strobe when PULL consumes data
input   wire        i_rx_full,  // 1 when RX FIFO cannot accept additional bytes
output  reg         o_rx_push,  // 1-cycle active-high strobe when PUSH emits data
```

### Strobe Timing:
- `o_tx_pop`: Pulsed high for exactly 1 clock cycle during execution of `PULL` when valid data is consumed (`i_tx_valid == 1`).
- `o_rx_push`: Pulsed high for exactly 1 clock cycle during execution of `PUSH` when data is emitted to `o_data`.

---

## 2. Conditional Jumps on Status Flags (`JMP [cond], target`)

Opcode `0x8` (`JMP`) is extended with a 3-bit condition field in bits `[10:8]`:

```
+---------------+---------------+---------------+-------------------------------+
| [15:12] (4b)  |     [11]      |  [10:8] (3b)  |          [4:0] (5b)           |
| Opcode = 0x8  |   Reserved    | Condition Code|         Target Address        |
+---------------+---------------+---------------+-------------------------------+
```

| Code `[10:8]` | Mnemonic | Description | Branch Condition |
| :---: | :--- | :--- | :--- |
| `3'b000` | `JMP target` | Unconditional Jump | Always branches to `target` (backward compatible) |
| `3'b001` | `JMP TX_VALID, target` | Jump if TX data available | Branches if `i_tx_valid == 1` |
| `3'b010` | `JMP TX_EMPTY, target` | Jump if TX FIFO empty | Branches if `i_tx_valid == 0` |
| `3'b011` | `JMP RX_FULL, target` | Jump if RX FIFO full | Branches if `i_rx_full == 1` |
| `3'b100` | `JMP RX_READY, target` | Jump if RX FIFO has space | Branches if `i_rx_full == 0` |
| `3'b101` | `JMP PIN_HI, target` | Jump if RX pin logic 1 | Branches if `gpio_in[rx_pin] == 1` |
| `3'b110` | `JMP PIN_LO, target` | Jump if RX pin logic 0 | Branches if `gpio_in[rx_pin] == 0` |

If the condition is met, `PC <= target` in a single clock cycle. If not met, execution falls through to `PC + 1`.

---

## 3. Flow-Control `PULL` and `PUSH` Modes

Bit `[0]` of `PULL` (opcode `0x9`) and `PUSH` (opcode `0xA`) configures blocking behavior:

### `PULL` (Opcode `0x9`):
- **`PULL`** (`instr[0] = 0`): Non-blocking default. Copies `i_data` to `OSR`, asserts `o_tx_pop <= i_tx_valid`, and advances `PC <= PC + 1`.
- **`PULL BLOCK`** (`instr[0] = 1`): If `i_tx_valid == 0`, stalls core (`PC <= PC`, `o_tx_pop <= 0`) until data arrives. Once `i_tx_valid == 1`, pops byte and advances.

### `PUSH` (Opcode `0xA`):
- **`PUSH`** (`instr[0] = 0`): Non-blocking default. Transfers `ISR` to `o_data` and `OSR`, asserts `o_rx_push <= 1`, and advances `PC <= PC + 1`.
- **`PUSH BLOCK`** (`instr[0] = 1`): If `i_rx_full == 1`, stalls core (`PC <= PC`, `o_rx_push <= 0`) until space opens. Once space is available, transfers byte and advances.

---

## Example: FIFO Packet Echo Loop (`fifo_stream_demo.asm`)

```asm
start:
    ; Wait for incoming byte in TX FIFO
wait_for_tx:
    JMP     TX_EMPTY, wait_for_tx

    ; Pop byte into OSR
    PULL

    ; Send byte over UART / SPI / etc.
    OUT     $BAUD

    ; Echo received byte back to RX FIFO (wait if RX FIFO full)
    PUSH    BLOCK

    JMP     start
```
