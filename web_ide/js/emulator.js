// =============================================================================
// File        : emulator.js
// Module      : OmniBus MP Cycle-Accurate Silicon Multi-Core Emulator
// Description : Cycle-by-cycle Verilog-equivalent behavioral emulator of the
//               OmniBus MP Symmetric Multi-Engine Architecture.
//               Supports parameterized 1, 2, or 4 Cores (NUM_CORES = 1, 2, 4),
//               8 Shared Mailboxes, 4 Atomic Spinlocks, Hardware Rendezvous Barrier,
//               Inter-Core Cascade FIFOs, Sidecar Delays, and Waveform Telemetry.
// License     : MIT License
// =============================================================================

export class OmniBusEmulator {
    constructor(clkFreqHz = 50000000, numCores = 2) {
        this.clkFreqHz = clkFreqHz;
        this.numCores = numCores; // 1, 2, or 4
        this.baudDiv = 434; // Default 115200 at 50 MHz
        this.maxCyclesHistory = 20000;
        this.reset();
    }

    setNumCores(n) {
        this.numCores = Math.max(1, Math.min(4, n === 3 ? 4 : n));
        for (let i = 0; i < 4; i++) {
            if (this.cores[i]) {
                this.cores[i].enabled = (i < this.numCores);
            }
        }
    }

    reset() {
        // IMEM: 128 words x 16-bit (32 words per bank)
        this.imem = new Uint16Array(128);
        this.totalCycles = 0;
        this.instructionsExecuted = 0;

        // Core Array: 4 Symmetric Micro-Engine Slices
        this.cores = Array.from({ length: 4 }, (_, id) => ({
            id: id,
            enabled: (id < this.numCores),
            bank: id,
            pc: id * 32,
            nextPc: id * 32,
            resetPc: id * 32,
            state: "FETCH", // "FETCH", "EXEC", "DELAY", "WAIT_PIN", "WAIT_FIFO", "BARRIER_WAIT", "HALTED"
            delayCnt: 0,
            activeInst: 0,
            lastDisasm: "NOP",
            instructionsExecuted: 0,
            
            // Registers & Stack
            acc: 0,
            flags: { z: 1, c: 0, n: 0 },
            r: new Uint8Array(8), // R0..R7
            lc0: 0,
            lc1: 0,
            callStack: [0, 0, 0, 0],
            callSp: 0,

            // SERDES & Shift Registers
            osr: 0,
            isr: 0,
            osrCnt: 0,
            isrCnt: 0,
            osrValid: false,
            isrValid: false,

            // Pin Matrix & Open-Drain
            pinmap: { tx: (id * 4 + 0) & 7, rx: (id * 4 + 3) & 7, sck: (id * 4 + 1) & 7, cs: (id * 4 + 2) & 7 },
            uioOut: 0,
            uioOe: 0,
            gpioOd: 0,

            // Subsystems (CRC, etc.)
            crcAccum: 0xFFFFFFFF,
            crcPoly: 0xEDB88320
        }));

        // Shared Inter-Core Hardware Synchronization Fabric
        this.mailboxes = new Uint8Array(8);
        this.mbLastAccess = Array.from({ length: 8 }, () => ({ core: null, action: null, cycle: 0 }));
        this.spinlocks = [null, null, null, null]; // null = unlocked, 0..3 = core id owner
        this.barrierArrived = [false, false, false, false];
        this.barrierReleasePulse = false;

        // Inter-Core Cascade Streaming FIFOs (Depth 16 each)
        this.cascadeFifos = Array.from({ length: 4 }, () => []);
        this.cascadeStreamMode = true; // true = circular cascade pipeline, false = independent host

        // Host Level FIFOs (64 bytes each)
        this.txFifo = [];
        this.rxFifo = [];
        this.fifoDepth = 64;

        // Global Physical Pins
        this.uioOut = 0;
        this.uioOe = 0;
        this.uioIn = 0xFF; // External pullups default HIGH

        // Hardware Assists
        this.nrziState = 1;
        this.bitStuffCount = 0;
        this.pulseTime0 = 17;
        this.pulseTime1 = 35;
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

        // Profiler & BIST
        this.profilerActive = false;
        this.profilerTmin = 0xFFFF;
        this.profilerEdgeCnt = 0;
        this.profilerLastLevel = 1;
        this.profilerPulseDuration = 0;

        this.bistLfsr = 0x7F;
        this.bistLoopback = false;
        this.bistErrCnt = 0;
        this.bistTotalBits = 0;

        // Waveform Trace Buffer
        this.trace = [];
        this.isRecording = true;
        this.running = false;
    }

