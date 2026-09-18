# Task 01: Minimal Deterministic Micro-Core and UART Transmitter

> **Specification & Verification Document for Task 01**  
> **Target**: Physical FPGA (Tang Console 60K) and Simulation  
> **Objective**: Prove the foundational execution model of OmniBus: single-cycle instruction execution with hardware sidecar delays to output a 115200-baud UART transmission from a physical pin.

---

## 1. Task Objective and Rationale

Following the Jane Street challenge guidance (*"Start by getting a UART transmitter out of a pin. Then make it programmable."*), Task 01 implements the minimal viable subset of the OmniBus architecture.

Rather than a fixed UART peripheral or a software loop on an MCU, this task proves the **zero-jitter sidecar delay execution model**:
1. Every instruction executes in 1 clock cycle plus an exact number of sidecar delay cycles.
2. Timing is maintained purely by hardware counters rather than CPU polling.
3. The program is fully reprogrammable via a microcode array.

---

## 2. Micro-Architecture Specification

### 2.1. 16-Bit Instruction Encoding

Every instruction word is 16 bits wide:
```
[15:12] (4 bits) : Opcode
[11:10] (2 bits) : Pin Index (0 = pin 0, 1 = pin 1, etc.)
[9]     (1 bit)  : Pin Value (0 = drive low, 1 = drive high)
[8:0]   (9 bits) : Sidecar Delay (0 to 511 additional clock cycles)
```

For jump instructions (`JMP`):
```
[15:12] (4 bits) : Opcode 0x8 (JMP)
[11:8]  (4 bits) : Reserved
[7:0]   (8 bits) : Target Program Counter Address (0 to 255)
```

### 2.2. Opcode Table

| Opcode | Mnemonic | Syntax | Description | Cycles |
| :--- | :--- | :--- | :--- | :--- |
| `0x0` | **NOP** | `NOP [delay]` | Pauses execution for `delay` cycles | $1 + \text{delay}$ |
| `0x3` | **SET** | `SET pin, val [delay]` | Drives `pin` to `val` and holds for `delay` cycles | $1 + \text{delay}$ |
| `0x8` | **JMP** | `JMP target` | Unconditional jump to address `target` | $1$ |

### 2.3. Timing Mathematics: 115200 Baud on 50 MHz Master Clock

* System Clock ($f_{\text{clk}}$): $50\,\text{MHz} \implies T_{\text{clk}} = 20.0\,\text{ns}$
* Target Baud Rate ($B$): $115,200\,\text{baud} \implies T_{\text{bit}} \approx 8.6805\,\mu\text{s}$
* Bit Duration in Clock Cycles:
  $$N_{\text{cycles}} = \frac{50,000,000}{115,200} = 434.027 \implies 434 \text{ cycles}$$
* Sidecar Delay Value ($D$):
  Since execution consumes 1 clock cycle, the sidecar delay counter must hold for:
  $$D = N_{\text{cycles}} - 1 = 434 - 1 = 433 \text{ cycles}$$
  $433$ in 9-bit binary: `9'd433` = `9'b1_1011_0001` = `0x1B1`

---

## 3. Microcode: Transmitting Character 'U' (0x55)

The ASCII character `'U'` (`8'h55` = `8'b01010101`) produces alternating bits on the line, making it ideal for verification via oscilloscope, logic analyzer, or serial terminal.

UART 8N1 Framing (LSB first):
1. **Idle**: Line high (`1`)
2. **Start bit**: `0` (434 cycles)
3. **Data bit 0**: `1` (434 cycles)
4. **Data bit 1**: `0` (434 cycles)
5. **Data bit 2**: `1` (434 cycles)
6. **Data bit 3**: `0` (434 cycles)
7. **Data bit 4**: `1` (434 cycles)
8. **Data bit 5**: `0` (434 cycles)
9. **Data bit 6**: `1` (434 cycles)
10. **Data bit 7**: `0` (434 cycles)
11. **Stop bit**: `1` (434 cycles)
12. **Inter-character pause**: `1` (434 cycles)
13. **Loop**: Repeat

