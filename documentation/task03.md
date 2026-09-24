# Task 03: Input Shift Register (ISR) and UART Receiver / Echo Transceiver

> **Specification & Verification Document for Task 03**  
> **Target**: Physical FPGA (Tang Console 60K), Cocotb Simulation, and SymbiYosys Formal Verification  
> **Objective**: Implement the deserialization half of the OmniBus **Dual SERDES Engine** (`OSR` + `ISR`). Introduce the Input Shift Register (`ISR`), the multi-cycle mid-bit sampling deserializer **`IN`** (Opcode `0x2`), the edge/level synchronizer **`WAIT`** (Opcode `0x4`), and the internal bus transfer instruction **`PUSH`** (Opcode `0xA`). Wire the Tang Console 60K BL616 MCU RX pin (`V14`) to demonstrate live interactive UART Echo / Loopback.

---

## 1. Task Objective and Rationale

In **Task 01**, the OmniBus core proved the foundational **zero-jitter sidecar delay execution model** with static ROM microcode.  
In **Task 02**, the core evolved into a dynamic transmitter by introducing the **Output Shift Register (`OSR`)** and the multi-cycle bit serializer **`OUT`** (`0x1`).

Following the Jane Street challenge guidance (*"Start by getting a UART transmitter out of a pin. Then make it programmable."*), **Task 03** completes the physical communication loop by establishing the receiving datapath:
1. **Full-Duplex Dual SERDES**: Pairs the existing `OSR` with the new **Input Shift Register (`ISR`)**, creating the universal deserializer engine used for UART, SPI MISO, I2C SDA read, USB 1.1 RX, and CAN RX.
2. **Deterministic Edge Synchronization (`WAIT`)**: Replaces high-overhead CPU interrupt handlers with an exact hardware synchronizer that stalls the program counter until a line transition occurs, appending an exact sidecar delay to align subsequent instructions to the bit midpoint.
3. **Hardware UART Echo Demonstration**: Implements an interactive loopback program in microcode. Typing into a serial terminal sends bytes into `ISR`, displays the ASCII bit pattern on 8 physical PMOD LEDs, and immediately retransmits the byte back to the terminal over `uart_tx`.

---

## 2. Micro-Architecture Specification

### 2.1. Datapath Registers

| Register | Width | Description |
| :--- | :--- | :--- |
| `pc` | 4 bits | Program Counter addressing 16-word microcode ROM |
| `delay_cnt` | 9 bits | Hardware sidecar delay down-counter (0 to 511 clock cycles) |
| `tx_reg` | 1 bit | Registered output state of the physical UART TX pin (`o_tx`) |
| `osr` | 8 bits | **Output Shift Register**: holds byte being serialized |
| `bit_cnt` | 4 bits | Serialization counter: tracks remaining bits during `OUT` |
| `isr` | 8 bits | **Input Shift Register**: accumulates deserialized incoming bits |
| `rx_bit_cnt` | 4 bits | Deserialization counter: tracks remaining bits during `IN` |

---

### 2.2. Opcode Table

| Opcode | Mnemonic | Syntax | Description | Cycle Duration |
| :--- | :--- | :--- | :--- | :--- |
| `0x0` | **NOP** | `NOP [delay]` | Pauses execution for `delay` cycles | $1 + \text{delay}$ |
| `0x1` | **OUT** | `OUT pin, count [delay]` | Serializes `count` bits from `osr` to `pin` @ `delay` cycles/bit | $\text{count} \times (1 + \text{delay})$ |
| `0x2` | **IN** | `IN pin, count [delay]` | Deserializes `count` bits from `pin` into `isr` @ `delay` cycles/bit | $\text{count} \times (1 + \text{delay})$ |
| `0x3` | **SET** | `SET pin, val [delay]` | Drives `pin` to immediate `val` for `delay` cycles | $1 + \text{delay}$ |
| `0x4` | **WAIT** | `WAIT pin, level [delay]` | Stalls until `pin == level`, then holds for `delay` cycles | Stalls $+ (1 + \text{delay})$ |
| `0x8` | **JMP** | `JMP target` | Unconditional jump to address `target` | $1$ |
| `0x9` | **PULL** | `PULL` | Latches `i_data[7:0]` into `osr` | $1$ |
| `0xA` | **PUSH** | `PUSH` | Transfers `isr[7:0]` into `osr` (for echo) and outputs to `o_data` | $1$ |

