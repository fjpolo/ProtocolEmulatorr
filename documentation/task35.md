# Task 35: Multi-Core Symmetric OmniBus Micro-Engine (OmniBus MP)

## 1. Overview & Architectural Motivation

The **OmniBus MP (Multi-Core Protocol Engine)** extends the deterministic OmniBus architecture into a scalable, symmetric multi-core micro-engine. Configurable at synthesis/instantiation time with **1, 2, or 4 independent execution cores** (`NUM_CORES = 1, 2, 4`), OmniBus MP allows protocols to be decomposed into parallel, cycle-accurate execution slices or pipelined streaming stages without CPU intervention or scheduling jitter.

Each core operates with its own 32-word local program memory window, private register file (`ACC`, `OSR`, `ISR`, `R0..R7`, `LC0`, `LC1`), and deterministic single-cycle execution engine, while sharing a dedicated low-latency hardware synchronization fabric:
1. **8 Shared Hardware Mailbox Registers (`MAILBOX[0..7]`)**: 8-bit single-cycle inter-core communication registers accessible by all cores and memory-mapped to the Wishbone host.
2. **4 Single-Cycle Atomic Spinlocks (`SPINLOCK[0..3]`)**: Hardware test-and-set mutual exclusion locks granting single-cycle atomic ownership and automatic release arbitration.
3. **Hardware Rendezvous Barrier (`BARRIER_WAIT`)**: Single-cycle phase synchronization mechanism holding all active cores in a zero-overhead stall until every active core arrives at the rendezvous point.
4. **Cascade Streaming FIFOs**: Dedicated circular inter-core FIFO pipeline routing streaming data from Core $i$ to Core $(i+1) \bmod N$ or host TX/RX FIFOs.

```
                  +-------------------------------------------------------------+
                  |                      Wishbone B4 SoC Host                   |
                  +------------------------------+------------------------------+
                                                 |
                                 +---------------+---------------+
                                 |  OmniBus_Wishbone SoC Wrapper  |
                                 +---------------+---------------+
                                                 |
                  +------------------------------v------------------------------+
                  |                   ProtocolEmulator_MP.v                     |
                  |                                                             |
                  |   +-------------------+              +-------------------+  |
                  |   |   OmniBus Core 0  | <---FIFO---> |   OmniBus Core 1  |  |
                  |   | (Bank 0: 0x00..1F)|              | (Bank 1: 0x20..3F)|  |
                  |   +---------+---------+              +---------+---------+  |
                  |             |                                  |            |
                  |   +---------v----------------------------------v---------+  |
                  |   |    Hardware Synchronization & Inter-Core Fabric:      |  |
                  |   |     - 8 Shared Mailboxes (MAILBOX[0..7])              |  |
                  |   |     - 4 Single-Cycle Atomic Spinlocks (LOCK[0..3])    |  |
                  |   |     - Hardware Rendezvous Barrier (BARRIER_WAIT)      |  |
                  |   |     - Circular Stream Cascade Inter-Core Crossbar     |  |
                  |   +---------^----------------------------------^---------+  |
                  |             |                                  |            |
                  |   +---------+---------+              +---------+---------+  |
                  |   |   OmniBus Core 2  | <---FIFO---> |   OmniBus Core 3  |  |
                  |   | (Bank 2: 0x40..5F)|              | (Bank 3: 0x60..7F)|  |
                  |   +-------------------+              +-------------------+  |
                  |        (Optional)                         (Optional)        |
                  +-------------------------------------------------------------+
```

---

## 2. Parameterization & Core Topologies

OmniBus MP is parameterized via the Verilog parameter `NUM_CORES`:

