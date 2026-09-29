// =============================================================================
// File        : emulator.js
// Module      : OmniBus Cycle-Accurate Silicon Micro-Engine Emulator
// Description : Cycle-by-cycle Verilog-equivalent behavioral emulator of the
//               OmniBus Protocol Emulator ASIC architecture.
//               Supports all 16 opcodes, sidecar delay countdowns, hardware assists,
//               CRCs, open-drain bus safety, waveform history capturing, and audio.
// License     : MIT License
// =============================================================================

export class OmniBusEmulator {
    constructor(clkFreqHz = 50000000) {
        this.clkFreqHz = clkFreqHz;
        this.baudDiv = 434; // Default 115200 at 50 MHz
        this.maxCyclesHistory = 20000;
        this.reset();
    }

    reset() {
        // IMEM: 128 words x 16-bit
        this.imem = new Uint16Array(128);
        this.pc = 0;
        this.nextPc = 0;
        
        // Execution state
        this.state = "FETCH"; // "FETCH", "EXEC", "DELAY", "WAIT_PIN", "WAIT_FIFO"
        this.delayCnt = 0;
        this.activeInst = 0;
        this.totalCycles = 0;
        this.instructionsExecuted = 0;
        
        // Registers & Stack
        this.lc0 = 0;
        this.lc1 = 0;
        this.callStack = [0, 0, 0, 0];
        this.callSp = 0;
        this.acc = 0;
        this.flags = { z: 1, c: 0, n: 0 };
        this.activeBank = 0;

        // Shift Registers
        this.osr = 0;
        this.isr = 0;
        this.osrCnt = 0;
        this.isrCnt = 0;
        this.osrValid = false;
        this.isrValid = false;

        // FIFOs (64 bytes each)
        this.txFifo = [];
        this.rxFifo = [];
        this.fifoDepth = 64;

        // GPIO and Pin Crossbar
        this.uioOut = 0;   // 8-bit output drive
        this.uioOe = 0;    // 8-bit output enable
        this.uioIn = 0xFF; // 8-bit input pins (external / pull-up)
        this.gpioOd = 0;   // 8-bit open-drain mask
        this.pinmap = { tx: 0, rx: 1, sck: 2, cs: 3 };

        // Subsystems: CRC-32/16/8/5 Accelerator
        this.crcAccum = 0xFFFFFFFF;
        this.crcPoly = 0xEDB88320; // Ethernet standard

        // Hardware Assists
        this.nrziState = 1;
        this.bitStuffCount = 0;
        this.pulseTime0 = 17; // NeoPixel T0H default
        this.pulseTime1 = 35; // NeoPixel T1H default
        this.pulseActive = false;
        this.pulseCnt = 0;

        // Glitch & MitM Engine
        this.glitchArmed = false;
        this.glitchActive = false;
        this.glitchWidth = 5;
        this.glitchDelay = 0;
        this.glitchPol = 0;
        this.glitchPin = 0;
        this.mitmMatchPattern = 0x00;
        this.mitmReplacePattern = 0x00;
        this.mitmEnabled = false;

        // Audio & PDM DAC
        this.audioEnabled = false;
        this.pdmAccum = 0;
        this.audioPdmBit = 0;
        this.audioSample = 128;
        this.audioToneFreq = 440;
        this.audioPhase = 0;

        // Waveform Profiler & Histogrammer
        this.profilerActive = false;
        this.profilerTmin = 0xFFFF;
        this.profilerEdgeCnt = 0;
        this.profilerLastLevel = 1;
        this.profilerPulseDuration = 0;

        // BIST Engine
        this.bistLfsr = 0x7F; // Non-zero seed
        this.bistLoopback = false;
        this.bistErrCnt = 0;
        this.bistTotalBits = 0;

        // Waveform recording trace buffer
        this.trace = [];
        this.traceIndex = 0;
        this.isRecording = true;

        // Breakpoints
        this.breakpoints = new Set();
        this.running = false;
    }