    // Single-Core Backward Compatibility Getters
    get pc() { return this.cores[0].pc; }
    set pc(val) { this.cores[0].pc = val; }
    get state() { return this.cores[0].state; }
    get delayCnt() { return this.cores[0].delayCnt; }
    get activeInst() { return this.cores[0].activeInst; }
    get lc0() { return this.cores[0].lc0; }
    get lc1() { return this.cores[0].lc1; }
    get acc() { return this.cores[0].acc; }
    get flags() { return this.cores[0].flags; }
    get osr() { return this.cores[0].osr; }
    get isr() { return this.cores[0].isr; }
    get callStack() { return this.cores[0].callStack; }

    loadProgram(machineCode) {
        this.imem.fill(0);
        for (let i = 0; i < machineCode.length && i < 128; i++) {
            this.imem[i] = machineCode[i];
        }
        for (let i = 0; i < 4; i++) {
            this.cores[i].pc = i * 32;
            this.cores[i].nextPc = i * 32;
            this.cores[i].state = "FETCH";
            this.cores[i].delayCnt = 0;
        }
    }

    stepInstruction() {
        if (this.imem.length === 0) return false;
        const startInstCount = this.instructionsExecuted;
        let limit = 10000;
        while (this.instructionsExecuted === startInstCount && limit > 0) {
            this.stepCycle();
            limit--;
        }
        return true;
    }

    stepCycle() {
        this.totalCycles++;

        // 1. Process Hardware Assists & Background Generators
        this.tickHardwareAssists();

        // 2. Multi-Core Concurrent Execution Slices
        for (let c = 0; c < 4; c++) {
            const core = this.cores[c];
            if (!core.enabled) continue;

            this.stepCoreCycle(core);
        }

        // 3. Hardware Rendezvous Barrier Evaluation
        this.evaluateBarrier();

        // 4. Resolve Combined Physical Pin Matrix
        this.resolveGpioMatrix();

        // 5. Record Multi-Core Waveform Sample
        if (this.isRecording) {
            this.recordTraceSample();
        }
    }

    stepCoreCycle(core) {
        switch (core.state) {
            case "BARRIER_WAIT": {
                // Stalled at rendezvous point until all active cores arrive
                break;
            }

            case "DELAY": {
                if (core.delayCnt > 0) {
                    core.delayCnt--;
                }
                if (core.delayCnt === 0) {
                    core.state = "FETCH";
                }
                break;
            }

            case "WAIT_PIN": {
                const effective = this.getEffectiveGpio();
                const pinBit = (effective >> core.waitPinSel) & 1;
                if (pinBit === core.waitPinVal) {
                    core.state = "FETCH";
                    if (core.waitSidecarDelay > 0) {
                        core.state = "DELAY";
                        core.delayCnt = core.waitSidecarDelay;
                    }
                }
                break;
            }

            case "WAIT_FIFO": {
                let hasData = false;
                if (this.cascadeStreamMode) {
                    const srcFifo = (core.id === 0) ? this.txFifo : this.cascadeFifos[(core.id - 1) & 3];
                    hasData = srcFifo.length > 0;
                } else {
                    hasData = this.txFifo.length > 0;
                }
                if (hasData) {
                    core.state = "FETCH";
                }
                break;
            }

            case "FETCH":
            default: {
                core.activeInst = this.imem[core.pc & 0x7F];
                core.lastDisasm = this.disassembleInstruction(core.activeInst);
                this.decodeAndExecuteCore(core, core.activeInst);
                core.instructionsExecuted++;
                this.instructionsExecuted++;
                break;
            }
        }
    }