| `NUM_CORES` | Active Execution Slices | IMEM Bank Slices | Reset Vectors (`RESET_PC`) | Default Stream Topology |
| :--- | :--- | :--- | :--- | :--- |
| **1** (Uniprocessor) | Core 0 | Bank 0 (`0x00..0x1F`) | Core 0: `0x00` | Host TX $\rightarrow$ Core 0 $\rightarrow$ Host RX |
| **2** (Dual-Core MP) | Core 0, Core 1 | Banks 0, 1 (`0x00..0x3F`) | Core 0: `0x00`, Core 1: `0x20` | Host TX $\rightarrow$ Core 0 $\rightarrow$ Core 1 $\rightarrow$ Host RX |
| **4** (Quad-Core MP) | Core 0, 1, 2, 3 | Banks 0, 1, 2, 3 (`0x00..0x7F`)| Core 0: `0x00`, Core 1: `0x20`, Core 2: `0x40`, Core 3: `0x60` | Host TX $\rightarrow$ Core 0 $\rightarrow$ Core 1 $\rightarrow$ Core 2 $\rightarrow$ Core 3 $\rightarrow$ Host RX |

### Execution Slice Reset & Addressing
Each core calculates its reset vector as:
$$\text{RESET\_PC} = \text{CORE\_ID} \times 32$$

When `i_prog_en` is active (microcode programming mode), all cores are held in synchronous reset and microcode is loaded linearly or bank-switched through the Wishbone programming window (`0x80..0xFC`). Upon deassertion of `i_prog_en`, all instantiated cores release from reset in lockstep.

---

## 3. Hardware Synchronization Subsystems

### 3.1 8 Shared Hardware Mailboxes (`MAILBOX[0..7]`)
- **Capacity**: 8 independent 8-bit storage registers.
- **Microcode Access**: Read with `MB_READ <id>` (`0xF800 | id`), write with `MB_WRITE <id>` (`0xF900 | id`).
- **Wishbone Host Window**: Memory-mapped at offset `ADDR_MP_MAILBOX` (`0x7C`), index selected via `ADDR_MP_CTRL[10:8]`.

### 3.2 4 Single-Cycle Atomic Spinlocks (`SPINLOCK[0..3]`)
- **Atomic Test-and-Set**: `SPINLOCK_ACQ <id>` (`0xFD00 | id`) evaluates combinational lock grant in a single clock cycle. If the lock is free, ownership is granted and the ALU `ZERO` flag is asserted (`ACC = 0`). If already held by another core, acquisition fails and `NOT_ZERO` is set (`ACC = 1`).
- **Atomic Release**: `SPINLOCK_REL <id>` (`0xFE00 | id`) clears ownership unconditionally in 1 clock cycle.
- **Hardware Mutual Exclusion**: Purely combinational grant arbitration prevents race conditions between simultaneous core requests.

### 3.3 Hardware Rendezvous Barrier (`BARRIER_WAIT`)
- **Opcode**: `BARRIER_WAIT` (`0xFF00`).
- **Operation**: When a core executes `BARRIER_WAIT`, it registers a barrier arrival signal and asserts an internal pipeline stall (`barrier_stall`).
- **Phase-Locked Release**: As soon as all active cores (`0 .. NUM_CORES-1`) have reached the barrier, the barrier engine pulses a simultaneous release signal (`barrier_release`), unblocking all cores on the exact same clock cycle.

### 3.4 Cascade Inter-Core FIFO Streaming
- Core 0 TX connects to Core 1 RX FIFO.
- In 4-core mode: Core 0 $\rightarrow$ Core 1 $\rightarrow$ Core 2 $\rightarrow$ Core 3 $\rightarrow$ Host RX FIFO.
- Direct host streaming or loopback routing is dynamically switchable via `ADDR_MP_CTRL[5]`.

---

## 4. SoC Register Map & Telemetry

