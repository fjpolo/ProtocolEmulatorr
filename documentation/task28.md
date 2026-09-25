# Task 28: USB 1.1 Autonomous Serial Interface Engine (SIE)

## 1. Executive Summary

**Task 28** integrates an autonomous, full-hardware **USB 1.1 Serial Interface Engine (SIE)** into the OmniBus architecture. Prior to Task 28, USB communication required bit-by-bit software emulation and bit-stuffing loop control. With the Autonomous USB SIE, OmniBus can emulate full-speed (12 Mbps) and low-speed (1.5 Mbps) USB peripherals with zero CPU overhead for packet-level processing:
- **Differential Line Encoding & Recovery**: Direct physical decoding of `D+` and `D-` lines into J, K, Single-Ended Zero (SE0), and Single-Ended One (SE1) states.
- **Autonomous SYNC & PID Verification**: Automatically locks onto the leading sync byte (`0x80`), deserializes the 8-bit Packet Identifier (PID), and verifies the inverted complement field (`PID[7:4] == ~PID[3:0]`).
- **Token Decoding & Device Address Filtering**: Hardware extraction of 7-bit Device Address (`ADDR`), 4-bit Endpoint (`ENDP`), and residual checking against the CRC-5 token polynomial. Inbound packets matching `i_dev_addr` trigger immediate token capture and status interrupts.
- **Hardware Data CRC-16 Engine**: Automatically computes and checks the 16-bit CRC ($G(x) = x^{16} + x^{15} + x^2 + 1$, reflected polynomial `0xA001`, residual `0xB001`) across payload bytes on both TX and RX.
- **Autonomous Handshake Generation**: High-speed automatic hardware generation of `ACK`, `NAK`, and `STALL` handshake responses with sub-microsecond turnaround time, satisfying USB 1.1 inter-packet delay specifications ($2 \text{ to } 6.5 \text{ bit periods}$).
- **Bus Reset & EOP Detection**: Autonomous detection of sustained SE0 ($\ge 32$ bit times) indicating USB Bus Reset, and valid End-of-Packet (EOP) framing detection (2 SE0 bit times followed by 1 J-state bit).

Both microcode execution (via dedicated `USB_*` instructions and `ASSIST READ` targets) and host software (via Wishbone B4 slave registers `0x60..0x6C`) have full access to configure, transmit, and monitor USB bus activity.

---

## 2. Hardware Architecture (`rtl/OmniBus_USB_SIE.v`)

```
               +-------------------------------------------------------+
               |                  OmniBus_USB_SIE                      |
               |                                                       |
i_dp (Pin 0) ->|--+--> [ Double-Flop Synchronizer ]                    |
i_dm (Pin 1) ->|  |                   |                                |
               |  |       [ Differential Line Decoder ]                |
               |  |        (J, K, SE0, SE1 Line States)                |
               |  |                   |                                |
               |  |     +-------------+-------------+                  |
               |  |     |                           |                  |
               |  |  [Bus Reset Monitor]    [NRZI & Bit-Destuffing]    |
               |  |  (SE0 >= 32 bit times)  (Sample at 0.5T, mid-bit)  |
               |  |                                 |                  |
               |  |                         [SYNC & PID Check]         |
               |  |                      * Locks to SYNC 0x80          |
               |  |                      * Validates PID == ~Check     |
               |  |                                 |                  |
               |  |        +------------------------+-------+          |
               |  |        |                                |          |
               |  |  [Token FSM]                       [Data FSM]      |
               |  |  * Extract ADDR[6:0] & ENDP[3:0]   * Byte stream   |
               |  |  * Check CRC-5 residual (0x06)     * Check CRC-16  |
               |  |  * Address filter comparison       * Auto-ACK      |
               |  |        |                                |          |
               |  |        +----------------+---------------+          |
               |  |                         |                          |
               |  |               [Handshake & TX FSM]                 |
               |  |               * SYNC + PID + EOP generator         |
               |  |               * ACK / NAK / STALL responder        |
               |  |                                 |                  |
o_dp --------<-|------------------------------------+                  |
o_dm --------<-|------------------------------------+                  |
o_oe --------<-|------------------------------------+                  |
               +-------------------------------------------------------+
```

### 2.1 Differential Line Decoding
The SIE samples `i_dp` and `i_dm` through a 2-stage double-flop synchronizer:
- **Full Speed (12 Mbps)**:
  - J-state (Idle / '1'): `D+ = 1, D- = 0`
  - K-state (Invert / '0'): `D+ = 0, D- = 1`