    decodeAndExecuteCore(core, instr) {
        const opcode = (instr >> 12) & 0xF;
        let nextPc = (core.pc + 1) & 0x7F;
        let sidecarDelay = 0;

        switch (opcode) {
            // NOP (0x0)
            case 0x0: {
                sidecarDelay = this.resolveDelay(instr & 0x1FF);
                break;
            }

            // OUT (0x1)
            case 0x1: {
                const pinSel = (instr >> 9) & 0x7;
                const bitCount = ((instr >> 5) & 0xF) || 1;
                sidecarDelay = this.resolveDelay(instr & 0x1F);
                
                // Shift out from OSR LSB
                const outBit = core.osr & 1;
                core.osr = (core.osr >>> 1);
                core.osrCnt = Math.max(0, core.osrCnt - 1);
                core.osrValid = (core.osrCnt > 0);

                const pinIndex = this.getPinIndex(core, pinSel);
                this.setCorePin(core, pinIndex, outBit, 1);
                break;
            }

            // IN (0x2)
            case 0x2: {
                const pinSel = (instr >> 9) & 0x7;
                const bitCount = ((instr >> 5) & 0xF) || 1;
                sidecarDelay = this.resolveDelay(instr & 0x1F);

                const pinIndex = this.getPinIndex(core, pinSel);
                const effective = this.getEffectiveGpio();
                const inBit = (effective >> pinIndex) & 1;

                core.isr = ((core.isr << 1) | inBit) >>> 0;
                core.isrCnt = Math.min(32, core.isrCnt + 1);
                core.isrValid = true;
                break;
            }

            // SET (0x3)
            case 0x3: {
                const pinSel = (instr >> 9) & 0x7;
                const pinVal = (instr >> 8) & 0x1;
                sidecarDelay = this.resolveDelay(instr & 0xFF);

                const pinIndex = this.getPinIndex(core, pinSel);
                this.setCorePin(core, pinIndex, pinVal, 1);
                break;
            }

            // WAIT (0x4)
            case 0x4: {
                const pinSel = (instr >> 9) & 0x7;
                const pinVal = (instr >> 8) & 0x1;
                sidecarDelay = this.resolveDelay(instr & 0xFF);

                const pinIndex = this.getPinIndex(core, pinSel);
                const effective = this.getEffectiveGpio();
                const curVal = (effective >> pinIndex) & 1;

                if (curVal !== pinVal) {
                    core.state = "WAIT_PIN";
                    core.waitPinSel = pinIndex;
                    core.waitPinVal = pinVal;
                    core.waitSidecarDelay = sidecarDelay;
                    return; // Don't advance PC until pin condition is met
                }
                break;
            }

            // PINMAP (0x5)
            case 0x5: {
                core.pinmap.tx  = (instr >> 6) & 0x3;
                core.pinmap.rx  = (instr >> 4) & 0x3;
                core.pinmap.sck = (instr >> 2) & 0x3;
                core.pinmap.cs  = (instr >> 0) & 0x3;
                break;
            }

            // CFG_OD (0x6)
            case 0x6: {
                core.gpioOd = instr & 0xFF;
                break;
            }

            // LOOP / DJNZ (0x7)
            case 0x7: {
                const subOp = (instr >> 9) & 0x7;
                const target = instr & 0x7F;
                if (subOp === 0) {
                    // DJNZ LC0
                    if (core.lc0 > 0) {
                        core.lc0--;
                        if (core.lc0 > 0) nextPc = target;
                    }
                } else if (subOp === 1) {
                    // DJNZ LC1
                    if (core.lc1 > 0) {
                        core.lc1--;
                        if (core.lc1 > 0) nextPc = target;
                    }
                } else if (subOp === 2) {
                    // SET_LC LC0
                    core.lc0 = instr & 0xFF;
                } else if (subOp === 3) {
                    // SET_LC LC1
                    core.lc1 = instr & 0xFF;
                }
                break;
            }

            // JMP (0x8)
            case 0x8: {
                const cond = (instr >> 7) & 0x1F;
                const target = instr & 0x7F;
                let takeJump = false;

                switch (cond) {
                    case 0: takeJump = true; break; // ALWAYS
                    case 1: takeJump = (core.flags.z === 1); break; // ZERO / EQ
                    case 2: takeJump = (core.flags.z === 0); break; // NOT_ZERO / NE
                    case 3: takeJump = (core.flags.c === 1); break; // CARRY
                    case 4: takeJump = (core.flags.c === 0); break; // NOT_CARRY
                    case 5: takeJump = (this.txFifo.length === 0); break;
                    case 6: takeJump = (this.txFifo.length >= this.fifoDepth); break;
                    default: takeJump = true; break;
                }

                if (takeJump) {
                    nextPc = target;
                }
                break;
            }

            // PULL (0x9)
            case 0x9: {
                const isBlock = (instr >> 8) & 0x1;
                let pulledByte = null;

                if (this.cascadeStreamMode) {
                    const srcFifo = (core.id === 0) ? this.txFifo : this.cascadeFifos[(core.id - 1) & 3];
                    if (srcFifo.length > 0) {
                        pulledByte = srcFifo.shift();
                    }
                } else {
                    if (this.txFifo.length > 0) {
                        pulledByte = this.txFifo.shift();
                    }
                }

                if (pulledByte !== null) {
                    core.osr = pulledByte & 0xFF;
                    core.osrCnt = 8;
                    core.osrValid = true;
                } else if (isBlock) {
                    core.state = "WAIT_FIFO";
                    return;
                }
                break;
            }

            // PUSH (0xA)
            case 0xA: {
                const byteToPush = core.acc & 0xFF;
                if (this.cascadeStreamMode) {
                    if (core.id === (this.numCores - 1)) {
                        // Final core pushes to Host RX FIFO
                        if (this.rxFifo.length < this.fifoDepth) {
                            this.rxFifo.push(byteToPush);
                        }
                    } else {
                        // Intermediate core pushes to next cascade FIFO
                        const dstFifo = this.cascadeFifos[core.id];
                        if (dstFifo.length < 16) {
                            dstFifo.push(byteToPush);
                        }
                    }
                } else {
                    if (this.rxFifo.length < this.fifoDepth) {
                        this.rxFifo.push(byteToPush);
                    }
                }
                break;
            }

            // ALU (0xB)
            case 0xB: {
                this.executeAlu(core, instr);
                break;
            }

            // CALL (0xC)
            case 0xC: {
                const target = instr & 0x7F;
                core.callStack[core.callSp & 3] = (core.pc + 1) & 0x7F;
                core.callSp = (core.callSp + 1) & 3;
                nextPc = target;
                break;
            }

            // RET (0xD)
            case 0xD: {
                core.callSp = (core.callSp - 1 + 4) & 3;
                nextPc = core.callStack[core.callSp & 3];
                break;
            }

            // CRC (0xE)
            case 0xE: {
                const crcSub = (instr >> 8) & 0xF;
                const imm = instr & 0xFF;
                if (crcSub === 0) {
                    core.crcAccum = 0xFFFFFFFF;
                } else if (crcSub === 1) {
                    this.stepCrc(core, core.acc);
                } else if (crcSub === 2) {
                    this.stepCrc(core, core.osr & 0xFF);
                } else if (crcSub === 3) {
                    core.acc = core.crcAccum & 0xFF;
                } else if (crcSub === 4) {
                    core.acc = (core.crcAccum >>> 8) & 0xFF;
                }
                break;
            }

            // ASSIST / Multi-Core MP (0xF)
            case 0xF: {
                const subMajor = (instr >> 10) & 0x3;
                const subMinor = (instr >> 8) & 0x3;
                const payload = instr & 0xFF;

                // 1. CORE_ID (0xFC00): [11:10]=00, [9:8]=00
                if (subMajor === 0 && subMinor === 0) {
                    core.acc = core.id;
                    core.flags.z = (core.acc === 0 ? 1 : 0);
                }
                // 2. SPINLOCK_ACQ (0xFD00 | id): [11:10]=01, [9:8]=00
                else if (subMajor === 1 && subMinor === 0) {
                    const lockId = payload & 3;
                    if (this.spinlocks[lockId] === null || this.spinlocks[lockId] === core.id) {
                        this.spinlocks[lockId] = core.id;
                        core.acc = 0;
                        core.flags.z = 1; // Success
                    } else {
                        core.acc = 1;
                        core.flags.z = 0; // Contention / Spin
                    }
                }
                // 3. SPINLOCK_REL (0xFE00 | id): [11:10]=01, [9:8]=01
                else if (subMajor === 1 && subMinor === 1) {
                    const lockId = payload & 3;
                    if (this.spinlocks[lockId] === core.id) {
                        this.spinlocks[lockId] = null;
                    }
                }
                // 4. MB_READ (0xF800 | id): [11:10]=10, [9:8]=00
                else if (subMajor === 2 && subMinor === 0) {
                    const mbId = payload & 7;
                    core.acc = this.mailboxes[mbId];
                    core.flags.z = (core.acc === 0 ? 1 : 0);
                    this.mbLastAccess[mbId] = { core: core.id, action: "READ", cycle: this.totalCycles };
                }
                // 5. MB_WRITE (0xF900 | id): [11:10]=10, [9:8]=01
                else if (subMajor === 2 && subMinor === 1) {
                    const mbId = payload & 7;
                    this.mailboxes[mbId] = core.acc;
                    this.mbLastAccess[mbId] = { core: core.id, action: "WRITE", cycle: this.totalCycles };
                }
                // 6. BARRIER_WAIT (0xFF00): [11:10]=11, [9:8]=11
                else if (subMajor === 3 && subMinor === 3) {
                    this.barrierArrived[core.id] = true;
                    core.state = "BARRIER_WAIT";
                    core.pc = nextPc;
                    return; // Wait for barrier release pulse
                }
                break;
            }
        }

        core.pc = nextPc;
        if (sidecarDelay > 0) {
            core.state = "DELAY";
            core.delayCnt = sidecarDelay;
        }
    }