| Offset | Register Name | Access | Width | Description |
| :--- | :--- | :--- | :--- | :--- |
| **`0x28`** | `ADDR_MP_CTRL` | R/W | 32-bit | **OmniBus MP Multi-Core Control Register**<br>• `[3:0]`: `core_enable` (Core 0..3 active enable mask)<br>• `[4]`: `barrier_rst` (Software reset barrier state)<br>• `[5]`: `stream_mode` (0: Cascade Pipeline, 1: Core 0 Direct)<br>• `[10:8]`: `mailbox_sel` (Mailbox register window index 0..7)<br>• `[15:12]`: `spinlock_force_unlock` (Host override unlock mask) |
| **`0x2C`** | `ADDR_MP_STATUS`| RO | 32-bit | **OmniBus MP Multi-Core Telemetry & Status**<br>• `[3:0]`: `core_halted` (Halt state per core 0..3)<br>• `[7:4]`: `spinlock_status` (Active lock state 0..3)<br>• `[11:8]`: `barrier_waiting` (Barrier arrival mask per core)<br>• `[15:12]`: `active_cores` (Number of synthesized cores: 1, 2, 4)<br>• `[23:16]`: `core0_pc` (Live Program Counter for Core 0)<br>• `[31:24]`: `core1_pc` (Live Program Counter for Core 1) |
| **`0x7C`** | `ADDR_MP_MAILBOX`| R/W | 32-bit | **Host Shared Mailbox Window Register**<br>• `[7:0]`: `mailbox_data[selected]`<br>• `[15:8]`: `mailbox_data[selected + 1]`<br>• `[23:16]`: `mailbox_data[selected + 2]`<br>• `[31:24]`: `mailbox_data[selected + 3]` |

---

## 5. Instruction Set Architecture Extensions

| Mnemonic | Opcode Binary | Hex Code | Operation | Cycles |
| :--- | :--- | :--- | :--- | :--- |
| `CORE_ID` | `1111 1100 0000 0000` | `0xFC00` | `ACC <= CORE_ID` (0..3) | 1 |
| `SPINLOCK_ACQ <id>` | `1111 1101 0000 00<id>` | `0xFD00..0xFD03` | Atomic Test-and-Set: `ACC <= (lock held ? 1 : 0)`, Sets Zero Flag | 1 |
| `SPINLOCK_REL <id>` | `1111 1110 0000 00<id>` | `0xFE00..0xFE03` | Atomic Release: `LOCK[id] <= 0` | 1 |
| `BARRIER_WAIT` | `1111 1111 0000 0000` | `0xFF00` | Hardware rendezvous barrier arrival and phase-locked wait | $1 + N_{\text{wait}}$ |
| `MB_READ <id>` | `1111 1000 0000 0<id>` | `0xF800..0xF807` | `ACC <= MAILBOX[id]` | 1 |
| `MB_WRITE <id>` | `1111 1001 0000 0<id>` | `0xF900..0xF907` | `MAILBOX[id] <= ACC` | 1 |

---

## 6. Software & Compiler Support

### 6.1 Assembler Directives (`omnibus_asm.py`)
- `.core <id>` / `.bank <id>`: Switches active compilation origin to Core `id` (`id * 32`).
- Symbolic aliases: `R0..R7`, `ACC`, `OSR`, `ISR`, `LC0`, `LC1`.

### 6.2 Omni-C Compiler (`omnic` / `sdk/omnibus/compiler`)
- `#pragma core <id>`: Assigns subsequent C functions to the execution slice of Core `id`.
- C Standard MP Intrinsics in `omnibus.h`:
  ```c
  uint8_t core_id(void);
  uint8_t spinlock_acquire(uint8_t lock_id);
  void spinlock_release(uint8_t lock_id);
  void barrier_wait(void);
  uint8_t mailbox_read(uint8_t mb_id);
  void mailbox_write(uint8_t mb_id, uint8_t data);
  ```

---

## 7. Demonstrators & Code Examples