    loadProgram(machineCode) {
        this.imem.fill(0);
        for (let i = 0; i < machineCode.length && i < 128; i++) {
            this.imem[i] = machineCode[i];
        }
        this.pc = 0;
        this.nextPc = 0;
        this.state = "FETCH";
        this.delayCnt = 0;
    }

    stepInstruction() {
        if (this.imem.length === 0) return false;
        const startInstCount = this.instructionsExecuted;
        let limit = 10000; // max cycles safety
        while (this.instructionsExecuted === startInstCount && limit > 0) {
            this.stepCycle();
            limit--;
        }
        return true;
    }

    stepCycle() {
        this.totalCycles++;

        // 1. Process Hardware Assists & Background Engines
        this.tickHardwareAssists();

        // 2. Execution State Machine
        switch (this.state) {
            case "FETCH": {
                this.activeInst = this.imem[this.pc & 0x7F];
                this.decodeAndExecute(this.activeInst);
                this.instructionsExecuted++;
                break;
            }

            case "DELAY": {
                if (this.delayCnt > 0) {
                    this.delayCnt--;
                }
                if (this.delayCnt === 0) {
                    this.pc = this.nextPc;
                    this.state = "FETCH";
                }
                break;
            }

            case "WAIT_PIN": {
                // Checking pin condition
                const targetPin = (this.activeInst >> 1) & 0x7;
                const targetVal = this.activeInst & 0x1;
                const currentVal = (this.getEffectiveGpio() >> targetPin) & 0x1;

                if (currentVal === targetVal) {
                    if (this.delayCnt > 0) {
                        this.state = "DELAY";
                    } else {
                        this.pc = this.nextPc;
                        this.state = "FETCH";
                    }
                }
                break;
            }

            case "WAIT_FIFO": {
                // Blocking PULL / PUSH waiting for data
                const isPull = ((this.activeInst >> 12) & 0xF) === 0x9;
                if (isPull && this.txFifo.length > 0) {
                    this.osr = this.txFifo.shift();
                    this.osrCnt = 8;
                    this.osrValid = true;
                    this.pc = this.nextPc;
                    this.state = "FETCH";
                } else if (!isPull && this.rxFifo.length < this.fifoDepth) {
                    this.rxFifo.push(this.isr & 0xFF);
                    this.isrValid = false;
                    this.pc = this.nextPc;
                    this.state = "FETCH";
                }
                break;
            }
        }

        // 3. Record trace sample for Logic Analyzer
        if (this.isRecording) {
            this.recordTraceSample();
        }

        // Check if hit breakpoint
        if (this.breakpoints.has(this.pc) && this.state === "FETCH") {
            this.running = false;
            return false;
        }

        return true;
    }

