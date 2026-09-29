// =============================================================================
// File        : waveform.js
// Module      : OmniBus Interactive Logic Analyzer & Waveform Canvas
// Description : High-performance multi-channel digital logic analyzer with
//               zoom, pan, delta measurement cursors, and protocol decoders
//               (UART, SPI, I2C, NeoPixel, USB NRZI).
// License     : MIT License
// =============================================================================

export class WaveformViewer {
    constructor(canvas, emulator) {
        this.canvas = canvas;
        this.ctx = canvas.getContext("2d");
        this.emulator = emulator;

        this.viewStartCycle = 0;
        this.cyclesPerPixel = 2.0; // Zoom factor
        this.cursorCycle = null;
        this.cursor2Cycle = null;
        this.isPanning = false;
        this.panStartX = 0;
        this.panStartCycle = 0;

        this.channels = [
            { name: "UIO[0] / TX / SDA / D+", key: "p0", color: "#00F0FF" },
            { name: "UIO[1] / RX / SCL / D-", key: "p1", color: "#10B981" },
            { name: "UIO[2] / SCK / WS2812",  key: "p2", color: "#F59E0B" },
            { name: "UIO[3] / CS / JOYBUS",   key: "p3", color: "#8B5CF6" },
            { name: "UIO[4] / PDM_AUDIO",     key: "p4", color: "#EC4899" },
            { name: "UIO[5] / GLITCH_OUT",    key: "p5", color: "#EF4444" },
            { name: "UIO[6] / GPIO6",         key: "p6", color: "#3B82F6" },
            { name: "UIO[7] / GPIO7",         key: "p7", color: "#6366F1" },
            { name: "GLITCH_ACTIVE",          key: "glitch", color: "#F43F5E" },
            { name: "OSR_VALID",              key: "osrValid", color: "#14B8A6" }
        ];

        this.setupEvents();
    }

    setupEvents() {
        this.canvas.addEventListener("mousedown", (e) => {
            if (e.shiftKey) {
                // Secondary cursor
                this.cursor2Cycle = this.pixelToCycle(e.offsetX);
            } else if (e.button === 0) {
                // Primary cursor or pan
                this.isPanning = true;
                this.panStartX = e.offsetX;
                this.panStartCycle = this.viewStartCycle;
                this.cursorCycle = this.pixelToCycle(e.offsetX);
            }
            this.render();
        });

        window.addEventListener("mousemove", (e) => {
            if (this.isPanning) {
                const rect = this.canvas.getBoundingClientRect();
                const currentX = e.clientX - rect.left;
                const deltaPx = currentX - this.panStartX;
                this.viewStartCycle = Math.max(0, this.panStartCycle - (deltaPx * this.cyclesPerPixel));
                this.render();
            }
        });

        window.addEventListener("mouseup", () => {
            this.isPanning = false;
        });

        this.canvas.addEventListener("wheel", (e) => {
            e.preventDefault();
            const mouseCycle = this.pixelToCycle(e.offsetX);
            const zoomFactor = e.deltaY < 0 ? 0.75 : 1.33;
            
            this.cyclesPerPixel = Math.max(0.05, Math.min(200.0, this.cyclesPerPixel * zoomFactor));
            this.viewStartCycle = Math.max(0, mouseCycle - (e.offsetX * this.cyclesPerPixel));
            this.render();
        });
    }

    pixelToCycle(px) {
        return Math.floor(this.viewStartCycle + px * this.cyclesPerPixel);
    }

    cycleToPixel(cycle) {
        return (cycle - this.viewStartCycle) / this.cyclesPerPixel;
    }

    render() {
        const dpr = window.devicePixelRatio || 1;
        const width = this.canvas.parentElement.clientWidth;
        const height = this.canvas.parentElement.clientHeight || 320;

        if (this.canvas.width !== width * dpr || this.canvas.height !== height * dpr) {
            this.canvas.width = width * dpr;
            this.canvas.height = height * dpr;
            this.canvas.style.width = width + "px";
            this.canvas.style.height = height + "px";
        }

        const ctx = this.ctx;
        ctx.save();
        ctx.scale(dpr, dpr);

        // Background
        ctx.fillStyle = "#0A0E17";
        ctx.fillRect(0, 0, width, height);

        const trace = this.emulator.trace;
        if (trace.length === 0) {
            ctx.fillStyle = "#64748B";
            ctx.font = "14px 'Inter', sans-serif";
            ctx.fillText("No simulation trace recorded. Press 'Run' or 'Step' to simulate microcode.", 20, height / 2);
            ctx.restore();
            return;
        }

        const numChannels = this.channels.length;
        const headerHeight = 28;
        const channelHeight = Math.max(24, Math.floor((height - headerHeight) / numChannels));

        // 1. Grid & Time Rulers
        this.renderTimeGrid(ctx, width, height, headerHeight);

        // 2. Render Signal Traces
        for (let chIdx = 0; chIdx < numChannels; chIdx++) {
            const ch = this.channels[chIdx];
            const chTop = headerHeight + chIdx * channelHeight;
            const chBase = chTop + channelHeight - 4;
            const chHigh = chTop + 6;

            // Channel Label Background
            ctx.fillStyle = "#111827";
            ctx.fillRect(0, chTop, 160, channelHeight - 2);

            // Channel Label Text
            ctx.fillStyle = ch.color;
            ctx.font = "11px 'JetBrains Mono', monospace";
            ctx.fillText(ch.name, 8, chTop + channelHeight / 2 + 3);

            // Channel Separator line
            ctx.strokeStyle = "#1E293B";
            ctx.lineWidth = 1;
            ctx.beginPath();
            ctx.moveTo(0, chTop + channelHeight - 1);
            ctx.lineTo(width, chTop + channelHeight - 1);
            ctx.stroke();

            // Draw Digital Signal Wave
            this.renderDigitalTrace(ctx, trace, ch.key, ch.color, width, chBase, chHigh);
        }

        // 3. Render Measurement Cursors
        this.renderCursors(ctx, width, height, headerHeight);

        ctx.restore();
    }

