// =============================================================================
// File        : assembler.js
// Module      : OmniBus Microcode Assembler in JavaScript
// Description : Two-pass macro assembler for the OmniBus 16-bit ISA.
//               100% compatible with omnibus_asm.py.
//               Calculates sidecar delays, resolves labels, encodes opcodes,
//               hardware assists, CRC, ALU, Glitch, MitM, Audio, Profiler, and BIST.
// License     : MIT License
// =============================================================================

export class OmniBusAssembler {
    constructor(clkFreqHz = 50000000, defaultBaud = 115200) {
        this.clkFreqHz = clkFreqHz;
        this.baud = defaultBaud;
        this.reset();
    }

    reset() {
        this.symbols = {};
        this.constants = {};
        this.pinAliases = {
            "MOSI": 0, "TX": 0, "TX_PIN": 0, "PIN0": 0, "P0": 0, "UIO0": 0, "UIO[0]": 0,
            "SCK":  1, "SCL": 1, "SCL_PIN": 1, "PIN1": 1, "P1": 1, "UIO1": 1, "UIO[1]": 1,
            "CS":   2, "CS_N": 2, "CSN": 2, "DIN": 2, "PIN2": 2, "P2": 2, "UIO2": 2, "UIO[2]": 2,
            "MISO": 3, "RX": 3, "RX_PIN": 3, "JOY_PIN": 3, "PIN3": 3, "P3": 3, "UIO3": 3, "UIO[3]": 3,
            "SDA":  0, "SDA_PIN": 0,
            "AUDIO_OUT": 4, "PIN4": 4, "P4": 4, "UIO4": 4, "UIO[4]": 4,
            "GLITCH_TRIG": 5, "PIN5": 5, "P5": 5, "UIO5": 5, "UIO[5]": 5,
            "PIN6": 6, "P6": 6, "UIO6": 6, "UIO[6]": 6,
            "PIN7": 7, "P7": 7, "UIO7": 7, "UIO[7]": 7
        };
        this.errors = [];
        this.warnings = [];
        this.machineCode = [];
        this.debugMap = [];
        this.entryLabel = null;
        this.entryPoint = 0;
    }