### Microcode Table (ROM Memory)

| Address | Binary (16-bit) | Hex Word | Instruction Equivalent |
| :--- | :--- | :--- | :--- |
| `0x0` | `0011_00_0_110110001` | `16'h31B1` | `SET pin0, 0 [433]` (Start Bit) |
| `0x1` | `0011_00_1_110110001` | `16'h33B1` | `SET pin0, 1 [433]` (Bit 0 = 1) |
| `0x2` | `0011_00_0_110110001` | `16'h31B1` | `SET pin0, 0 [433]` (Bit 1 = 0) |
| `0x3` | `0011_00_1_110110001` | `16'h33B1` | `SET pin0, 1 [433]` (Bit 2 = 1) |
| `0x4` | `0011_00_0_110110001` | `16'h31B1` | `SET pin0, 0 [433]` (Bit 3 = 0) |
| `0x5` | `0011_00_1_110110001` | `16'h33B1` | `SET pin0, 1 [433]` (Bit 4 = 1) |
| `0x6` | `0011_00_0_110110001` | `16'h31B1` | `SET pin0, 0 [433]` (Bit 5 = 0) |
| `0x7` | `0011_00_1_110110001` | `16'h33B1` | `SET pin0, 1 [433]` (Bit 6 = 1) |
| `0x8` | `0011_00_0_110110001` | `16'h31B1` | `SET pin0, 0 [433]` (Bit 7 = 0) |
| `0x9` | `0011_00_1_110110001` | `16'h33B1` | `SET pin0, 1 [433]` (Stop Bit = 1) |
| `0xA` | `0000_00_0_110110001` | `16'h01B1` | `NOP [433]` (Inter-character gap) |
| `0xB` | `1000_0000_00000000` | `16'h8000` | `JMP 0x0` (Repeat) |

---

## 4. Hardware Implementation Plan

### 4.1. Core RTL: `rtl/ProtocolEmulator.v`
* Implements the 16-word microcode ROM.
* State machine:
  * In the active cycle, decodes the instruction word at `rom[pc]`.
  * For `SET`: updates output register and loads `delay_counter <= sidecar_delay`.
  * For `NOP`: loads `delay_counter <= sidecar_delay`.
  * For `JMP`: updates `pc <= target_addr`.
  * While `delay_counter > 0`: decrements counter each clock cycle, freezing `pc`.
  * When `delay_counter == 0`: increments `pc <= pc + 1`.

### 4.2. Physical Top Level: `boards/sipeed/console60k/src/top.v`
* Connects 50 MHz crystal oscillator on Pin `V22`.
* Connects reset button S0 on Pin `AA13`.
* Maps `uart_tx` directly to Pin `U15` (FPGA TX -> BL616 MCU USB-Serial bridge).
* Maps the UART signal in parallel to `o_led[0]` (PMOD1 Pin `D21`) so bit transmission is visible.

---

## 5. Verification Plan

### 5.1. Simulation Testbench (`test_rtl/tb_ProtocolEmulator.v`)
1. Instantiates the core with a 50 MHz clock (20 ns period).
2. Runs for 15,000 clock cycles (~300 microseconds).
3. Verifies that the start bit, 8 data bits, and stop bit each measure exactly $8.68\,\mu\text{s}$ (434 clock cycles) with zero cycle jitter.
4. Generates a `.vcd` waveform file for visual inspection.

### 5.2. Physical Hardware Test on Tang Console 60K
1. Compile bitstream using `.\build_console60k.bat`.
2. Program FPGA SRAM using `.\build_console60k.bat -Flash sram`.
3. Open serial monitor at 115200 baud on the Tang Console 60K COM port.
4. Confirm continuous stream of `'U'` characters received.