---

### 2.3. Instruction Word Encoding (16-Bit)

#### `WAIT` Instruction (Opcode `0x4`)
```
[15:12] (4 bits) : Opcode 0x4 (WAIT)
[11:10] (2 bits) : Pin Index (0 = RX pin)
[9]     (1 bit)  : Target Level (0 = wait for low, 1 = wait for high)
[8:0]   (9 bits) : Post-synchronization Sidecar Delay
```

#### `IN` Instruction (Opcode `0x2`)
```
[15:12] (4 bits) : Opcode 0x2 (IN)
[11:10] (2 bits) : Pin Index (0 = RX pin)
[9]     (1 bit)  : Shift Direction (0 = LSB first, 1 = MSB first)
[8:0]   (9 bits) : Sidecar Delay per bit (433 = 115200 baud @ 50 MHz)
```

#### `PUSH` Instruction (Opcode `0xA`)
```
[15:12] (4 bits) : Opcode 0xA (PUSH)
[11:0]  (12 bits): Reserved (0x000)
```

---

### 2.4. Timing Mathematics: Mid-Bit Sampling on 50 MHz Clock

* System Clock: $f_{\text{clk}} = 50\,\text{MHz} \implies T_{\text{clk}} = 20.0\,\text{ns}$
* Target Baud Rate: $115,200\,\text{baud} \implies T_{\text{bit}} = 434\text{ clock cycles}$
* Half-bit Duration: $T_{\text{half}} = 217\text{ clock cycles}$
* Delays:
  * Full bit sidecar delay: $D_{\text{bit}} = 434 - 1 = 433$ (`9'h1B1`)
  * Half bit sidecar delay: $D_{\text{half}} = 217 - 1 = 216$ (`9'h0D8`)

```
RX Pin:  1 1 1 1 0 0 0 0 0 0 0 0 0 0 0 0 | D0 D0 D0 D0 D0 D0 D0 D0 | D1 D1 D1 ...
                 |                      |                     |
                 +--- Falling Edge      |                     |
                 |                      |                     |
                 <------ 217 cyc ------>|                     |
                 WAIT rx=0 [216]        <------- 434 cyc ---->|
                                        NOP [433]             |
                                                              +-- Midpoint of D0
                                                                  Sampled by IN!
```

1. **Start Bit Detection**: `WAIT rx=0 [216]` stalls while `i_rx == 1`. When `i_rx` drops to `0`, the instruction triggers and holds for 216 cycles, placing the core at the midpoint of the Start bit (217 cycles from edge).
2. **Bit 0 Midpoint Alignment**: `NOP [433]` delays by 1 full bit (434 cycles). Total elapsed time since edge = $217 + 434 = 651\text{ cycles} \equiv 1.5\text{ bit periods}$ (exact center of Bit 0).
3. **Mid-Bit Deserialization**: `IN rx, 8 [433]` samples Bit 0 immediately at cycle 651, then holds for 433 cycles per bit, sampling Bits 1 through 7 at cycles $1085, 1519, 1953, 2387, 2821, 3255, 3689$.
4. **Stop Bit Confirmation**: `WAIT rx=1 [0]` confirms line return to idle high (`1`).

---

## 3. Microcode Specification (UART Echo Transceiver)

The complete bidirectional transceiver executes in just **10 microcode instructions**:

