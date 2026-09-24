# Task 17 — Autonomous Stream Accelerators: NRZI & Hardware Bit-Stuffer/De-stuffer

## 1. Overview & Motivation

In high-speed and edge-synchronized physical layers such as **USB 1.1** (Full Speed 12 Mbps / Low Speed 1.5 Mbps) and **CAN 2.0A/B** (up to 1 Mbps), signals require physical-layer stream transformations:
1. **NRZI (Non-Return-to-Zero Inverted) Modulation**: Encodes '0' as a line state toggle and '1' as holding current state. This embeds clock transitions directly into data lines.
2. **Autonomous Bit-Stuffing (TX)**: Consecutive runs of identical bits would cause clock recovery PLLs to lose synchronization.
   - **USB 1.1**: Inserts a complementary `'0'` bit after 6 consecutive `'1'`s.
   - **CAN 2.0**: Inserts an inverted complement bit after 5 consecutive identical bits.
3. **Autonomous Bit-Destuffing (RX)**: Transparently removes stuffed bits before assembling bytes into the Input Shift Register (`ISR`), detecting illegal bit-stuffing framing violations in hardware.

Performing bit-stuffing and NRZI in microcode software loops would require multiple clock cycles per bit, severely limiting maximum baud rates and consuming program memory. **Task 17 offloads these stream transformations entirely to autonomous hardware stream accelerators within the serializer and deserializer pipelines**.

---

## 2. Hardware Architecture & Register Specification

The Stream Accelerator operates as a zero-latency pipeline stage between the core serializer/deserializer and the physical I/O pins (`tx_pin`, `rx_pin`):

```
TX Pipeline:
[OSR / Byte] ---> [Serializer] ---> [Bit-Stuffer] ---> [NRZI Encoder] ---> o_tx / gpio_out

RX Pipeline:
i_rx / gpio_in ---> [Input Sync] ---> [NRZI Decoder] ---> [Bit-Destuffer] ---> [Deserializer] ---> [ISR]
                                                                |
                                                                +---> [stuff_error Flag] ---> JMP STUFF_ERR
```

### Accelerator Registers (`ProtocolEmulator.v`)

| Register | Width | Reset | Description |
| :--- | :--- | :--- | :--- |
| `assist_nrzi_en` | 1 bit | `1'b0` | `1` = Enable NRZI encoding on TX and decoding on RX |
| `assist_stuff_mode` | 2 bits | `2'b00` | `00` = Disabled, `01` = USB 1.1 mode, `10` = CAN 2.0 mode |
| `nrzi_tx_state` | 1 bit | `1'b1` | Current NRZI TX line level (Idle High = 1) |
| `nrzi_rx_prev` | 1 bit | `1'b1` | Previous RX line sample for NRZI edge detection |
| `tx_stuff_cnt` | 3 bits | `3'd0` | TX consecutive identical bit counter |
| `rx_stuff_cnt` | 3 bits | `3'd0` | RX consecutive identical bit counter |
| `tx_last_bit` | 1 bit | `1'b1` | Previous TX bit transmitted (used for CAN mode) |
| `rx_last_bit` | 1 bit | `1'b1` | Previous RX bit received (used for CAN mode) |
| `stuff_error` | 1 bit | `1'b0` | Latch flag set on bit-stuff framing violation |

---

## 3. Instruction Set Architecture Updates

### A. Opcode `0xF` — Stream Accelerator Control (`ASSIST`)

The new 16-bit instruction format allocates Opcode `4'hF`:

```
15:12 = 4'hF (ASSIST Opcode)
11:10 = Sub-operation:
        2'b00 : ASSIST CFG
        2'b01 : ASSIST RESET
        2'b10 : ASSIST READ
```

#### 1. `ASSIST CFG, NRZI=<0|1>, STUFF=<0|USB|CAN> [, INIT=<0|1>]`
- **Encoding**: `16'b1111_00_II_SS_NNNNNNNN`
  - `instr[7:6]`: `INIT` line state (`2'b00`=Low, `2'b10`=High)
  - `instr[5:4]`: `STUFF` mode (`2'b00`=Off, `2'b01`=USB 1.1, `2'b10`=CAN 2.0)
  - `instr[0]`: `NRZI` enable (`1`=Enable, `0`=Bypass)
- **Action**: Configures stream accelerator modes and initializes line state.

#### 2. `ASSIST RESET`
- **Encoding**: `16'hF400`
- **Action**: Resets `tx_stuff_cnt`, `rx_stuff_cnt`, and clears `stuff_error` without altering mode configurations.

