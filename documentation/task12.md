# Task 12: 1-Wire (OneWire) Protocol & Hardware Serializer/Deserializer

## 1. Overview & Architectural Motivation
The **Dallas / Maxim 1-Wire (OneWire)** bus is an asynchronous, single-wire bidirectional interface widely used in IoT and industrial hardware (e.g. Dallas DS18B20 digital temperature sensors, DS2431 1024-bit EEPROMs, DS1990A iButtons).

Unlike UART (point-to-point, dual unidirectional lines) or SPI/I2C (clocked multi-wire buses):
1. **Single-Wire Bidirectional Open-Drain**: Both master and slave share a single data line (`DQ`) pulled high by an external $4.7\text{ k}\Omega$ pull-up resistor.
2. **Master-Initiated Time Slots**: Every bit transfer (whether Master Write or Master Read) is initiated by the master pulling `DQ` low.
3. **LSB-First Serialization**: Data is shifted least-significant bit first.
4. **Strict Bit Timing**:
   - **Write 1 Slot**: Short low pulse ($1 \text{ to } 15\,\mu\text{s}$), then release line high for remainder of $60\,\mu\text{s}$ slot.
   - **Write 0 Slot**: Long low pulse ($60 \text{ to } 120\,\mu\text{s}$), then release line high for $1\,\mu\text{s}$ recovery.
   - **Read Slot**: Master pulls line low for $1 \text{ to } 15\,\mu\text{s}$, releases line, and samples at $\sim 12\text{--}15\,\mu\text{s}$ from slot start while slave either holds low ('0') or leaves released ('1').
   - **Reset / Presence**: Master pulls line low for $\ge 480\,\mu\text{s}$, releases line, and detects slave pulling line low for $60\text{--}240\,\mu\text{s}$.

Task 12 enhances the OmniBus engine with **native hardware 1-Wire serialization/deserialization** and a **16-bit delay counter**, enabling microcode to communicate with 1-Wire slaves with cycle-accurate timing and zero instruction overhead.

---

## 2. 16-Bit Delay Counter Expansion

In previous tasks, the sidecar delay counter `delay_cnt` was 9 bits wide (`[8:0]`), capping delays at 511 clock cycles ($10.22\,\mu\text{s}$ at $50\text{ MHz}$).
Task 12 widens `delay_cnt` and resolved delay signals `eff_delay` and `eff_sw_delay` to **16 bits**:

$$\text{delay\_cnt} \in [0, 65535] \implies \text{Up to } 1.31\text{ ms at } 50\text{ MHz}$$

- `$BAUD` sentinel (`9'h1FF` or `8'hFF`) decodes to the full 16-bit input port `i_baud_div[15:0]`.
- `$HBAUD` sentinel (`9'h1FE` or `8'hFE`) decodes to `i_baud_div[15:0] >> 1`.
- Enables native generation of the $480\,\mu\text{s}$ 1-Wire reset pulse (`SET 0, 0, $BAUD` with `i_baud_div = 24000` at $50\text{ MHz}$) and low-baud UART (e.g. 9600 baud = 5,208 cycles).

---

## 3. ISA Opcode Extensions

### Opcode `0x1`: `OUT 1W, [bit_count,] delay`
- **Machine Word Encoding**:
  - `instr[15:12] = 4'h1` (OUT opcode)
  - `instr[11:10] = 2'b10` (1-Wire Mode)
  - `instr[9]`: Bit count mode (`0` = 8-bit byte transfer, `1` = 1-bit single slot for Search ROM)
  - `instr[8:0]`: Sidecar short-pulse delay $T_{\text{SHORT}}$ (`eff_delay`)

#### Bit Timing Generator (Zero Jitter)
Each bit slot lasts exactly $11 \times T_{\text{SHORT}}$ clock cycles:
- **Phase 0 (Drive Low)**:
  - `gpio_out_reg[tx_pin] <= 0; gpio_oe_reg[tx_pin] <= 1;`
  - If `osr[0] == 1` (Write 1): held low for $1 \times T_{\text{SHORT}}$ (`eff_delay`).
  - If `osr[0] == 0` (Write 0): held low for $10 \times T_{\text{SHORT}}$ (`eff_delay_10x`).
- **Phase 1 (Release High & Recovery)**:
  - `gpio_out_reg[tx_pin] <= 1; gpio_oe_reg[tx_pin] <= 0;` (Open-drain Hi-Z)
  - If `osr[0] == 1`: released high for $10 \times T_{\text{SHORT}}$ (`eff_delay_10x`).
  - If `osr[0] == 0`: released high for $1 \times T_{\text{SHORT}}$ (`eff_delay`).
  - Shift `osr <= {1'b0, osr[7:1]}`.

---

### Opcode `0x2`: `IN 1W, [bit_count,] delay`
- **Machine Word Encoding**:
  - `instr[15:12] = 4'h2` (IN opcode)
  - `instr[11:10] = 2'b10` (1-Wire Mode)
  - `instr[9]`: Bit count mode (`0` = 8-bit byte read, `1` = 1-bit single slot)
  - `instr[8:0]`: Sidecar short-pulse delay $T_{\text{SHORT}}$ (`eff_delay`)

#### Read Slot Generator (3-Phase Sampling)
- **Phase 0 (Master Pull-Down)**:
  - Master pulls line low for $1 \times T_{\text{SHORT}}$ (`eff_delay`).
- **Phase 1 (Release & Settle)**:
  - Master releases line to Hi-Z (`out=1, oe=0`) and waits $1 \times T_{\text{SHORT}}$ for slave to assert line low (if slave sending 0) or pull-up to maintain high (if slave sending 1).
- **Phase 2 (Sample & Recovery)**:
  - At $2 \times T_{\text{SHORT}}$ from slot start (optimal $\sim 12\,\mu\text{s}$ sampling window):
    $$\text{isr} \le \{\text{gpio\_in}[\text{rx\_pin}], \text{isr}[7:1]\}$$
  - Line remains released for $9 \times T_{\text{SHORT}}$ (`eff_delay_9x`) to complete the slot and allow recovery time.

---

## 4. Summary of Supported Protocols on OmniBus

| Protocol | Line Count | Physical Pins | Direction / Duplex | Opcode Modes |
| :--- | :---: | :--- | :--- | :--- |
| **UART** | 2 | TX, RX | Full-Duplex Asynchronous | `OUT delay`, `IN [N,] delay` |
| **SPI** | 3--4 | SCK, MOSI, MISO, CS_n | Full-Duplex Synchronous | `OUT SCK, delay`, `IN SCK, delay` |
| **I2C** | 2 | SCL, SDA | Half-Duplex Open-Drain | `OUT SDA, delay`, `IN SDA, delay` |
| **1-Wire** | 1 | DQ (Bidirectional) | Half-Duplex Open-Drain | `OUT 1W, delay`, `IN 1W, delay` |
