// =============================================================================
// File        : app.js
// Module      : OmniBus Web IDE Main Application Orchestrator
// Description : Manages UI state, code editing, assembly compilation,
//               cycle-by-cycle execution, waveform visualization, audio,
//               and WebSerial hardware flashing.
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
        this.emulator = new OmniBusEmulator(50000000);
        this.audio = new OmniBusAudioEngine();
        this.webSerial = new OmniBusWebSerial();
        this.waveform = null;

        this.currentPresetId = "uart_tx";
        this.animFrameId = null;
        this.execSpeed = 1000; // Cycles per animation frame
        this.compiledData = null;

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
        this.statusBadge = document.getElementById("status-badge");
        this.clockFreqSelect = document.getElementById("clock-freq-select");
        this.speedSlider = document.getElementById("speed-slider");
        this.speedLabel = document.getElementById("speed-label");

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

        // Register / State DOM
        this.valPc = document.getElementById("val-pc");
        this.valState = document.getElementById("val-state");
        this.valDelay = document.getElementById("val-delay");
        this.valInst = document.getElementById("val-inst");
        this.valCycles = document.getElementById("val-cycles");
        this.valLc0 = document.getElementById("val-lc0");
        this.valLc1 = document.getElementById("val-lc1");
        this.valAcc = document.getElementById("val-acc");
        this.valFlags = document.getElementById("val-flags");
        this.valOsr = document.getElementById("val-osr");
        this.valIsr = document.getElementById("val-isr");
        this.valTxCount = document.getElementById("val-tx-count");
        this.valRxCount = document.getElementById("val-rx-count");
        this.txFifoList = document.getElementById("tx-fifo-list");
        this.rxFifoList = document.getElementById("rx-fifo-list");
        this.callStackContainer = document.getElementById("call-stack-container");

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
        this.waveform.render();
    }

    bindEvents() {
        this.presetSelect.addEventListener("change", (e) => {
            this.loadPreset(e.target.value);
        });

        this.codeEditor.addEventListener("input", () => {
            this.updateLineNumbers();
        });

        this.codeEditor.addEventListener("scroll", () => {
            this.lineNumbers.scrollTop = this.codeEditor.scrollTop;
        });

        this.btnAssemble.addEventListener("click", () => this.assembleCode());
        
        this.btnRun.addEventListener("click", () => this.startExecution());
        this.btnPause.addEventListener("click", () => this.pauseExecution());
        this.btnStepInst.addEventListener("click", () => this.stepInstruction());
        this.btnStepCycle.addEventListener("click", () => this.stepCycle());
        this.btnReset.addEventListener("click", () => this.resetEmulator());

        this.speedSlider.addEventListener("input", (e) => {
            this.execSpeed = parseInt(e.target.value, 10);
            this.speedLabel.textContent = `${this.execSpeed} cyc/frame`;
        });

        this.clockFreqSelect.addEventListener("change", (e) => {
            const freq = parseInt(e.target.value, 10);
            this.assembler.clkFreqHz = freq;
            this.emulator.clkFreqHz = freq;
            this.log(`Clock frequency updated to ${(freq / 1e6).toFixed(1)} MHz`);
        });

        // WebSerial
        this.webSerial.setLogCallback((msg) => this.log(msg));
        this.btnConnectSerial.addEventListener("click", async () => {
            try {
                if (!this.webSerial.isConnected) {
                    await this.webSerial.connect();
                    this.btnConnectSerial.textContent = "Disconnect";
                    this.btnConnectSerial.classList.add("connected");
                    this.btnFlashSerial.disabled = false;
                } else {
                    await this.webSerial.disconnect();
                    this.btnConnectSerial.textContent = "Connect Hardware";
                    this.btnConnectSerial.classList.remove("connected");
                    this.btnFlashSerial.disabled = true;
                }
            } catch (err) {
                this.log(`[Error] ${err.message}`);
            }
        });

        this.btnFlashSerial.addEventListener("click", async () => {
            if (!this.compiledData || !this.compiledData.success) {
                this.assembleCode();
            }
            if (this.compiledData && this.compiledData.success) {
                try {
                    await this.webSerial.programMicrocode(this.compiledData.machineCode);
                } catch (err) {
                    this.log(`[Flash Error] ${err.message}`);
                }
            }
        });

        // Interactive Stimulus: Inject TX byte
        const btnInjectTx = document.getElementById("btn-inject-tx");
        const inputTxByte = document.getElementById("input-tx-byte");
        if (btnInjectTx && inputTxByte) {
            btnInjectTx.addEventListener("click", () => {
                const val = parseInt(inputTxByte.value, 16) || 0;
                this.emulator.pushTxByte(val);
                this.log(`Pushed 0x${val.toString(16).padStart(2, "0").toUpperCase()} to TX FIFO`);
                this.updateUi();
            });
        }

        // Export VCD
        this.btnExportVcd.addEventListener("click", () => this.exportVcd());
        this.btnExportHex.addEventListener("click", () => this.exportHex());
    }

    loadPreset(presetId) {
        const p = PRESETS.find(item => item.id === presetId);
        if (p) {
            this.codeEditor.value = p.code;
            this.updateLineNumbers();
            this.assembleCode();
            this.log(`Loaded preset: ${p.title}`);
        }
    }

    updateLineNumbers() {
        const lines = this.codeEditor.value.split("\n").length;
        this.lineNumbers.innerHTML = Array.from({ length: lines }, (_, i) => `<div>${i + 1}</div>`).join("");
    }

    assembleCode() {
        const src = this.codeEditor.value;
        this.compiledData = this.assembler.assemble(src);

        if (this.compiledData.success) {
            this.statusBadge.textContent = "ASSEMBLY OK";
            this.statusBadge.className = "status-badge ok";
            this.emulator.loadProgram(this.compiledData.machineCode);
            this.renderHexListing();
            this.log(`Assembly successful: ${this.compiledData.machineCode.length} words emitted.`);
            this.updateUi();
            return true;
        } else {
            this.statusBadge.textContent = `ERRORS (${this.compiledData.errors.length})`;
            this.statusBadge.className = "status-badge error";
            this.compiledData.errors.forEach(err => {
                this.log(`[ASM Error Line ${err.line}] ${err.message}`);
            });
            return false;
        }
    }

    startExecution() {
        if (!this.compiledData || !this.compiledData.success) {
            if (!this.assembleCode()) return;
        }
        this.emulator.running = true;
        this.btnRun.disabled = true;
        this.btnPause.disabled = false;
        this.runLoop();
    }

    pauseExecution() {
        this.emulator.running = false;
        if (this.animFrameId) {
            cancelAnimationFrame(this.animFrameId);
            this.animFrameId = null;
        }
        this.btnRun.disabled = false;
        this.btnPause.disabled = true;
        this.updateUi();
    }

    runLoop() {
        if (!this.emulator.running) return;

        for (let i = 0; i < this.execSpeed; i++) {
            if (!this.emulator.stepCycle()) {
                this.pauseExecution();
                break;
            }
        }

        this.updateUi();
        this.animFrameId = requestAnimationFrame(() => this.runLoop());
    }

    stepInstruction() {
        this.emulator.stepInstruction();
        this.updateUi();
    }

    stepCycle() {
        this.emulator.stepCycle();
        this.updateUi();
    }

    resetEmulator() {
        this.pauseExecution();
        this.emulator.reset();
        if (this.compiledData && this.compiledData.success) {
            this.emulator.loadProgram(this.compiledData.machineCode);
        }
        this.log("Micro-engine reset.");
        this.updateUi();
    }

    updateUi() {
        // Register displays
        this.valPc.textContent = `0x${this.emulator.pc.toString(16).padStart(2, "0").toUpperCase()} (${this.emulator.pc})`;
        this.valState.textContent = this.emulator.state;
        this.valDelay.textContent = this.emulator.delayCnt;
        this.valInst.textContent = `0x${this.emulator.activeInst.toString(16).padStart(4, "0").toUpperCase()}`;
        this.valCycles.textContent = this.emulator.totalCycles.toLocaleString();
        
        this.valLc0.textContent = this.emulator.lc0;
        this.valLc1.textContent = this.emulator.lc1;
        this.valAcc.textContent = `0x${this.emulator.acc.toString(16).padStart(2, "0").toUpperCase()} (${this.emulator.acc})`;
        this.valFlags.textContent = `Z:${this.emulator.flags.z} C:${this.emulator.flags.c} N:${this.emulator.flags.n}`;
        
        this.valOsr.textContent = `0x${this.emulator.osr.toString(16).padStart(8, "0").toUpperCase()}`;
        this.valIsr.textContent = `0x${this.emulator.isr.toString(16).padStart(8, "0").toUpperCase()}`;
        
        this.valTxCount.textContent = `${this.emulator.txFifo.length}/${this.emulator.fifoDepth}`;
        this.valRxCount.textContent = `${this.emulator.rxFifo.length}/${this.emulator.fifoDepth}`;

        // FIFOs List
        this.txFifoList.innerHTML = this.emulator.txFifo.map(b => `<span class="fifo-byte">0x${b.toString(16).padStart(2, "0").toUpperCase()}</span>`).join("") || "<span class='empty'>(empty)</span>";
        this.rxFifoList.innerHTML = this.emulator.rxFifo.map(b => `<span class="fifo-byte">0x${b.toString(16).padStart(2, "0").toUpperCase()}</span>`).join("") || "<span class='empty'>(empty)</span>";

        // Call Stack
        let stackHtml = "";
        for (let i = 0; i < 4; i++) {
            const isTop = (i === this.emulator.callSp - 1);
            const val = this.emulator.callStack[i];
            stackHtml += `<div class="stack-slot ${isTop ? 'active-slot' : ''}">[SP ${i}] PC: 0x${val.toString(16).padStart(2, "0").toUpperCase()}</div>`;
        }
        this.callStackContainer.innerHTML = stackHtml;

        // Pin Matrix LED states
        const gpio = this.emulator.getEffectiveGpio();
        const oe = this.emulator.uioOe;
        const od = this.emulator.gpioOd;

        for (let p = 0; p < 8; p++) {
            const el = this.pinElements[p];
            if (el) {
                const bitVal = (gpio >> p) & 1;
                const isOe = (oe >> p) & 1;
                const isOd = (od >> p) & 1;
                
                el.className = "pin-badge";
                if (bitVal === 1) el.classList.add("pin-high");
                else el.classList.add("pin-low");
                if (isOd) el.classList.add("pin-od");

                el.querySelector(".pin-level").textContent = bitVal === 1 ? "1" : "0";
                el.querySelector(".pin-mode").textContent = isOd ? "OD" : (isOe ? "OUT" : "IN");
            }
        }

        // Render Waveform Logic Analyzer
        if (this.waveform) {
            this.waveform.render();
        }
    }

    renderHexListing() {
        if (!this.compiledData || !this.compiledData.debugMap) return;
        this.hexViewContainer.innerHTML = this.compiledData.debugMap.map(d => {
            return `<div class="hex-row ${d.pc === this.emulator.pc ? 'hex-active' : ''}">
                <span class="hex-pc">0x${d.pc.toString(16).padStart(2, "0").toUpperCase()}</span>
                <span class="hex-word">${d.hex}</span>
                <span class="hex-asm">${d.raw}</span>
            </div>`;
        }).join("");
    }

    log(msg) {
        const time = new Date().toLocaleTimeString();
        const div = document.createElement("div");
        div.className = "log-line";
        div.innerHTML = `<span class="log-time">[${time}]</span> ${msg}`;
        this.terminalOutput.appendChild(div);
        this.terminalOutput.scrollTop = this.terminalOutput.scrollHeight;
    }

    exportHex() {
        if (!this.compiledData) this.assembleCode();
        const blob = new Blob([this.compiledData.verilogHex], { type: "text/plain" });
        const a = document.createElement("a");
        a.href = URL.createObjectURL(blob);
        a.download = "program.hex";
        a.click();
    }

    exportVcd() {
        const trace = this.emulator.trace;
        if (trace.length === 0) {
            this.log("No simulation trace to export.");
            return;
        }

        let vcd = `$date\n  ${new Date().toISOString()}\n$end\n`;
        vcd += `$version\n  OmniBus Web IDE VCD Generator\n$end\n`;
        vcd += `$timescale 20ns $end\n`;
        vcd += `$scope module top $end\n`;
        vcd += `$var wire 1 ! clk $end\n`;
        vcd += `$var wire 8 " uio [7:0] $end\n`;
        vcd += `$var wire 1 # glitch $end\n`;
        vcd += `$upscope $end\n$enddefinitions $end\n`;

        trace.forEach(s => {
            vcd += `#${s.cycle}\n`;
            vcd += `b${s.gpio.toString(2).padStart(8, "0")} "\n`;
            vcd += `${s.glitch} #\n`;
        });

        const blob = new Blob([vcd], { type: "text/plain" });
        const a = document.createElement("a");
        a.href = URL.createObjectURL(blob);
        a.download = "omnibus_trace.vcd";
        a.click();
        this.log("Exported waveform to omnibus_trace.vcd");
    }
}

window.addEventListener("DOMContentLoaded", () => {
    window.app = new OmniBusApp();
});