    executeAlu(core, instr) {
        const aluOp = (instr >> 8) & 0xF;
        const operand = instr & 0xFF;

        switch (aluOp) {
            case 0: { // ADD
                const sum = core.acc + operand;
                core.flags.c = sum > 0xFF ? 1 : 0;
                core.acc = sum & 0xFF;
                core.flags.z = core.acc === 0 ? 1 : 0;
                break;
            }
            case 1: { // SUB
                const diff = core.acc - operand;
                core.flags.c = diff < 0 ? 1 : 0;
                core.acc = diff & 0xFF;
                core.flags.z = core.acc === 0 ? 1 : 0;
                break;
            }
            case 2: { // CMP
                const cmp = core.acc - operand;
                core.flags.c = cmp < 0 ? 1 : 0;
                core.flags.z = (core.acc === operand) ? 1 : 0;
                break;
            }
            case 3: { // AND
                core.acc = (core.acc & operand) & 0xFF;
                core.flags.z = core.acc === 0 ? 1 : 0;
                break;
            }
            case 4: { // OR
                core.acc = (core.acc | operand) & 0xFF;
                core.flags.z = core.acc === 0 ? 1 : 0;
                break;
            }
            case 5: { // XOR
                core.acc = (core.acc ^ operand) & 0xFF;
                core.flags.z = core.acc === 0 ? 1 : 0;
                break;
            }
            case 6: { // MOV
                const src = (operand >> 4) & 0xF;
                const dst = operand & 0xF;
                let val = 0;
                if (src === 0) val = core.acc;
                else if (src === 1) val = core.osr & 0xFF;
                else if (src === 2) val = core.isr & 0xFF;
                else if (src >= 8 && src <= 15) val = core.r[src - 8];
                else val = operand;

                if (dst === 0) core.acc = val;
                else if (dst === 1) core.osr = val;
                else if (dst === 2) core.isr = val;
                else if (dst >= 8 && dst <= 15) core.r[dst - 8] = val;
                core.flags.z = core.acc === 0 ? 1 : 0;
                break;
            }
            case 7: { // NOT
                core.acc = (~core.acc) & 0xFF;
                core.flags.z = core.acc === 0 ? 1 : 0;
                break;
            }
            case 14: { // INC
                core.acc = (core.acc + 1) & 0xFF;
                core.flags.z = core.acc === 0 ? 1 : 0;
                break;
            }
            case 15: { // DEC
                core.acc = (core.acc - 1 + 256) & 0xFF;
                core.flags.z = core.acc === 0 ? 1 : 0;
                break;
            }
        }
    }

