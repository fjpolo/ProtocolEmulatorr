# Task 06 — Runtime-Configurable Baud Rate

## Summary

Adds a runtime-configurable baud rate divisor to the OmniBus Protocol Emulator.
The baud rate can be changed in the field without rebuilding the FPGA bitstream
or reprogramming the IMEM. A single 16-bit register (`baud_div`) in
`OmniBootloader` feeds the `i_baud_div` port on `ProtocolEmulator`, which
transparently substitutes the runtime divisor when magic sentinel values appear
in instruction delay fields.

---

## Quick Start

```bat
REM 1. Build & flash the Task 06 bitstream (one-time)
build_task06.bat
flash_task06.bat

REM 2. Run the configurable echo at default 115200 baud
run_echo_configurable.bat

REM 3. Switch core to 57600 baud, then load and run
run_echo_configurable.bat 57600

REM 4. Switch core to 230400 baud
run_echo_configurable.bat 230400
```

---

## Architecture

### Magic Delay Sentinel Tokens

Two new sentinel values in the 9-bit `delay` field of any instruction:

| Token    | Encoding  | Resolved to          | Assembler token |
|:---------|:---------:|:---------------------|:---------------:|
| `$BAUD`  | `9'h1FF`  | `i_baud_div[8:0]`    | `$BAUD`         |
| `$HBAUD` | `9'h1FE`  | `i_baud_div[8:0]>>1` | `$HBAUD`        |

All other delay values (`0x000`..`0x1FD`) pass through unchanged — full
backward compatibility with existing microcode.

### Baud Divisor Values @ 50 MHz

| Baud Rate | Divisor | Formula           |
|----------:|:-------:|:------------------|
| 921600    | 53      | `50M/921600 - 1`  |
| 460800    | 107     | `50M/460800 - 1`  |
| 230400    | 216     | `50M/230400 - 1`  |
| **115200** | **433** | **default**       |
| 57600     | 867     | `50M/57600 - 1`   |
| 38400     | 1301    | `50M/38400 - 1`   |
| 19200     | 2603    | `50M/19200 - 1`   |
| 9600      | 5207    | `50M/9600 - 1`    |

### OmniBootloader 'B' Command Protocol

```
Host → FPGA:  [0x42 'B'] [div_hi] [div_lo]
FPGA → Host:  [0x06 ACK] [div_hi] [div_lo]   (echo-verify)
```

---

## Files

| File | Change |
|:-----|:-------|
| `rtl/ProtocolEmulator.v` | `+i_baud_div[15:0]` port; `eff_delay` wire with sentinel decode |
| `rtl/OmniBootloader.v` | `+baud_div` register; `+o_baud_div[15:0]`; `'B'` command FSM |
| `boards/sipeed/console60k/src/top.v` | Wire `bootloader.o_baud_div → DUT.i_baud_div` |
| `python/omnibus_asm.py` | `$BAUD → 0x1FF`, `$HBAUD → 0x1FE` symbol tokens |
| `python/omnibus_loader.py` | `set_baud_div()`, `--set-baud <Hz>`, `--set-div <N>` |
| `examples/echo_configurable.asm` | 9-word echo using `$BAUD`/`$HBAUD` tokens |
| `build_task06.bat` | Build bitstream script |
| `flash_task06.bat` | Flash to SPI Flash / SRAM script |
| `run_echo_configurable.bat` | Load and run at any baud rate |

---

## Verification

- **Cocotb/Icarus**: 10/10 PASS
  - `test_baud_div_configurable`: loads `$BAUD` sentinels, sets `i_baud_div=216`
    (230400 baud), sends `0xA5`, verifies echo in 80,830 ns
  - All 9 Task 01–05 regression tests pass unchanged

---

## AI Experiment Notes

This task demonstrates:
- **AI creativity**: novel sentinel encoding (`0x1FF`/`0x1FE`) to extend ISA without
  adding new opcodes or breaking existing programs
- **AI accuracy**: `eff_delay` wire correctly inserted at decode stage; all 5 timing
  instructions updated in a single RTL edit without breaking any existing test
- **AI verification**: import error (`get_sim_time`) caught immediately from Cocotb
  output and fixed in one iteration