    decodeAndExecute(inst) {
        const opcode = (inst >> 12) & 0xF;
        const sidecarDelayRaw = (inst >> 7) & 0x1F;
        let sidecarDelay = sidecarDelayRaw;

        if (sidecarDelayRaw === 0x1F) {
            sidecarDelay = this.baudDiv - 1; // $BAUD
        } else if (sidecarDelayRaw === 0x1E) {
            sidecarDelay = Math.floor(this.baudDiv / 2) - 1; // $HBAUD
        }

        this.nextPc = (this.pc + 1) & 0x7F;

        switch (opcode) {
            case 0x0: { // NOP
                this.enterDelay(sidecarDelay);
                break;
            }

            case 0x1: { // OUT pin, count
                const pin = (inst >> 4) & 0x7;
                const count = inst & 0xF;
                // Shift LSB out to selected pin
                const bit = this.osr & 0x1;
                this.osr = (this.osr >>> 1);
                this.setPinOutput(pin, bit);
                this.enterDelay(sidecarDelay);
                break;
            }

            case 0x2: { // IN pin, count
                const pin = (inst >> 4) & 0x7;
                const currentVal = (this.getEffectiveGpio() >> pin) & 0x1;
                this.isr = ((this.isr << 1) | currentVal) >>> 0;
                this.isrCnt++;
                this.isrValid = true;
                this.enterDelay(sidecarDelay);
                break;
            }

            case 0x3: { // SET pin, val
                const pin = (inst >> 1) & 0x7;
                const val = inst & 0x1;
                this.setPinOutput(pin, val);
                this.enterDelay(sidecarDelay);
                break;
            }

            case 0x4: { // WAIT pin, val
                const pin = (inst >> 1) & 0x7;
                const val = inst & 0x1;
                const currentVal = (this.getEffectiveGpio() >> pin) & 0x1;
                if (currentVal !== val) {
                    this.state = "WAIT_PIN";
                    this.delayCnt = sidecarDelay;
                    return;
                }
                this.enterDelay(sidecarDelay);
                break;
            }

            case 0x5: { // PINMAP
                const tx = (inst >> 6) & 0x3;
                const rx = (inst >> 4) & 0x3;
                const sck = (inst >> 2) & 0x3;
                const cs = inst & 0x3;
                this.pinmap = { tx, rx, sck, cs };
                this.enterDelay(0);
                break;
            }

            case 0x6: { // CFG_OD (Open-Drain Mask)
                this.gpioOd = inst & 0xFF;
                this.enterDelay(0);
                break;
            }

            case 0x7: { // DJNZ / SET_LC / LOOP
                const subop = (inst >> 10) & 0x3;
                const lc = (inst >> 9) & 0x1;
                const operand = inst & 0x7F;

                if (subop === 0) { // DJNZ
                    if (lc === 0) {
                        if (this.lc0 > 0) this.lc0--;
                        if (this.lc0 > 0) this.nextPc = operand;
                    } else {
                        if (this.lc1 > 0) this.lc1--;
                        if (this.lc1 > 0) this.nextPc = operand;
                    }
                } else if (subop === 1) { // SET_LC
                    const val = inst & 0x1FF;
                    if (lc === 0) this.lc0 = val;
                    else this.lc1 = val;
                }
                this.enterDelay(0);
                break;
            }

            case 0x8: { // JMP [cond,] target
                const cond = (inst >> 7) & 0xF;
                const target = inst & 0x7F;
                let takeJump = false;

                switch (cond) {
                    case 0: takeJump = true; break; // ALWAYS
                    case 1: takeJump = this.flags.z === 1; break; // ZERO / EQ
                    case 2: takeJump = this.flags.z === 0; break; // NZ / NE
                    case 3: takeJump = this.flags.c === 1; break; // CARRY
                    case 4: takeJump = this.flags.c === 0; break; // NC
                    case 5: takeJump = this.txFifo.length === 0; break; // FIFO_EMPTY
                    case 6: takeJump = this.txFifo.length >= this.fifoDepth; break; // FIFO_FULL
                    default: takeJump = true; break;
                }

                if (takeJump) {
                    this.nextPc = target;
                }
                this.enterDelay(0);
                break;
            }

            case 0x9: { // PULL
                const isBlock = (inst & 0x1) === 1;
                if (this.txFifo.length > 0) {
                    this.osr = this.txFifo.shift();
                    this.osrCnt = 8;
                    this.osrValid = true;
                    this.enterDelay(0);
                } else if (isBlock) {
                    this.state = "WAIT_FIFO";
                    return;
                } else {
                    this.osr = 0;
                    this.osrValid = false;
                    this.enterDelay(0);
                }
                break;
            }

            case 0xA: { // PUSH
                const isBlock = (inst & 0x1) === 1;
                if (this.rxFifo.length < this.fifoDepth) {
                    this.rxFifo.push(this.isr & 0xFF);
                    this.isrValid = false;
                    this.enterDelay(0);
                } else if (isBlock) {
                    this.state = "WAIT_FIFO";
                    return;
                } else {
                    this.enterDelay(0);
                }
                break;
            }

            case 0xB: { // ALU Operations & Flags
                const subop = (inst >> 8) & 0x7;
                const val = inst & 0xFF;
                let result = this.acc;

                switch (subop) {
                    case 0: // ADD
                        result = this.acc + val;
                        this.flags.c = result > 0xFF ? 1 : 0;
                        this.acc = result & 0xFF;
                        break;
                    case 1: // SUB
                        result = this.acc - val;
                        this.flags.c = result < 0 ? 1 : 0;
                        this.acc = result & 0xFF;
                        break;
                    case 2: // CMP
                        result = this.acc - val;
                        this.flags.c = result < 0 ? 1 : 0;
                        this.flags.z = (result & 0xFF) === 0 ? 1 : 0;
                        break;
                    case 3: // AND
                        this.acc = (this.acc & val) & 0xFF;
                        break;
                    case 4: // OR
                        this.acc = (this.acc | val) & 0xFF;
                        break;
                    case 5: // XOR
                        this.acc = (this.acc ^ val) & 0xFF;
                        break;
                    case 6: // MOV
                        this.acc = val & 0xFF;
                        break;
                    case 7: // NOT / INV
                        this.acc = (~this.acc) & 0xFF;
                        break;
                }

                if (subop !== 2) {
                    this.flags.z = this.acc === 0 ? 1 : 0;
                    this.flags.n = (this.acc & 0x80) !== 0 ? 1 : 0;
                }
                this.enterDelay(0);
                break;
            }

            case 0xC: { // CALL target
                const target = inst & 0x7F;
                if (this.callSp < 4) {
                    this.callStack[this.callSp] = this.nextPc;
                    this.callSp++;
                }
                this.nextPc = target;
                this.enterDelay(0);
                break;
            }

            case 0xD: { // RET
                if (this.callSp > 0) {
                    this.callSp--;
                    this.nextPc = this.callStack[this.callSp];
                }
                this.enterDelay(0);
                break;
            }

            case 0xE: { // CRC Engine
                const subop = (inst >> 8) & 0xF;
                const byteVal = inst & 0xFF;

                if (subop === 1) { // CRC_INIT
                    this.crcAccum = 0xFFFFFFFF;
                } else if (subop === 2) { // CRC_BYTE
                    this.stepCrc(byteVal);
                } else if (subop >= 5 && subop <= 8) { // READ B0..B3
                    const byteIdx = subop - 5;
                    this.acc = (this.crcAccum >>> (byteIdx * 8)) & 0xFF;
                }
                this.enterDelay(0);
                break;
            }

            case 0xF: { // Assists (Pulse, Glitch, Audio, Profiler, BIST)
                const assistSub = (inst >> 8) & 0xF;
                const val = inst & 0xFF;

                if (assistSub === 0x4) { // AUDIO
                    this.audioEnabled = true;
                    this.audioSample = val;
                } else if (assistSub === 0x8) { // GLITCH
                    this.glitchActive = true;
                    this.glitchWidth = val > 0 ? val : 5;
                } else if (assistSub === 0x9) { // MITM
                    this.mitmEnabled = true;
                    this.mitmMatchPattern = val;
                } else if (assistSub === 0xA) { // PROFILER
                    this.profilerActive = true;
                } else if (assistSub === 0xC) { // BIST
                    this.bistLoopback = true;
                }
                this.enterDelay(0);
                break;
            }
        }
    }