#### 3. `ASSIST READ`
- **Encoding**: `16'hF800`
- **Action**: Reads status into accumulator:
  - `acc[0]`: `stuff_error`
  - `acc[1]`: `assist_nrzi_en`
  - `acc[3:2]`: `assist_stuff_mode`
  - `acc[7:4]`: `4'b0000`

### B. Hardware Conditional Jump on Stuffing Error (`JMP STUFF_ERR`)

- **Condition Code**: `4'hF` (15) in Opcode `0x8` (`JMP`).
- **Mnemonic**: `JMP STUFF_ERR, <target>` (aliases: `STUFF_ERROR`, `STUFF_BAD`).
- **Action**: Branches to `<target>` if `stuff_error == 1'b1`; falls through to `pc + 1` otherwise.

---

## 4. Autonomous Serializer & Deserializer Operation

### A. Transmission (`OUT`)
1. **USB 1.1 Bit-Stuffing**:
   - The serializer tracks consecutive `'1'`s via `tx_stuff_cnt`.
   - When `tx_stuff_cnt == 6`, the serializer pauses payload transmission, emits a stuffed `'0'`, resets `tx_stuff_cnt <= 0`, and delays for `eff_delay` cycles.
   - Microcode execution remains paused on `OUT` until the full frame (payload + stuffed bits) finishes.
2. **CAN 2.0 Bit-Stuffing**:
   - The serializer tracks consecutive identical bits (`tx_last_bit`).
   - When `tx_stuff_cnt == 5`, an inverted bit (`~tx_last_bit`) is autonomously emitted.
3. **NRZI Encoding**:
   - Bits from the stuffer pass to the NRZI modulator:
     - Bit `'0'`: Toggles `nrzi_tx_state <= ~nrzi_tx_state`.
     - Bit `'1'`: Holds `nrzi_tx_state <= nrzi_tx_state`.

### B. Reception (`IN`)
1. **NRZI Decoding**:
   - Combinational transition detector: `nrzi_rx_bit = (gpio_in[rx_pin] == nrzi_rx_prev) ? 1'b1 : 1'b0;`
2. **USB 1.1 Bit-Destuffing**:
   - When `rx_stuff_cnt == 6`:
     - If incoming bit is `'0'`, it is discarded as a stuff bit; `rx_stuff_cnt <= 0`; payload counter is not decremented.
     - If incoming bit is `'1'`, a protocol violation has occurred (7 consecutive ones); sets `stuff_error <= 1'b1`.
3. **CAN 2.0 Bit-Destuffing**:
   - When `rx_stuff_cnt == 5`:
     - Discards complement bit.
     - Asserts `stuff_error <= 1'b1` on 6th identical bit.

---

## 5. Verification & Test Suite

### A. Cocotb Simulation Testbench (43 Tests, 100% Pass)
Located in `test_rtl/simulation/cocotb/ProtocolEmulator/testbench.py`:
- `test_assist_nrzi_tx_rx`: Verifies NRZI TX toggling on '0' and holding on '1' for test vector `0x96` (`[0, 0, 0, 1, 1, 0, 1, 1]`).
- `test_assist_usb_bit_stuffing_tx`: Verifies autonomous insertion of '0' after 6 consecutive 1s on byte `0x7E` (`[0, 1, 1, 1, 1, 1, 1, 0, 0]`).
- `test_assist_usb_bit_destuffing_rx`: Verifies transparent stripping of stuffed '0' bit during RX and assembly of pristine `0x7E` into `ISR`.
- `test_assist_usb_stuff_error`: Injects 7 consecutive ones into RX and verifies `stuff_error == 1` and `JMP STUFF_ERR` branch taken.
- `test_assist_can_bit_stuffing`: Verifies CAN 2.0 inversion stuffing after 5 identical bits.

### B. Formal Verification (`properties.v`)
- Formal assertions verify reset states, bit-stuff counters, and branching behavior across bounded model checking (BMC).

---

## 6. Demo & Tooling

- **Assembler**: `python/omnibus_asm.py` supports `ASSIST CFG`, `ASSIST RESET`, `ASSIST READ`, and `JMP STUFF_ERR`.
- **USB Example**: `examples/usb_packet_demo.asm` demonstrates complete USB 1.1 packet transmission (SYNC, PID, DATA0 with bit-stuffing).
- **Batch Runners**:
  - `run_usb_demo.bat` (and alias `run_usb.bat`): Full-featured script for simulation, formal verification, IMEM dumping, and FPGA hardware testing.