- **Low Speed (1.5 Mbps)**:
  - J-state (Idle / '1'): `D+ = 0, D- = 1`
  - K-state (Invert / '0'): `D+ = 1, D- = 0`
- **Common Signaling**:
  - SE0 (Single-Ended Zero): `D+ = 0, D- = 0` (Used for EOP and Bus Reset)
  - SE1 (Single-Ended One): `D+ = 1, D- = 1` (Illegal state / Error)

### 2.2 SYNC Locking & Mid-Bit Alignment
Upon detecting the leading transition from idle J-state to K-state, the receiver preloads its baud prescaler counter with `half_div` ($T/2$), positioning all subsequent samples dead-center in the eye diagram ($0.5T, 1.5T, 2.5T, \dots, 7.5T$). The receiver checks for the standard USB SYNC pattern `0x80` (`00000001b` transmitted LSB-first).

### 2.3 Autonomous Handshake Response
When `i_auto_ack` is enabled:
1. An incoming valid `OUT` or `SETUP` token latches endpoint target configuration.
2. Subsequent `DATA0` or `DATA1` packet is received and verified by the hardware CRC-16 engine.
3. If CRC-16 residual matches `0xB001` and the endpoint is not flagged with `STALL` or `NAK`, the transmitter FSM immediately asserts `o_oe` and generates an autonomous `ACK` packet (SYNC + `PID_ACK` + 2-bit SE0 + 1-bit J).

---

## 3. Microcode Assembler Extensions

The Omnibus Assembler (`python/omnibus_asm.py`) includes dedicated USB 1.1 SIE mnemonics:

| Instruction | Binary Format | Description |
| :--- | :--- | :--- |
| `USB_CFG <addr>` | `0xF4B[addr]` | Set device address (`addr` 0..127) and enable SIE |
| `USB_SIE_EN` | `0xF40B` | Enable autonomous USB Serial Interface Engine |
| `USB_SIE_DIS` | `0xF40C` | Disable USB SIE and release bus lines to Hi-Z |
| `USB_SEND_ACK` | `0xF40D` | Strobe hardware transmission of ACK handshake |
| `USB_SEND_NAK` | `0xF40E` | Strobe hardware transmission of NAK handshake |
| `USB_SEND_STALL` | `0xF40F` | Strobe hardware transmission of STALL handshake |
| `USB_TX_TOKEN <pid>` | `0xF4C[pid]` | Transmit token packet (`OUT`=1, `IN`=9, `SOF`=5, `SETUP`=13) to target in `acc` |
| `USB_TX_DATA <pid>` | `0xF4D[pid]` | Transmit data packet (`DATA0`=3, `DATA1`=11) with payload from `acc` |

### `ASSIST READ` USB Telemetry Targets
| Syntax | Target Register | Value Latched into `acc` | Flags Updated |
| :--- | :--- | :--- | :--- |
| `ASSIST READ, USB_STATUS` | Status Byte | `{crc_err, pid_err, bus_rst, tx_done, rx_done, tok_val, idle, oe}` | `ZERO` = (status == 0), `CARRY` = crc_err |
| `ASSIST READ, USB_TOKEN` | Token Info | `{token_pid[3:0], token_endp[3:0]}` | `ZERO` = !token_valid, `CARRY` = bus_reset |
| `ASSIST READ, USB_DATA` | Received Byte | `o_rx_data_byte[7:0]` | `ZERO` = (byte == 0), `CARRY` = packet_done |
| `ASSIST READ, USB_ADDR` | Address Info | `{1'b0, token_addr[6:0]}` | `ZERO` = (addr == 0), `CARRY` = 0 |

---

## 4. Wishbone B4 Slave Memory Map (`0x60..0x6C`)

Host processors and DMA masters control the USB SIE through 4 dedicated Wishbone registers:

### 4.1 `ADDR_USB_CTRL` (`0x60`, R/W)
- `[0]`: `usb_sie_en` - Enable USB 1.1 SIE (1 = Active, 0 = Disabled)
- `[1]`: `usb_speed_mode` - Speed mode (0 = Full-Speed 12 Mbps, 1 = Low-Speed 1.5 Mbps)
- `[2]`: `usb_auto_ack` - Autonomous ACK generation on valid CRC-16 data packets
- `[9:3]`: `usb_dev_addr` - 7-bit Device Address for hardware token filtering
- `[25:10]`: `usb_bit_div` - 16-bit clock prescaler for bit time ($T = \text{div} \times 20 \text{ ns}$)
- `[31:26]`: Reserved (0)