    evaluateBarrier() {
        // Check if all active/enabled cores have arrived at the barrier
        let allArrived = true;
        for (let i = 0; i < this.numCores; i++) {
            if (!this.barrierArrived[i]) {
                allArrived = false;
                break;
            }
        }

        if (allArrived && this.numCores > 0) {
            // Simultaneous lockstep release
            this.barrierArrived.fill(false);
            for (let i = 0; i < this.numCores; i++) {
                if (this.cores[i].state === "BARRIER_WAIT") {
                    this.cores[i].state = "FETCH";
                }
            }
            this.barrierReleasePulse = true;
        } else {
            this.barrierReleasePulse = false;
        }
    }

    resolveGpioMatrix() {
        let combinedOut = 0;
        let combinedOe = 0;

        for (let i = 0; i < this.numCores; i++) {
            const core = this.cores[i];
            combinedOut |= core.uioOut;
            combinedOe |= core.uioOe;
        }

        this.uioOut = combinedOut & 0xFF;
        this.uioOe = combinedOe & 0xFF;
    }

    getEffectiveGpio() {
        let effective = 0;
        for (let p = 0; p < 8; p++) {
            const mask = 1 << p;
            const isDriven = (this.uioOe & mask) !== 0;
            if (isDriven) {
                effective |= (this.uioOut & mask);
            } else {
                effective |= (this.uioIn & mask);
            }
        }
        return effective;
    }