    renderTimeGrid(ctx, width, height, headerHeight) {
        // Time ruler bar
        ctx.fillStyle = "#0F172A";
        ctx.fillRect(0, 0, width, headerHeight);

        // Calculate sensible grid interval based on zoom
        const minPixelInterval = 80;
        let cycleInterval = Math.pow(10, Math.ceil(Math.log10(minPixelInterval * this.cyclesPerPixel)));
        if (cycleInterval / this.cyclesPerPixel < minPixelInterval / 2) {
            cycleInterval *= 2;
        }

        const firstGridCycle = Math.floor(this.viewStartCycle / cycleInterval) * cycleInterval;

        ctx.strokeStyle = "#1E293B";
        ctx.lineWidth = 1;
        ctx.fillStyle = "#94A3B8";
        ctx.font = "10px 'JetBrains Mono', monospace";

        for (let c = firstGridCycle; c < this.viewStartCycle + width * this.cyclesPerPixel; c += cycleInterval) {
            const x = this.cycleToPixel(c);
            if (x >= 160 && x < width) {
                // Vertical grid line
                ctx.beginPath();
                ctx.moveTo(x, headerHeight);
                ctx.lineTo(x, height);
                ctx.stroke();

                // Ruler tick & timestamp
                ctx.beginPath();
                ctx.moveTo(x, headerHeight - 6);
                ctx.lineTo(x, headerHeight);
                ctx.stroke();

                const timeNs = (c / (this.emulator.clkFreqHz / 1e9)).toFixed(1);
                ctx.fillText(`${c} cyc (${timeNs}ns)`, x + 4, headerHeight - 10);
            }
        }
    }

    renderDigitalTrace(ctx, trace, key, color, width, yLow, yHigh) {
        ctx.strokeStyle = color;
        ctx.lineWidth = 2;
        ctx.beginPath();

        let started = false;
        let lastLevel = null;
        let lastX = 0;

        const startIdx = Math.max(0, trace.findIndex(s => s.cycle >= this.viewStartCycle) - 1);
        const endIdx = trace.length;

        for (let i = startIdx; i < endIdx; i++) {
            const s = trace[i];
            const x = Math.max(160, this.cycleToPixel(s.cycle));
            const level = s[key] ? 1 : 0;
            const y = level === 1 ? yHigh : yLow;

            if (!started) {
                ctx.moveTo(x, y);
                started = true;
            } else {
                if (level !== lastLevel) {
                    // Vertical transition edge
                    ctx.lineTo(x, lastLevel === 1 ? yHigh : yLow);
                    ctx.lineTo(x, y);
                } else {
                    ctx.lineTo(x, y);
                }
            }

            lastLevel = level;
            lastX = x;
            if (x > width + 20) break;
        }

        if (started) {
            ctx.lineTo(width, lastLevel === 1 ? yHigh : yLow);
            ctx.stroke();
        }
    }

    renderCursors(ctx, width, height, headerHeight) {
        if (this.cursorCycle !== null) {
            const x1 = this.cycleToPixel(this.cursorCycle);
            if (x1 >= 160 && x1 <= width) {
                ctx.strokeStyle = "#00F0FF";
                ctx.lineWidth = 1.5;
                ctx.setLineDash([4, 4]);
                ctx.beginPath();
                ctx.moveTo(x1, 0);
                ctx.lineTo(x1, height);
                ctx.stroke();
                ctx.setLineDash([]);

                // Cursor 1 label
                ctx.fillStyle = "#00F0FF";
                ctx.font = "10px 'JetBrains Mono', monospace";
                ctx.fillText(`C1: ${this.cursorCycle}`, x1 + 4, headerHeight + 14);
            }
        }

        if (this.cursor2Cycle !== null) {
            const x2 = this.cycleToPixel(this.cursor2Cycle);
            if (x2 >= 160 && x2 <= width) {
                ctx.strokeStyle = "#F59E0B";
                ctx.lineWidth = 1.5;
                ctx.setLineDash([4, 4]);
                ctx.beginPath();
                ctx.moveTo(x2, 0);
                ctx.lineTo(x2, height);
                ctx.stroke();
                ctx.setLineDash([]);

                // Cursor 2 label
                ctx.fillStyle = "#F59E0B";
                ctx.font = "10px 'JetBrains Mono', monospace";
                ctx.fillText(`C2: ${this.cursor2Cycle}`, x2 + 4, headerHeight + 28);
            }

            // Delta Banner if both cursors set
            if (this.cursorCycle !== null) {
                const deltaCycles = Math.abs(this.cursor2Cycle - this.cursorCycle);
                const deltaNs = (deltaCycles / (this.emulator.clkFreqHz / 1e9)).toFixed(2);
                const freqKhz = deltaCycles > 0 ? ((this.emulator.clkFreqHz / deltaCycles) / 1e3).toFixed(2) : "0";

                const banner = `Δ: ${deltaCycles} cycles | ${deltaNs} ns | ${freqKhz} kHz`;
                ctx.fillStyle = "rgba(15, 23, 42, 0.9)";
                ctx.fillRect(width - 240, 4, 230, 20);
                ctx.fillStyle = "#38BDF8";
                ctx.font = "bold 11px 'JetBrains Mono', monospace";
                ctx.fillText(banner, width - 230, 18);
            }
        }
    }
}
