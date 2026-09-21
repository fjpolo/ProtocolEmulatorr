# Task 04: Runtime Programmable Microcode RAM (IMEM), Hardware Bootloader, and Host Loader

## 1. Overview & Architectural Motivation

In Tasks 01 through 03, the OmniBus protocol engine proved its deterministic dual-SERDES execution datapath (`OSR`, `ISR`, `OUT`, `IN`, `WAIT`, `SET`, `PUSH`, `PULL`, and sidecar delay timers), achieving zero-jitter UART serialization and full-duplex interactive echo loopback. However, the microcode was baked into synthesis-time Verilog ROM (`rom [0:15]`). Changing protocols or adjusting timing parameters required a full synthesis, placement, routing, and bitstream generation cycle (~45–60 seconds).

**Task 04 fulfills the core tenet of the Jane Street Protocol Emulator challenge:**
> *"Start by getting a UART transmitter out of a pin. Then make it programmable. An engineer should be able to define a new wire protocol, compile it to microcode, and run it on the chip in milliseconds without resynthesizing the silicon."*

Task 04 upgrades the system with:
1. **Dual-Port Instruction RAM (`IMEM`)**: 32 words $\times$ 16 bits of distributed asynchronous/LUT RAM, allowing zero-latency combinational instruction fetch during execution and synchronous single-cycle write updates during programming.
2. **5-bit Program Counter (`pc[4:0]`)**: Doubles program capacity to 32 instructions, accommodating complex multi-byte framing protocols, string streams, and multi-state handshakes.
3. **In-Band Hardware Bootloader (`OmniBootloader.v`)**: Listens on the existing UART interface for a dedicated 3-byte synchronization token (`0xAA 0x55 0x50`). When detected, it captures the UART lines, places the core in reset, and provides commands to write (`'W'`), read back (`'R'`), and execute (`'X'`) microcode in ~20 milliseconds.
4. **Python Microcode Assembler (`omnibus_asm.py`)**: Human-readable symbolic assembly with label support, comments, and timing constants.
5. **Host Dynamic Loader (`omnibus_loader.py`) & Batch Script (`load_microcode.bat`)**: Single-command assembly, upload, verification, and interactive terminal launch.

---

## 2. Core Specification: `ProtocolEmulator.v`

### 2.1. Memory & Execution Datapath
* **Instruction Memory**: `reg [15:0] imem [0:31]`
  * Read Port (combinational, zero latency): `assign instr = imem[pc];`
  * Write Port (synchronous): `if (i_prog_en && i_prog_we) imem[i_prog_addr] <= i_prog_data;`
  * Readback Port: `assign o_prog_rdata = imem[i_prog_addr];`
* **Program Counter**: `reg [4:0] pc` (addresses 0 to 31).
* **Branch Target**: `wire [4:0] target = instr[4:0]`.

### 2.2. Programming Interface Ports
| Port Name | Direction | Width | Description |
| :--- | :--- | :--- | :--- |
| `i_prog_en` | Input | 1 | Programming Mode Enable. When HIGH, halts core execution, holds `pc <= 0`, `delay_cnt <= 0`, `tx_reg <= 1`, `bit_cnt <= 0`, `rx_bit_cnt <= 0`. |
| `i_prog_we` | Input | 1 | Write Enable strobe. Writes `i_prog_data` into `imem[i_prog_addr]` on rising clock edge. |
| `i_prog_addr` | Input | 5 | Microcode word address (`0x00` to `0x1F`). |
| `i_prog_data` | Input | 16 | 16-bit instruction word to write. |
| `o_prog_rdata`| Output | 16 | Combinational readback data from `imem[i_prog_addr]`. |

