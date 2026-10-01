// =============================================================================
// File        : waveform.js
// Module      : OmniBus MP Interactive Logic Analyzer & Multi-Core Waveform Canvas
// Description : High-performance multi-channel digital logic analyzer with
//               multi-core PC bus rendering, barrier pulses, spinlock traces,
//               zoom, pan, delta measurement cursors, and protocol decoders.
// License     : MIT License
// =============================================================================

export class WaveformViewer {
    constructor(canvas, emulator) {
        this.canvas = canvas;
        this.ctx = canvas.getContext("2d");
        this.emulator = emulator;

        this.viewStartCycle = 0;
        this.cyclesPerPixel = 2.0;
        this.cursorCycle = null;
        this.cursor2Cycle = null;
        this.isPanning = false;
        this.panStartX = 0;
        this.panStartCycle = 0;

        this.updateChannels();
        this.setupEvents();
    }

    updateChannels() {
        const numCores = this.emulator.numCores || 2;
        this.channels = [];

        // Add active multi-core program counter buses
        for (let i = 0; i < numCores; i++) {
            const colors = ["#00F0FF", "#10B981", "#F59E0B", "#8B5CF6"];
            this.channels.push({
                name: `CORE ${i} PC [Bank ${i}]`,
                key: `pc${i}`,
                type: "bus",
                color: colors[i]
            });
        }

        // Multi-Core synchronization signals
        this.channels.push({ name: "BARRIER PULSE", key: "barrierPulse", type: "digital", color: "#EC4899" });
        this.channels.push({ name: "SPINLOCKS [0..1]", key: "spinlocks", type: "digital", color: "#EF4444" });

        // Physical GPIO pins
        this.channels.push(
            { name: "UIO[0] / TX0 / SDA", key: "p0", type: "digital", color: "#00F0FF" },
            { name: "UIO[1] / SCK0 / SCL", key: "p1", type: "digital", color: "#10B981" },
            { name: "UIO[2] / CS0 / WS2812", key: "p2", type: "digital", color: "#F59E0B" },
            { name: "UIO[3] / RX0 / JOY",  key: "p3", type: "digital", color: "#8B5CF6" },
            { name: "UIO[4] / TX1 / MOSI", key: "p4", type: "digital", color: "#3B82F6" },
            { name: "UIO[5] / SCK1 / GLITCH", key: "p5", type: "digital", color: "#F43F5E" },
            { name: "UIO[6] / CS1 / GPIO6", key: "p6", type: "digital", color: "#6366F1" },
            { name: "UIO[7] / RX1 / GPIO7", key: "p7", type: "digital", color: "#14B8A6" }
        );
    }

