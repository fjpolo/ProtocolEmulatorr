# Task 26 — OmniBus Direct Memory Access (DMA) Scatter-Gather Controller & Host Memory Streamer

## 1. Overview & Motivation

High-speed protocol emulation (e.g. QSPI, Ethernet, USB 2.0, multi-channel logic analyzers, and continuous RF/audio streaming) demands sustained data throughput reaching tens to hundreds of megabits per second. In standard PIO (Programmed I/O) architectures:
1. **CPU & Bus Overhead**: The host processor must execute polling loops or handle interrupts for every single byte or 32-bit word written to or read from the FIFO registers.
2. **Buffer Fragmentation**: Data frames in host operating systems (Linux `sk_buff`, Windows NDIS, ring buffers) are rarely stored in contiguous physical memory. Scatter-Gather capability is necessary to assemble non-contiguous pages into a contiguous stream without software copy overhead.
3. **Microcode Engine Stalls**: When the ProtocolEmulator core is waiting on the host CPU to refill the TX FIFO or drain the RX FIFO, wire-speed protocol timing can slip or violate bus specifications.

**Task 26 implements a dedicated 32-bit Wishbone B4 Master Dual-Channel Direct Memory Access (DMA) Scatter-Gather Controller (`rtl/OmniBus_DMA.v`) integrated into `OmniBus_Wishbone.v`**:
- **High-Throughput Wishbone Master Interface**: Drives autonomous 32-bit read and write bus cycles directly across host system memory.
- **Independent Dual-Channel Architecture**: Concurrent or arbitrated TX (Memory $\to$ TX FIFO) and RX (RX FIFO $\to$ Memory) streaming engines.
- **Hardware Scatter-Gather Descriptor Traversal**: Automatically parses 16-byte linked-list descriptor chains in host memory, updates transfer progress in-place, and terminates on End-of-Transmission (EOT) flags.
- **Sub-Word Byte Packing & Unpacking**: Automatically handles unaligned or non-multiple-of-4 transfer lengths using Wishbone byte enables (`sel[3:0]`).
- **Telemetry & Host Interrupts**: Integrates channel busy/done/error flags and completion interrupts directly with the host system (`o_irq`).

---

## 2. Hardware Architecture & Wishbone Master Interconnect

```
                    +-----------------------------------------------------------+
                    |                      OmniBus_Wishbone                     |
                    |                                                           |
                    |   +-------------------+          +--------------------+   |
Host Wishbone Slave --->|   Register File   |          |  ProtocolEmulator  |   |
  (0x00 .. 0x4C)    |   |  & Control Logic  |          |      ASIC Core     |   |
                    |   +-------------------+          +--------------------+   |
                    |             |                              |    ^         |
                    |             v                              v    |         |
                    |   +-------------------+          +--------------------+   |
                    |   |  OmniBus_DMA.v    |          |    omnibus_fifo    |   |
                    |   |  (Wishbone Master)|<-------->|  TX FIFO / RX FIFO |   |
                    |   +-------------------+          +--------------------+   |
                    +-------------|---------------------------------------------+
                                  |
                                  v Wishbone B4 Master Bus
               [o_m_wb_cyc, o_m_wb_stb, o_m_wb_we, o_m_wb_addr,
                o_m_wb_data, o_m_wb_sel, i_m_wb_data, i_m_wb_ack]
                                  |
                                  v
                    +---------------------------+
                    | Host System RAM / Intercon |
                    +---------------------------+
```

### Submodule Architecture (`OmniBus_DMA.v`)
1. **TX Streaming Engine (Memory-to-FIFO)**:
   - Fetches 32-bit words from host memory via Wishbone Master read cycles.
   - Holds words in a 32-bit unpacking shift register and streams bytes into `tx_fifo` when almost-full is deasserted.
   - In Scatter-Gather mode: fetches descriptors, steps through memory buffers, writes back completed byte counts to descriptor status words, and follows `next_desc` pointers.
2. **RX Streaming Engine (FIFO-to-Memory)**:
   - Pops bytes from `rx_fifo` using a deterministic 2-phase FWFT (First-Word Fall-Through) handshake.
   - Packs 1 to 4 bytes into a 32-bit word register with active byte select flags (`rx_pack_sel[3:0]`).
   - Issues 32-bit Wishbone Master write cycles with exact byte enables (`o_m_wb_sel`) into host memory.
   - Writes back transferred byte status to descriptors and follows chains until EOT.
3. **Round-Robin Bus Arbiter**:
   - Arbitrates Wishbone master cycles between TX and RX engines when both channels request memory access simultaneously.
   - Ensures zero channel starvation and fair bandwidth sharing.

---

## 3. Register Map (Host Wishbone Slave)

The DMA controller is mapped into the `OmniBus_Wishbone` slave address space from offset `0x30` to `0x4C`:

| Offset | Register Name | Access | Width | Description |
| :--- | :--- | :---: | :---: | :--- |
| `0x30` | `ADDR_DMA_CTRL` | R/W | 32 | **DMA Channel Control Register**<br>Bit [0]: `tx_en` (Enable TX Channel)<br>Bit [1]: `tx_start` (Start TX Transfer, self-clearing)<br>Bit [2]: `tx_irq_en` (Enable TX Completion Interrupt)<br>Bit [3]: `tx_sg_en` (Enable TX Scatter-Gather Linked-List Mode)<br>Bit [4]: `rx_en` (Enable RX Channel)<br>Bit [5]: `rx_start` (Start RX Transfer, self-clearing)<br>Bit [6]: `rx_irq_en` (Enable RX Completion Interrupt)<br>Bit [7]: `rx_sg_en` (Enable RX Scatter-Gather Linked-List Mode)<br>Bit [8]: `abort` (Immediate Abort / Soft Reset) |
| `0x34` | `ADDR_DMA_STATUS` | RO | 32 | **DMA Channel Status Register**<br>Bit [0]: `tx_busy` (TX transfer active)<br>Bit [1]: `tx_done` (TX transfer completed successfully)<br>Bit [2]: `tx_err` (TX bus error encountered)<br>Bit [4]: `rx_busy` (RX transfer active)<br>Bit [5]: `rx_done` (RX transfer completed successfully)<br>Bit [6]: `rx_err` (RX bus error encountered)<br>Bit [8]: `irq` (DMA Interrupt active) |
| `0x38` | `ADDR_DMA_TX_ADDR` | R/W | 32 | TX Memory Source Address (Linear mode) / Initial Descriptor Address (SG mode) |
| `0x3C` | `ADDR_DMA_TX_LEN` | R/W | 32 | TX Transfer Length in Bytes (`[15:0]`, linear mode) |
| `0x40` | `ADDR_DMA_RX_ADDR` | R/W | 32 | RX Memory Destination Address (Linear mode) / Initial Descriptor Address (SG mode) |
| `0x44` | `ADDR_DMA_RX_LEN` | R/W | 32 | RX Transfer Length in Bytes (`[15:0]`, linear mode) |
| `0x48` | `ADDR_DMA_TX_DESC` | RO | 32 | TX Current Descriptor Pointer / Active Address Telemetry |
| `0x4C` | `ADDR_DMA_RX_DESC` | RO | 32 | RX Current Descriptor Pointer / Active Address Telemetry |

---

## 4. Scatter-Gather 16-Byte Descriptor Specification

In Scatter-Gather mode (`tx_sg_en = 1` or `rx_sg_en = 1`), transfer buffers are defined by 16-byte aligned descriptor structures stored in host memory:

```
+---------------------------------------------------------------+
| Byte Offset | Field Name   | Width   | Description             |
+=============+==============+=========+=========================+
| +0x00       | buf_addr     | 32 bits | Host Buffer Address     |
+-------------+--------------+---------+-------------------------+
| +0x04       | length_flags | 32 bits | [15:0]  = Length (bytes)|
|             |              |         | [31:16] = Control Flags |
|             |              |         |   Bit 0: EOT (1=End)    |
+-------------+--------------+---------+-------------------------+
| +0x08       | next_desc    | 32 bits | Pointer to Next Desc    |
+-------------+--------------+---------+-------------------------+
| +0x0C       | status       | 32 bits | [15:0] Transferred Bytes|
|             |              |         | Written back by DMA     |
+---------------------------------------------------------------+
```

### Descriptor Traversal Lifecycle:
1. **Fetch**: DMA Master reads Word 0 (`buf_addr`), Word 1 (`length`, `flags`), and Word 2 (`next_desc`).
2. **Execute**: Streams data between `buf_addr` and the respective FIFO until `length` bytes are transferred.
3. **Writeback**: DMA Master writes Word 3 (`status`) with the exact number of bytes transferred.
4. **Link or Terminate**:
   - If `flags[0] == 1'b0` (EOT not set): DMA updates descriptor pointer to `next_desc` and repeats step 1.
   - If `flags[0] == 1'b1` (EOT set): DMA asserts `done`, sets `ADDR_DMA_STATUS` done flag, asserts `o_irq` (if enabled), and transitions to idle.

---

## 5. Verification & Test Suite

The DMA controller and Wishbone Master integration are fully validated through 4 new automated Cocotb self-checking testcases in `test_rtl/simulation/cocotb/Wishbone/testbench.py`:

| Testcase | Mode | Verification Checks | Status |
| :--- | :--- | :--- | :---: |
| `test_wb_dma_linear_tx` | Linear TX | Streams 16 bytes from host RAM into TX FIFO, verifies FIFO level and exact byte sequence. | **PASS** |
| `test_wb_dma_linear_rx` | Linear RX | Pushes 8 bytes into RX FIFO, DMA drains FIFO and writes 8 bytes to RAM, verifies memory contents. | **PASS** |
| `test_wb_dma_scatter_gather_chain` | Chained SG | Traverses 2-stage linked-list descriptor chain, validates multi-buffer streaming and in-place status writebacks. | **PASS** |
| `test_wb_dma_irq_and_abort` | IRQ & Abort | Verifies `o_irq` assertion upon completion and immediate channel halt/cleanup on software abort. | **PASS** |

### Regression Results
- **Wishbone & DMA Test Suite**: **11 / 11 tests passed (100%)**
- **Core ProtocolEmulator Regression**: **75 / 75 tests passed (100%)**
- **Hardware CRC Accelerator Suite**: **4 / 4 tests passed (100%)**
- **Combined Test Regression**: **86 / 86 tests passed (100%)**