    static get OPCODES() {
        return {
            "NOP": 0x0,
            "OUT": 0x1,
            "IN": 0x2,
            "SET": 0x3,
            "WAIT": 0x4,
            "PINMAP": 0x5,
            "CFG_OD": 0x6,
            "DJNZ": 0x7,
            "LOOP": 0x7,
            "SET_LC": 0x7,
            "PULL_LC": 0x7,
            "PUSH_LC": 0x7,
            "MOV_LC": 0x7,
            "JMP": 0x8,
            "PULL": 0x9,
            "PUSH": 0xA,
            "ALU": 0xB,
            "ADD": 0xB,
            "SUB": 0xB,
            "CMP": 0xB,
            "AND": 0xB,
            "OR": 0xB,
            "XOR": 0xB,
            "MOV": 0xB,
            "NOT": 0xB,
            "INV": 0xB,
            "INC": 0xB,
            "DEC": 0xB,
            "CLR": 0xB,
            "SHL": 0xB,
            "SHR": 0xB,
            "ROL": 0xB,
            "ROR": 0xB,
            "BANK": 0xB,
            "SET_BANK": 0xB,
            "JMP_BANK": 0xB,
            "CALL": 0xC,
            "RET": 0xD,
            "CRC": 0xE,
            "CRC_INIT": 0xE,
            "CRC_BYTE": 0xE,
            "CRC_READ_LOW": 0xE,
            "CRC_READ_L": 0xE,
            "CRC_READ_HIGH": 0xE,
            "CRC_READ_H": 0xE,
            "CRC_READ_B0": 0xE,
            "CRC_READ_B1": 0xE,
            "CRC_READ_B2": 0xE,
            "CRC_READ_B3": 0xE,
            "CRC_RESET": 0xE,
            "ASSIST": 0xF,
            "ASSIST_CFG": 0xF,
            "ASSIST_RESET": 0xF,
            "ASSIST_READ": 0xF,
            "PULSE_CFG": 0xF,
            "GAMEPAD_CFG": 0xF,
            "PULSE_TIME0": 0xF,
            "PULSE_TIME1": 0xF,
            "I2C_SLAVE_CFG": 0xF,
            "I2C_RELEASE_SCL": 0xF,
            "I2C_SLAVE_DISABLE": 0xF,
            "AUDIO_CFG": 0xF,
            "AUDIO_VOL": 0xF,
            "AUDIO_SAMPLE": 0xF,
            "AUDIO_DUTY": 0xF,
            "AUDIO_NOTE_LO": 0xF,
            "AUDIO_NOTE_HI": 0xF,
            "AUDIO_PLAY": 0xF,
            "AUDIO_STOP": 0xF,
            "JTAG_CFG": 0xF,
            "JTAG_TMS": 0xF,
            "JTAG_NAV": 0xF,
            "JTAG_SHIFT": 0xF,
            "SWD_CFG": 0xF,
            "SWD_REQ": 0xF,
            "SWD_RESET": 0xF,
            "SWD_RD32": 0xF,
            "SWD_WR32": 0xF,
            "SWD_LOAD": 0xF,
            "QSPI_CFG": 0xF,
            "QSPI_CS": 0xF,
            "QSPI_CMD": 0xF,
            "QSPI_DUMMY": 0xF,
            "QSPI_ADDR": 0xF,
            "QSPI_LOAD_ADDR": 0xF,
            "QSPI_LOAD": 0xF,
            "GLITCH_CFG": 0xF,
            "GLITCH_WIDTH": 0xF,
            "GLITCH_DELAY": 0xF,
            "GLITCH_DELAY_LO": 0xF,
            "GLITCH_DELAY_HI": 0xF,
            "GLITCH_ARM": 0xF,
            "GLITCH_TRIG": 0xF,
            "GLITCH_TRIGGER": 0xF,
            "GLITCH_DISARM": 0xF,
            "MITM_CFG": 0xF,
            "MITM_MATCH": 0xF,
            "MITM_REPLACE": 0xF,
            "MITM_MASK": 0xF,
            "MITM_ENABLE": 0xF,
            "MITM_DISABLE": 0xF,
            "MITM_RESET": 0xF,
            "MITM_CLR": 0xF,
            "PROFILER_CFG": 0xF,
            "PROFILER_FILTER": 0xF,
            "PROFILER_ARM": 0xF,
            "PROFILER_STOP": 0xF,
            "PROFILER_RST": 0xF,
            "PROFILER_RESET": 0xF,
            "USB_CFG": 0xF,
            "USB_CONFIG": 0xF,
            "USB_TX_TOKEN": 0xF,
            "USB_TOKEN": 0xF,
            "USB_TX_DATA": 0xF,
            "USB_DATA_PKT": 0xF,
            "USB_SEND_ACK": 0xF,
            "USB_ACK": 0xF,
            "USB_SEND_NAK": 0xF,
            "USB_NAK": 0xF,
            "USB_SEND_STALL": 0xF,
            "USB_STALL": 0xF,
            "USB_SIE_EN": 0xF,
            "USB_SIE_DIS": 0xF,
            "BIST_CFG": 0xF,
            "BIST_CONFIG": 0xF,
            "BIST_DIS": 0xF,
            "BIST_DISABLE": 0xF,
            "BIST_LOOP": 0xF,
            "BIST_LOOPBACK": 0xF,
            "BIST_SPLIT": 0xF,
            "BIST_CROSSBAR": 0xF,
            "BIST_JITTER": 0xF,
            "BIST_STRESS": 0xF,
            "BIST_START": 0xF,
            "BIST_EN": 0xF,
            "BIST_STOP": 0xF,
            "BIST_RST": 0xF,
            "BIST_RESET": 0xF,
            "BIST_PASS": 0xF,
            "BIST_FAIL": 0xF,
            "BIST_STAGE": 0xF,
            // Multi-Core OmniBus MP (Task 35)
            "CORE_ID": 0xF,
            "SPINLOCK_ACQ": 0xF,
            "SPINLOCK_REL": 0xF,
            "LOCK_ACQ": 0xF,
            "LOCK_REL": 0xF,
            "BARRIER_WAIT": 0xF,
            "BARRIER": 0xF,
            "MB_READ": 0xF,
            "MB_RD": 0xF,
            "MAILBOX_READ": 0xF,
            "MB_WRITE": 0xF,
            "MB_WR": 0xF,
            "MAILBOX_WRITE": 0xF
        };
    }