    setCorePin(core, pinIndex, val, oe) {
        const mask = 1 << (pinIndex & 7);
        if (oe) {
            core.uioOe |= mask;
        } else {
            core.uioOe &= ~mask;
        }

        if (val) {
            core.uioOut |= mask;
        } else {
            core.uioOut &= ~mask;
        }
    }

    getPinIndex(core, pinSel) {
        if (pinSel === 0) return core.pinmap.tx;
        if (pinSel === 1) return core.pinmap.rx;
        if (pinSel === 2) return core.pinmap.sck;
        if (pinSel === 3) return core.pinmap.cs;
        return pinSel & 7;
    }

    resolveDelay(delayVal) {
        if (delayVal === 0x1FF || delayVal === 0xFF) return this.baudDiv;
        if (delayVal === 0x1FE || delayVal === 0xFE) return Math.floor(this.baudDiv / 2);
        return delayVal;
    }

    stepCrc(core, byte) {
        let crc = core.crcAccum ^ byte;
        for (let j = 0; j < 8; j++) {
            if (crc & 1) {
                crc = (crc >>> 1) ^ core.crcPoly;
            } else {
                crc = (crc >>> 1);
            }
        }
        core.crcAccum = crc >>> 0;
    }

    tickHardwareAssists() {
        if (this.audioEnabled) {
            this.pdmAccum += this.audioSample;
            if (this.pdmAccum >= 256) {
                this.pdmAccum -= 256;
                this.audioPdmBit = 1;
            } else {
                this.audioPdmBit = 0;
            }
        }

        if (this.glitchActive) {
            if (this.glitchWidth > 0) {
                this.glitchWidth--;
            } else {
                this.glitchActive = false;
            }
        }
    }

