// =============================================================================
// File        : app.js
// Module      : OmniBus MP Web IDE Main Application Orchestrator
// Description : Manages Multi-Core UI state, code editing, assembly compilation,
//               cycle-by-cycle execution, multi-core waveform visualization,
//               shared mailbox & spinlock telemetry, and WebSerial hardware flashing.
// License     : MIT License
// =============================================================================

import { OmniBusAssembler } from "./assembler.js";
import { OmniBusEmulator } from "./emulator.js";
import { WaveformViewer } from "./waveform.js";
import { OmniBusAudioEngine } from "./audio_engine.js";
import { OmniBusWebSerial } from "./webserial.js";
import { PRESETS } from "./presets.js";

class OmniBusApp {
    constructor() {
        this.assembler = new OmniBusAssembler(50000000);
        this.emulator = new OmniBusEmulator(50000000, 2);
        this.audio = new OmniBusAudioEngine();
        this.webSerial = new OmniBusWebSerial();
        this.waveform = null;

        this.currentPresetId = "multicore_uart_spi_bridge";
        this.animFrameId = null;
        this.execSpeed = 1000;
        this.compiledData = null;

        window.app = this;
        this.init();
    }

    init() {
        this.cacheDomElements();
        this.populatePresets();
        this.setupWaveform();
        this.bindEvents();
        this.loadPreset(this.currentPresetId);
        this.updateUi();
    }

    cacheDomElements() {
        this.codeEditor = document.getElementById("code-editor");
        this.lineNumbers = document.getElementById("line-numbers");
        this.presetSelect = document.getElementById("preset-select");
        this.coreCountSelect = document.getElementById("core-count-select");
        this.statusBadge = document.getElementById("status-badge");
        this.clockFreqSelect = document.getElementById("clock-freq-select");
        this.speedSlider = document.getElementById("speed-slider");
        this.speedLabel = document.getElementById("speed-label");
        this.labelNumCores = document.getElementById("label-num-cores");

        // Action Buttons
        this.btnAssemble = document.getElementById("btn-assemble");
        this.btnRun = document.getElementById("btn-run");
        this.btnPause = document.getElementById("btn-pause");
        this.btnStepInst = document.getElementById("btn-step-inst");
        this.btnStepCycle = document.getElementById("btn-step-cycle");
        this.btnReset = document.getElementById("btn-reset");
        this.btnConnectSerial = document.getElementById("btn-connect-serial");
        this.btnFlashSerial = document.getElementById("btn-flash-serial");
        this.btnExportVcd = document.getElementById("btn-export-vcd");
        this.btnExportHex = document.getElementById("btn-export-hex");
        this.btnInjectTx = document.getElementById("btn-inject-tx");
        this.inputTxByte = document.getElementById("input-tx-byte");

        // Waveform & Zoom Controls
        this.btnZoomIn = document.getElementById("btn-zoom-in");
        this.btnZoomOut = document.getElementById("btn-zoom-out");
        this.btnZoomFit = document.getElementById("btn-zoom-fit");
        this.btnZoomReset = document.getElementById("btn-zoom-reset");
        this.btnClearCursors = document.getElementById("btn-clear-cursors");
        this.waveformScaleBadge = document.getElementById("waveform-scale-badge");

        // Multi-Core Slices DOM
        this.coreCards = [
            document.getElementById("core-card-0"),
            document.getElementById("core-card-1"),
            document.getElementById("core-card-2"),
            document.getElementById("core-card-3")
        ];

        // Shared Synchronization Fabric DOM
        this.valCycles = document.getElementById("val-cycles");
        this.mbValElements = Array.from({ length: 8 }, (_, i) => document.getElementById(`mb-val-${i}`));
        this.mbCellElements = Array.from({ length: 8 }, (_, i) => document.getElementById(`mb-cell-${i}`));
        this.lockStatusElements = Array.from({ length: 4 }, (_, i) => document.getElementById(`lock-status-${i}`));
        this.lockCellElements = Array.from({ length: 4 }, (_, i) => document.getElementById(`lock-cell-${i}`));
        this.barrierNodes = Array.from({ length: 4 }, (_, i) => document.getElementById(`barrier-node-${i}`));
        this.barrierPulseElem = document.getElementById("barrier-pulse");

        // FIFOs DOM
        this.txFifoList = document.getElementById("tx-fifo-list");
        this.rxFifoList = document.getElementById("rx-fifo-list");
        this.cascadeFifoLists = [
            document.getElementById("cascade-fifo-0"),
            document.getElementById("cascade-fifo-1"),
            document.getElementById("cascade-fifo-2")
        ];
        this.cascadeRows = [
            document.getElementById("cascade-row-0"),
            document.getElementById("cascade-row-1"),
            document.getElementById("cascade-row-2")
        ];

        // Pin Matrix
        this.pinElements = Array.from({ length: 8 }, (_, i) => document.getElementById(`pin-${i}`));
        
        // Logs & Console
        this.terminalOutput = document.getElementById("terminal-output");
        this.hexViewContainer = document.getElementById("hex-view-container");
    }

