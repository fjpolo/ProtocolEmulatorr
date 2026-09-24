# OmniBus Hardware Glitch / Fault Injector & Active Wire-Speed MitM Engine
## User & Hardware Security Engineer Guide

---

## Table of Contents
1. [Introduction & Purpose](#1-introduction--purpose)
2. [Hardware Architecture & Theory of Operation](#2-hardware-architecture--theory-of-operation)
   - [Glitch Pulse Generator FSM](#glitch-pulse-generator-fsm)
   - [Wire-Speed Pattern Matcher & Trigger Engine](#wire-speed-pattern-matcher--trigger-engine)
   - [Real-Time MitM Stream Mutator](#real-time-mitm-stream-mutator)
3. [Physical Wiring & Bench Setup](#3-physical-wiring--bench-setup)
   - [Voltage Fault Injection (Crowbar / VCC Glitching)](#voltage-fault-injection-crowbar--vcc-glitching)
   - [Clock Fault Injection (Clock Glitching / Muxing)](#clock-fault-injection-clock-glitching--muxing)
   - [Inline Active Wire-Speed Man-in-the-Middle Fuzzing](#inline-active-wire-speed-man-in-the-middle-fuzzing)
4. [Microcode Instruction Set Reference (ISA)](#4-microcode-instruction-set-reference-isa)
   - [Glitch Generator Instructions](#glitch-generator-instructions)
   - [MitM Fuzzing Instructions](#mitm-fuzzing-instructions)
   - [Conditional Branch & Telemetry Instructions](#conditional-branch--telemetry-instructions)
5. [Wishbone B4 Host Integration (`ADDR_GLITCH = 0x24`)](#5-wishbone-b4-host-integration-addr_glitch--0x24)
6. [Practical Recipes & Example Workflows](#6-practical-recipes--example-workflows)
   - [Recipe 1: Crowbar VCC Glitch on Target Password Verification](#recipe-1-crowbar-vcc-glitch-on-target-password-verification)
   - [Recipe 2: Wire-Speed Payload Byte Mutation (Bypassing Signatures / Forcing ACKs)](#recipe-2-wire-speed-payload-byte-mutation-bypassing-signatures--forcing-acks)
   - [Recipe 3: Manual Microcode Software Trigger with Cycle Countdown](#recipe-3-manual-microcode-software-trigger-with-cycle-countdown)
   - [Recipe 4: Wildcard Mask Matching (Command Opcode Isolation)](#recipe-4-wildcard-mask-matching-command-opcode-isolation)
7. [Python Host Automation Scripting](#7-python-host-automation-scripting)
8. [Troubleshooting & Best Practices](#8-troubleshooting--best-practices)

---

## 1. Introduction & Purpose

The **OmniBus Hardware Glitch & Active Wire-Speed MitM Fuzzing Engine** is a dedicated silicon-level security evaluation instrument integrated directly into the OmniBus Protocol Emulator ASIC core.

Traditional fault-injection setups rely on external delay generators, oscilloscopes, or host PC software. These solutions suffer from **USB/host latency jitter (tens of microseconds)**, loose clock-domain synchronization, and cumbersome cabling.

OmniBus solves this by co-locating the **protocol transceiver**, the **wire-speed packet parser**, and the **nanosecond-precision glitch generator** on the **same 50 MHz clock domain**:

* **Zero-Jitter Trigger-on-Match**: Starts pulse countdown within a single clock cycle ($20\text{ ns}$) of detecting a target byte in the live protocol stream.
* **Sub-Cycle Glitch Precision**: Configurable pulse duration from $1$ to $255$ cycles ($20\text{ ns}$ to $5.1\,\mu\text{s}$) with programmable countdown delay from $0$ to $65,535$ cycles ($0$ to $1.31\text{ ms}$).
* **Active In-Flight Payload Mutation**: Dynamically modifies or corrupts data bytes on the fly without stalling the serial bus or interrupting the target microcontroller.
* **Dual Trigger Modes**: Autonomous hardware trigger-on-match or microcode-driven software trigger (`GLITCH_TRIG`).

---

## 2. Hardware Architecture & Theory of Operation

```
                             OMNIBUS ASIC CORE
+----------------------------------------------------------------------------------+
|                                                                                  |
|  Live Serial Stream                                                              |
|  (UART, SPI, I2C, etc.)                                                          |
|       |                                                                          |
|       v                                                                          |
|  [ SERDES RX / TX Engine ]                                                       |
|       |                                                                          |
|       v                                                                          |
|  [ Wire-Speed Pattern Matcher ] <--- mitm_match_byte[7:0] & mitm_mask[7:0]       |
|       |                                                                          |
|       +---------------------------------------------+                            |
|       | (Match Pulse)                               | (Payload Stream)           |
|       v                                             v                            |
|  [ Glitch Generator FSM ]                    [ Wire-Speed Mutator ]              |
|    - Countdown: glitch_timer[15:0]             - Substitute: mitm_replace_byte   |
|    - Pulse Width: glitch_width[7:0]            - Invert: ~payload                |
|    - Polarity: glitch_pol                      - Passthrough (Trigger only)      |
|       |                                             |                            |
|       v                                             v                            |
|  [ Pin Override Mux ]                        [ Modified Stream ]                 |
|  Drives target GPIO pin (0..7)               (o_data / o_tx)                     |
+----------------------------------------------------------------------------------+
        |                                             |
        v                                             v
  Crowbar / Glitch Pulse                        Mutated Frame
  (to Target MCU VCC / Clock)                   (to Target RX)
```

### Glitch Pulse Generator FSM

The glitch generator operates as a deterministic 3-state hardware finite state machine:

```
  +--------------+
  |  STATE_IDLE  | <-----------------------------------------+
  +--------------+                                           |
         |                                                   |
         | Trigger Event (MitM Match Pulse OR GLITCH_TRIG)   |
         v                                                   |
  +--------------+                                           |
  | STATE_DELAY  | (Counts down glitch_timer from delay..1)  |
  +--------------+                                           |
         |                                                   |
         | Countdown reaches 0                               |
         v                                                   |
  +--------------+                                           |
  | STATE_PULSE  | (Asserts glitch pulse on target GPIO pin) |
  +--------------+                                           |
         |                                                   |
         | Pulse duration (glitch_width) completes           |
         +---------------------------------------------------+
           (Sets sticky flag glitch_fired = 1)
```

1. **IDLE (`2'b00`)**: The glitch pin operates under normal microcode or GPIO control. The FSM waits for an arm condition (`glitch_armed == 1`) and a trigger event.
2. **DELAY (`2'b01`)**: The 16-bit hardware counter `glitch_timer` decrements every clock cycle ($20\text{ ns}$ resolution).
3. **PULSE (`2'b10`)**: When `glitch_timer` expires, the target GPIO pin is immediately overridden by hardware:
   - `o_gpio_oe[glitch_pin] = 1'b1` (driven active).
   - If `glitch_pol == 0` (Active-High): `o_gpio[glitch_pin] = 1'b1`.
   - If `glitch_pol == 1` (Active-Low Crowbar): `o_gpio[glitch_pin] = 1'b0`.
   - The pin remains in this state for exactly `glitch_width` clock cycles.
   - Upon completion, `glitch_fired` is asserted high (sticky flag), and the pin returns to its default state.

### Wire-Speed Pattern Matcher & Trigger Engine

The pattern matcher continuously evaluates:
* **Inbound Stream (`IN`)**: Evaluated at the exact clock cycle when the 8th bit of a deserialized byte is sampled (`rx_bit_cnt == 1`, `delay_cnt == 0`).
* **Outbound Stream (`PULL`)**: Evaluated at the clock cycle when a byte is transferred from the TX FIFO into the `OSR` for transmission.

The match condition evaluates with zero latency:
$$\text{match} = \text{mitm\_en} \land \left( (\text{stream\_byte} \ \& \ \text{mitm\_mask}) == (\text{mitm\_match\_byte} \ \& \ \text{mitm\_mask}) \right)$$

When `match == 1`:
* Sticky flag `mitm_match_found` is latched to `1`.
* Telemetry counter `mitm_match_count` increments.
* If `glitch_armed && glitch_on_match`, the glitch FSM initiates its delay countdown immediately on that same clock edge.

### Real-Time MitM Stream Mutator

When a pattern match occurs and `mitm_en == 1`, the mutator handles the byte according to `mitm_mode`:
* **Mode `00` (Trigger Only)**: The byte passes through unaltered; only the glitch trigger and status flags fire.
* **Mode `01` (Substitute)**: The byte is replaced in real time with `mitm_replace_byte[7:0]`.
  - For `IN`: `isr <= mitm_replace_byte`.
  - For `PULL`: `osr <= mitm_replace_byte`.
* **Mode `10` (Bitwise Invert)**: The byte is inverted on-the-fly (`~payload`).

---

## 3. Physical Wiring & Bench Setup

### Voltage Fault Injection (Crowbar / VCC Glitching)

In Voltage Fault Injection (VFI), a rapid low-impedance pulldown transient drops the target microcontroller's $V_{DD}$ rail below its minimum operating voltage for tens of nanoseconds, causing CPU instruction decoding faults or skipped branch checks (e.g. bypassing `BNE` / password verification):

```
       +3.3V / +1.2V Power Supply
                   |
             [Shunt Resistor / Inductor (10 - 50 Ohm)]
                   |
                   +-------------------------> Target MCU VDD Rail
                   |
                   | Drain
             [ N-Channel MOSFET ] (e.g. CSD16301Q2 / AO3400A)
                   | Gate
                   |
                   +-------[ 22 Ohm ]<-------- OmniBus GPIO Pin (e.g. Pin 4)
                   |                           (Configured as Active-High: pol=0)
                   | Source
                  GND
```

* **Recommended Pin**: Use **GPIO 4** or **GPIO 3** (defaults to High-Z on reset).
* **Polarity**: Use `pol = 0` (Active-High pulse turns on N-MOSFET to short VDD to GND).
* **Pulse Duration**: Typically 2 to 8 clock cycles ($40\text{ ns}$ to $160\text{ ns}$ @ $50\text{ MHz}$).

### Clock Fault Injection (Clock Glitching / Muxing)

In Clock Fault Injection (CFI), an abnormally narrow clock pulse or missing edge is inserted into the target MCU's clock line, violating the setup time of critical internal flip-flops:

```
  Normal Target Clock ----------------\
                                       MUX (e.g. 74LVC1G3157) ---> Target MCU EXTCLK
  OmniBus Glitch Pin (Pin 3) ---------/
                                       ^
                                       | Select Line (OmniBus Pin 4)
```

Alternatively, direct clock driving:
* Connect OmniBus `glitch_pin` directly to the target external clock input pin.
* Generate normal clock bursts via microcode, and fire a single sub-cycle glitch pulse using `GLITCH_WIDTH 1`.

### Inline Active Wire-Speed Man-in-the-Middle Fuzzing

To transparently fuzz or alter data exchanged between a Host Controller and a Target Device:

```
  Host TX Line --------> OmniBus Pin 0 (RX) [Deserializer + MitM Mutator]
                         OmniBus Pin 1 (TX) [Serializer Echo] --------> Target RX Line

  Target TX Line ------> Host RX Line (or monitored through OmniBus Pin 2)
```

The OmniBus microcode runs a low-latency echo loop (`IN 8, $BAUD` $\to$ `PUSH` $\to$ `OUT 8, $BAUD`). When the designated match pattern passes through, OmniBus automatically swaps the byte and transmits the mutated payload to the target.

---

## 4. Microcode Instruction Set Reference (ISA)

All Glitch and MitM instructions are single-cycle microcode operations encoded under Opcode `4'hF` (`ASSIST`) and `4'h8` (`JMP`).

### Glitch Generator Instructions

#### `GLITCH_CFG <pin>, <pol>`
Configures the target output pin and active pulse polarity.
* **Syntax**: `GLITCH_CFG pin, pol`
* **Operands**:
  - `pin`: GPIO pin index (`0` to `7`).
  - `pol`: Active polarity:
    - `0`: Active-High (line idle Low, pulses High).
    - `1`: Active-Low Crowbar (line idle High, pulses Low).
* **Example**:
  ```assembly
  GLITCH_CFG 4, 1   ; Target GPIO 4, active-Low crowbar
  ```

#### `GLITCH_WIDTH <width>`
Sets the duration of the glitch pulse.
* **Syntax**: `GLITCH_WIDTH width`
* **Operands**:
  - `width`: Direct integer (`1` to `15`), or omit to load 8-bit value from accumulator `acc` ($1$ to $255$ cycles).
* **Resolution**: $20\text{ ns}$ per count @ $50\text{ MHz}$.
* **Example**:
  ```assembly
  GLITCH_WIDTH 5    ; Pulse width = 5 cycles (100 ns)
  ```
  *For widths > 15 cycles:*
  ```assembly
  MOV acc, 45
  GLITCH_WIDTH      ; Pulse width = 45 cycles (900 ns)
  ```

#### `GLITCH_DELAY <delay>`
Sets the countdown delay between trigger detection and pulse assertion.
* **Syntax**: `GLITCH_DELAY delay`
* **Operands**:
  - `delay`: Direct integer (`1` to `15`), or omit to load 16-bit countdown from accumulator `acc`.
* **Example**:
  ```assembly
  GLITCH_DELAY 10   ; Wait 10 cycles (200 ns) after trigger before firing
  ```

#### `GLITCH_ARM <mode>`
Arms the glitch generator state machine.
* **Syntax**: `GLITCH_ARM mode`
* **Operands**:
  - `0`: Manual / Software Trigger mode (waits for `GLITCH_TRIG` instruction).
  - `1`: Autonomous Trigger-on-Match mode (fires countdown automatically on MitM pattern match).
* **Example**:
  ```assembly
  GLITCH_ARM 1      ; Arm autonomous trigger-on-match
  ```

#### `GLITCH_DISARM`
Immediately disarms the glitch generator and aborts any pending countdown.
* **Syntax**: `GLITCH_DISARM`

#### `GLITCH_TRIG`
Manually initiates the glitch countdown timer from microcode.
* **Syntax**: `GLITCH_TRIG`
* **Example**:
  ```assembly
  GLITCH_ARM 0      ; Arm for manual trigger
  NOP 5
  GLITCH_TRIG       ; Start glitch countdown immediately
  ```

---

### MitM Fuzzing Instructions

#### `MITM_MATCH`
Loads the 8-bit target comparison byte from the accumulator.
* **Syntax**: `MITM_MATCH`
* **Operands**: Implicitly uses `acc`.
* **Example**:
  ```assembly
  MOV acc, 0xA5
  MITM_MATCH        ; Match target byte 0xA5
  ```

#### `MITM_REPLACE`
Loads the 8-bit replacement byte from the accumulator.
* **Syntax**: `MITM_REPLACE`
* **Operands**: Implicitly uses `acc`.
* **Example**:
  ```assembly
  MOV acc, 0x58     ; ASCII 'X'
  MITM_REPLACE      ; Substitute matching byte with 0x58
  ```

#### `MITM_MASK`
Loads the 8-bit comparison bitmask from the accumulator.
* **Syntax**: `MITM_MASK`
* **Operands**: Implicitly uses `acc` (`1` = compare bit, `0` = wildcard/don't care).
* **Example**:
  ```assembly
  MOV acc, 0xF0
  MITM_MASK         ; Match upper nibble only (lower nibble is don't care)
  ```

#### `MITM_ENABLE`
Enables the wire-speed pattern matcher and byte substitution engine.
* **Syntax**: `MITM_ENABLE`

#### `MITM_DISABLE`
Disables pattern matching and restores normal transparent passthrough.
* **Syntax**: `MITM_DISABLE`

#### `MITM_CLR`
Resets the sticky `mitm_match_found` flag and clears the match event counter to zero.
* **Syntax**: `MITM_CLR`

---

### Conditional Branch & Telemetry Instructions

#### `JMP GLITCH_DONE, <target>`
Jumps to `<target>` if the glitch pulse has fired and completed (`glitch_fired == 1`).
* **Condition Code**: `4'hC`
* **Example**:
  ```assembly
wait_glitch:
  JMP GLITCH_DONE, glitch_finished
  JMP wait_glitch
glitch_finished:
  ```

#### `JMP MATCH_FOUND, <target>`
Jumps to `<target>` if a pattern match has been detected (`mitm_match_found == 1`).
* **Condition Code**: `4'hD`
* **Example**:
  ```assembly
  JMP MATCH_FOUND, handle_attack_payload
  ```

#### `ASSIST READ, GLITCH`
Reads the live glitch and MitM status byte directly into `acc`:
* **Bitfield**:
  - `acc[7]`: `mitm_match_found`
  - `acc[6]`: `glitch_fired`
  - `acc[5]`: `glitch_armed`
  - `acc[4]`: `glitch_active`
  - `acc[3]`: Reserved (`0`)
  - `acc[2:0]`: `glitch_pin[2:0]`

---

## 5. Wishbone B4 Host Integration (`ADDR_GLITCH = 0x24`)

When OmniBus is integrated into an SoC (e.g. alongside a RISC-V or ARM host processor), software can monitor telemetry and verify glitch status via Wishbone address `0x24`:

```
 31                  24 23                  16 15                   8 7   6   5   4   3   2      0
+----------------------+----------------------+----------------------+---+---+---+---+---+--------+
|   mitm_match_count   |     glitch_timer     |  mitm_replace_byte   | F | M | A | G | P |  PIN   |
+----------------------+----------------------+----------------------+---+---+---+---+---+--------+
```

| Bitfield | Name | Access | Description |
| :--- | :--- | :--- | :--- |
| `[31:24]` | `mitm_match_count` | RO | Total number of pattern match events detected (0 to 255). |
| `[23:16]` | `glitch_timer[7:0]` | RO | Lower 8 bits of live countdown timer (0 when idle). |
| `[15:8]` | `mitm_replace_byte` | RO | Configured replacement byte currently active. |
| `[7]` | `glitch_fired` | RO | Sticky flag: `1` when glitch pulse has completed. |
| `[6]` | `mitm_match_found` | RO | Sticky flag: `1` when pattern match has occurred. |
| `[5]` | `glitch_armed` | RO | Arm status: `1` when engine is armed. |
| `[4]` | `glitch_active` | RO | Active status: `1` during countdown or pulse output. |
| `[3]` | `glitch_pol` | RO | Configured polarity: `0`=Active High, `1`=Active Low. |
| `[2:0]` | `glitch_pin` | RO | Configured target GPIO pin (0..7). |

---

## 6. Practical Recipes & Example Workflows

### Recipe 1: Crowbar VCC Glitch on Target Password Verification

**Objective**: Target MCU firmware executes `if (strcmp(input, password) == 0)` after receiving the string `PASS`. We inject an active-High crowbar pulse on GPIO 4 exactly 14 clock cycles after the last byte of `PASS` is received to corrupt the branch decision.

```assembly
; =============================================================================
; Recipe 1: VCC Glitch Triggered on Inbound 'S' of "PASS"
; =============================================================================

    ; 1. Configure Glitch Output on Pin 4, Active-High (N-MOSFET Crowbar)
    GLITCH_CFG 4, 0

    ; 2. Set glitch pulse width: 3 clock cycles (60 ns @ 50 MHz)
    GLITCH_WIDTH 3

    ; 3. Set delay: 14 clock cycles (280 ns) to hit the branch instruction
    GLITCH_DELAY 14

    ; 4. Match character 'S' (0x53)
    MOV acc, 0x53
    MITM_MATCH
    MOV acc, 0xFF
    MITM_MASK

    ; 5. Enable MitM in Trigger-Only Mode (Mode 00: Do not corrupt the payload)
    MITM_ENABLE

    ; 6. Arm Glitch Generator to fire on match
    GLITCH_ARM 1

echo_loop:
    WAIT 0, 0, $HBAUD
    NOP $BAUD
    IN 8, $BAUD           ; Deserializes byte; on 'S', hardware starts 14-cycle countdown
    WAIT 0, 1, 0
    PUSH
    OUT 8, $BAUD

    ; Check if glitch completed
    JMP GLITCH_DONE, glitch_fired_handler
    JMP echo_loop

glitch_fired_handler:
    ; Target MCU should now be in unlocked state
halt:
    JMP halt
```

---

### Recipe 2: Wire-Speed Payload Byte Mutation (Bypassing Signatures / Forcing ACKs)

**Objective**: An embedded peripheral returns a negative acknowledge status byte (`0x15` / NAK). We transparently mutate it to an acknowledge (`0x06` / ACK) in-flight before the host CPU sees it.

```assembly
; =============================================================================
; Recipe 2: Real-Time Byte Mutation (0x15 NAK -> 0x06 ACK)
; =============================================================================

    ; Set match target to NAK (0x15)
    MOV acc, 0x15
    MITM_MATCH

    ; Set replacement byte to ACK (0x06)
    MOV acc, 0x06
    MITM_REPLACE

    ; Exact match on all 8 bits
    MOV acc, 0xFF
    MITM_MASK

    ; Enable wire-speed mutation
    MITM_ENABLE

transceiver_loop:
    WAIT 0, 0, $HBAUD
    NOP $BAUD
    IN 8, $BAUD           ; If input byte is 0x15, ISR is automatically replaced with 0x06!
    WAIT 0, 1, 0
    PUSH                  ; RX FIFO receives 0x06 (Host CPU sees valid ACK!)
    JMP transceiver_loop
```

---

### Recipe 3: Manual Microcode Software Trigger with Cycle Countdown

**Objective**: Microcode executes a complex diagnostic or testbench sequence and fires a calibrated 4-cycle active-Low pulse on GPIO 3 after an exact 20-cycle delay.

```assembly
; =============================================================================
; Recipe 3: Software-Triggered Calibrated Pulse
; =============================================================================

    GLITCH_CFG 3, 1       ; Target GPIO 3, Active-Low pulse
    GLITCH_WIDTH 4        ; 4 clock cycles (80 ns)
    GLITCH_DELAY 20       ; 20 clock cycles delay (400 ns)
    GLITCH_ARM 0          ; Arm for manual trigger

    NOP 10                ; Microcode work
    GLITCH_TRIG           ; Fire hardware countdown!

wait_completion:
    JMP GLITCH_DONE, done ; Tight loop until glitch finishes
    JMP wait_completion

done:
    ; Glitch pulse is finished
    NOP 1
```

---

### Recipe 4: Wildcard Mask Matching (Command Opcode Isolation)

**Objective**: Match any write command packet starting with nibble `0x3_` (e.g. `0x30`, `0x31`, `0x3A`), ignoring the lower 4 bits (which represent sub-register addresses).

```assembly
; =============================================================================
; Recipe 4: Wildcard Nibble Matching
; =============================================================================

    MOV acc, 0x30
    MITM_MATCH            ; Match base pattern 0x30

    MOV acc, 0xF0
    MITM_MASK             ; Mask: upper 4 bits must match '3', lower 4 bits wildcard

    MITM_ENABLE
    GLITCH_ARM 1          ; Trigger glitch whenever ANY 0x3x write packet arrives
```

---

## 7. Python Host Automation Scripting

When controlling OmniBus via a serial bootloader or Wishbone over USB-UART bridge, you can use Python to automate parameter sweeps (e.g. glitch delay vs. width):

```python
import serial
import time

ser = serial.Serial('COM5', 115200, timeout=1.0)

def sweep_glitch_parameters(target_byte, min_delay, max_delay, min_width, max_width):
    """Automates a 2D fault-injection parameter sweep across delay and width."""
    for delay in range(min_delay, max_delay + 1):
        for width in range(min_width, max_width + 1):
            print(f"[SWEEP] Testing Delay={delay} cycles ({delay*20} ns), Width={width} cycles ({width*20} ns)...")
            
            # Generate microcode dynamically
            asm = f"""
            GLITCH_CFG 4, 1
            GLITCH_WIDTH {width}
            GLITCH_DELAY {delay}
            MOV acc, 0x{target_byte:02X}
            MITM_MATCH
            MOV acc, 0xFF
            MITM_MASK
            MITM_ENABLE
            GLITCH_ARM 1
        rx_loop:
            WAIT 0, 0, $HBAUD
            NOP $BAUD
            IN 8, $BAUD
            WAIT 0, 1, 0
            PUSH
            OUT 8, $BAUD
            JMP GLITCH_DONE, success
            JMP rx_loop
        success:
            JMP success
            """
            
            # Compile and load into OmniBus IMEM via bootloader
            # ... (load hex into FPGA) ...
            
            # Send trigger payload to target and observe if exploit succeeded
            ser.write(bytes([target_byte]))
            response = ser.read(16)
            
            if b"UNLOCKED" in response:
                print(f"[!] SUCCESS! Exploit found at Delay={delay}, Width={width}")
                return (delay, width)

    print("[-] Sweep completed. No fault observed.")
    return None

if __name__ == '__main__':
    sweep_glitch_parameters(target_byte=0x53, min_delay=5, max_delay=30, min_width=2, max_width=8)
```

---

## 8. Troubleshooting & Best Practices

1. **Target Pin Reset Defaults**:
   - Note that **Pin 2 (CS#)** defaults to driven High (`o_gpio_oe[2]=1`, `o_gpio[2]=1`) to keep SPI flash unselected upon reset.
   - For active-High glitch pulses, prefer **Pin 3, 4, 5, 6, or 7**, which default to High-Z (input) upon reset.
2. **Ground Bounce & Shunt Resistance**:
   - Crowbar glitching creates large transient currents ($>1\text{ A}$). Ensure **solid ground bonding** with thick, short ground leads between OmniBus and the target MCU to prevent false resets or ground bounce.
3. **Minimum Glitch Width**:
   - At $50\text{ MHz}$, $1$ cycle $= 20\text{ ns}$. Most modern microcontrollers (ARM Cortex-M, RISC-V) with on-chip decoupling capacitors require at least **2 to 4 cycles ($40\text{ ns}$ to $80\text{ ns}$)** of pulldown to overcome the bypass capacitance.
4. **Decoupling Capacitor Removal**:
   - When performing VCC crowbar glitching, remove or reduce the target MCU's decoupling capacitors on the core voltage rail (e.g. replace $1\,\mu\text{F}$ caps with $10\text{ nF}$ or wire directly after an isolation ferrite bead).
5. **Checking Glitch Fired Status**:
   - Always read back status via `JMP GLITCH_DONE` in microcode or register `0x24` (`ADDR_GLITCH`) over Wishbone to confirm the pulse actually fired before analyzing target responses.