    setupEvents() {
        this.canvas.addEventListener("mousedown", (e) => {
            if (e.shiftKey) {
                this.cursor2Cycle = this.pixelToCycle(e.offsetX);
            } else if (e.button === 0) {
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
            const zoomFactor = e.deltaY < 0 ? 0.75 : 1.33;
            this.zoom(zoomFactor, e.offsetX);
        });
    }

    zoom(zoomFactor, centerPx = null) {
        const width = this.canvas.parentElement ? this.canvas.parentElement.clientWidth : 800;
        const cx = centerPx !== null ? centerPx : Math.max(170, (width + 170) / 2);
        const mouseCycle = this.pixelToCycle(cx);
        
        this.cyclesPerPixel = Math.max(0.01, Math.min(200.0, this.cyclesPerPixel * zoomFactor));
        this.viewStartCycle = Math.max(0, mouseCycle - (cx * this.cyclesPerPixel));
        this.render();
    }

    zoomIn() {
        this.zoom(0.70);
    }

    zoomOut() {
        this.zoom(1.40);
    }

    zoomFit() {
        const trace = this.emulator.trace;
        const width = this.canvas.parentElement ? this.canvas.parentElement.clientWidth : 800;
        const availableWidth = Math.max(100, width - 180);

        if (trace && trace.length > 0) {
            const minCycle = trace[0].cycle || 0;
            const maxCycle = trace[trace.length - 1].cycle || this.emulator.totalCycles || 10;
            const totalCycles = Math.max(10, maxCycle - minCycle);
            this.cyclesPerPixel = Math.max(0.01, Math.min(200.0, totalCycles / availableWidth));
            this.viewStartCycle = Math.max(0, minCycle);
        } else {
            this.cyclesPerPixel = 2.0;
            this.viewStartCycle = 0;
        }
        this.render();
    }

    resetZoom() {
        this.cyclesPerPixel = 2.0;
        this.viewStartCycle = 0;
        this.render();
    }

    clearCursors() {
        this.cursorCycle = null;
        this.cursor2Cycle = null;
        this.render();
    }

    pan(deltaPixels) {
        this.viewStartCycle = Math.max(0, this.viewStartCycle + deltaPixels * this.cyclesPerPixel);
        this.render();
    }

    updateScaleBadge() {
        const scaleBadge = document.getElementById("waveform-scale-badge");
        if (scaleBadge) {
            const timePerPx = (this.cyclesPerPixel / (this.emulator.clkFreqHz / 1e9));
            let timeStr = `${timePerPx.toFixed(1)}ns/px`;
            if (timePerPx >= 1000) {
                timeStr = `${(timePerPx / 1000).toFixed(2)}µs/px`;
            } else if (timePerPx < 0.1) {
                timeStr = `${(timePerPx * 1000).toFixed(0)}ps/px`;
            }
            scaleBadge.textContent = `${this.cyclesPerPixel.toFixed(this.cyclesPerPixel < 1 ? 2 : 1)} cyc/px (${timeStr})`;
        }
    }

    pixelToCycle(px) {
        return Math.floor(this.viewStartCycle + px * this.cyclesPerPixel);
    }

    cycleToPixel(cycle) {
        return (cycle - this.viewStartCycle) / this.cyclesPerPixel;
    }

    render() {
        this.updateChannels();
        this.updateScaleBadge();
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
            ctx.fillText("No simulation trace recorded. Press 'Run' or 'Step' to simulate multi-core microcode.", 20, height / 2);
            ctx.restore();
            return;
        }

        const numChannels = this.channels.length;
        const headerHeight = 28;
        const channelHeight = Math.max(22, Math.floor((height - headerHeight) / numChannels));

        // 1. Grid & Time Rulers
        this.renderTimeGrid(ctx, width, height, headerHeight);

        // 2. Render Signal Traces
        for (let chIdx = 0; chIdx < numChannels; chIdx++) {
            const ch = this.channels[chIdx];
            const chTop = headerHeight + chIdx * channelHeight;
            const chBase = chTop + channelHeight - 4;
            const chHigh = chTop + 4;

            // Channel Label Background
            ctx.fillStyle = "#111827";
            ctx.fillRect(0, chTop, 170, channelHeight - 2);

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

            // Draw Signal (Digital or Bus)
            if (ch.type === "bus") {
                this.renderBusTrace(ctx, trace, ch.key, ch.color, width, chBase, chHigh);
            } else {
                this.renderDigitalTrace(ctx, trace, ch.key, ch.color, width, chBase, chHigh);
            }
        }

        // 3. Render Measurement Cursors
        this.renderCursors(ctx, width, height, headerHeight);

        ctx.restore();
    }

    renderTimeGrid(ctx, width, height, headerHeight) {
        ctx.fillStyle = "#0F172A";
        ctx.fillRect(0, 0, width, headerHeight);

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
            if (x >= 170 && x < width) {
                ctx.beginPath();
                ctx.moveTo(x, headerHeight);
                ctx.lineTo(x, height);
                ctx.stroke();

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
            const x = Math.max(170, this.cycleToPixel(s.cycle));
            const level = s[key] ? 1 : 0;
            const y = level === 1 ? yHigh : yLow;

            if (!started) {
                ctx.moveTo(x, y);
                started = true;
            } else {
                if (level !== lastLevel) {
                    ctx.lineTo(x, y === yHigh ? yLow : yHigh);
                    ctx.lineTo(x, y);
                } else {
                    ctx.lineTo(x, y);
                }
            }

            lastLevel = level;
            lastX = x;
            if (x > width) break;
        }

        ctx.stroke();
    }

