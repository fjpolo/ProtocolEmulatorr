# Task 14: Parameterized FIFO Subsystem & Wishbone B4 Slave SoC Wrapper

## 1. Executive Summary

To enable seamless, zero-glue-logic integration of the OmniBus Protocol Engine into open-source RISC-V SoC architectures (such as PicoRV32, LiteX, Caravel, OpenLane, and Gowin EMPU softcores), **Task 14** equips OmniBus with:
1. **Parameterized Hardware FIFO Subsystem ([rtl/omnibus_fifo.v](file:///c:/Workspace/ASIC/ProtocolEmulator/rtl/omnibus_fifo.v))**: High-speed, First-Word Fall-Through (FWFT) circular FIFO with programmable depth ($4, 8, 16, 32, 64, 128, 256$), almost-full and almost-empty watermarks, and hardware count tracking.
2. **Standard Wishbone B4 Slave SoC Wrapper ([rtl/OmniBus_Wishbone.v](file:///c:/Workspace/ASIC/ProtocolEmulator/rtl/OmniBus_Wishbone.v))**:
   - Pipelined / Classic Wishbone B4 bus interface (`wb_cyc`, `wb_stb`, `wb_we`, `wb_addr`, `wb_data`, `wb_ack`).
   - Memory-mapped registers for Data FIFO access, Status & Levels, Control & Soft Reset, Baud Divisor, and GPIO pin monitoring.
   - **Direct 32-Word Microcode RAM Programming Window (`0x80`..`0xFC`)**: Allows the host CPU to write and verify microcode instructions directly into IMEM without needing the external UART serial bootloader.
   - **Hardware Watermark Interrupt Generation (`o_irq`)**: Dedicated interrupt output with configurable masks for TX FIFO empty, RX FIFO data ready, and RX almost-full conditions.

---

## 2. SoC Architecture & Interconnect

```
   +-------------------------------------------------------------------------+
   |                            OmniBus_Wishbone                             |
   |                                                                         |
   |    Wishbone B4 Bus                                                      |
   |    i_wb_clk, i_wb_rst_n                                                 |
   |    i_wb_cyc, i_wb_stb, i_wb_we                                         |
   |    i_wb_addr, i_wb_data, o_wb_data, o_wb_ack                            |
   |           |                                                             |
   |           v                                                             |
   |    +---------------+                                                    |
   |    | Register &    |-- Write 0x00 --> [ TX FIFO (16x8 FWFT) ]           |
   |    | Address Decode|                                | i_data, i_tx_valid|
   |    |               |<-- Read 0x00 --- [ RX FIFO (16x8 FWFT) ]           |
   |    |               |                                ^ o_data, o_rx_push |
   |    |               |-- Write 0x80..0xFC (Direct IMEM Programming)       |
   |    +---------------+                                |                   |
   |           |                                         v                   |
   |           |         +---------------------------------------------+     |
   |           +-------->|           ProtocolEmulator Core             |     |
   |                     |                                             |     |
   |                     |  - PC, Delay Counter, CALL/RET Stack        |     |
   |                     |  - Serializers/Deserializers (UART/SPI/1W)  |     |
   |                     |  - Hardware Loop Counters (LC0, LC1)        |     |
   |                     |  - Hardware CRC Accelerator (Opcode 0xE)    |     |
   |                     +---------------------------------------------+     |
   |                                             |                           |
   +---------------------------------------------|---------------------------+
                                                 v
                                   External GPIO Bus (0..7)
                                      i_gpio, o_gpio, o_gpio_oe
```

---

## 3. Wishbone Register Memory Map

All registers are 32-bit aligned. Byte offsets are shown below:

| Offset | Name | Access | Reset Default | Description |
|---|---|---|---|---|
| `0x00` | **`REG_DATA`** | RW | `0x00000000` | **Write**: Pushes `data[7:0]` to TX FIFO.<br>**Read**: Pops and returns byte from RX FIFO. |
| `0x04` | **`REG_STATUS`** | RO | `0x60000022` | Core telemetry and FIFO status flags (see bitfield breakdown). |
| `0x08` | **`REG_CTRL`** | RW | `0x00000000` | Core run/halt, soft reset, FIFO flushes, and IRQ enable masks. |
| `0x0C` | **`REG_BAUD`** | RW | `DEFAULT_BAUD_DIV` | Dynamic baud rate divisor in clock cycles ($ cycles\_per\_bit - 1 $). |
| `0x10` | **`REG_GPIO`** | RO | — | Direct monitoring: `{8'h0, o_gpio_oe, o_gpio, i_gpio}`. |
| `0x80`..`0xFC` | **`REG_IMEM[0..31]`** | RW | Bootloader Echo | Direct 32-word microcode window (`word_addr = (addr - 0x80) >> 2`). |

### `REG_STATUS` (Offset `0x04`) Bitfields:
- `[0]`: `tx_fifo_full` (1 = TX FIFO cannot accept more bytes)
- `[1]`: `tx_fifo_empty` (1 = TX FIFO has no data pending)
- `[2]`: `tx_fifo_almost_full` (level $\ge \text{threshold}$)
- `[3]`: `tx_fifo_almost_empty` (level $\le \text{threshold}$)
- `[4]`: `rx_fifo_full` (1 = RX FIFO full)
- `[5]`: `rx_fifo_empty` (1 = RX FIFO empty)
- `[6]`: `rx_fifo_almost_full` (level $\ge \text{threshold}$)
- `[7]`: `rx_fifo_almost_empty` (level $\le \text{threshold}$)
- `[15:8]`: `tx_fifo_level` (current number of bytes stored in TX FIFO)
- `[23:16]`: `rx_fifo_level` (current number of bytes stored in RX FIFO)
- `[28:24]`: `core_pc` (current execution program counter, 0..31)
- `[29]`: `crc_ok` (1 if hardware CRC accumulator residue equals `0x0000`)
- `[30]`: `core_running` (1 when core is actively executing microcode)
- `[31]`: `irq_state` (current state of `o_irq`)

### `REG_CTRL` (Offset `0x08`) Bitfields:
- `[0]`: `soft_rst` (1 = asserts synchronous soft reset to core and FIFOs)
- `[1]`: `prog_en` (1 = halts core for safe microcode programming)
- `[2]`: `tx_flush` (write 1 to flush TX FIFO, self-clearing)
- `[3]`: `rx_flush` (write 1 to flush RX FIFO, self-clearing)
- `[4]`: `irq_tx_empty_en` (asserts `o_irq` when TX FIFO is empty)
- `[5]`: `irq_rx_ready_en` (asserts `o_irq` when RX FIFO has data: `!rx_empty`)
- `[6]`: `irq_rx_afull_en` (asserts `o_irq` when RX FIFO reaches almost-full watermark)

---

## 4. C Firmware Driver Header (`omnibus_wb.h`)

```c
#ifndef OMNIBUS_WB_H
#define OMNIBUS_WB_H

#include <stdint.h>
#include <stdbool.h>

#define OMNIBUS_REG_DATA        0x00
#define OMNIBUS_REG_STATUS      0x04
#define OMNIBUS_REG_CTRL        0x08
#define OMNIBUS_REG_BAUD        0x0C
#define OMNIBUS_REG_GPIO        0x10
#define OMNIBUS_REG_IMEM_BASE   0x80

// Status flags
#define OMNIBUS_STATUS_TX_FULL    (1 << 0)
#define OMNIBUS_STATUS_TX_EMPTY   (1 << 1)
#define OMNIBUS_STATUS_RX_FULL    (1 << 4)
#define OMNIBUS_STATUS_RX_EMPTY   (1 << 5)
#define OMNIBUS_STATUS_CRC_OK     (1 << 29)
#define OMNIBUS_STATUS_RUNNING    (1 << 30)

// Control flags
#define OMNIBUS_CTRL_SOFT_RST     (1 << 0)
#define OMNIBUS_CTRL_PROG_EN      (1 << 1)
#define OMNIBUS_CTRL_TX_FLUSH     (1 << 2)
#define OMNIBUS_CTRL_RX_FLUSH     (1 << 3)
#define OMNIBUS_CTRL_IRQ_TX_EMPTY (1 << 4)
#define OMNIBUS_CTRL_IRQ_RX_READY (1 << 5)

static inline void omnibus_write_tx(uintptr_t base, uint8_t byte) {
    while (*(volatile uint32_t *)(base + OMNIBUS_REG_STATUS) & OMNIBUS_STATUS_TX_FULL);
    *(volatile uint32_t *)(base + OMNIBUS_REG_DATA) = byte;
}

static inline uint8_t omnibus_read_rx(uintptr_t base) {
    while (*(volatile uint32_t *)(base + OMNIBUS_REG_STATUS) & OMNIBUS_STATUS_RX_EMPTY);
    return (uint8_t)(*(volatile uint32_t *)(base + OMNIBUS_REG_DATA));
}

static inline void omnibus_load_program(uintptr_t base, const uint16_t *prog, size_t len) {
    *(volatile uint32_t *)(base + OMNIBUS_REG_CTRL) |= OMNIBUS_CTRL_PROG_EN;
    for (size_t i = 0; i < len && i < 32; i++) {
        *(volatile uint32_t *)(base + OMNIBUS_REG_IMEM_BASE + (i * 4)) = prog[i];
    }
    *(volatile uint32_t *)(base + OMNIBUS_REG_CTRL) &= ~OMNIBUS_CTRL_PROG_EN;
}

#endif // OMNIBUS_WB_H
```

---

## 5. Verification Results

### 1. FIFO Formal Verification (`test_rtl/formal/FIFO/`)
- Tool: SymbiYosys (`smtbmc` + `yices`)
- Results:
  - **`bound`**: PASS (depth 15, zero violations)
  - **`prf`**: PASS ($k$-induction temporal safety proof for arbitrary memory slot data preservation)
  - **`cvr`**: PASS (**5 of 5** cover traces reached: FIFO full, FIFO drained, simultaneous push/pop, almost-full, almost-empty)

### 2. Wishbone Simulation Suite (`test_rtl/simulation/cocotb/Wishbone/`)
- Tool: Cocotb + Icarus Verilog
- Testcases:
  1. `test_wb_reg_access`: PASS (Status defaults, Baud rate divisor update to 50, Soft reset).
  2. `test_wb_imem_programming`: PASS (Direct CPU write of microcode, readback verification, and autonomous execution).
  3. `test_wb_tx_streaming`: PASS (CPU writes 3 bytes to `REG_DATA`, ProtocolEmulator consumes via `PULL BLOCK` and transmits).
  4. `test_wb_rx_streaming`: PASS (ProtocolEmulator receives 3 UART bytes and pushes to RX FIFO via `PUSH BLOCK`, CPU reads from `REG_DATA`).
  5. `test_wb_irq_watermarks`: PASS (Interrupt asserts on TX empty and RX data ready with mask bits).
- **Result: `TESTS=5 PASS=5 FAIL=0 SKIP=0`** (Real time: 0.07 s).