    assemble(sourceCode) {
        this.reset();
        const rawLines = sourceCode.split(/\r?\n/);

        // Preprocess lines: strip comments, trim, extract labels and assignments
        const parsedLines = [];
        let currentPC = 0;
        let inPinsSection = false;

        for (let i = 0; i < rawLines.length; i++) {
            let line = rawLines[i].trim();
            // Remove comments (; or // or #)
            const commentIdx = line.search(/;|(\/\/)|#/);
            if (commentIdx !== -1) {
                line = line.substring(0, commentIdx).trim();
            }

            if (!line) {
                parsedLines.push({ raw: rawLines[i], lineNum: i + 1, isEmpty: true });
                continue;
            }

            // Directives (.clock, .pins, .const, .equ, .org, .entry, .bank)
            if (line.startsWith(".")) {
                const parts = line.split(/\s+/);
                const dir = parts[0].toLowerCase();

                if (dir === ".clock") {
                    const val = parts[1];
                    if (val.toLowerCase().endsWith("mhz")) {
                        this.clkFreqHz = parseFloat(val) * 1e6;
                    } else if (val.toLowerCase().endsWith("khz")) {
                        this.clkFreqHz = parseFloat(val) * 1e3;
                    } else if (val.toLowerCase().endsWith("hz")) {
                        this.clkFreqHz = parseFloat(val);
                    } else {
                        this.clkFreqHz = this.parseValue(val);
                    }
                } else if (dir === ".baud") {
                    this.baud = this.parseValue(parts[1]);
                } else if (dir === ".const" || dir === ".equ") {
                    const cName = parts[1];
                    const cVal = this.parseValue(parts[2]);
                    this.constants[cName] = cVal;
                    this.constants[cName.toUpperCase()] = cVal;
                } else if (dir === ".entry") {
                    this.entryLabel = parts[1];
                } else if (dir === ".org") {
                    currentPC = this.parseValue(parts[1]);
                } else if (dir === ".bank" || dir === ".core") {
                    const bankNum = this.parseValue(parts[1]);
                    currentPC = (bankNum & 3) * 32;
                } else if (dir === ".pins") {
                    inPinsSection = true;
                } else if (dir === ".define") {
                    if (parts.length >= 3) {
                        const cName = parts[1];
                        const cVal = this.parseValue(parts[2]);
                        this.constants[cName] = cVal;
                        this.constants[cName.toUpperCase()] = cVal;
                    }
                } else if (dir === ".include") {
                    // Predefined includes handled or skipped safely
                }

                parsedLines.push({ raw: rawLines[i], lineNum: i + 1, isDirective: true, text: line });
                continue;
            }

            // Preprocessor defines: #define NAME VAL or `define NAME VAL
            const defMatch = line.match(/^[#`]?define\s+([A-Za-z_][A-Za-z0-9_]*)\s+(.+)$/);
            if (defMatch) {
                const dName = defMatch[1];
                const dVal = this.parseValue(defMatch[2].split("//")[0].split(";")[0].trim());
                this.constants[dName] = dVal;
                this.constants[dName.toUpperCase()] = dVal;
                parsedLines.push({ raw: rawLines[i], lineNum: i + 1, isDirective: true, text: line });
                continue;
            }

            // Preprocessor includes: #include "..." or `include "..."
            const incMatch = line.match(/^[#`]?include\s+["<](.*)[">]/);
            if (incMatch) {
                parsedLines.push({ raw: rawLines[i], lineNum: i + 1, isDirective: true, text: line });
                continue;
            }

            // Check for assignment: alias = pin / expr (e.g. tx_pin = uio[0], T0H = 17)
            const assignMatch = line.match(/^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$/);
            if (assignMatch) {
                const varName = assignMatch[1];
                const rhs = assignMatch[2].trim();
                const pinVal = this.resolvePinRhs(rhs);
                
                this.pinAliases[varName] = pinVal;
                this.pinAliases[varName.toUpperCase()] = pinVal;
                this.constants[varName] = pinVal;
                this.constants[varName.toUpperCase()] = pinVal;

                parsedLines.push({ raw: rawLines[i], lineNum: i + 1, isDirective: true, text: line });
                continue;
            }

            // Check for label definition: label:
            let label = null;
            const labelMatch = line.match(/^([a-zA-Z_][a-zA-Z0-9_]*):(.*)$/);
            if (labelMatch) {
                label = labelMatch[1];
                this.symbols[label] = currentPC;
                this.symbols[label.toUpperCase()] = currentPC;
                line = labelMatch[2].trim();
            }

            if (!line) {
                parsedLines.push({ raw: rawLines[i], lineNum: i + 1, label: label, isLabelOnly: true, pc: currentPC });
                continue;
            }

            parsedLines.push({
                raw: rawLines[i],
                lineNum: i + 1,
                label: label,
                text: line,
                pc: currentPC
            });
            currentPC++;
        }

        // Resolve entry point
        if (this.entryLabel && (this.entryLabel in this.symbols)) {
            this.entryPoint = this.symbols[this.entryLabel];
        }

        // Pass 2: Instruction Encoding
        this.machineCode = [];
        this.debugMap = [];

        for (const item of parsedLines) {
            if (item.isEmpty || item.isDirective || item.isLabelOnly) {
                continue;
            }

            try {
                const word16 = this.encodeInstruction(item.text, item.pc, item.lineNum);
                this.machineCode.push(word16);
                this.debugMap.push({
                    pc: item.pc,
                    lineNum: item.lineNum,
                    raw: item.raw,
                    word: word16,
                    hex: "0x" + word16.toString(16).padStart(4, "0").toUpperCase(),
                    bin: word16.toString(2).padStart(16, "0")
                });
            } catch (err) {
                this.errors.push({ line: item.lineNum, message: err.message, text: item.raw });
            }
        }

        return {
            success: this.errors.length === 0,
            machineCode: this.machineCode,
            debugMap: this.debugMap,
            symbols: this.symbols,
            constants: this.constants,
            errors: this.errors,
            warnings: this.warnings,
            hexListing: this.getHexListing(),
            verilogHex: this.getVerilogMemHex()
        };
    }

    resolvePinRhs(rhs) {
        const s = rhs.trim().toUpperCase();
        if (s.startsWith("UIO[") && s.endsWith("]")) {
            return parseInt(s.replace(/\D/g, ""), 10) || 0;
        }
        if (s.startsWith("PIN") || s.startsWith("P")) {
            return parseInt(s.replace(/\D/g, ""), 10) || 0;
        }
        return this.parseValue(rhs);
    }

    encodeInstruction(text, pc, lineNum) {
        // Extract sidecar delay if present: [N] or [$BAUD] or [8.68us]
        let delay = 0;
        let delayMatch = text.match(/\[(.*?)\]/);
        let cleaned = text;

        if (delayMatch) {
            const delayStr = delayMatch[1].trim();
            cleaned = text.replace(/\[.*?\]/, "").trim();

            if (delayStr === "$BAUD") {
                delay = 0x1FF; // 511 sentinel
            } else if (delayStr === "$HBAUD") {
                delay = 0x1FE; // 510 sentinel
            } else if (delayStr.toLowerCase().endsWith("us")) {
                const us = parseFloat(delayStr);
                delay = Math.round(us * 1e-6 * this.clkFreqHz) - 1;
            } else if (delayStr.toLowerCase().endsWith("ns")) {
                const ns = parseFloat(delayStr);
                delay = Math.round(ns * 1e-9 * this.clkFreqHz) - 1;
            } else {
                delay = this.evalExpression(delayStr);
            }
            if (delay < 0) delay = 0;
        }

        // Split mnemonic and arguments
        const firstSpace = cleaned.search(/\s/);
        let mnemonic = "";
        let argStr = "";

        if (firstSpace === -1) {
            mnemonic = cleaned.toUpperCase();
        } else {
            mnemonic = cleaned.substring(0, firstSpace).toUpperCase();
            argStr = cleaned.substring(firstSpace).trim();
        }

        const args = argStr ? argStr.split(",").map(s => s.trim()) : [];

        const opcodes = OmniBusAssembler.OPCODES;
        if (!(mnemonic in opcodes)) {
            throw new Error(`Unknown instruction or mnemonic: '${mnemonic}'`);
        }

        const opcode = opcodes[mnemonic];
        let word = 0;

        switch (mnemonic) {
            case "NOP": {
                const d5 = delay & 0x1F;
                word = (opcode << 12) | (d5 << 7);
                break;
            }

            case "OUT": {
                let pin = 0;
                let count = 8;
                if (args.length >= 2) {
                    pin = this.resolvePin(args[0]);
                    count = this.evalExpression(args[1]);
                } else if (args.length === 1) {
                    count = this.evalExpression(args[0]);
                }
                const d5 = delay & 0x1F;
                const operand = ((pin & 0x7) << 4) | (count & 0xF);
                word = (opcode << 12) | (d5 << 7) | (operand & 0x7F);
                break;
            }

            case "IN": {
                let pin = 0;
                let count = 8;
                if (args.length >= 2) {
                    pin = this.resolvePin(args[0]);
                    count = this.evalExpression(args[1]);
                } else if (args.length === 1) {
                    count = this.evalExpression(args[0]);
                }
                const d5 = delay & 0x1F;
                const operand = ((pin & 0x7) << 4) | (count & 0xF);
                word = (opcode << 12) | (d5 << 7) | (operand & 0x7F);
                break;
            }

            case "SET": {
                let pin = 0;
                let val = 0;
                if (args.length >= 2) {
                    pin = this.resolvePin(args[0]);
                    val = (args[1] === "1" || args[1].toUpperCase() === "HIGH" || args[1].toUpperCase() === "Z") ? 1 : 0;
                } else if (args.length === 1) {
                    val = this.evalExpression(args[0]) & 1;
                }
                const d5 = delay & 0x1F;
                const operand = ((pin & 0x7) << 1) | (val & 0x1);
                word = (opcode << 12) | (d5 << 7) | (operand & 0x7F);
                break;
            }

            case "WAIT": {
                let pin = 0;
                let val = 1;
                if (args.length >= 2) {
                    pin = this.resolvePin(args[0]);
                    val = (args[1] === "1" || args[1].toUpperCase() === "HIGH") ? 1 : 0;
                } else if (args.length === 1) {
                    val = this.evalExpression(args[0]) & 1;
                }
                const d5 = delay & 0x1F;
                const operand = ((pin & 0x7) << 1) | (val & 0x1);
                word = (opcode << 12) | (d5 << 7) | (operand & 0x7F);
                break;
            }

            case "PINMAP": {
                let operand = 0;
                if (args.length >= 4) {
                    const tx = this.resolvePin(args[0]) & 0x3;
                    const rx = this.resolvePin(args[1]) & 0x3;
                    const sck = this.resolvePin(args[2]) & 0x3;
                    const cs = this.resolvePin(args[3]) & 0x3;
                    operand = (tx << 6) | (rx << 4) | (sck << 2) | cs;
                } else if (args.length === 1) {
                    operand = this.evalExpression(args[0]) & 0xFF;
                }
                word = (opcode << 12) | (operand & 0xFFF);
                break;
            }

            case "CFG_OD": {
                const mask = args.length > 0 ? this.evalExpression(args[0]) : 0xFF;
                word = (opcode << 12) | (mask & 0xFF);
                break;
            }

            case "DJNZ":
            case "LOOP": {
                let lc = 0;
                let target = 0;
                if (args.length >= 2) {
                    lc = args[0].toUpperCase() === "LC1" ? 1 : 0;
                    target = this.resolveTarget(args[1]);
                } else if (args.length === 1) {
                    target = this.resolveTarget(args[0]);
                }
                const subop = 0;
                word = (opcode << 12) | (subop << 10) | (lc << 9) | (target & 0x7F);
                break;
            }

            case "SET_LC": {
                let lc = 0;
                let val = 0;
                if (args.length >= 2) {
                    lc = args[0].toUpperCase() === "LC1" ? 1 : 0;
                    val = this.evalExpression(args[1]);
                } else if (args.length === 1) {
                    val = this.evalExpression(args[0]);
                }
                const subop = 1;
                word = (opcode << 12) | (subop << 10) | (lc << 9) | (val & 0x1FF);
                break;
            }

            case "JMP": {
                let cond = 0;
                let target = 0;
                if (args.length >= 2) {
                    cond = this.resolveCondition(args[0]);
                    target = this.resolveTarget(args[1]);
                } else if (args.length === 1) {
                    target = this.resolveTarget(args[0]);
                }
                word = (opcode << 12) | ((cond & 0xF) << 7) | (target & 0x7F);
                break;
            }

            case "PULL": {
                const isBlock = args.length > 0 && args[0].toUpperCase().includes("BLOCK");
                const operand = isBlock ? 0x1 : 0x0;
                word = (opcode << 12) | (operand & 0xFFF);
                break;
            }

            case "PUSH": {
                const isBlock = args.length > 0 && args[0].toUpperCase().includes("BLOCK");
                const operand = isBlock ? 0x1 : 0x0;
                word = (opcode << 12) | (operand & 0xFFF);
                break;
            }

            case "CALL": {
                const target = args.length > 0 ? this.resolveTarget(args[0]) : 0;
                word = (opcode << 12) | (target & 0x7F);
                break;
            }

            case "RET": {
                word = (opcode << 12);
                break;
            }

            case "ALU":
            case "ADD":
            case "SUB":
            case "CMP":
            case "AND":
            case "OR":
            case "XOR":
            case "MOV":
            case "NOT":
            case "INV":
            case "INC":
            case "DEC":
            case "CLR":
            case "SHL":
            case "SHR":
            case "ROL":
            case "ROR":
            case "BANK":
            case "SET_BANK": {
                const aluOps = {
                    "ADD": 0, "SUB": 1, "CMP": 2, "AND": 3,
                    "OR": 4, "XOR": 5, "MOV": 6, "NOT": 7, "INV": 7
                };
                let aluSub = aluOps[mnemonic] !== undefined ? aluOps[mnemonic] : 0;
                let val = 0;
                if (args.length >= 2) {
                    val = this.evalExpression(args[1]);
                } else if (args.length === 1) {
                    val = this.evalExpression(args[0]);
                }
                word = (opcode << 12) | ((aluSub & 0x7) << 8) | (val & 0xFF);
                break;
            }

            case "CRC":
            case "CRC_INIT":
            case "CRC_BYTE":
            case "CRC_READ_LOW":
            case "CRC_READ_L":
            case "CRC_READ_HIGH":
            case "CRC_READ_H":
            case "CRC_READ_B0":
            case "CRC_READ_B1":
            case "CRC_READ_B2":
            case "CRC_READ_B3":
            case "CRC_RESET": {
                let crcSub = 0;
                if (mnemonic === "CRC_INIT") crcSub = 1;
                else if (mnemonic === "CRC_BYTE") crcSub = 2;
                else if (mnemonic === "CRC_READ_LOW" || mnemonic === "CRC_READ_L") crcSub = 3;
                else if (mnemonic === "CRC_READ_HIGH" || mnemonic === "CRC_READ_H") crcSub = 4;
                else if (mnemonic === "CRC_READ_B0") crcSub = 5;
                else if (mnemonic === "CRC_READ_B1") crcSub = 6;
                else if (mnemonic === "CRC_READ_B2") crcSub = 7;
                else if (mnemonic === "CRC_READ_B3") crcSub = 8;
                else if (mnemonic === "CRC_RESET") crcSub = 0;

                const val = args.length > 0 ? this.evalExpression(args[0]) : 0;
                word = (opcode << 12) | ((crcSub & 0xF) << 8) | (val & 0xFF);
                break;
            }

            default: {
                let val = args.length > 0 ? this.evalExpression(args[0]) : 0;

                // Multi-Core OmniBus MP (Task 35) Instructions
                if (mnemonic === "CORE_ID") {
                    word = 0xFC00;
                } else if (mnemonic === "SPINLOCK_ACQ" || mnemonic === "LOCK_ACQ") {
                    word = 0xFD00 | (val & 3);
                } else if (mnemonic === "SPINLOCK_REL" || mnemonic === "LOCK_REL") {
                    word = 0xFE00 | (val & 3);
                } else if (mnemonic === "MB_READ" || mnemonic === "MB_RD" || mnemonic === "MAILBOX_READ") {
                    word = 0xF800 | (val & 7);
                } else if (mnemonic === "MB_WRITE" || mnemonic === "MB_WR" || mnemonic === "MAILBOX_WRITE") {
                    word = 0xF900 | (val & 7);
                } else if (mnemonic === "BARRIER_WAIT" || mnemonic === "BARRIER") {
                    word = 0xFF00;
                } else {
                    let assistSub = 0;
                    if (mnemonic.startsWith("PULSE")) assistSub = 0x1;
                    else if (mnemonic.startsWith("GAMEPAD")) assistSub = 0x2;
                    else if (mnemonic.startsWith("I2C_SLAVE")) assistSub = 0x3;
                    else if (mnemonic.startsWith("AUDIO")) assistSub = 0x4;
                    else if (mnemonic.startsWith("JTAG")) assistSub = 0x5;
                    else if (mnemonic.startsWith("SWD")) assistSub = 0x6;
                    else if (mnemonic.startsWith("QSPI")) assistSub = 0x7;
                    else if (mnemonic.startsWith("GLITCH")) assistSub = 0x8;
                    else if (mnemonic.startsWith("MITM")) assistSub = 0x9;
                    else if (mnemonic.startsWith("PROFILER")) assistSub = 0xA;
                    else if (mnemonic.startsWith("USB")) assistSub = 0xB;
                    else if (mnemonic.startsWith("BIST")) assistSub = 0xC;

                    word = (0xF << 12) | ((assistSub & 0xF) << 8) | (val & 0xFF);
                }
                break;
            }
        }

        return word & 0xFFFF;
    }

    resolvePin(pinStr) {
        if (!pinStr) return 0;
        const s = pinStr.trim().toUpperCase();
        if (s in this.pinAliases) return this.pinAliases[s];
        if (s.startsWith("UIO[") && s.endsWith("]")) return parseInt(s.replace(/\D/g, ""), 10) || 0;
        if (s.startsWith("PIN") || s.startsWith("P")) return parseInt(s.replace(/\D/g, ""), 10) || 0;
        if (s === "TX" || s === "MOSI" || s === "SDA" || s === "D_PLUS" || s === "DP") return 0;
        if (s === "RX" || s === "MISO" || s === "SCL" || s === "D_MINUS" || s === "DM") return 1;
        if (s === "SCK" || s === "CLK" || s === "DIN") return 2;
        if (s === "CS" || s === "CS_N" || s === "JOY_PIN") return 3;
        const v = this.parseValue(pinStr);
        return isNaN(v) ? 0 : v;
    }

    resolveCondition(condStr) {
        const conds = {
            "ALWAYS": 0, "EQ": 1, "NE": 2, "ZERO": 1, "NZ": 2,
            "CARRY": 3, "NC": 4, "FIFO_EMPTY": 5, "FIFO_FULL": 6,
            "I2C_START": 7, "I2C_STOP": 8, "SWD_ACK": 9, "MATCH": 10
        };
        const s = condStr.trim().toUpperCase();
        return conds[s] !== undefined ? conds[s] : (this.parseValue(s) & 0xF);
    }

    resolveTarget(targetStr) {
        const s = targetStr.trim();
        if (s in this.symbols) return this.symbols[s];
        const u = s.toUpperCase();
        if (u in this.symbols) return this.symbols[u];
        return this.evalExpression(s) & 0x7F;
    }

    evalExpression(expr) {
        if (!expr) return 0;
        const s = expr.trim();
        if (s in this.constants) return this.constants[s];
        const u = s.toUpperCase();
        if (u in this.constants) return this.constants[u];
        if (s in this.symbols) return this.symbols[s];
        if (u in this.symbols) return this.symbols[u];
        return this.parseValue(s);
    }

    parseValue(valStr) {
        if (typeof valStr === "number") return valStr;
        const s = String(valStr).trim();
        if (s.startsWith("0x") || s.startsWith("0X")) return parseInt(s, 16) || 0;
        if (s.startsWith("0b") || s.startsWith("0B")) return parseInt(s.substring(2), 2) || 0;
        if (s.startsWith("'h") || s.startsWith("'H")) return parseInt(s.substring(2), 16) || 0;
        if (s.startsWith("'b") || s.startsWith("'B")) return parseInt(s.substring(2), 2) || 0;
        return parseInt(s, 10) || 0;
    }

    getHexListing() {
        return this.machineCode.map((word, idx) => {
            const hex = word.toString(16).padStart(4, "0").toUpperCase();
            return `0x${idx.toString(16).padStart(2, "0").toUpperCase()}: 0x${hex}`;
        }).join("\n");
    }

    getVerilogMemHex() {
        return this.machineCode.map(word => {
            return word.toString(16).padStart(4, "0").toUpperCase();
        }).join("\n");
    }
}