    populatePresets() {
        this.presetSelect.innerHTML = "";
        PRESETS.forEach(p => {
            const opt = document.createElement("option");
            opt.value = p.id;
            opt.textContent = `[${p.category}] ${p.title}`;
            this.presetSelect.appendChild(opt);
        });
    }

    setupWaveform() {
        const canvas = document.getElementById("waveform-canvas");
        this.waveform = new WaveformViewer(canvas, this.emulator);
    }

    bindEvents() {
        this.presetSelect.addEventListener("change", (e) => this.loadPreset(e.target.value));
        this.coreCountSelect.addEventListener("change", (e) => this.setCoreTopology(parseInt(e.target.value, 10)));
        this.clockFreqSelect.addEventListener("change", (e) => {
            const freq = parseInt(e.target.value, 10);
            this.assembler.clkFreqHz = freq;
            this.emulator.clkFreqHz = freq;
            this.log(`Master clock set to ${(freq / 1e6).toFixed(1)} MHz`);
        });

        this.codeEditor.addEventListener("input", () => this.updateLineNumbers());
        this.codeEditor.addEventListener("scroll", () => {
            this.lineNumbers.scrollTop = this.codeEditor.scrollTop;
        });

        this.speedSlider.addEventListener("input", (e) => {
            this.execSpeed = parseInt(e.target.value, 10);
            this.speedLabel.textContent = `${this.execSpeed} cyc/fr`;
        });

        // Execution actions
        this.btnAssemble.addEventListener("click", () => this.assembleCode());
        this.btnRun.addEventListener("click", () => this.startSimulation());
        this.btnPause.addEventListener("click", () => this.pauseSimulation());
        this.btnStepInst.addEventListener("click", () => this.stepInstruction());
        this.btnStepCycle.addEventListener("click", () => this.stepCycle());
        this.btnReset.addEventListener("click", () => this.resetSimulation());

        // Waveform Zoom actions
        if (this.btnZoomIn) this.btnZoomIn.addEventListener("click", () => this.waveform?.zoomIn());
        if (this.btnZoomOut) this.btnZoomOut.addEventListener("click", () => this.waveform?.zoomOut());
        if (this.btnZoomFit) this.btnZoomFit.addEventListener("click", () => this.waveform?.zoomFit());
        if (this.btnZoomReset) this.btnZoomReset.addEventListener("click", () => this.waveform?.resetZoom());
        if (this.btnClearCursors) this.btnClearCursors.addEventListener("click", () => this.waveform?.clearCursors());

        // Byte injection
        this.btnInjectTx.addEventListener("click", () => {
            const val = parseInt(this.inputTxByte.value.trim(), 16);
            if (!isNaN(val)) {
                this.emulator.pushTxByte(val);
                this.log(`Injected 0x${val.toString(16).padStart(2, "0").toUpperCase()} into Host TX FIFO`);
                this.updateUi();
            }
        });

        // WebSerial
        this.btnConnectSerial.addEventListener("click", () => this.connectSerial());
        this.btnFlashSerial.addEventListener("click", () => this.flashSerial());

        // Exports
        this.btnExportHex.addEventListener("click", () => this.exportHex());
        this.btnExportVcd.addEventListener("click", () => this.exportVcd());

        // Keyboard shortcuts (Ctrl+B assemble, +, -, 0, 1, Esc for Waveform)
        window.addEventListener("keydown", (e) => {
            const activeTag = document.activeElement?.tagName?.toLowerCase();
            const isTyping = (activeTag === "textarea" || activeTag === "input");

            if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "b") {
                e.preventDefault();
                this.assembleCode();
                return;
            }

            if (!isTyping) {
                if (e.key === "+" || e.key === "=") {
                    e.preventDefault();
                    this.waveform?.zoomIn();
                } else if (e.key === "-" || e.key === "_") {
                    e.preventDefault();
                    this.waveform?.zoomOut();
                } else if (e.key === "0") {
                    e.preventDefault();
                    this.waveform?.zoomFit();
                } else if (e.key === "1") {
                    e.preventDefault();
                    this.waveform?.resetZoom();
                } else if (e.key === "Escape") {
                    this.waveform?.clearCursors();
                } else if (e.key === "ArrowLeft") {
                    e.preventDefault();
                    this.waveform?.pan(-40);
                } else if (e.key === "ArrowRight") {
                    e.preventDefault();
                    this.waveform?.pan(40);
                }
            }
        });
    }

    setCoreTopology(numCores) {
        this.emulator.setNumCores(numCores);
        this.labelNumCores.textContent = numCores;
        this.coreCountSelect.value = numCores;

        for (let i = 0; i < 4; i++) {
            if (this.coreCards[i]) {
                this.coreCards[i].style.display = (i < numCores) ? "flex" : "none";
            }
            if (i < 3 && this.cascadeRows[i]) {
                this.cascadeRows[i].style.display = (i < numCores - 1) ? "flex" : "none";
            }
            if (this.barrierNodes[i]) {
                this.barrierNodes[i].style.opacity = (i < numCores) ? "1.0" : "0.3";
            }
        }

        this.log(`Multi-Core Topology reconfigured: ${numCores} Symmetric Core(s) (NUM_CORES = ${numCores})`);
        this.waveform?.render();
        this.updateUi();
    }

    loadPreset(presetId) {
        const preset = PRESETS.find(p => p.id === presetId);
        if (!preset) return;

        this.currentPresetId = presetId;
        this.codeEditor.value = preset.code;
        this.updateLineNumbers();

        if (preset.numCores) {
            this.setCoreTopology(preset.numCores);
        }

        this.log(`Loaded preset [${preset.category}]: "${preset.title}"`);
        this.assembleCode();
    }

    updateLineNumbers() {
        const lines = this.codeEditor.value.split("\n").length;
        this.lineNumbers.innerHTML = Array.from({ length: lines }, (_, i) => i + 1).join("<br>");
    }

    assembleCode() {
        const source = this.codeEditor.value;
        const result = this.assembler.assemble(source);

        if (this.assembler.errors.length > 0) {
            this.statusBadge.textContent = "SYNTAX ERR";
            this.statusBadge.className = "status-badge err";
            this.log(`[Error] Compilation failed with ${this.assembler.errors.length} error(s):`);
            this.assembler.errors.forEach(err => this.log(`  Line ${err.lineNum}: ${err.message}`));
            return false;
        }

        this.statusBadge.textContent = `OK (${this.assembler.machineCode.length} INST)`;
        this.statusBadge.className = "status-badge ok";
        this.compiledData = this.assembler.machineCode;

        this.emulator.loadProgram(this.compiledData);
        this.log(`[Assemble] Successfully compiled ${this.compiledData.length} instructions into multi-bank IMEM.`);
        this.renderHexDisasm();
        this.updateUi();
        return true;
    }

    startSimulation() {
        if (!this.compiledData) {
            if (!this.assembleCode()) return;
        }

        this.emulator.running = true;
        this.btnRun.disabled = true;
        this.btnPause.disabled = false;
        this.btnStepInst.disabled = true;
        this.btnStepCycle.disabled = true;

        const loop = () => {
            if (!this.emulator.running) return;

            for (let i = 0; i < this.execSpeed; i++) {
                this.emulator.stepCycle();
            }

            this.updateUi();
            this.waveform?.render();
            this.animFrameId = requestAnimationFrame(loop);
        };

        this.animFrameId = requestAnimationFrame(loop);
        this.log("Multi-Core continuous simulation running...");
    }

    pauseSimulation() {
        this.emulator.running = false;
        if (this.animFrameId) {
            cancelAnimationFrame(this.animFrameId);
            this.animFrameId = null;
        }

        this.btnRun.disabled = false;
        this.btnPause.disabled = true;
        this.btnStepInst.disabled = false;
        this.btnStepCycle.disabled = false;

        this.log(`Simulation paused at cycle ${this.emulator.totalCycles}.`);
        this.updateUi();
        this.waveform?.render();
    }

    stepInstruction() {
        if (!this.compiledData) this.assembleCode();
        this.emulator.stepInstruction();
        this.updateUi();
        this.waveform?.render();
    }

    stepCycle() {
        if (!this.compiledData) this.assembleCode();
        this.emulator.stepCycle();
        this.updateUi();
        this.waveform?.render();
    }

    resetSimulation() {
        this.pauseSimulation();
        this.emulator.reset();
        if (this.compiledData) {
            this.emulator.loadProgram(this.compiledData);
        }
        this.log("Multi-engine reset to initial vector (RESET_PC = CORE_ID * 32).");
        this.updateUi();
        this.waveform?.render();
    }

    forceUnlock(lockId) {
        this.emulator.forceUnlockSpinlock(lockId);
        this.log(`Host Wishbone Override: Force-unlocked Spinlock ${lockId}`);
        this.updateUi();
    }

    updateUi() {
        const emu = this.emulator;

        // 1. Update Real-Time Multi-Core Tiles
        for (let i = 0; i < 4; i++) {
            const core = emu.cores[i];
            const card = this.coreCards[i];
            if (!card || !core.enabled) continue;

            const elState = document.getElementById(`core-state-${i}`);
            const elInst  = document.getElementById(`core-inst-${i}`);
            const elPc    = document.getElementById(`core-pc-${i}`);
            const elAcc   = document.getElementById(`core-acc-${i}`);
            const elFz    = document.getElementById(`core-fz-${i}`);
            const elLc0   = document.getElementById(`core-lc0-${i}`);

            if (elState) {
                elState.textContent = core.state;
                elState.className = `core-state-pill ${core.state.toLowerCase().replace('_', '-')}`;
            }
            if (elInst) elInst.textContent = core.lastDisasm || "NOP";
            if (elPc) elPc.textContent = `0x${core.pc.toString(16).padStart(2, "0").toUpperCase()}`;
            if (elAcc) elAcc.textContent = `0x${core.acc.toString(16).padStart(2, "0").toUpperCase()}`;
            if (elFz) elFz.textContent = core.flags.z;
            if (elLc0) elLc0.textContent = core.lc0;
        }

        // 2. Hardware Synchronization Fabric
        if (this.valCycles) {
            this.valCycles.textContent = `${emu.totalCycles} Cycles`;
        }

        // Shared Mailboxes
        for (let mb = 0; mb < 8; mb++) {
            const valElem = this.mbValElements[mb];
            const cellElem = this.mbCellElements[mb];
            if (valElem) {
                valElem.textContent = `0x${emu.mailboxes[mb].toString(16).padStart(2, "0").toUpperCase()}`;
            }
            if (cellElem) {
                const last = emu.mbLastAccess[mb];
                if (last && (emu.totalCycles - last.cycle < 5)) {
                    cellElem.className = `mb-cell ${last.action === "WRITE" ? "write-glow" : "read-glow"}`;
                } else {
                    cellElem.className = "mb-cell";
                }
            }
        }

        // Spinlocks
        for (let lk = 0; lk < 4; lk++) {
            const statusElem = this.lockStatusElements[lk];
            const cellElem = this.lockCellElements[lk];
            const owner = emu.spinlocks[lk];
            if (statusElem) {
                statusElem.textContent = owner === null ? "FREE" : `HELD: C${owner}`;
            }
            if (cellElem) {
                cellElem.className = `spinlock-cell ${owner === null ? "unlocked" : "locked"}`;
            }
        }

        // Barrier Radar
        for (let bn = 0; bn < 4; bn++) {
            const node = this.barrierNodes[bn];
            if (node) {
                const led = node.querySelector(".node-led");
                if (led) {
                    if (emu.barrierArrived[bn]) {
                        led.className = "node-led arrived";
                    } else {
                        led.className = "node-led";
                    }
                }
            }
        }

        if (this.barrierPulseElem) {
            if (emu.barrierReleasePulse) {
                this.barrierPulseElem.className = "barrier-center-pulse active";
            } else {
                this.barrierPulseElem.className = "barrier-center-pulse";
            }
        }

        // 3. FIFOs & Cascade Queues
        this.renderFifo(this.txFifoList, emu.txFifo);
        this.renderFifo(this.rxFifoList, emu.rxFifo);
        for (let cf = 0; cf < 3; cf++) {
            if (this.cascadeFifoLists[cf]) {
                this.renderFifo(this.cascadeFifoLists[cf], emu.cascadeFifos[cf]);
            }
        }

        // 4. Physical Pin Matrix (UIO[0..7])
        const effective = emu.getEffectiveGpio();
        for (let p = 0; p < 8; p++) {
            const pinElem = this.pinElements[p];
            if (pinElem) {
                const isHigh = ((effective >> p) & 1) === 1;
                const isDriven = ((emu.uioOe >> p) & 1) === 1;
                const lvlElem = pinElem.querySelector(".pin-level");
                const modeElem = pinElem.querySelector(".pin-mode");

                if (lvlElem) {
                    lvlElem.textContent = isHigh ? "1" : "0";
                    lvlElem.className = `pin-level ${isHigh ? "high" : ""}`;
                }
                if (modeElem) {
                    modeElem.textContent = isDriven ? "OUT" : "IN";
                }
            }
        }
    }

    renderFifo(container, fifoArray) {
        if (!container) return;
        if (fifoArray.length === 0) {
            container.innerHTML = `<span style="font-size: 9px; color: var(--text-dim); margin-left: 4px;">empty</span>`;
            return;
        }
        container.innerHTML = fifoArray.slice(0, 8).map(b => 
            `<span class="fifo-byte-badge">0x${b.toString(16).padStart(2, "0").toUpperCase()}</span>`
        ).join("");
    }

    renderHexDisasm() {
        if (!this.hexViewContainer || !this.assembler.machineCode) return;
        const mc = this.assembler.machineCode;
        let html = "";
        for (let i = 0; i < mc.length; i++) {
            const hex = mc[i].toString(16).padStart(4, "0").toUpperCase();
            const disasm = this.emulator.disassembleInstruction(mc[i]);
            const bank = Math.floor(i / 32);
            html += `<div class="hex-row"><span style="color: var(--text-dim);">[B${bank}:${i.toString(16).padStart(2, "0").toUpperCase()}]</span> <span style="color: var(--primary-cyan);">0x${hex}</span> -- <span style="color: #FFF;">${disasm}</span></div>`;
        }
        this.hexViewContainer.innerHTML = html;
    }

    log(message) {
        if (!this.terminalOutput) return;
        const line = document.createElement("div");
        line.className = "log-line";
        const time = new Date().toLocaleTimeString();
        line.innerHTML = `<span class="log-time">[${time}]</span> ${message}`;
        this.terminalOutput.appendChild(line);
        this.terminalOutput.scrollTop = this.terminalOutput.scrollHeight;
    }

    async connectSerial() {
        try {
            await this.webSerial.connect();
            this.btnFlashSerial.disabled = false;
            this.btnConnectSerial.textContent = "🔌 Connected";
            this.log("WebSerial: Connected to OmniBus hardware bridge.");
        } catch (err) {
            this.log(`WebSerial Connection Error: ${err.message}`);
        }
    }

    async flashSerial() {
        if (!this.compiledData) {
            this.log("Cannot flash: Assemble microcode first.");
            return;
        }
        try {
            this.log(`WebSerial: Flashing ${this.compiledData.length} words to FPGA silicon...`);
            await this.webSerial.flashMicrocode(this.compiledData);
            this.log("WebSerial: [SUCCESS] Silicon IMEM flashed successfully!");
        } catch (err) {
            this.log(`WebSerial Flash Error: ${err.message}`);
        }
    }

    exportHex() {
        if (!this.compiledData) this.assembleCode();
        const hex = this.assembler.getVerilogMemHex();
        const blob = new Blob([hex], { type: "text/plain" });
        const url = URL.createObjectURL(blob);
        const a = document.createElement("a");
        a.href = url;
        a.download = "multicore_program.hex";
        a.click();
        URL.revokeObjectURL(url);
        this.log("Exported Verilog $readmemh memory file: multicore_program.hex");
    }

    exportVcd() {
        const trace = this.emulator.trace;
        if (trace.length === 0) {
            this.log("No waveform trace available to export.");
            return;
        }
        let vcd = `$date\n  ${new Date().toISOString()}\n$end\n$version\n  OmniBus Studio MP\n$end\n$timescale 1ns $end\n$scope module top $end\n`;
        vcd += `$var wire 1 ! UIO0 $end\n$var wire 1 \" UIO1 $end\n$var wire 1 # UIO2 $end\n$var wire 1 $ UIO3 $end\n$upscope $end\n$enddefinitions $end\n#0\n$dumpvars\n`;
        trace.forEach(s => {
            vcd += `#${s.cycle * 20}\n${s.p0}!\n${s.p1}\"\n${s.p2}#\n${s.p3}$\n`;
        });
        const blob = new Blob([vcd], { type: "text/plain" });
        const url = URL.createObjectURL(blob);
        const a = document.createElement("a");
        a.href = url;
        a.download = "omnibus_multicore_trace.vcd";
        a.click();
        URL.revokeObjectURL(url);
        this.log("Exported Sigrok / PulseView waveform: omnibus_multicore_trace.vcd");
    }
}

document.addEventListener("DOMContentLoaded", () => {
    new OmniBusApp();
});