    enterDelay(delay) {
        if (delay > 0) {
            this.state = "DELAY";
            this.delayCnt = delay;
        } else {
            this.pc = this.nextPc;
            this.state = "FETCH";
        }
    }

    setPinOutput(pin, val) {
        const bitMask = 1 << pin;
        const isOd = (this.gpioOd & bitMask) !== 0;

        if (isOd) {
            // Open-drain: val=0 drives LOW (OE=1, OUT=0), val=1 releases Hi-Z (OE=0)
            if (val === 0) {
                this.uioOe |= bitMask;
                this.uioOut &= ~bitMask;
            } else {
                this.uioOe &= ~bitMask;
                this.uioOut &= ~bitMask;
            }
        } else {
            // Push-pull drive
            this.uioOe |= bitMask;
            if (val === 1) {
                this.uioOut |= bitMask;
            } else {
                this.uioOut &= ~bitMask;
            }
        }
    }

    getEffectiveGpio() {
        // Output pins driven by core, undriven pins take external / pull-up value
        let effective = 0;
        for (let p = 0; p < 8; p++) {
            const mask = 1 << p;
            const isDriven = (this.uioOe & mask) !== 0;
            if (isDriven) {
                effective |= (this.uioOut & mask);
            } else {
                effective |= (this.uioIn & mask); // default 1 from pullup
            }
        }
        return effective;
    }