### 2.3. Power-On Default Contents
To preserve full backward compatibility with Task 03, `imem` is pre-populated at power-on with the 10-instruction UART Echo Transceiver:
```verilog
imem[0] = 16'h40D8; // WAIT rx=0 [216]   - Wait for Start bit falling edge, delay to mid-start (217 cycles)
imem[1] = 16'h01B1; // NOP       [433]   - Advance 1.0 bit to center of Data Bit 0
imem[2] = 16'h21B1; // IN  rx, 8 [433]   - Sample 8 data bits LSB-first into ISR
imem[3] = 16'h4200; // WAIT rx=1 [0]     - Confirm Stop bit logic 1
imem[4] = 16'hA000; // PUSH              - Transfer ISR -> OSR for echo transmission
imem[5] = 16'h31B1; // SET tx=0  [433]   - Transmit Start bit (0)
imem[6] = 16'h11B1; // OUT tx, 8 [433]   - Transmit 8 data bits from OSR
imem[7] = 16'h33B1; // SET tx=1  [433]   - Transmit Stop bit (1)
imem[8] = 16'h8000; // JMP 0x0           - Loop back to WAIT for next incoming byte
```

---

## 3. Hardware UART Bootloader: `OmniBootloader.v`

The bootloader operates directly over the 115200-baud UART RX/TX lines connected to the host.

### 3.1. Framing & State Machine
1. **Normal Execution Mode (`prog_active == 0`)**:
   * Incoming RX bytes are routed to `ProtocolEmulator`.
   * Outgoing TX is driven by `ProtocolEmulator.o_tx`.
   * Bootloader snoops RX data looking for the 3-byte unlock sequence: `0xAA` -> `0x55` -> `0x50` (`'P'`).
2. **Entering Programming Mode (`prog_active == 1`)**:
   * Upon receiving `0xAA 0x55 0x50`, `prog_active` asserts.
   * `o_prog_en` is driven HIGH to freeze the protocol engine.
   * TX is multiplexed to the bootloader's transmitter.
   * Bootloader transmits: `0x06` (`ACK`) + `"OK\r\n"` (`0x06 0x4F 0x4B 0x0D 0x0A`).
3. **Command Processing**:
   * **Write (`'W'` / `0x57`)**:
     * Host sends: `'W'`, `<addr: 1 byte>`, `<data_hi: 1 byte>`, `<data_lo: 1 byte>`.
     * Bootloader writes `imem[addr] <= {data_hi, data_lo}` and replies `0x06` + `addr`.
   * **Read (`'R'` / `0x52`)**:
     * Host sends: `'R'`, `<addr: 1 byte>`.
     * Bootloader reads `imem[addr]` and replies `0x06` + `data_hi` + `data_lo`.
   * **Execute / Exit (`'X'` / `0x58`)**:
     * Host sends: `'X'`.
     * Bootloader replies `0x06` + `"RUN\r\n"`, deasserts `o_prog_en`, and restores UART lines to `ProtocolEmulator`.
     * Core begins execution at `pc = 0` with the new microcode!

---

## 4. Microcode Assembler & Host Tools

### 4.1. Syntax Reference (`omnibus_asm.py`)
```asm
; OmniBus Microcode Assembly
; Format: [label:] OPCODE [arg1], [delay]

start:
    WAIT 0, 216       ; Wait for start bit falling edge
    NOP  433          ; Move to center of bit 0
    IN   8, 433       ; Deserializer: sample 8 bits into ISR
    WAIT 1, 0         ; Verify stop bit is high
    PUSH              ; Transfer ISR to OSR
    SET  0, 433       ; Transmit start bit (0)
    OUT  8, 433       ; Serializer: shift out 8 bits from OSR
    SET  1, 433       ; Transmit stop bit (1)
    JMP  start        ; Loop
```

### 4.2. Host Dynamic Loader (`omnibus_loader.py`)
* Usage:
  ```bash
  python omnibus_loader.py --port COM19 --file examples/hello.asm --terminal
  ```
* Flashes 32 microcode words in <20 milliseconds and drops immediately into the interactive terminal.