    recordTraceSample() {
        const gpio = this.getEffectiveGpio();
        const sample = {
            cycle: this.totalCycles,
            pc0: this.cores[0].pc,
            pc1: this.cores[1].pc,
            pc2: this.cores[2].pc,
            pc3: this.cores[3].pc,
            barrierPulse: this.barrierReleasePulse ? 1 : 0,
            spinlocks: (this.spinlocks[0] !== null ? 1 : 0) | ((this.spinlocks[1] !== null ? 1 : 0) << 1),
            gpio: gpio,
            p0: (gpio >> 0) & 1,
            p1: (gpio >> 1) & 1,
            p2: (gpio >> 2) & 1,
            p3: (gpio >> 3) & 1,
            p4: (gpio >> 4) & 1,
            p5: (gpio >> 5) & 1,
            p6: (gpio >> 6) & 1,
            p7: (gpio >> 7) & 1,
            glitch: this.glitchActive ? 1 : 0,
            pdm: this.audioPdmBit
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

    forceUnlockSpinlock(lockId) {
        if (lockId >= 0 && lockId < 4) {
            this.spinlocks[lockId] = null;
        }
    }

    disassembleInstruction(word) {
        const opcode = (word >> 12) & 0xF;
        const opHex = `0x${word.toString(16).padStart(4, "0").toUpperCase()}`;
        switch (opcode) {
            case 0x0: return `NOP [${word & 0x1FF}]`;
            case 0x1: return `OUT [${word & 0x1F}]`;
            case 0x2: return `IN [${word & 0x1F}]`;
            case 0x3: return `SET pin${(word>>9)&7}=${(word>>8)&1} [${word&0xFF}]`;
            case 0x4: return `WAIT pin${(word>>9)&7}==${(word>>8)&1}`;
            case 0x5: return `PINMAP tx=${(word>>6)&3} rx=${(word>>4)&3} sck=${(word>>2)&3} cs=${word&3}`;
            case 0x6: return `CFG_OD 0x${(word&0xFF).toString(16).toUpperCase()}`;
            case 0x7: return `LOOP / DJNZ 0x${(word&0x7F).toString(16).toUpperCase()}`;
            case 0x8: return `JMP 0x${(word&0x7F).toString(16).toUpperCase()}`;
            case 0x9: return `PULL`;
            case 0xA: return `PUSH`;
            case 0xB: {
                const aluOp = (word >> 8) & 0xF;
                const ops = ["ADD", "SUB", "CMP", "AND", "OR", "XOR", "MOV", "NOT", "INV", "SHL", "SHR", "ROL", "ROR", "CLR", "INC", "DEC"];
                return `${ops[aluOp] || "ALU"} 0x${(word&0xFF).toString(16).toUpperCase()}`;
            }
            case 0xC: return `CALL 0x${(word&0x7F).toString(16).toUpperCase()}`;
            case 0xD: return `RET`;
            case 0xE: return `CRC`;
            case 0xF: {
                const subMaj = (word >> 10) & 3;
                const subMin = (word >> 8) & 3;
                const p = word & 0xFF;
                if (subMaj === 0 && subMin === 0) return `CORE_ID`;
                if (subMaj === 1 && subMin === 0) return `SPINLOCK_ACQ ${p & 3}`;
                if (subMaj === 1 && subMin === 1) return `SPINLOCK_REL ${p & 3}`;
                if (subMaj === 2 && subMin === 0) return `MB_READ ${p & 7}`;
                if (subMaj === 2 && subMin === 1) return `MB_WRITE ${p & 7}`;
                if (subMaj === 3 && subMin === 3) return `BARRIER_WAIT`;
                return `ASSIST [${opHex}]`;
            }
            default: return `INST [${opHex}]`;
        }
    }
}