| Address | Hex Word | Instruction Equivalent | Function | Duration |
| :--- | :--- | :--- | :--- | :--- |
| `0x0` | `16'h40D8` | `WAIT rx=0 [216]` | Wait for Start bit edge; delay to mid-start | Stalls $+ 217$ cycles |
| `0x1` | `16'h01B1` | `NOP [433]` | Advance $1.0$ bit to center of Data Bit 0 | 434 cycles |
| `0x2` | `16'h21B1` | `IN rx, 8 [433]` | Sample 8 data bits at bit midpoints into `isr` | 3472 cycles |
| `0x3` | `16'h4200` | `WAIT rx=1 [0]` | Confirm Stop bit (logic 1) | 1 cycle |
| `0x4` | `16'hA000` | `PUSH` | Transfer `isr` -> `osr` and update `o_data` | 1 cycle |
| `0x5` | `16'h31B1` | `SET tx=0 [433]` | Transmit Start bit (logic 0) | 434 cycles |
| `0x6` | `16'h11B1` | `OUT tx, 8 [433]` | Transmit 8 data bits dynamically from `osr` | 3472 cycles |
| `0x7` | `16'h33B1` | `SET tx=1 [433]` | Transmit Stop bit (logic 1) | 434 cycles |
| `0x8` | `16'h01B1` | `NOP [433]` | Inter-character idle pause | 434 cycles |
| `0x9` | `16'h8000` | `JMP 0x0` | Loop back to `WAIT` for next incoming byte | 1 cycle |

---

## 4. Hardware Implementation Details

### 4.1. Core RTL: `rtl/ProtocolEmulator.v`
* Ports:
  * `input wire i_clk`
  * `input wire i_reset_n`
  * `input wire i_rx` (UART RX pin)
  * `input wire [7:0] i_data`
  * `output wire o_tx` (UART TX pin)
  * `output reg [7:0] o_data` (received byte `isr[7:0]` displayed on LEDs)
* Implements `isr` (8 bits) and `rx_bit_cnt` (4 bits).
* Implements `WAIT` (`0x4`), `IN` (`0x2`), and `PUSH` (`0xA`).

### 4.2. Physical Top Level: `boards/sipeed/console60k/src/top.v`
* Connects `uart_rx` on Pin `V14` (BL616 MCU TX -> FPGA RX) with internal pull-up.
* Connects `uart_tx` on Pin `U15` (FPGA TX -> BL616 MCU RX).
* Maps `o_led[7:0]` to `o_data` (`isr[7:0]`) so received ASCII characters light up on PMOD LEDs.

---

## 5. Verification Plan

### 5.1. Cocotb Simulation Testbench
1. **Interactive Echo Verification**:
   - Transmit arbitrary test bytes into `i_rx`: `0x55`, `0xAA`, `0x00`, `0xFF`, `0x42`, `0xC3`.
   - Verify that `o_tx` emits the identical bytes with zero cycle error and exact 8N1 framing.
2. **Text String Streaming**:
   - Stream ASCII sentences (e.g. `"Hello from Cocotb UART RX!\r\n"`).
   - Verify that the receiver decodes all characters and echoes the complete string back byte-for-byte.
3. **Baud Rate Tolerance / Skew Margin**:
   - Inject frames at $\pm 2.5\%$ baud rate offset (simulating real-world oscillator drift) and confirm flawless reception.

### 5.2. SymbiYosys Formal Verification
1. **`WAIT` Soundness**: Formally prove that `pc` cannot advance past `0x0` while `i_rx == 1`.
2. **`IN` Deserialization Invariant**: Formally prove that 8 successive sampling edges accurately reconstruct the serialized byte into `isr`.
3. **`PUSH` Equivalence**: Formally prove that `osr == isr` upon executing `PUSH`.

### 5.3. Physical Hardware Validation
* Build bitstream: `.\build_console60k.bat -Flash sram`.
* Open serial terminal: `.\scripts\serial_monitor_console60k.bat`.
* Type characters into the console and observe instant echo in the terminal and binary ASCII patterns on the PMOD LEDs.