### 7.1 Dual-Core Asymmetric UART-to-SPI Bridge
- **Assembly**: [`examples/multicore_uart_spi_bridge.asm`](file:///c:/Workspace/ASIC/ProtocolEmulator/examples/multicore_uart_spi_bridge.asm) $\rightarrow$ [`examples/multicore_uart_spi_bridge.hex`](file:///c:/Workspace/ASIC/ProtocolEmulator/examples/multicore_uart_spi_bridge.hex)
- **Omni-C**: [`examples/omnic/dual_core_bridge.c`](file:///c:/Workspace/ASIC/ProtocolEmulator/examples/omnic/dual_core_bridge.c) $\rightarrow$ [`examples/omnic/dual_core_bridge.hex`](file:///c:/Workspace/ASIC/ProtocolEmulator/examples/omnic/dual_core_bridge.hex)
- **Description**: Core 0 continuously ingests UART frames (Pins 0..3), passes payload via Mailbox 0 with Spinlock 0 arbitration, and Core 1 transmits SPI frames (Pins 4..7) simultaneously.

### 7.2 Dual-Core Synchronized Mailbox Ping-Pong
- **Assembly**: [`examples/multicore_mailbox_sync.asm`](file:///c:/Workspace/ASIC/ProtocolEmulator/examples/multicore_mailbox_sync.asm) $\rightarrow$ [`examples/multicore_mailbox_sync.hex`](file:///c:/Workspace/ASIC/ProtocolEmulator/examples/multicore_mailbox_sync.hex)
- **Omni-C**: [`examples/omnic/dual_core_mailbox_sync.c`](file:///c:/Workspace/ASIC/ProtocolEmulator/examples/omnic/dual_core_mailbox_sync.c) $\rightarrow$ [`examples/omnic/dual_core_mailbox_sync.hex`](file:///c:/Workspace/ASIC/ProtocolEmulator/examples/omnic/dual_core_mailbox_sync.hex)
- **Description**: Core 0 issues tokens to Mailbox 0, Core 1 modifies and replies via Mailbox 1, with both cores synchronized through `BARRIER_WAIT`.

### 7.3 Quad-Core (4-Core) Pipelined Processing Grid
- **Assembly**: [`examples/multicore_quad_grid.asm`](file:///c:/Workspace/ASIC/ProtocolEmulator/examples/multicore_quad_grid.asm) $\rightarrow$ [`examples/multicore_quad_grid.hex`](file:///c:/Workspace/ASIC/ProtocolEmulator/examples/multicore_quad_grid.hex)
- **Omni-C**: [`examples/omnic/quad_core_grid.c`](file:///c:/Workspace/ASIC/ProtocolEmulator/examples/omnic/quad_core_grid.c) $\rightarrow$ [`examples/omnic/quad_core_grid.hex`](file:///c:/Workspace/ASIC/ProtocolEmulator/examples/omnic/quad_core_grid.hex)
- **Description**: 4-stage pipeline where Core 0 ingests host data, Core 1 applies cryptographic mask, Core 2 computes CRC8 checksum, and Core 3 transmits SPI data and returns completion status.

---

## 8. Verification & Test Results

The OmniBus MP architecture was validated with 100% test pass rate on Icarus Verilog and Cocotb:

### Wishbone Regression Suite (`testrunner_icarus.py`)
- **Total Tests**: 19
- **Passed**: 19 / 19 (100%)
- **Multi-Core Testcases**:
  1. `test_wb_mp_registers_and_telemetry`: Telemetry status, active core count, software reset, and stream mode.
  2. `test_wb_mp_shared_mailboxes`: Host & microcode atomic access to all 8 mailboxes.
  3. `test_wb_mp_atomic_spinlocks`: Single-cycle mutual exclusion and conflict avoidance across Core 0 and Core 1.
  4. `test_wb_mp_hardware_barrier`: Simultaneous phase-locked release across all active cores.
  5. `test_wb_mp_cascade_pipeline_streaming`: Full pipeline stream: Host TX $\rightarrow$ Core 0 $\rightarrow$ FIFO 0 $\rightarrow$ Core 1 $\rightarrow$ Host RX.

### Parameterized Multi-Core Suite (`testrunner_multicore_mp.py`)
- **`NUM_CORES = 2` (Dual-Core)**: **2/2 PASSED**
- **`NUM_CORES = 4` (Quad-Core)**: **2/2 PASSED**