    stepCrc(byte) {
        let crc = this.crcAccum ^ byte;
        for (let j = 0; j < 8; j++) {
            if (crc & 1) {
                crc = (crc >>> 1) ^ 0xEDB88320;
            } else {
                crc = (crc >>> 1);
            }
        }
        this.crcAccum = crc >>> 0;
    }

    tickHardwareAssists() {
        // 1. Audio Delta-Sigma PDM Modulator
        if (this.audioEnabled) {
            this.pdmAccum += this.audioSample;
            if (this.pdmAccum >= 256) {
                this.pdmAccum -= 256;
                this.audioPdmBit = 1;
            } else {
                this.audioPdmBit = 0;
            }
        }

        // 2. Glitch Pulse Generator
        if (this.glitchActive) {
            if (this.glitchWidth > 0) {
                this.glitchWidth--;
            } else {
                this.glitchActive = false;
            }
        }

        // 3. Profiler Edge & Minimum Pulse Histogrammer
        const curPin0 = (this.getEffectiveGpio() & 1);
        if (curPin0 !== this.profilerLastLevel) {
            this.profilerEdgeCnt++;
            if (this.profilerPulseDuration > 0 && this.profilerPulseDuration < this.profilerTmin) {
                this.profilerTmin = this.profilerPulseDuration;
            }
            this.profilerPulseDuration = 0;
            this.profilerLastLevel = curPin0;
        } else {
            this.profilerPulseDuration++;
        }

        // 4. BIST LFSR Progress
        if (this.bistLoopback) {
            const feedback = ((this.bistLfsr >> 6) ^ (this.bistLfsr >> 5)) & 1;
            this.bistLfsr = (((this.bistLfsr << 1) | feedback) & 0x7F) || 0x7F;
            this.bistTotalBits++;
        }
    }

    recordTraceSample() {
        const gpio = this.getEffectiveGpio();
        const sample = {
            cycle: this.totalCycles,
            pc: this.pc,
            gpio: gpio,
            oe: this.uioOe,
            p0: (gpio >> 0) & 1,
            p1: (gpio >> 1) & 1,
            p2: (gpio >> 2) & 1,
            p3: (gpio >> 3) & 1,
            p4: (gpio >> 4) & 1,
            p5: (gpio >> 5) & 1,
            p6: (gpio >> 6) & 1,
            p7: (gpio >> 7) & 1,
            glitch: this.glitchActive ? 1 : 0,
            pdm: this.audioPdmBit,
            osrValid: this.osrValid ? 1 : 0,
            isrValid: this.isrValid ? 1 : 0
        };

        this.trace.push(sample);
        if (this.trace.length > this.maxCyclesHistory) {
            this.trace.shift();
        }
    }

    pushTxByte(byte) {
        if (this.txFifo.length < this.fifoDepth) {
            this.txFifo.push(byte & 0xFF);
            return true;
        }
        return false;
    }

    popRxByte() {
        return this.rxFifo.length > 0 ? this.rxFifo.shift() : null;
    }
}