    renderBusTrace(ctx, trace, key, color, width, yLow, yHigh) {
        ctx.strokeStyle = color;
        ctx.fillStyle = color;
        ctx.lineWidth = 1.5;
        ctx.font = "10px 'JetBrains Mono', monospace";

        const startIdx = Math.max(0, trace.findIndex(s => s.cycle >= this.viewStartCycle) - 1);
        const endIdx = trace.length;

        let lastVal = null;
        let busStartX = 170;

        for (let i = startIdx; i < endIdx; i++) {
            const s = trace[i];
            const x = Math.max(170, this.cycleToPixel(s.cycle));
            const val = s[key] !== undefined ? s[key] : 0;

            if (lastVal === null) {
                lastVal = val;
                busStartX = x;
            } else if (val !== lastVal || i === endIdx - 1 || x > width) {
                const busWidth = Math.max(4, x - busStartX);
                
                // Draw bus diamond envelope
                ctx.beginPath();
                ctx.moveTo(busStartX + 2, yHigh);
                ctx.lineTo(x - 2, yHigh);
                ctx.lineTo(x, (yHigh + yLow) / 2);
                ctx.lineTo(x - 2, yLow);
                ctx.lineTo(busStartX + 2, yLow);
                ctx.lineTo(busStartX, (yHigh + yLow) / 2);
                ctx.closePath();
                ctx.stroke();

                if (busWidth > 32) {
                    const text = `0x${lastVal.toString(16).padStart(2, "0").toUpperCase()}`;
                    ctx.fillText(text, busStartX + 4, (yHigh + yLow) / 2 + 3);
                }

                lastVal = val;
                busStartX = x;
            }

            if (x > width) break;
        }
    }

    renderCursors(ctx, width, height, headerHeight) {
        // Primary Cursor (Yellow)
        if (this.cursorCycle !== null && this.cursorCycle >= this.viewStartCycle) {
            const cx = this.cycleToPixel(this.cursorCycle);
            if (cx >= 170 && cx < width) {
                ctx.strokeStyle = "#FBBF24";
                ctx.lineWidth = 1.5;
                ctx.setLineDash([4, 4]);
                ctx.beginPath();
                ctx.moveTo(cx, headerHeight);
                ctx.lineTo(cx, height);
                ctx.stroke();
                ctx.setLineDash([]);

                ctx.fillStyle = "#FBBF24";
                ctx.fillRect(cx - 24, headerHeight - 22, 48, 16);
                ctx.fillStyle = "#000";
                ctx.font = "bold 9px 'JetBrains Mono', monospace";
                ctx.fillText(`C1:${this.cursorCycle}`, cx - 20, headerHeight - 10);
            }
        }

        // Secondary Cursor (Cyan)
        if (this.cursor2Cycle !== null && this.cursor2Cycle >= this.viewStartCycle) {
            const c2x = this.cycleToPixel(this.cursor2Cycle);
            if (c2x >= 170 && c2x < width) {
                ctx.strokeStyle = "#00F0FF";
                ctx.lineWidth = 1.5;
                ctx.setLineDash([2, 2]);
                ctx.beginPath();
                ctx.moveTo(c2x, headerHeight);
                ctx.lineTo(c2x, height);
                ctx.stroke();
                ctx.setLineDash([]);

                ctx.fillStyle = "#00F0FF";
                ctx.fillRect(c2x - 24, headerHeight - 22, 48, 16);
                ctx.fillStyle = "#000";
                ctx.font = "bold 9px 'JetBrains Mono', monospace";
                ctx.fillText(`C2:${this.cursor2Cycle}`, c2x - 20, headerHeight - 10);

                if (this.cursorCycle !== null) {
                    const delta = Math.abs(this.cursor2Cycle - this.cursorCycle);
                    const dtNs = (delta / (this.emulator.clkFreqHz / 1e9)).toFixed(1);
                    ctx.fillStyle = "#F8FAFC";
                    ctx.font = "11px 'JetBrains Mono', monospace";
                    ctx.fillText(`ΔT = ${delta} cyc (${dtNs} ns)`, 180, headerHeight - 10);
                }
            }
        }
    }
}
