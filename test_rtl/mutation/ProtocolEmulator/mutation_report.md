# OmniBus RTL Mutation Testing Report

- **Total Mutants**: 20
- **Killed Mutants**: 20
- **Surviving Mutants**: 0
- **Mutation Kill Rate**: **100.00%**

## Detailed Mutation Kill Matrix

| Mutant ID | Subsystem | Operator | Fault Description | Status | Kill Reason |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `MUT_01_ALU_ADD_AOR` | Micro-ALU | AOR (Arithmetic Operator) | Mutate ADD immediate to SUB | ✅ KILLED | KILLED (Caught by pyUVM Scoreboard / Cocotb Assertion) |
| `MUT_02_ALU_SUB_AOR` | Micro-ALU | AOR (Arithmetic Operator) | Mutate SUB immediate to ADD | ✅ KILLED | KILLED (Caught by pyUVM Scoreboard / Cocotb Assertion) |
| `MUT_03_ALU_AND_LCR` | Micro-ALU | LCR (Logical Connector) | Mutate bitwise AND to OR | ✅ KILLED | KILLED (Caught by pyUVM Scoreboard / Cocotb Assertion) |
| `MUT_04_ALU_OR_LCR` | Micro-ALU | LCR (Logical Connector) | Mutate bitwise OR to AND | ✅ KILLED | KILLED (Caught by pyUVM Scoreboard / Cocotb Assertion) |
| `MUT_05_ALU_XOR_LCR` | Micro-ALU | LCR (Logical Connector) | Mutate bitwise XOR to AND | ✅ KILLED | KILLED (Caught by pyUVM Scoreboard / Cocotb Assertion) |
| `MUT_06_ALU_NOT_LCR` | Micro-ALU | LCR (Logical Connector) | Suppress bitwise NOT inversion | ✅ KILLED | KILLED (Caught by pyUVM Scoreboard / Cocotb Assertion) |
| `MUT_07_ALU_SHL_SOR` | Micro-ALU | SOR (Shift Operator) | Mutate SHL (left shift) to SHR (right shift) | ✅ KILLED | KILLED (Caught by pyUVM Scoreboard / Cocotb Assertion) |
| `MUT_08_ALU_SHR_SOR` | Micro-ALU | SOR (Shift Operator) | Mutate SHR (right shift) to SHL (left shift) | ✅ KILLED | KILLED (Caught by pyUVM Scoreboard / Cocotb Assertion) |
| `MUT_09_ALU_ROL_SOR` | Micro-ALU | SOR (Shift Operator) | Mutate ROL (rotate left) to ROR (rotate right) | ✅ KILLED | KILLED (Caught by pyUVM Scoreboard / Cocotb Assertion) |
| `MUT_10_ALU_ROR_SOR` | Micro-ALU | SOR (Shift Operator) | Mutate ROR (rotate right) to ROL (rotate left) | ✅ KILLED | KILLED (Caught by pyUVM Scoreboard / Cocotb Assertion) |
| `MUT_11_ALU_INC_AOR` | Micro-ALU | AOR (Arithmetic Operator) | Mutate INC (increment) to DEC (decrement) | ✅ KILLED | KILLED (Caught by pyUVM Scoreboard / Cocotb Assertion) |
| `MUT_12_ALU_DEC_AOR` | Micro-ALU | AOR (Arithmetic Operator) | Mutate DEC (decrement) to INC (increment) | ✅ KILLED | KILLED (Caught by pyUVM Scoreboard / Cocotb Assertion) |
| `MUT_13_ALU_ZERO_ROR` | Micro-ALU | ROR (Relational Operator) | Invert zero_flag calculation on ADD | ✅ KILLED | KILLED (Caught by pyUVM Scoreboard / Cocotb Assertion) |
| `MUT_14_STACK_CALL_INC` | Call Stack | SCR (Stack Counter) | Corrupt call stack pointer increment on CALL | ✅ KILLED | KILLED (Caught by pyUVM Scoreboard / Cocotb Assertion) |
| `MUT_15_STACK_RET_POP` | Call Stack | SCR (Stack Counter) | Suppress call stack pointer decrement on RET | ✅ KILLED | KILLED (Caught by pyUVM Scoreboard / Cocotb Assertion) |
| `MUT_16_CRC_DALLAS_POLY` | CRC Engine | FPR (Feedback Polynomial) | Mutate Dallas CRC-8 feedback polynomial tap | ✅ KILLED | KILLED (Caught by pyUVM Scoreboard / Cocotb Assertion) |
| `MUT_17_CRC_SMBUS_POLY` | CRC Engine | FPR (Feedback Polynomial) | Mutate SMBus CRC-8 feedback polynomial tap | ✅ KILLED | KILLED (Caught by pyUVM Scoreboard / Cocotb Assertion) |
| `MUT_18_FIFO_PUSH_STROBE` | FIFO Control | FSR (FIFO Strobe) | Suppress active-high FIFO push strobe | ✅ KILLED | KILLED (Caught by pyUVM Scoreboard / Cocotb Assertion) |
| `MUT_19_FIFO_POP_STROBE` | FIFO Control | FSR (FIFO Strobe) | Suppress active-high FIFO pop strobe | ✅ KILLED | KILLED (Caught by pyUVM Scoreboard / Cocotb Assertion) |
| `MUT_20_OPEN_DRAIN_OE` | GPIO / Open-Drain | ODR (Open Drain Rule) | Disable Hi-Z float in open-drain serialization | ✅ KILLED | KILLED (Caught by pyUVM Scoreboard / Cocotb Assertion) |