### 4.2 `ADDR_USB_STATUS` (`0x64`, Read-Only)
- `[7:0]`: `o_status_byte` - Consolidated hardware status byte
- `[11:8]`: `o_token_pid` - Last latched token PID
- `[15:12]`: `o_token_endp` - Last latched endpoint number
- `[22:16]`: `o_token_addr` - Last latched token device address
- `[23]`: Reserved (0)
- `[27:24]`: `o_rx_pid` - Last received packet PID
- `[28]`: `o_bus_reset` - Bus Reset flag (sustained SE0 $\ge 32$ bit times)
- `[29]`: `o_bus_idle` - Bus Idle flag (sustained J-state)
- `[31:30]`: Reserved (0)

### 4.3 `ADDR_USB_EP_CTRL` (`0x68`, R/W)
- `[3:0]`: `ep_stall[3:0]` - Per-endpoint hardware STALL flags (EP0..EP3)
- `[7:4]`: `ep_nak[3:0]` - Per-endpoint hardware NAK flags (EP0..EP3)
- `[11:8]`: `ep_toggle[3:0]` - Per-endpoint data toggle bit expectation (0 = DATA0, 1 = DATA1)
- `[31:12]`: Reserved (0)

### 4.4 `ADDR_USB_TX_TOKEN` (`0x6C`, Write-Only Strobe)
- `[3:0]`: `tx_token_pid` - Token PID to transmit (`OUT`=1, `IN`=9, `SOF`=5, `SETUP`=13)
- `[10:4]`: `tx_token_addr` - Target device address
- `[14:11]`: `tx_token_endp` - Target endpoint
- `[15]`: Reserved (0)
- `[19:16]`: `tx_handshake_pid` - Handshake PID (`ACK`=2, `NAK`=10, `STALL`=14)
- `[20]`: `tx_handshake_req` - Trigger single-cycle handshake transmission
- `[31:21]`: Reserved (0)

---

## 5. Verification & Test Suite

The USB 1.1 SIE test suite provides complete end-to-end verification with zero regressions across the entire codebase:

1. **`test_usb_sie_token_rx`** (Task 28A):
   - Transmits NRZI-encoded SYNC (`0x80`), SETUP token PID (`0x2D`), Address 5, Endpoint 0, and inverted CRC-5 with EOP framing.
   - Validates that the hardware SIE locks to SYNC, verifies PID complement, verifies CRC-5 residual (`0x06`), and latches Token PID `0xD`, Address `5`, Endpoint `0`.
2. **`test_usb_sie_auto_ack`** (Task 28B):
   - Transmits OUT token to Address 5, followed by a DATA0 packet (`0xC3`) with ASCII payload `'A'` and valid CRC-16.
   - Verifies that the hardware SIE detects the valid packet and autonomously asserts `o_gpio_oe` to drive an `ACK` handshake packet.
3. **`test_usb_sie_bus_reset`** (Task 28C):
   - Drives sustained Single-Ended Zero (SE0) on `D+` and `D-` for $\ge 32$ bit times.
   - Validates that `o_usb_bus_reset` asserts and triggers reset exception microcode.
4. **`test_wb_usb_sie_registers`** (Task 28D):
   - Performs Wishbone reads and writes across `0x60`, `0x64`, `0x68`, and `0x6C`.
   - Validates `dev_addr`, `bit_div`, `ep_stall`, `ep_nak`, `ep_toggle`, and `bus_idle` status reporting.

### Regression Results
- **Core Suite (`ProtocolEmulator`)**: 81 / 81 Tests Passing (100%)
- **Wishbone Suite (`OmniBus_Wishbone`)**: 13 / 13 Tests Passing (100%)
- **Total**: 94 / 94 Tests Passing (100% Pass Rate)

---

## 6. Hardware Runner Scripts

- **`scripts/run_usb_sie.bat`**: Shortcut launcher for running USB test suites and demos.
- **`scripts/run_usb_sie_demo.bat`**: Full-featured interactive hardware launcher supporting FPGA programming, microcode assembly, interactive terminal monitoring, and simulation modes (`sim`, `token`, `ack`, `reset`, `wb`, `all`, `build`, `flash`).
- **`examples/usb_sie_demo.asm`**: Ready-to-run microcode application implementing an autonomous USB device responder on Address 5.
