// =============================================================================
// File        : waveform.js
// Module      : OmniBus MP Interactive Logic Analyzer & Multi-Core Waveform Canvas
// Description : High-performance multi-channel digital logic analyzer with
//               multi-core PC bus rendering, barrier pulses, spinlock traces,
//               zoom, pan, delta measurement cursors, timing bookmarks & markers,
//               hardware event auto-detection, and timing latency export reports.
// License     : MIT License
// =============================================================================

export class WaveformViewer {
    constructor(canvas, emulator) {
        this.canvas = canvas;
        this.ctx = canvas.getContext("2d");
        this.emulator = emulator;

        this.gutterWidth = 175; // Left channel name sidebar width in pixels
        this.viewStartCycle = 0;
        this.cyclesPerPixel = 2.0;
        this.cursorCycle = null;
        this.cursor2Cycle = null;
        this.isPanning = false;
        this.panStartX = 0;
        this.panStartCycle = 0;
        this.autoFollow = true;

        // Timing Bookmarks & Event Markers
        this.markers = [];
        this.hoveredMarker = null;
        this.selectedMarkerId = null;
        this.mousePos = { x: 0, y: 0 };
        this.onMarkersChanged = null;
        this.onMarkerSelected = null;

        this.colorPalette = [
            "#00F0FF", // Cyan (Info / UART)
            "#10B981", // Emerald (Success / Free / Complete)
            "#F59E0B", // Amber (Warning / CS / SPI)
            "#EC4899", // Pink (Barrier Sync Pulse)
            "#8B5CF6", // Purple (Sync / Multi-Core)
            "#EF4444", // Crimson (Spinlock Held / Fault)
            "#3B82F6", // Blue (Data / Bus)
            "#F43F5E"  // Rose (Glitch / Crowbar)
        ];

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
                name: `CORE ${i} PC [B${i}]`,
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
            const rect = this.canvas.getBoundingClientRect();
            const clickX = e.clientX - rect.left;
            const clickY = e.clientY - rect.top;

            // Check if clicked on a marker flag ribbon in the header ruler
            const hitMarker = this.getMarkerAtPosition(clickX, clickY);
            if (hitMarker) {
                this.selectedMarkerId = hitMarker.id;
                if (e.shiftKey) {
                    this.cursor2Cycle = hitMarker.cycle;
                } else {
                    this.cursorCycle = hitMarker.cycle;
                }
                this.onMarkerSelected?.(hitMarker);
                this.render();
                return;
            }

            // Ignore direct waveform clicks inside the channel label sidebar
            if (clickX < this.gutterWidth) return;

            if (e.shiftKey) {
                this.cursor2Cycle = this.pixelToCycle(clickX);
            } else if (e.button === 0) {
                this.isPanning = true;
                this.panStartX = clickX;
                this.panStartCycle = this.viewStartCycle;
                this.cursorCycle = this.pixelToCycle(clickX);
            }
            this.render();
        });

        window.addEventListener("mousemove", (e) => {
            const rect = this.canvas.getBoundingClientRect();
            const currentX = e.clientX - rect.left;
            const currentY = e.clientY - rect.top;
            this.mousePos = { x: currentX, y: currentY };

            if (this.isPanning) {
                const deltaPx = currentX - this.panStartX;
                this.viewStartCycle = Math.max(0, this.panStartCycle - (deltaPx * this.cyclesPerPixel));
                this.autoFollow = false; // Disable auto-follow when user manually scrolls
                this.render();
            } else if (currentX >= 0 && currentX <= rect.width && currentY >= 0 && currentY <= rect.height) {
                const hit = this.getMarkerAtPosition(currentX, currentY);
                if (hit !== this.hoveredMarker) {
                    this.hoveredMarker = hit;
                    this.canvas.style.cursor = hit ? "pointer" : (currentX >= this.gutterWidth ? "crosshair" : "default");
                    this.render();
                }
            }
        });

        window.addEventListener("mouseup", () => {
            this.isPanning = false;
        });

        this.canvas.addEventListener("mouseleave", () => {
            if (this.hoveredMarker) {
                this.hoveredMarker = null;
                this.render();
            }
        });

        this.canvas.addEventListener("wheel", (e) => {
            e.preventDefault();
            const zoomFactor = e.deltaY < 0 ? 0.75 : 1.33;
            this.zoom(zoomFactor, e.offsetX);
        });
    }

    getMarkerAtPosition(px, py) {
        if (py > 32) return null; // markers are in top ruler header
        for (const m of this.markers) {
            const mx = this.cycleToPixel(m.cycle);
            if (Math.abs(px - mx) <= 30) {
                return m;
            }
        }
        return null;
    }

    ensureVisible(cycle) {
        const width = this.canvas.parentElement ? this.canvas.parentElement.clientWidth : 800;
        const availableWidth = Math.max(50, width - this.gutterWidth);
        const visibleCycles = availableWidth * this.cyclesPerPixel;

        if (cycle > this.viewStartCycle + visibleCycles) {
            this.viewStartCycle = Math.max(0, cycle - visibleCycles * 0.85);
        } else if (cycle < this.viewStartCycle) {
            this.viewStartCycle = Math.max(0, cycle - visibleCycles * 0.1);
        }
    }

    zoom(zoomFactor, centerPx = null) {
        const width = this.canvas.parentElement ? this.canvas.parentElement.clientWidth : 800;
        const availableWidth = Math.max(50, width - this.gutterWidth);
        const cx = centerPx !== null ? Math.max(this.gutterWidth, centerPx) : (this.gutterWidth + availableWidth / 2);
        const mouseCycle = this.pixelToCycle(cx);

        this.cyclesPerPixel = Math.max(0.01, Math.min(500.0, this.cyclesPerPixel * zoomFactor));
        this.viewStartCycle = Math.max(0, mouseCycle - ((cx - this.gutterWidth) * this.cyclesPerPixel));
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
        const availableWidth = Math.max(50, width - this.gutterWidth);

        if (trace && trace.length > 0) {
            const minCycle = trace[0].cycle || 0;
            const maxCycle = trace[trace.length - 1].cycle || this.emulator.totalCycles || 10;
            const totalCycles = Math.max(10, maxCycle - minCycle);
            this.cyclesPerPixel = Math.max(0.01, Math.min(500.0, totalCycles / availableWidth));
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
        this.autoFollow = false;
        this.render();
    }

    // =========================================================================
    // Marker & Bookmark Management
    // =========================================================================

    addMarker(param1 = null, label = null, color = null, note = "", type = "user", autoDetected = false) {
        let cycle = null;
        if (typeof param1 === "object" && param1 !== null) {
            cycle = param1.cycle;
            label = param1.label || label;
            color = param1.color || color;
            note = param1.note || note;
            type = param1.type || type;
            autoDetected = param1.autoDetected !== undefined ? param1.autoDetected : autoDetected;
        } else {
            cycle = param1;
        }

        if (cycle === null || cycle === undefined) {
            cycle = this.cursorCycle !== null ? this.cursorCycle : Math.floor(this.viewStartCycle + 50 * this.cyclesPerPixel);
        }
        cycle = Math.max(0, Math.floor(cycle));

        const id = "m_" + Date.now() + "_" + Math.floor(Math.random() * 1000);
        const colorIdx = this.markers.length % this.colorPalette.length;
        const chosenColor = color || this.colorPalette[colorIdx];
        const timeNs = (cycle / (this.emulator.clkFreqHz / 1e9));

        const newMarker = {
            id: id,
            tag: "",
            cycle: cycle,
            timeNs: timeNs,
            label: label || `Event @ ${cycle} cyc`,
            color: chosenColor,
            note: note || "",
            type: type,
            autoDetected: !!autoDetected,
            createdAt: Date.now()
        };

        this.markers.push(newMarker);
        this.sortAndIndexMarkers();
        this.render();
        this.onMarkersChanged?.(this.markers);
        return newMarker;
    }

    removeMarker(id) {
        this.markers = this.markers.filter(m => m.id !== id);
        if (this.selectedMarkerId === id) this.selectedMarkerId = null;
        if (this.hoveredMarker && this.hoveredMarker.id === id) this.hoveredMarker = null;
        this.sortAndIndexMarkers();
        this.render();
        this.onMarkersChanged?.(this.markers);
    }

    updateMarker(id, updates) {
        const marker = this.markers.find(m => m.id === id);
        if (!marker) return;
        Object.assign(marker, updates);
        if (updates.cycle !== undefined) {
            marker.timeNs = (marker.cycle / (this.emulator.clkFreqHz / 1e9));
        }
        this.sortAndIndexMarkers();
        this.render();
        this.onMarkersChanged?.(this.markers);
    }

    clearMarkers() {
        this.markers = [];
        this.selectedMarkerId = null;
        this.hoveredMarker = null;
        this.render();
        this.onMarkersChanged?.(this.markers);
    }

    sortAndIndexMarkers() {
        this.markers.sort((a, b) => a.cycle - b.cycle);
        this.markers.forEach((m, idx) => {
            m.tag = `M${idx + 1}`;
            m.timeNs = (m.cycle / (this.emulator.clkFreqHz / 1e9));
        });
    }

    jumpToMarker(id) {
        const marker = this.markers.find(m => m.id === id);
        if (!marker) return;
        this.selectedMarkerId = marker.id;
        this.cursorCycle = marker.cycle;
        this.viewStartCycle = Math.max(0, marker.cycle - (100 * this.cyclesPerPixel));
        this.render();
    }

    snapCursor(cursorNum, markerId) {
        const marker = this.markers.find(m => m.id === markerId);
        if (!marker) return;
        if (cursorNum === 1) {
            this.cursorCycle = marker.cycle;
        } else if (cursorNum === 2) {
            this.cursor2Cycle = marker.cycle;
        }
        this.render();
    }

    autoDetectMarkers() {
        const trace = this.emulator.trace;
        if (!trace || trace.length < 2) return 0;

        let addedCount = 0;
        let lastBarrier = -100;
        let lastSpinlock = -100;
        let lastP0 = -100;
        let lastP2 = -100;

        for (let i = 1; i < trace.length; i++) {
            const prev = trace[i - 1];
            const curr = trace[i];
            const cyc = curr.cycle;

            // 1. Barrier Release Pulse (0 -> 1)
            if (curr.barrierPulse === 1 && prev.barrierPulse === 0 && (cyc - lastBarrier > 5)) {
                this.addMarker(cyc, "Barrier Lockstep Release", "#EC4899", "All active cores released synchronously", "barrier", true);
                lastBarrier = cyc;
                addedCount++;
            }

            // 2. Spinlock Acquired (0 -> >0)
            if (curr.spinlocks > 0 && prev.spinlocks === 0 && (cyc - lastSpinlock > 5)) {
                this.addMarker(cyc, "Spinlock Acquired", "#EF4444", `Spinlock bitmask 0x${curr.spinlocks.toString(16)} held`, "spinlock", true);
                lastSpinlock = cyc;
                addedCount++;
            } else if (curr.spinlocks === 0 && prev.spinlocks > 0 && (cyc - lastSpinlock > 5)) {
                this.addMarker(cyc, "Spinlock Released", "#10B981", "Atomic spinlock returned to FREE status", "spinlock", true);
                lastSpinlock = cyc;
                addedCount++;
            }

            // 3. UIO[0] Falling Edge (UART TX Start bit or I2C Start condition)
            if (prev.p0 === 1 && curr.p0 === 0 && (cyc - lastP0 > 20)) {
                this.addMarker(cyc, "UIO[0] Fall (TX0 Start)", "#00F0FF", "Falling edge on UIO0 / TX0 serial stream", "gpio", true);
                lastP0 = cyc;
                addedCount++;
            }

            // 4. UIO[2] Falling Edge (SPI CS0 Active)
            if (prev.p2 === 1 && curr.p2 === 0 && (cyc - lastP2 > 20)) {
                this.addMarker(cyc, "UIO[2] CS0 Active (LOW)", "#F59E0B", "SPI Chip-Select 0 asserted active low", "gpio", true);
                lastP2 = cyc;
                addedCount++;
            }

            // 5. Crowbar Glitch Pulse
            if (curr.glitch === 1 && prev.glitch === 0) {
                this.addMarker(cyc, "Crowbar Glitch Injected", "#F43F5E", "Active wire-speed fault pulse trigger", "glitch", true);
                addedCount++;
            }

            if (addedCount >= 25) break; // limit to prevent overwhelming table
        }

        return addedCount;
    }

    measureLatency(idOrCycleA, idOrCycleB) {
        const getCycle = (item) => {
            if (typeof item === "number") return item;
            const m = this.markers.find(x => x.id === item);
            return m ? m.cycle : 0;
        };

        const cA = getCycle(idOrCycleA);
        const cB = getCycle(idOrCycleB);
        const deltaCycles = Math.abs(cB - cA);
        const freqHz = this.emulator.clkFreqHz || 50000000;
        const deltaNs = (deltaCycles / (freqHz / 1e9));

        let formattedTime = `${deltaNs.toFixed(1)} ns`;
        if (deltaNs >= 1000000) {
            formattedTime = `${(deltaNs / 1000000).toFixed(3)} ms`;
        } else if (deltaNs >= 1000) {
            formattedTime = `${(deltaNs / 1000).toFixed(2)} µs`;
        }

        let formattedFreq = "—";
        if (deltaNs > 0) {
            const eqFreq = 1e9 / deltaNs;
            if (eqFreq >= 1e6) {
                formattedFreq = `${(eqFreq / 1e6).toFixed(2)} MHz`;
            } else if (eqFreq >= 1e3) {
                formattedFreq = `${(eqFreq / 1e3).toFixed(2)} kHz`;
            } else {
                formattedFreq = `${eqFreq.toFixed(1)} Hz`;
            }
        }

        return {
            cycleA: cA,
            cycleB: cB,
            deltaCycles: deltaCycles,
            deltaNs: deltaNs,
            formattedTime: formattedTime,
            formattedFreq: formattedFreq
        };
    }

    generateTimingReportMarkdown() {
        return this.exportTimingReportMarkdown();
    }

    exportTimingReportMarkdown() {
        const clkMHz = (this.emulator.clkFreqHz / 1e6).toFixed(1);
        const numCores = this.emulator.numCores || 2;
        const dateStr = new Date().toUTCString();

        let md = `# OmniBus MP Silicon Timing & Latency Verification Report\n\n`;
        md += `* **Generated:** ${dateStr}\n`;
        md += `* **Master Clock:** ${clkMHz} MHz (${(1e9 / this.emulator.clkFreqHz).toFixed(1)} ns cycle period)\n`;
        md += `* **Cores Topology:** ${numCores} Symmetric Core(s) (Bank 0..${numCores - 1})\n`;
        md += `* **Total Recorded Cycles:** ${this.emulator.totalCycles} cycles\n`;
        md += `* **Total Event Markers:** ${this.markers.length}\n\n`;

        md += `## 1. Event Markers & Milestones Table\n\n`;
        md += `| Tag | Cycle | Time (ns) | Time (µs) | Δ From Prev (cyc) | Δ From Prev (ns) | Category | Label | Notes |\n`;
        md += `| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |\n`;

        let prevCycle = 0;
        this.markers.forEach((m, idx) => {
            const deltaCyc = idx === 0 ? m.cycle : (m.cycle - prevCycle);
            const deltaNs = (deltaCyc / (this.emulator.clkFreqHz / 1e9)).toFixed(1);
            const timeUs = (m.timeNs / 1000).toFixed(3);
            md += `| **${m.tag}** | ${m.cycle} | ${m.timeNs.toFixed(1)} | ${timeUs} | ${deltaCyc} | ${deltaNs} | \`${m.type}\` | **${m.label}** | ${m.note || '—'} |\n`;
            prevCycle = m.cycle;
        });

        md += `\n## 2. Timing Intervals & Latency Analysis\n\n`;
        if (this.markers.length >= 2) {
            md += `| Interval | Span (Cycles) | Duration (ns) | Duration (µs) | Equivalent Baud / Freq |\n`;
            md += `| :--- | :--- | :--- | :--- | :--- |\n`;
            for (let i = 1; i < this.markers.length; i++) {
                const mA = this.markers[i - 1];
                const mB = this.markers[i];
                const lat = this.measureLatency(mA.cycle, mB.cycle);
                md += `| **${mA.tag} → ${mB.tag}** (${mA.label} → ${mB.label}) | ${lat.deltaCycles} cyc | ${lat.deltaNs.toFixed(1)} ns | ${(lat.deltaNs / 1000).toFixed(3)} µs | **${lat.formattedFreq}** |\n`;
            }
        } else {
            md += `*Place 2 or more markers to view latency spans and frequency measurements.*\n`;
        }

        md += `\n---\n*Report generated by OmniBus MP Logic Analyzer & Studio Suite.*\n`;
        return md;
    }

    exportMarkersCsv() {
        return this.exportTimingReportCsv();
    }

    exportTimingReportCsv() {
        let csv = `Tag,Cycle,Time_ns,Time_us,Delta_Prev_Cycles,Delta_Prev_ns,Category,Label,Notes,AutoDetected\n`;
        let prevCycle = 0;
        this.markers.forEach((m, idx) => {
            const deltaCyc = idx === 0 ? m.cycle : (m.cycle - prevCycle);
            const deltaNs = (deltaCyc / (this.emulator.clkFreqHz / 1e9)).toFixed(1);
            const timeUs = (m.timeNs / 1000).toFixed(4);
            const cleanLabel = (m.label || "").replace(/"/g, '""');
            const cleanNote = (m.note || "").replace(/"/g, '""');
            csv += `"${m.tag}",${m.cycle},${m.timeNs.toFixed(2)},${timeUs},${deltaCyc},${deltaNs},"${m.type}","${cleanLabel}","${cleanNote}",${m.autoDetected}\n`;
            prevCycle = m.cycle;
        });
        return csv;
    }

    exportWaveformPng() {
        return this.canvas.toDataURL("image/png");
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
        const relX = Math.max(0, px - this.gutterWidth);
        return Math.floor(this.viewStartCycle + relX * this.cyclesPerPixel);
    }

    cycleToPixel(cycle) {
        return this.gutterWidth + (cycle - this.viewStartCycle) / this.cyclesPerPixel;
    }

    render() {
        this.updateChannels();
        this.updateScaleBadge();

        const dpr = window.devicePixelRatio || 1;
        const parent = this.canvas.parentElement;
        const width = parent ? parent.clientWidth : 800;
        const height = parent ? parent.clientHeight || 320 : 320;

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
        if (!trace || trace.length === 0) {
            ctx.fillStyle = "#64748B";
            ctx.font = "13px 'Inter', sans-serif";
            ctx.fillText("No simulation trace recorded. Press 'Run' or 'Step Inst / Step Cyc' to start simulation.", this.gutterWidth + 20, height / 2);
            ctx.restore();
            return;
        }

        const numChannels = this.channels.length;
        const headerHeight = 28;
        const channelHeight = Math.max(22, Math.floor((height - headerHeight) / numChannels));

        // 1. Render Time Grid & Background Rulers
        this.renderTimeGrid(ctx, width, height, headerHeight);

        // 2. Render Signal Traces (Clipped to Waveform display area)
        for (let chIdx = 0; chIdx < numChannels; chIdx++) {
            const ch = this.channels[chIdx];
            const chTop = headerHeight + chIdx * channelHeight;
            const chBase = chTop + channelHeight - 4;
            const chHigh = chTop + 4;

            // Draw Channel Separator Grid Line across waveform
            ctx.strokeStyle = "#162032";
            ctx.lineWidth = 1;
            ctx.beginPath();
            ctx.moveTo(this.gutterWidth, chTop + channelHeight - 1);
            ctx.lineTo(width, chTop + channelHeight - 1);
            ctx.stroke();

            // Draw Signal (Digital or Bus)
            if (ch.type === "bus") {
                this.renderBusTrace(ctx, trace, ch.key, ch.color, width, chBase, chHigh);
            } else {
                this.renderDigitalTrace(ctx, trace, ch.key, ch.color, width, chBase, chHigh);
            }
        }

        // 3. Render Channel Labels Sidebar (Drawn on top to ensure crisp separation)
        this.renderChannelLabels(ctx, numChannels, headerHeight, channelHeight);

        // 4. Render Bookmarks & Timing Markers
        this.renderMarkers(ctx, width, height, headerHeight);

        // 5. Render Measurement Cursors (C1 & C2)
        this.renderCursors(ctx, width, height, headerHeight);

        // 6. Render Hover Tooltip
        if (this.hoveredMarker) {
            this.renderMarkerTooltip(ctx, this.hoveredMarker, width, height);
        }

        ctx.restore();
    }

    renderChannelLabels(ctx, numChannels, headerHeight, channelHeight) {
        for (let chIdx = 0; chIdx < numChannels; chIdx++) {
            const ch = this.channels[chIdx];
            const chTop = headerHeight + chIdx * channelHeight;

            // Channel Label Background
            ctx.fillStyle = chIdx % 2 === 0 ? "#0C111C" : "#0F1523";
            ctx.fillRect(0, chTop, this.gutterWidth, channelHeight);

            // Channel Color Pip
            ctx.fillStyle = ch.color;
            ctx.fillRect(4, chTop + 4, 3, channelHeight - 8);

            // Channel Label Text
            ctx.fillStyle = "#E2E8F0";
            ctx.font = "bold 10px 'JetBrains Mono', monospace";
            ctx.fillText(ch.name, 12, chTop + channelHeight / 2 + 3);

            // Channel Separator line
            ctx.strokeStyle = "#1E293B";
            ctx.lineWidth = 1;
            ctx.beginPath();
            ctx.moveTo(0, chTop + channelHeight - 1);
            ctx.lineTo(this.gutterWidth, chTop + channelHeight - 1);
            ctx.stroke();
        }

        // Vertical Divider Border between Gutter and Waveform Area
        ctx.strokeStyle = "rgba(0, 240, 255, 0.25)";
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.moveTo(this.gutterWidth, 0);
        ctx.lineTo(this.gutterWidth, headerHeight + numChannels * channelHeight + 20);
        ctx.stroke();
    }

    renderTimeGrid(ctx, width, height, headerHeight) {
        // Time ruler background
        ctx.fillStyle = "#0B0F19";
        ctx.fillRect(0, 0, width, headerHeight);

        const availableWidth = width - this.gutterWidth;
        const minPixelInterval = 80;
        let cycleInterval = Math.pow(10, Math.ceil(Math.log10(Math.max(1, minPixelInterval * this.cyclesPerPixel))));
        if (cycleInterval / this.cyclesPerPixel < minPixelInterval / 2) {
            cycleInterval *= 2;
        } else if (cycleInterval / this.cyclesPerPixel > minPixelInterval * 2) {
            cycleInterval = Math.max(1, Math.floor(cycleInterval / 2));
        }

        const firstGridCycle = Math.floor(this.viewStartCycle / cycleInterval) * cycleInterval;

        ctx.save();
        ctx.beginPath();
        ctx.rect(this.gutterWidth, 0, availableWidth, height);
        ctx.clip();

        ctx.strokeStyle = "#162032";
        ctx.lineWidth = 1;
        ctx.fillStyle = "#94A3B8";
        ctx.font = "10px 'JetBrains Mono', monospace";

        const maxVisibleCycle = this.viewStartCycle + availableWidth * this.cyclesPerPixel;
        for (let c = firstGridCycle; c <= maxVisibleCycle + cycleInterval; c += cycleInterval) {
            if (c < 0) continue;
            const x = this.cycleToPixel(c);
            if (x >= this.gutterWidth && x <= width) {
                // Vertical grid line through trace area
                ctx.strokeStyle = "#162032";
                ctx.beginPath();
                ctx.moveTo(x, headerHeight);
                ctx.lineTo(x, height);
                ctx.stroke();

                // Tick mark in ruler
                ctx.strokeStyle = "#334155";
                ctx.beginPath();
                ctx.moveTo(x, headerHeight - 8);
                ctx.lineTo(x, headerHeight);
                ctx.stroke();

                const timeNs = (c / (this.emulator.clkFreqHz / 1e9)).toFixed(1);
                ctx.fillText(`${c} cyc (${timeNs}ns)`, x + 4, headerHeight - 10);
            }
        }
        ctx.restore();

        // Gutter header corner
        ctx.fillStyle = "#090D16";
        ctx.fillRect(0, 0, this.gutterWidth, headerHeight);
        ctx.fillStyle = "#64748B";
        ctx.font = "bold 10px 'JetBrains Mono', monospace";
        ctx.fillText("SIGNALS / CHANNELS", 8, headerHeight / 2 + 3);

        // Header bottom border
        ctx.strokeStyle = "#1E293B";
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.moveTo(0, headerHeight);
        ctx.lineTo(width, headerHeight);
        ctx.stroke();
    }

    renderDigitalTrace(ctx, trace, key, color, width, yLow, yHigh) {
        ctx.save();
        ctx.beginPath();
        ctx.rect(this.gutterWidth, 0, width - this.gutterWidth, this.canvas.height);
        ctx.clip();

        ctx.strokeStyle = color;
        ctx.lineWidth = 2;
        ctx.beginPath();

        const visibleEndCycle = this.viewStartCycle + (width - this.gutterWidth) * this.cyclesPerPixel + 10;
        
        let startIdx = 0;
        for (let i = 0; i < trace.length; i++) {
            if (trace[i].cycle >= this.viewStartCycle) {
                startIdx = Math.max(0, i - 1);
                break;
            }
        }

        let started = false;
        let lastLevel = null;
        let lastX = this.cycleToPixel(trace[startIdx]?.cycle || 0);

        for (let i = startIdx; i < trace.length; i++) {
            const s = trace[i];
            const x = this.cycleToPixel(s.cycle);
            const level = s[key] ? 1 : 0;
            const y = level === 1 ? yHigh : yLow;

            if (!started) {
                ctx.moveTo(x, y);
                started = true;
            } else {
                if (level !== lastLevel) {
                    ctx.lineTo(x, lastLevel === 1 ? yHigh : yLow);
                    ctx.lineTo(x, y);
                } else {
                    ctx.lineTo(x, y);
                }
            }

            lastLevel = level;
            lastX = x;
            if (s.cycle > visibleEndCycle) break;
        }

        // Extend line horizontally to current total cycles if running
        if (started && this.emulator.totalCycles > 0) {
            const endX = Math.min(width + 20, this.cycleToPixel(this.emulator.totalCycles));
            if (endX > lastX) {
                ctx.lineTo(endX, lastLevel === 1 ? yHigh : yLow);
            }
        }

        ctx.stroke();
        ctx.restore();
    }

    renderBusTrace(ctx, trace, key, color, width, yLow, yHigh) {
        ctx.save();
        ctx.beginPath();
        ctx.rect(this.gutterWidth, 0, width - this.gutterWidth, this.canvas.height);
        ctx.clip();

        ctx.strokeStyle = color;
        ctx.fillStyle = color;
        ctx.lineWidth = 1.5;
        ctx.font = "10px 'JetBrains Mono', monospace";

        const visibleEndCycle = this.viewStartCycle + (width - this.gutterWidth) * this.cyclesPerPixel + 10;
        let startIdx = 0;
        for (let i = 0; i < trace.length; i++) {
            if (trace[i].cycle >= this.viewStartCycle) {
                startIdx = Math.max(0, i - 1);
                break;
            }
        }

        let lastVal = null;
        let busStartX = this.cycleToPixel(trace[startIdx]?.cycle || 0);

        for (let i = startIdx; i < trace.length; i++) {
            const s = trace[i];
            const x = this.cycleToPixel(s.cycle);
            const val = s[key] !== undefined ? s[key] : 0;

            if (lastVal === null) {
                lastVal = val;
                busStartX = x;
            } else if (val !== lastVal || i === trace.length - 1 || s.cycle > visibleEndCycle) {
                const busEndX = (i === trace.length - 1 && val === lastVal) ? Math.max(x, this.cycleToPixel(this.emulator.totalCycles)) : x;
                const busWidth = busEndX - busStartX;
                
                if (busWidth > 1) {
                    ctx.beginPath();
                    const chamfer = Math.min(3, busWidth / 2);
                    ctx.moveTo(busStartX + chamfer, yHigh);
                    ctx.lineTo(busEndX - chamfer, yHigh);
                    ctx.lineTo(busEndX, (yHigh + yLow) / 2);
                    ctx.lineTo(busEndX - chamfer, yLow);
                    ctx.lineTo(busStartX + chamfer, yLow);
                    ctx.lineTo(busStartX, (yHigh + yLow) / 2);
                    ctx.closePath();
                    ctx.stroke();

                    if (busWidth > 28) {
                        const text = `0x${lastVal.toString(16).padStart(2, "0").toUpperCase()}`;
                        ctx.fillText(text, busStartX + 5, (yHigh + yLow) / 2 + 3);
                    }
                }

                lastVal = val;
                busStartX = x;
            }

            if (s.cycle > visibleEndCycle) break;
        }

        ctx.restore();
    }

    renderMarkers(ctx, width, height, headerHeight) {
        this.markers.forEach(m => {
            const mx = this.cycleToPixel(m.cycle);
            if (mx < this.gutterWidth || mx > width) return;

            const isSelected = (this.selectedMarkerId === m.id);
            const isHovered = (this.hoveredMarker && this.hoveredMarker.id === m.id);

            // Vertical Guideline
            ctx.strokeStyle = m.color;
            ctx.lineWidth = isSelected ? 2 : (isHovered ? 1.5 : 1);
            ctx.setLineDash(isSelected ? [6, 2] : [4, 4]);
            ctx.beginPath();
            ctx.moveTo(mx, headerHeight);
            ctx.lineTo(mx, height);
            ctx.stroke();
            ctx.setLineDash([]);

            // Marker Banner Ribbon at Top
            const tagText = `${m.tag}`;
            const labelText = m.label.length > 10 ? m.label.slice(0, 9) + "…" : m.label;
            const fullText = `${tagText}: ${labelText}`;
            
            ctx.font = "bold 9px 'JetBrains Mono', monospace";
            const textWidth = ctx.measureText(fullText).width;
            const ribbonWidth = Math.max(48, textWidth + 12);
            const ribbonHalf = ribbonWidth / 2;

            ctx.fillStyle = m.color;
            ctx.beginPath();
            ctx.moveTo(mx - ribbonHalf, 2);
            ctx.lineTo(mx + ribbonHalf, 2);
            ctx.lineTo(mx + ribbonHalf, headerHeight - 8);
            ctx.lineTo(mx, headerHeight - 1);
            ctx.lineTo(mx - ribbonHalf, headerHeight - 8);
            ctx.closePath();
            ctx.fill();

            if (isSelected || isHovered) {
                ctx.strokeStyle = "#FFFFFF";
                ctx.lineWidth = 1.5;
                ctx.stroke();
            }

            // Ribbon Text
            ctx.fillStyle = "#000000";
            ctx.textAlign = "center";
            ctx.fillText(fullText, mx, headerHeight / 2 - 1);
            ctx.textAlign = "left";
        });
    }

    renderMarkerTooltip(ctx, marker, width, height) {
        const mx = this.cycleToPixel(marker.cycle);
        const timeNs = (marker.cycle / (this.emulator.clkFreqHz / 1e9)).toFixed(1);
        const timeUs = (timeNs / 1000).toFixed(3);

        const lines = [
            `[${marker.tag}] ${marker.label}`,
            `Cycle: ${marker.cycle} (${timeNs} ns / ${timeUs} µs)`,
            marker.note ? `Note: ${marker.note}` : null
        ].filter(Boolean);

        ctx.font = "11px 'JetBrains Mono', monospace";
        let maxW = 120;
        lines.forEach(l => {
            const w = ctx.measureText(l).width;
            if (w > maxW) maxW = w;
        });

        const boxW = maxW + 16;
        const boxH = lines.length * 16 + 10;
        let boxX = Math.min(width - boxW - 10, Math.max(this.gutterWidth + 10, mx - boxW / 2));
        const boxY = 32;

        // Tooltip Background
        ctx.fillStyle = "rgba(7, 10, 16, 0.95)";
        ctx.strokeStyle = marker.color;
        ctx.lineWidth = 1.5;
        ctx.beginPath();
        ctx.roundRect(boxX, boxY, boxW, boxH, 6);
        ctx.fill();
        ctx.stroke();

        // Tooltip text
        ctx.fillStyle = marker.color;
        ctx.font = "bold 11px 'JetBrains Mono', monospace";
        ctx.fillText(lines[0], boxX + 8, boxY + 16);

        ctx.fillStyle = "#E2E8F0";
        ctx.font = "10px 'JetBrains Mono', monospace";
        for (let i = 1; i < lines.length; i++) {
            ctx.fillText(lines[i], boxX + 8, boxY + 16 + i * 16);
        }
    }

    renderCursors(ctx, width, height, headerHeight) {
        // Primary Cursor (Yellow)
        if (this.cursorCycle !== null && this.cursorCycle >= this.viewStartCycle) {
            const cx = this.cycleToPixel(this.cursorCycle);
            if (cx >= this.gutterWidth && cx < width) {
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
            if (c2x >= this.gutterWidth && c2x < width) {
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
                    ctx.fillText(`ΔT = ${delta} cyc (${dtNs} ns)`, this.gutterWidth + 10, headerHeight - 10);
                }
            }
        }
    }
}
