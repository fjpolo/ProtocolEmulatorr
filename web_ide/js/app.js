// =============================================================================
// File        : app.js
// Module      : OmniBus MP Web IDE Main Application Orchestrator
// Description : Manages Multi-Core UI state, code editing, Omni-C & ASM compilation,
//               cycle-by-cycle execution, multi-core waveform visualization,
//               shared mailbox & spinlock telemetry, timing bookmarks & markers,
//               hardware event auto-detection, and WebSerial hardware flashing.
// License     : MIT License
// =============================================================================

import { OmniBusAssembler } from "./assembler.js";
import { OmniBusEmulator } from "./emulator.js";
import { WaveformViewer } from "./waveform.js";
import { OmniBusAudioEngine } from "./audio_engine.js";
import { OmniBusWebSerial } from "./webserial.js";
import { OmniCCompiler } from "./c_compiler.js";
import { VIRTUAL_HEADERS } from "./c_headers.js";
import { PRESETS } from "./presets.js";

class OmniBusApp {
    constructor() {
        this.assembler = new OmniBusAssembler(50000000);
        this.emulator = new OmniBusEmulator(50000000, 2);
        this.audio = new OmniBusAudioEngine();
        this.webSerial = new OmniBusWebSerial();
        this.cCompiler = new OmniCCompiler(VIRTUAL_HEADERS);
        this.waveform = null;

        this.currentLanguage = "c"; // "c" | "asm"
        this.lastEmittedAsm = "";
        this.currentPresetId = "c_uart_echo";
        this.selectedHeaderName = "omnibus.h";
        this.animFrameId = null;
        this.execSpeed = 1000;
        this.compiledData = null;
        this.editingMarkerId = null;

        // Optimization & Source Debugger State (Task 38)
        this.optLevel = 2; // 0, 1, 2
        this.breakpoints = new Set(); // Set of line numbers (1-indexed)
        this.currentExecLine = null;

        // Workspace Layout & Editor State
        this.editorFontSize = 13;
        this.isWordWrap = false;
        this.layoutMode = "default";
        this.isInspectorCollapsed = false;

        window.app = this;
        this.init();
    }

    init() {
        this.cacheDomElements();
        this.populatePresets();
        this.setupWaveform();
        this.initLayout();
        this.initResizers();
        this.bindEvents();
        this.loadPreset(this.currentPresetId);
        this.updateUi();
        this.updateMarkersUi();
    }

    cacheDomElements() {
        // Workspace Layout DOM
        this.mainWorkspace = document.getElementById("main-workspace");
        this.editorPanel = document.getElementById("editor-panel");
        this.inspectorPane = document.getElementById("inspector-pane");
        this.bottomDock = document.getElementById("bottom-dock");
        this.resizerLeft = document.getElementById("resizer-left");
        this.resizerRight = document.getElementById("resizer-right");
        this.resizerDock = document.getElementById("resizer-dock");
        this.layoutModeSelect = document.getElementById("layout-mode-select");

        // Code Editor & Controls
        this.codeEditor = document.getElementById("code-editor");
        this.lineNumbers = document.getElementById("line-numbers");
        this.presetSelect = document.getElementById("preset-select");
        this.coreCountSelect = document.getElementById("core-count-select");
        this.statusBadge = document.getElementById("status-badge");
        this.clockFreqSelect = document.getElementById("clock-freq-select");
        this.speedSlider = document.getElementById("speed-slider");
        this.speedLabel = document.getElementById("speed-label");
        this.labelNumCores = document.getElementById("label-num-cores");

        // Optimization & Debugging Controls
        this.optLevelSelect = document.getElementById("opt-level-select");
        this.optSavingsBadge = document.getElementById("opt-savings-badge");
        this.bpCountBadge = document.getElementById("bp-count-badge");
        this.btnStepCLine = document.getElementById("btn-step-c-line");

        // Language & Editor Controls
        this.btnModeC = document.getElementById("btn-mode-c");
        this.btnModeAsm = document.getElementById("btn-mode-asm");
        this.btnViewAsm = document.getElementById("btn-view-asm");
        this.btnViewHeaders = document.getElementById("btn-view-headers");
        this.btnFontDec = document.getElementById("btn-font-dec");
        this.btnFontInc = document.getElementById("btn-font-inc");
        this.fontSizeLabel = document.getElementById("font-size-label");
        this.btnToggleWrap = document.getElementById("btn-toggle-wrap");
        this.btnMaximizeEditor = document.getElementById("btn-maximize-editor");
        this.btnToggleInspector = document.getElementById("btn-toggle-inspector");

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

        // Debug Watch Panel DOM
        this.debugPcLoc = document.getElementById("debug-pc-loc");
        this.dbgRegAcc = document.getElementById("dbg-reg-acc");
        this.dbgRegFlags = document.getElementById("dbg-reg-flags");
        this.dbgRegLc0 = document.getElementById("dbg-reg-lc0");
        this.dbgRegLc1 = document.getElementById("dbg-reg-lc1");
        this.dbgRegR = Array.from({ length: 8 }, (_, i) => document.getElementById(`dbg-reg-r${i}`));
        this.dbgRegOsr = document.getElementById("dbg-reg-osr");
        this.dbgRegIsr = document.getElementById("dbg-reg-isr");
        this.dbgRegStack = document.getElementById("dbg-reg-stack");
        this.dbgRegState = document.getElementById("dbg-reg-state");
        this.bankUsageElems = Array.from({ length: 4 }, (_, i) => document.getElementById(`bank-usage-${i}`));
        this.bankFillElems = Array.from({ length: 4 }, (_, i) => document.getElementById(`bank-fill-${i}`));
        this.breakpointsListContainer = document.getElementById("breakpoints-list-container");
        this.btnClearAllBps = document.getElementById("btn-clear-all-bps");

        // Waveform & Zoom Controls
        this.btnZoomIn = document.getElementById("btn-zoom-in");
        this.btnZoomOut = document.getElementById("btn-zoom-out");
        this.btnZoomFit = document.getElementById("btn-zoom-fit");
        this.btnZoomReset = document.getElementById("btn-zoom-reset");
        this.btnClearCursors = document.getElementById("btn-clear-cursors");
        this.btnAutoFollow = document.getElementById("btn-auto-follow");
        this.waveformScaleBadge = document.getElementById("waveform-scale-badge");
        this.btnQuickAddMarker = document.getElementById("btn-quick-add-marker");
        this.btnQuickAutoDetect = document.getElementById("btn-quick-auto-detect");

        // Bottom Dock & Tabs
        this.tabBtnMarkers = document.getElementById("tab-btn-markers");
        this.tabBtnConsole = document.getElementById("tab-btn-console");
        this.dockPanelMarkers = document.getElementById("dock-panel-markers");
        this.dockPanelConsole = document.getElementById("dock-panel-console");
        this.markersCountBadge = document.getElementById("markers-count-badge");
        this.btnDockAddMarker = document.getElementById("btn-dock-add-marker");
        this.btnDockAutoDetect = document.getElementById("btn-dock-auto-detect");
        this.btnExportTimingReport = document.getElementById("btn-export-timing-report");
        this.btnExportTimingCsv = document.getElementById("btn-export-timing-csv");
        this.btnSnapshotPng = document.getElementById("btn-snapshot-png");
        this.btnClearAllMarkers = document.getElementById("btn-clear-all-markers");

        // Latency Calculator
        this.latencyFromSelect = document.getElementById("latency-from-select");
        this.latencyToSelect = document.getElementById("latency-to-select");
        this.metricDeltaCycles = document.getElementById("metric-delta-cycles");
        this.metricDeltaTime = document.getElementById("metric-delta-time");
        this.metricDeltaFreq = document.getElementById("metric-delta-freq");

        // Markers Table
        this.markersTableBody = document.getElementById("markers-table-body");

        // Marker Modal Dialog
        this.markerModal = document.getElementById("marker-modal");
        this.modalMarkerTitle = document.getElementById("modal-marker-title");
        this.btnCloseMarkerModal = document.getElementById("btn-close-marker-modal");
        this.btnCancelMarker = document.getElementById("btn-cancel-marker");
        this.btnSaveMarker = document.getElementById("btn-save-marker");
        this.inputMarkerCycle = document.getElementById("input-marker-cycle");
        this.labelMarkerTimeNs = document.getElementById("label-marker-time-ns");
        this.inputMarkerLabel = document.getElementById("input-marker-label");
        this.inputMarkerNote = document.getElementById("input-marker-note");

        // Timing Report Modal Dialog
        this.reportModal = document.getElementById("report-modal");
        this.btnCloseReportModal = document.getElementById("btn-close-report-modal");
        this.btnCopyReport = document.getElementById("btn-copy-report");
        this.btnDownloadReportMd = document.getElementById("btn-download-report-md");
        this.btnDownloadReportCsv = document.getElementById("btn-download-report-csv");
        this.reportPreviewText = document.getElementById("report-preview-text");

        // Generated Assembly Modal Dialog
        this.asmModal = document.getElementById("asm-modal");
        this.btnCloseAsmModal = document.getElementById("btn-close-asm-modal");
        this.btnCopyAsm = document.getElementById("btn-copy-asm");
        this.btnDownloadAsm = document.getElementById("btn-download-asm");
        this.btnLoadAsmEditor = document.getElementById("btn-load-asm-editor");
        this.asmPreviewText = document.getElementById("asm-preview-text");
        this.labelAsmStats = document.getElementById("label-asm-stats");

        // Virtual Headers Modal Dialog
        this.headersModal = document.getElementById("headers-modal");
        this.btnCloseHeadersModal = document.getElementById("btn-close-headers-modal");
        this.headersListContainer = document.getElementById("headers-list-container");
        this.currentHeaderTitle = document.getElementById("current-header-title");
        this.headerPreviewText = document.getElementById("header-preview-text");
        this.btnCopyHeader = document.getElementById("btn-copy-header");

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
            opt.textContent = `${p.title}`;
            this.presetSelect.appendChild(opt);
        });
    }

    setupWaveform() {
        const canvas = document.getElementById("waveform-canvas");
        this.waveform = new WaveformViewer(canvas, this.emulator);

        this.waveform.onMarkersChanged = () => {
            this.updateMarkersUi();
        };

        this.waveform.onMarkerSelected = (marker) => {
            this.switchDockTab("markers");
            this.highlightMarkerRow(marker.id);
        };
    }

    bindEvents() {
        this.presetSelect.addEventListener("change", (e) => this.loadPreset(e.target.value));
        this.coreCountSelect.addEventListener("change", (e) => this.setCoreTopology(parseInt(e.target.value, 10)));
        this.clockFreqSelect.addEventListener("change", (e) => {
            const freq = parseInt(e.target.value, 10);
            this.assembler.clkFreqHz = freq;
            this.emulator.clkFreqHz = freq;
            this.log(`Master clock set to ${(freq / 1e6).toFixed(1)} MHz`);
            this.updateMarkersUi();
        });

        // Language Switcher
        if (this.btnModeC) this.btnModeC.addEventListener("click", () => this.setLanguage("c"));
        if (this.btnModeAsm) this.btnModeAsm.addEventListener("click", () => this.setLanguage("asm"));
        if (this.btnViewAsm) this.btnViewAsm.addEventListener("click", () => this.openAsmModal());
        if (this.btnViewHeaders) this.btnViewHeaders.addEventListener("click", () => this.openHeadersModal());

        // Optimization Selector & Debugging
        if (this.optLevelSelect) {
            this.optLevelSelect.addEventListener("change", (e) => {
                this.optLevel = parseInt(e.target.value, 10);
                this.log(`Omni-C Optimizer Level set to: -O${this.optLevel}`);
                this.assembleCode();
            });
        }
        if (this.bpCountBadge) {
            this.bpCountBadge.addEventListener("click", () => this.clearBreakpoints());
        }

        this.codeEditor.addEventListener("input", () => this.updateLineNumbers());
        this.codeEditor.addEventListener("scroll", () => {
            this.lineNumbers.scrollTop = this.codeEditor.scrollTop;
        });

        // Gutter Click to toggle Breakpoint
        this.lineNumbers.addEventListener("click", (e) => {
            const lineElem = e.target.closest(".gutter-line");
            if (lineElem) {
                const lineNum = parseInt(lineElem.getAttribute("data-line"), 10);
                if (lineNum) this.toggleBreakpoint(lineNum);
            }
        });

        this.speedSlider.addEventListener("input", (e) => {
            this.execSpeed = parseInt(e.target.value, 10);
            this.speedLabel.textContent = `${this.execSpeed} cyc/fr`;
        });

        // Execution actions
        this.btnAssemble.addEventListener("click", () => this.assembleCode());
        this.btnRun.addEventListener("click", () => this.startSimulation());
        this.btnPause.addEventListener("click", () => this.pauseSimulation());
        if (this.btnStepCLine) this.btnStepCLine.addEventListener("click", () => this.stepCLine());
        this.btnStepInst.addEventListener("click", () => this.stepInstruction());
        this.btnStepCycle.addEventListener("click", () => this.stepCycle());
        this.btnReset.addEventListener("click", () => this.resetSimulation());

        // Waveform Zoom actions
        if (this.btnZoomIn) this.btnZoomIn.addEventListener("click", () => this.waveform?.zoomIn());
        if (this.btnZoomOut) this.btnZoomOut.addEventListener("click", () => this.waveform?.zoomOut());
        if (this.btnZoomFit) this.btnZoomFit.addEventListener("click", () => this.waveform?.zoomFit());
        if (this.btnZoomReset) this.btnZoomReset.addEventListener("click", () => this.waveform?.resetZoom());
        if (this.btnClearCursors) this.btnClearCursors.addEventListener("click", () => this.waveform?.clearCursors());
        if (this.btnAutoFollow) {
            this.btnAutoFollow.addEventListener("click", () => {
                if (!this.waveform) return;
                this.waveform.autoFollow = !this.waveform.autoFollow;
                this.btnAutoFollow.classList.toggle("active", this.waveform.autoFollow);
                this.log(`Waveform Auto-Follow: ${this.waveform.autoFollow ? "ENABLED" : "PAUSED"}`);
                if (this.waveform.autoFollow) {
                    this.waveform.ensureVisible(this.emulator.totalCycles);
                    this.waveform.render();
                }
            });
        }

        // Timing Markers & Bookmarks
        if (this.btnQuickAddMarker) this.btnQuickAddMarker.addEventListener("click", () => this.openMarkerModal());
        if (this.btnDockAddMarker) this.btnDockAddMarker.addEventListener("click", () => this.openMarkerModal());
        if (this.btnQuickAutoDetect) this.btnQuickAutoDetect.addEventListener("click", () => this.triggerAutoDetect());
        if (this.btnDockAutoDetect) this.btnDockAutoDetect.addEventListener("click", () => this.triggerAutoDetect());
        if (this.btnClearAllMarkers) this.btnClearAllMarkers.addEventListener("click", () => this.clearAllMarkers());

        // Dock Tabs
        if (this.tabBtnMarkers) this.tabBtnMarkers.addEventListener("click", () => this.switchDockTab("markers"));
        if (this.tabBtnConsole) this.tabBtnConsole.addEventListener("click", () => this.switchDockTab("console"));

        // Latency Dropdowns
        if (this.latencyFromSelect) this.latencyFromSelect.addEventListener("change", () => this.updateLatencyCalculation());
        if (this.latencyToSelect) this.latencyToSelect.addEventListener("change", () => this.updateLatencyCalculation());

        // Reports & Snapshot
        if (this.btnExportTimingReport) this.btnExportTimingReport.addEventListener("click", () => this.openReportModal());
        if (this.btnExportTimingCsv) this.btnExportTimingCsv.addEventListener("click", () => this.downloadReportCsv());
        if (this.btnSnapshotPng) this.btnSnapshotPng.addEventListener("click", () => this.downloadSnapshotPng());

        // Marker Modal
        if (this.btnCloseMarkerModal) this.btnCloseMarkerModal.addEventListener("click", () => this.closeMarkerModal());
        if (this.btnCancelMarker) this.btnCancelMarker.addEventListener("click", () => this.closeMarkerModal());
        if (this.btnSaveMarker) this.btnSaveMarker.addEventListener("click", () => this.saveMarkerFromModal());
        if (this.inputMarkerCycle) {
            this.inputMarkerCycle.addEventListener("input", (e) => {
                const cyc = parseInt(e.target.value, 10) || 0;
                const ns = (cyc / (this.emulator.clkFreqHz / 1e9)).toFixed(1);
                this.labelMarkerTimeNs.textContent = `${ns} ns (${(ns / 1000).toFixed(3)} µs)`;
            });
        }

        // Timing Report Modal
        if (this.btnCloseReportModal) this.btnCloseReportModal.addEventListener("click", () => this.closeReportModal());
        if (this.btnCopyReport) this.btnCopyReport.addEventListener("click", () => this.copyReportToClipboard());
        if (this.btnDownloadReportMd) this.btnDownloadReportMd.addEventListener("click", () => this.downloadReportMd());
        if (this.btnDownloadReportCsv) this.btnDownloadReportCsv.addEventListener("click", () => this.downloadReportCsv());

        // Generated ASM Modal
        if (this.btnCloseAsmModal) this.btnCloseAsmModal.addEventListener("click", () => this.closeAsmModal());
        if (this.btnCopyAsm) this.btnCopyAsm.addEventListener("click", () => this.copyAsmToClipboard());
        if (this.btnDownloadAsm) this.btnDownloadAsm.addEventListener("click", () => this.downloadAsmFile());
        if (this.btnLoadAsmEditor) this.btnLoadAsmEditor.addEventListener("click", () => this.loadAsmIntoEditor());

        // Headers Modal
        if (this.btnCloseHeadersModal) this.btnCloseHeadersModal.addEventListener("click", () => this.closeHeadersModal());
        if (this.btnCopyHeader) this.btnCopyHeader.addEventListener("click", () => this.copyHeaderToClipboard());

        // Byte injection
        this.btnInjectTx.addEventListener("click", () => {
            const val = parseInt(this.inputTxByte.value.trim(), 16);
            if (!isNaN(val)) {
                this.emulator.pushTxByte(val);
                this.log(`Injected 0x${val.toString(16).padStart(2, "0").toUpperCase()} into Host TX FIFO`);
                this.updateUi();
            }
        });

        // Layout & Editor Zoom Controls
        if (this.layoutModeSelect) {
            this.layoutModeSelect.addEventListener("change", (e) => this.setLayoutMode(e.target.value));
        }
        if (this.btnFontDec) {
            this.btnFontDec.addEventListener("click", () => this.changeFontSize(-1));
        }
        if (this.btnFontInc) {
            this.btnFontInc.addEventListener("click", () => this.changeFontSize(1));
        }
        if (this.btnToggleWrap) {
            this.btnToggleWrap.addEventListener("click", () => this.toggleWordWrap());
        }
        if (this.btnMaximizeEditor) {
            this.btnMaximizeEditor.addEventListener("click", () => this.toggleMaximizeEditor());
        }
        if (this.btnToggleInspector) {
            this.btnToggleInspector.addEventListener("click", () => this.toggleInspector());
        }

        // Code Editor Tab Key & Indentation Support
        this.codeEditor.addEventListener("keydown", (e) => {
            if (e.key === "Tab") {
                e.preventDefault();
                const start = this.codeEditor.selectionStart;
                const end = this.codeEditor.selectionEnd;
                const value = this.codeEditor.value;

                if (!e.shiftKey) {
                    // Indent
                    if (start === end) {
                        this.codeEditor.value = value.substring(0, start) + "    " + value.substring(end);
                        this.codeEditor.selectionStart = this.codeEditor.selectionEnd = start + 4;
                    } else {
                        const lines = value.substring(start, end).split("\n");
                        const indented = lines.map(line => "    " + line).join("\n");
                        this.codeEditor.value = value.substring(0, start) + indented + value.substring(end);
                        this.codeEditor.selectionStart = start;
                        this.codeEditor.selectionEnd = start + indented.length;
                    }
                } else {
                    // Outdent (Shift+Tab)
                    const lineStart = value.lastIndexOf("\n", start - 1) + 1;
                    const selectedText = value.substring(lineStart, end);
                    const lines = selectedText.split("\n");
                    let removedCount = 0;
                    const outdented = lines.map((line, idx) => {
                        if (line.startsWith("    ")) {
                            if (idx === 0) removedCount = 4;
                            return line.substring(4);
                        } else if (line.startsWith(" ")) {
                            const spaces = line.match(/^ +/)[0].length;
                            const toRemove = Math.min(spaces, 4);
                            if (idx === 0) removedCount = toRemove;
                            return line.substring(toRemove);
                        }
                        return line;
                    }).join("\n");
                    this.codeEditor.value = value.substring(0, lineStart) + outdented + value.substring(end);
                    this.codeEditor.selectionStart = Math.max(lineStart, start - removedCount);
                    this.codeEditor.selectionEnd = lineStart + outdented.length;
                }
                this.updateLineNumbers();
            }
        });

        // Window resize
        window.addEventListener("resize", () => {
            this.waveform?.render();
        });

        // WebSerial
        this.btnConnectSerial.addEventListener("click", () => this.connectSerial());
        this.btnFlashSerial.addEventListener("click", () => this.flashSerial());

        // Exports
        this.btnExportHex.addEventListener("click", () => this.exportHex());
        this.btnExportVcd.addEventListener("click", () => this.exportVcd());

        // Keyboard shortcuts
        window.addEventListener("keydown", (e) => {
            const activeTag = document.activeElement?.tagName?.toLowerCase();
            const isTyping = (activeTag === "textarea" || activeTag === "input");

            if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "b") {
                e.preventDefault();
                this.assembleCode();
                return;
            }

            if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "e") {
                e.preventDefault();
                this.openAsmModal();
                return;
            }

            if (e.key === "F9") {
                e.preventDefault();
                this.stepCLine();
                return;
            }

            if (e.key === "F8") {
                e.preventDefault();
                this.stepInstruction();
                return;
            }

            if (e.key === "F7") {
                e.preventDefault();
                this.stepCycle();
                return;
            }

            if (e.key === "F5") {
                e.preventDefault();
                if (this.emulator.running) this.pauseSimulation();
                else this.startSimulation();
                return;
            }

            if (e.key === "F11" || (e.altKey && e.key === "Enter")) {
                e.preventDefault();
                this.toggleMaximizeEditor();
                return;
            }

            if (e.altKey && e.key.toLowerCase() === "z") {
                e.preventDefault();
                this.toggleWordWrap();
                return;
            }

            if (e.altKey && e.key.toLowerCase() === "i") {
                e.preventDefault();
                this.toggleInspector();
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
                    this.closeMarkerModal();
                    this.closeReportModal();
                    this.closeAsmModal();
                    this.closeHeadersModal();
                    this.waveform?.clearCursors();
                } else if (e.key === "ArrowLeft") {
                    e.preventDefault();
                    this.waveform?.pan(-40);
                } else if (e.key === "ArrowRight") {
                    e.preventDefault();
                    this.waveform?.pan(40);
                } else if (e.key.toLowerCase() === "m") {
                    e.preventDefault();
                    this.openMarkerModal();
                }
            }
        });
    }

    // =========================================================================
    // Dynamic Layout & Resizing Management
    // =========================================================================

    initLayout() {
        // Restore layout mode
        const savedMode = localStorage.getItem("omnibus_layout_mode") || "default";
        if (this.layoutModeSelect) this.layoutModeSelect.value = savedMode;
        this.setLayoutMode(savedMode, false);

        // Restore custom widths if stored
        const savedEditorWidth = localStorage.getItem("omnibus_editor_width");
        if (savedEditorWidth) {
            document.documentElement.style.setProperty("--editor-width", savedEditorWidth);
        }

        const savedInspectorWidth = localStorage.getItem("omnibus_inspector_width");
        if (savedInspectorWidth) {
            document.documentElement.style.setProperty("--inspector-width", savedInspectorWidth);
        }

        const savedDockHeight = localStorage.getItem("omnibus_dock_height");
        if (savedDockHeight) {
            document.documentElement.style.setProperty("--dock-height", savedDockHeight);
        }

        // Restore Font Size
        const savedFontSize = parseInt(localStorage.getItem("omnibus_font_size"), 10);
        if (savedFontSize && savedFontSize >= 9 && savedFontSize <= 24) {
            this.editorFontSize = savedFontSize;
            this.applyFontSize();
        } else {
            this.editorFontSize = 13;
            this.applyFontSize();
        }

        // Restore Word Wrap
        const savedWrap = localStorage.getItem("omnibus_word_wrap") === "true";
        this.isWordWrap = savedWrap;
        this.applyWordWrap();

        // Restore Inspector Collapse state
        const savedInspectorCollapsed = localStorage.getItem("omnibus_inspector_collapsed") === "true";
        if (savedInspectorCollapsed) {
            this.isInspectorCollapsed = true;
            this.mainWorkspace?.classList.add("inspector-collapsed");
            if (this.btnToggleInspector) this.btnToggleInspector.textContent = "▶ Expand";
        }
    }

    initResizers() {
        // 1. Left Resizer (Editor <-> Center Waveform)
        if (this.resizerLeft) {
            this.setupDraggable(this.resizerLeft, "x", (deltaX, currentX) => {
                const workspaceRect = this.mainWorkspace.getBoundingClientRect();
                let newWidth = currentX - workspaceRect.left;
                const minW = 220;
                const maxW = Math.max(minW, workspaceRect.width - (this.isInspectorCollapsed ? 280 : 540));
                newWidth = Math.max(minW, Math.min(newWidth, maxW));
                document.documentElement.style.setProperty("--editor-width", `${newWidth}px`);
                localStorage.setItem("omnibus_editor_width", `${newWidth}px`);
                this.waveform?.render();
            });

            this.resizerLeft.addEventListener("dblclick", () => {
                const currentWidth = parseInt(getComputedStyle(document.documentElement).getPropertyValue("--editor-width"), 10) || 480;
                const workspaceWidth = this.mainWorkspace.clientWidth;
                if (currentWidth < workspaceWidth * 0.45) {
                    const wideWidth = Math.floor(workspaceWidth * 0.5);
                    document.documentElement.style.setProperty("--editor-width", `${wideWidth}px`);
                    localStorage.setItem("omnibus_editor_width", `${wideWidth}px`);
                } else {
                    document.documentElement.style.setProperty("--editor-width", `480px`);
                    localStorage.setItem("omnibus_editor_width", `480px`);
                }
                this.waveform?.render();
            });
        }

        // 2. Right Resizer (Center Waveform <-> Inspector)
        if (this.resizerRight) {
            this.setupDraggable(this.resizerRight, "x", (deltaX, currentX) => {
                const workspaceRect = this.mainWorkspace.getBoundingClientRect();
                let newWidth = workspaceRect.right - currentX;
                const minW = 200;
                const maxW = Math.max(minW, workspaceRect.width - 500);
                newWidth = Math.max(minW, Math.min(newWidth, maxW));
                document.documentElement.style.setProperty("--inspector-width", `${newWidth}px`);
                localStorage.setItem("omnibus_inspector_width", `${newWidth}px`);
                this.waveform?.render();
            });

            this.resizerRight.addEventListener("dblclick", () => {
                this.toggleInspector();
            });
        }

        // 3. Dock Resizer (Waveform <-> Bottom Dock)
        if (this.resizerDock) {
            this.setupDraggable(this.resizerDock, "y", (deltaY, currentY) => {
                const centerPane = document.querySelector(".center-pane");
                if (!centerPane) return;
                const centerRect = centerPane.getBoundingClientRect();
                let newHeight = centerRect.bottom - currentY;
                const minH = 34;
                const maxH = Math.max(minH, centerRect.height - 120);
                newHeight = Math.max(minH, Math.min(newHeight, maxH));
                document.documentElement.style.setProperty("--dock-height", `${newHeight}px`);
                localStorage.setItem("omnibus_dock_height", `${newHeight}px`);
                this.waveform?.render();
            });

            this.resizerDock.addEventListener("dblclick", () => {
                const currentHeight = parseInt(getComputedStyle(document.documentElement).getPropertyValue("--dock-height"), 10) || 160;
                if (currentHeight > 50) {
                    document.documentElement.style.setProperty("--dock-height", `34px`);
                    localStorage.setItem("omnibus_dock_height", `34px`);
                } else {
                    document.documentElement.style.setProperty("--dock-height", `180px`);
                    localStorage.setItem("omnibus_dock_height", `180px`);
                }
                this.waveform?.render();
            });
        }
    }

    setupDraggable(resizerElem, axis, onMove) {
        let isDragging = false;
        let startPos = 0;

        const onPointerDown = (e) => {
            isDragging = true;
            resizerElem.classList.add("active");
            document.body.classList.add("is-resizing");
            startPos = (axis === "x") ? e.clientX : e.clientY;
            document.body.style.cursor = (axis === "x") ? "col-resize" : "row-resize";
            e.preventDefault();
        };

        const onPointerMove = (e) => {
            if (!isDragging) return;
            const currentPos = (axis === "x") ? e.clientX : e.clientY;
            const delta = currentPos - startPos;
            onMove(delta, currentPos);
        };

        const onPointerUp = () => {
            if (isDragging) {
                isDragging = false;
                resizerElem.classList.remove("active");
                document.body.classList.remove("is-resizing");
                document.body.style.cursor = "";
                this.waveform?.render();
            }
        };

        resizerElem.addEventListener("mousedown", onPointerDown);
        window.addEventListener("mousemove", onPointerMove);
        window.addEventListener("mouseup", onPointerUp);
    }

    setLayoutMode(mode, save = true) {
        this.layoutMode = mode;
        if (!this.mainWorkspace) return;

        this.mainWorkspace.classList.remove("layout-max-editor", "layout-wide-editor", "layout-focus-waveform");

        if (mode === "max-editor") {
            this.mainWorkspace.classList.add("layout-max-editor");
            if (this.btnMaximizeEditor) {
                this.btnMaximizeEditor.textContent = "🗗 Restore";
                this.btnMaximizeEditor.title = "Restore standard layout split";
            }
        } else if (mode === "wide-editor") {
            this.mainWorkspace.classList.add("layout-wide-editor");
            if (this.btnMaximizeEditor) {
                this.btnMaximizeEditor.textContent = "⛶ Maximize";
                this.btnMaximizeEditor.title = "Maximize Editor (Full screen)";
            }
        } else if (mode === "focus-waveform") {
            this.mainWorkspace.classList.add("layout-focus-waveform");
            if (this.btnMaximizeEditor) {
                this.btnMaximizeEditor.textContent = "⛶ Maximize";
                this.btnMaximizeEditor.title = "Maximize Editor (Full screen)";
            }
        } else {
            // default
            if (this.btnMaximizeEditor) {
                this.btnMaximizeEditor.textContent = "⛶ Maximize";
                this.btnMaximizeEditor.title = "Maximize Editor (Full screen)";
            }
        }

        if (this.layoutModeSelect) this.layoutModeSelect.value = mode;
        if (save) localStorage.setItem("omnibus_layout_mode", mode);

        requestAnimationFrame(() => {
            this.waveform?.render();
        });
    }

    toggleMaximizeEditor() {
        if (this.layoutMode === "max-editor") {
            this.setLayoutMode("default");
        } else {
            this.setLayoutMode("max-editor");
        }
    }

    toggleInspector() {
        this.isInspectorCollapsed = !this.isInspectorCollapsed;
        if (this.isInspectorCollapsed) {
            this.mainWorkspace?.classList.add("inspector-collapsed");
            if (this.btnToggleInspector) this.btnToggleInspector.textContent = "▶ Expand";
        } else {
            this.mainWorkspace?.classList.remove("inspector-collapsed");
            if (this.btnToggleInspector) this.btnToggleInspector.textContent = "✕ Collapse";
        }
        localStorage.setItem("omnibus_inspector_collapsed", this.isInspectorCollapsed);
        requestAnimationFrame(() => {
            this.waveform?.render();
        });
    }

    changeFontSize(delta) {
        this.editorFontSize = Math.max(9, Math.min(24, this.editorFontSize + delta));
        this.applyFontSize();
        localStorage.setItem("omnibus_font_size", this.editorFontSize);
    }

    applyFontSize() {
        const size = this.editorFontSize;
        const lineHeight = Math.round(size * 1.55);
        document.documentElement.style.setProperty("--editor-font-size", `${size}px`);
        document.documentElement.style.setProperty("--editor-line-height", `${lineHeight}px`);
        if (this.fontSizeLabel) this.fontSizeLabel.textContent = `${size}px`;
        this.updateLineNumbers();
    }

    toggleWordWrap() {
        this.isWordWrap = !this.isWordWrap;
        this.applyWordWrap();
        localStorage.setItem("omnibus_word_wrap", this.isWordWrap);
    }

    applyWordWrap() {
        if (this.isWordWrap) {
            this.codeEditor?.classList.add("word-wrap");
            if (this.btnToggleWrap) {
                this.btnToggleWrap.textContent = "↔ No-Wrap";
                this.btnToggleWrap.classList.add("btn-primary");
            }
        } else {
            this.codeEditor?.classList.remove("word-wrap");
            if (this.btnToggleWrap) {
                this.btnToggleWrap.textContent = "↩ Wrap";
                this.btnToggleWrap.classList.remove("btn-primary");
            }
        }
        this.updateLineNumbers();
    }

    // =========================================================================
    // Language Mode Handling (C / ASM)
    // =========================================================================

    setLanguage(lang) {
        this.currentLanguage = lang;

        if (lang === "c") {
            this.btnModeC?.classList.add("active");
            this.btnModeAsm?.classList.remove("active");
            this.btnAssemble.textContent = "⚡ Compile & Assemble";
            this.btnAssemble.title = "Compile Omni-C and Assemble to Machine Code (Ctrl+B)";
            this.codeEditor.placeholder = "/* Enter Omni-C high-level C code here... */";
            if (this.btnViewAsm) this.btnViewAsm.style.display = "inline-flex";
        } else {
            this.btnModeAsm?.classList.add("active");
            this.btnModeC?.classList.remove("active");
            this.btnAssemble.textContent = "⚡ Assemble";
            this.btnAssemble.title = "Assemble OmniBus Microcode (Ctrl+B)";
            this.codeEditor.placeholder = "; Enter OmniBus 16-bit Assembly microcode here...";
            if (this.btnViewAsm) this.btnViewAsm.style.display = "none";
        }

        this.log(`Editor mode set to: ${lang === "c" ? "Omni-C (High-Level C)" : "OmniBus 16-bit Assembly"}`);
    }

    openAsmModal() {
        if (!this.lastEmittedAsm) {
            // Attempt to compile current code
            this.assembleCode();
        }

        if (this.asmPreviewText) {
            this.asmPreviewText.value = this.lastEmittedAsm || "; No assembly emitted yet. Click 'Compile & Assemble' first.";
        }

        if (this.labelAsmStats) {
            const lineCount = this.lastEmittedAsm ? this.lastEmittedAsm.split("\n").length : 0;
            this.labelAsmStats.textContent = `${lineCount} assembly lines emitted`;
        }

        if (this.asmModal) {
            this.asmModal.style.display = "flex";
        }
    }

    closeAsmModal() {
        if (this.asmModal) this.asmModal.style.display = "none";
    }

    copyAsmToClipboard() {
        if (!this.lastEmittedAsm) return;
        navigator.clipboard.writeText(this.lastEmittedAsm).then(() => {
            this.log("Copied emitted assembly to clipboard.");
        });
    }

    downloadAsmFile() {
        if (!this.lastEmittedAsm) return;
        const blob = new Blob([this.lastEmittedAsm], { type: "text/plain" });
        const url = URL.createObjectURL(blob);
        const a = document.createElement("a");
        a.href = url;
        a.download = "emitted_program.asm";
        a.click();
        URL.revokeObjectURL(url);
        this.log("Downloaded emitted assembly: emitted_program.asm");
    }

    loadAsmIntoEditor() {
        if (!this.lastEmittedAsm) return;
        this.setLanguage("asm");
        this.codeEditor.value = this.lastEmittedAsm;
        this.updateLineNumbers();
        this.closeAsmModal();
        this.assembleCode();
        this.log("Loaded emitted assembly into active editor (Switched to ASM mode).");
    }

    openHeadersModal() {
        if (!this.headersModal) return;

        if (this.headersListContainer) {
            this.headersListContainer.innerHTML = "";
            Object.keys(VIRTUAL_HEADERS).forEach(headerName => {
                const btn = document.createElement("button");
                btn.className = `header-item-btn ${headerName === this.selectedHeaderName ? "active" : ""}`;
                btn.innerHTML = `<span>${headerName}</span>`;
                btn.addEventListener("click", () => {
                    this.selectedHeaderName = headerName;
                    this.showVirtualHeader(headerName);
                });
                this.headersListContainer.appendChild(btn);
            });
        }

        this.showVirtualHeader(this.selectedHeaderName);
        this.headersModal.style.display = "flex";
    }

    showVirtualHeader(headerName) {
        if (this.currentHeaderTitle) this.currentHeaderTitle.textContent = `<${headerName}>`;
        if (this.headerPreviewText) this.headerPreviewText.value = VIRTUAL_HEADERS[headerName] || "";

        // Update active class on sidebar buttons
        if (this.headersListContainer) {
            const btns = this.headersListContainer.querySelectorAll(".header-item-btn");
            btns.forEach(b => {
                if (b.textContent.trim() === headerName) b.classList.add("active");
                else b.classList.remove("active");
            });
        }
    }

    closeHeadersModal() {
        if (this.headersModal) this.headersModal.style.display = "none";
    }

    copyHeaderToClipboard() {
        const text = VIRTUAL_HEADERS[this.selectedHeaderName];
        if (!text) return;
        navigator.clipboard.writeText(text).then(() => {
            this.log(`Copied <${this.selectedHeaderName}> header content to clipboard.`);
        });
    }

    // =========================================================================
    // Dock Tabs & Markers UI
    // =========================================================================

    switchDockTab(tabName) {
        if (tabName === "markers") {
            this.tabBtnMarkers?.classList.add("active");
            this.tabBtnConsole?.classList.remove("active");
            this.dockPanelMarkers?.classList.add("active");
            this.dockPanelConsole?.classList.remove("active");
        } else {
            this.tabBtnConsole?.classList.add("active");
            this.tabBtnMarkers?.classList.remove("active");
            this.dockPanelConsole?.classList.add("active");
            this.dockPanelMarkers?.classList.remove("active");
        }
    }

    triggerAutoDetect() {
        if (!this.waveform) return;
        const count = this.waveform.autoDetectMarkers();
        if (count > 0) {
            this.log(`Auto-detected ${count} hardware event timing marker(s).`);
            this.switchDockTab("markers");
        } else {
            this.log("No new hardware events detected. Run simulation or step instructions to generate protocol transitions.");
        }
    }

    clearAllMarkers() {
        if (!this.waveform) return;
        this.waveform.clearMarkers();
        this.log("Cleared all timing markers.");
    }

    updateMarkersUi() {
        if (!this.waveform) return;
        const markers = this.waveform.markers;

        // Badge Count
        if (this.markersCountBadge) {
            this.markersCountBadge.textContent = markers.length;
        }

        // Update Latency Dropdowns
        if (this.latencyFromSelect && this.latencyToSelect) {
            const currentFrom = this.latencyFromSelect.value;
            const currentTo = this.latencyToSelect.value;

            let opts = `<option value="C1">Cursor 1 (${this.waveform.cursorCycle !== null ? this.waveform.cursorCycle : 0} cyc)</option>`;
            opts += `<option value="C2">Cursor 2 (${this.waveform.cursor2Cycle !== null ? this.waveform.cursor2Cycle : 0} cyc)</option>`;

            markers.forEach(m => {
                opts += `<option value="${m.id}">[${m.tag}] ${m.label} (${m.cycle} cyc)</option>`;
            });

            this.latencyFromSelect.innerHTML = opts;
            this.latencyToSelect.innerHTML = opts;

            if (currentFrom && Array.from(this.latencyFromSelect.options).some(o => o.value === currentFrom)) {
                this.latencyFromSelect.value = currentFrom;
            } else if (markers.length >= 2) {
                this.latencyFromSelect.value = markers[0].id;
            }

            if (currentTo && Array.from(this.latencyToSelect.options).some(o => o.value === currentTo)) {
                this.latencyToSelect.value = currentTo;
            } else if (markers.length >= 2) {
                this.latencyToSelect.value = markers[1].id;
            }

            this.updateLatencyCalculation();
        }

        // Render Table
        if (!this.markersTableBody) return;
        if (markers.length === 0) {
            this.markersTableBody.innerHTML = `<tr><td colspan="7" class="markers-empty-msg">No timing markers placed. Click "+ Add Marker" (or press M), or click "⚡ Auto-Detect" to discover hardware events.</td></tr>`;
            return;
        }

        let html = "";
        markers.forEach((m, idx) => {
            const deltaPrev = idx > 0 ? (m.cycle - markers[idx - 1].cycle) : "-";
            const deltaPrevTime = idx > 0 ? `${((m.cycle - markers[idx - 1].cycle) / (this.emulator.clkFreqHz / 1e9)).toFixed(1)} ns` : "-";

            html += `
                <tr class="marker-row" data-id="${m.id}" onclick="window.app?.onMarkerRowClicked('${m.id}')">
                    <td>
                        <span class="marker-tag-badge" style="background: ${m.color}22; color: ${m.color}; border: 1px solid ${m.color}66;">
                            <span class="color-dot" style="background: ${m.color};"></span>
                            ${m.tag}
                        </span>
                    </td>
                    <td class="marker-label-cell" title="${this.escapeHtml(m.label)}">${this.escapeHtml(m.label)}</td>
                    <td style="color: var(--primary-cyan); font-weight: bold;">${m.cycle}</td>
                    <td style="color: var(--text-main);">${m.timeNs >= 1000 ? (m.timeNs / 1000).toFixed(2) + " µs" : m.timeNs.toFixed(1) + " ns"}</td>
                    <td style="color: var(--text-dim);">${deltaPrev !== "-" ? `+${deltaPrev} cyc (${deltaPrevTime})` : "-"}</td>
                    <td class="marker-notes-cell" title="${this.escapeHtml(m.note)}">${this.escapeHtml(m.note) || "-"}</td>
                    <td>
                        <div class="table-actions">
                            <button class="btn-table-action" onclick="event.stopPropagation(); window.app?.jumpToMarker('${m.id}')" title="Jump Waveform to Marker">🎯</button>
                            <button class="btn-table-action" onclick="event.stopPropagation(); window.app?.editMarker('${m.id}')" title="Edit Marker">✏️</button>
                            <button class="btn-table-action del" onclick="event.stopPropagation(); window.app?.deleteMarker('${m.id}')" title="Delete Marker">🗑️</button>
                        </div>
                    </td>
                </tr>
            `;
        });

        this.markersTableBody.innerHTML = html;
    }

    onMarkerRowClicked(markerId) {
        this.jumpToMarker(markerId);
        this.highlightMarkerRow(markerId);
    }

    highlightMarkerRow(markerId) {
        if (!this.markersTableBody) return;
        const rows = this.markersTableBody.querySelectorAll(".marker-row");
        rows.forEach(r => {
            if (r.getAttribute("data-id") === markerId) {
                r.classList.add("selected");
                r.scrollIntoView({ block: "nearest", behavior: "smooth" });
            } else {
                r.classList.remove("selected");
            }
        });
    }

    jumpToMarker(markerId) {
        if (!this.waveform) return;
        this.waveform.jumpToMarker(markerId);
    }

    deleteMarker(markerId) {
        if (!this.waveform) return;
        this.waveform.removeMarker(markerId);
        this.log(`Removed timing marker.`);
    }

    openMarkerModal(markerId = null) {
        this.editingMarkerId = markerId;

        let targetCycle = this.waveform?.cursorCycle !== null ? this.waveform.cursorCycle : (this.emulator.totalCycles || 0);
        let label = "Event Marker";
        let note = "";
        let color = "#00F0FF";

        if (markerId && this.waveform) {
            const m = this.waveform.markers.find(x => x.id === markerId);
            if (m) {
                targetCycle = m.cycle;
                label = m.label;
                note = m.note || "";
                color = m.color;
                this.modalMarkerTitle.textContent = `✏️ Edit Timing Marker [${m.tag}]`;
            }
        } else {
            this.modalMarkerTitle.textContent = "🔖 Place Waveform Timing Marker";
        }

        if (this.inputMarkerCycle) this.inputMarkerCycle.value = targetCycle;
        if (this.inputMarkerLabel) this.inputMarkerLabel.value = label;
        if (this.inputMarkerNote) this.inputMarkerNote.value = note;

        const ns = (targetCycle / (this.emulator.clkFreqHz / 1e9)).toFixed(1);
        if (this.labelMarkerTimeNs) this.labelMarkerTimeNs.textContent = `${ns} ns (${(ns / 1000).toFixed(3)} µs)`;

        // Select color radio
        const radios = document.querySelectorAll("input[name='marker-color']");
        radios.forEach(r => {
            r.checked = (r.value === color);
        });

        if (this.markerModal) this.markerModal.style.display = "flex";
    }

    closeMarkerModal() {
        if (this.markerModal) this.markerModal.style.display = "none";
        this.editingMarkerId = null;
    }

    setMarkerPreset(label, color, note) {
        if (this.inputMarkerLabel) this.inputMarkerLabel.value = label;
        if (this.inputMarkerNote) this.inputMarkerNote.value = note;

        const radios = document.querySelectorAll("input[name='marker-color']");
        radios.forEach(r => {
            r.checked = (r.value === color);
        });
    }

    saveMarkerFromModal() {
        if (!this.waveform) return;

        const cycle = parseInt(this.inputMarkerCycle.value, 10) || 0;
        const label = this.inputMarkerLabel.value.trim() || "Event Marker";
        const note = this.inputMarkerNote.value.trim();

        let color = "#00F0FF";
        const selectedRadio = document.querySelector("input[name='marker-color']:checked");
        if (selectedRadio) color = selectedRadio.value;

        if (this.editingMarkerId) {
            this.waveform.updateMarker(this.editingMarkerId, { cycle, label, color, note });
            this.log(`Updated marker [${label}] at cycle ${cycle}.`);
        } else {
            const m = this.waveform.addMarker({ cycle, label, color, note });
            this.log(`Placed marker [${m.tag}] "${label}" at cycle ${cycle}.`);
        }

        this.closeMarkerModal();
    }

    editMarker(markerId) {
        this.openMarkerModal(markerId);
    }

    updateLatencyCalculation() {
        if (!this.waveform || !this.latencyFromSelect || !this.latencyToSelect) return;

        const fromVal = this.latencyFromSelect.value;
        const toVal = this.latencyToSelect.value;

        const getCycleForVal = (val) => {
            if (val === "C1") return this.waveform.cursorCycle !== null ? this.waveform.cursorCycle : 0;
            if (val === "C2") return this.waveform.cursor2Cycle !== null ? this.waveform.cursor2Cycle : 0;
            const m = this.waveform.markers.find(x => x.id === val);
            return m ? m.cycle : 0;
        };

        const cA = getCycleForVal(fromVal);
        const cB = getCycleForVal(toVal);
        const delta = Math.abs(cB - cA);
        const dtNs = (delta / (this.emulator.clkFreqHz / 1e9));

        if (this.metricDeltaCycles) this.metricDeltaCycles.textContent = `${delta} cyc`;
        if (this.metricDeltaTime) this.metricDeltaTime.textContent = dtNs >= 1000 ? `${(dtNs / 1000).toFixed(3)} µs` : `${dtNs.toFixed(1)} ns`;

        if (this.metricDeltaFreq) {
            if (delta > 0 && dtNs > 0) {
                const freqHz = 1e9 / dtNs;
                if (freqHz >= 1e6) {
                    this.metricDeltaFreq.textContent = `${(freqHz / 1e6).toFixed(2)} MHz`;
                } else if (freqHz >= 1e3) {
                    this.metricDeltaFreq.textContent = `${(freqHz / 1e3).toFixed(1)} kHz`;
                } else {
                    this.metricDeltaFreq.textContent = `${freqHz.toFixed(0)} Hz`;
                }
            } else {
                this.metricDeltaFreq.textContent = "-- Hz";
            }
        }
    }

    openReportModal() {
        if (!this.waveform || !this.reportModal) return;
        const reportMd = this.waveform.generateTimingReportMarkdown();
        if (this.reportPreviewText) {
            this.reportPreviewText.value = reportMd;
        }
        this.reportModal.style.display = "flex";
    }

    closeReportModal() {
        if (this.reportModal) this.reportModal.style.display = "none";
    }

    copyReportToClipboard() {
        if (!this.waveform) return;
        const report = this.waveform.generateTimingReportMarkdown();
        navigator.clipboard.writeText(report).then(() => {
            this.log("Copied Timing Analysis Markdown report to clipboard.");
        });
    }

    downloadReportMd() {
        if (!this.waveform) return;
        const report = this.waveform.generateTimingReportMarkdown();
        const blob = new Blob([report], { type: "text/markdown" });
        const url = URL.createObjectURL(blob);
        const a = document.createElement("a");
        a.href = url;
        a.download = "omnibus_mp_timing_report.md";
        a.click();
        URL.revokeObjectURL(url);
        this.log("Exported Timing Analysis Report: omnibus_mp_timing_report.md");
    }

    downloadReportCsv() {
        if (!this.waveform) return;
        const csv = this.waveform.exportMarkersCsv();
        const blob = new Blob([csv], { type: "text/csv" });
        const url = URL.createObjectURL(blob);
        const a = document.createElement("a");
        a.href = url;
        a.download = "omnibus_mp_timing_markers.csv";
        a.click();
        URL.revokeObjectURL(url);
        this.log("Exported Timing Markers CSV: omnibus_mp_timing_markers.csv");
    }

    downloadSnapshotPng() {
        if (!this.waveform) return;
        const dataUrl = this.waveform.exportWaveformPng();
        const a = document.createElement("a");
        a.href = dataUrl;
        a.download = "omnibus_mp_waveform_annotated.png";
        a.click();
        this.log("Exported Annotated Waveform PNG: omnibus_mp_waveform_annotated.png");
    }

    escapeHtml(str) {
        if (!str) return "";
        return String(str).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
    }

    // =========================================================================
    // Core Topology & Presets
    // =========================================================================

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
        this.setLanguage(preset.lang || "c");
        this.codeEditor.value = preset.code;
        this.updateLineNumbers();

        if (preset.numCores) {
            this.setCoreTopology(preset.numCores);
        }

        this.log(`Loaded preset: "${preset.title}"`);
        this.assembleCode();
    }

    updateLineNumbers() {
        const lines = this.codeEditor.value.split("\n").length;
        let html = "";
        for (let i = 1; i <= lines; i++) {
            const hasBp = this.breakpoints.has(i);
            const isActive = (this.currentExecLine === i);
            const classes = ["gutter-line"];
            if (hasBp) classes.push("has-breakpoint");
            if (isActive) classes.push("active-line");
            html += `<div class="${classes.join(" ")}" data-line="${i}" title="Line ${i}${hasBp ? ' (Breakpoint active)' : ' (Click to set breakpoint)'}"><span class="bp-marker">●</span><span class="line-num">${i}</span><span class="exec-arrow">▶</span></div>`;
        }
        this.lineNumbers.innerHTML = html;
    }

    updateActiveLineGutter() {
        if (!this.lineNumbers) return;
        const lines = this.lineNumbers.querySelectorAll(".gutter-line");
        lines.forEach(elem => {
            const lineNum = parseInt(elem.getAttribute("data-line"), 10);
            if (lineNum === this.currentExecLine) {
                elem.classList.add("active-line");
            } else {
                elem.classList.remove("active-line");
            }
        });
    }

    toggleBreakpoint(line) {
        if (this.breakpoints.has(line)) {
            this.breakpoints.delete(line);
            this.log(`Removed breakpoint at Line ${line}.`);
        } else {
            this.breakpoints.add(line);
            const mappedPCs = (this.currentLanguage === "c") ? (this.assembler.cLineToPCs[line] || []) : [this.assembler.asmLineToPC[line]];
            const validPCs = mappedPCs.filter(p => p !== undefined);
            const pcStr = validPCs.map(p => "0x" + p.toString(16).padStart(2, "0").toUpperCase()).join(", ");
            this.log(`Set breakpoint at ${this.currentLanguage === "c" ? "C Line" : "ASM Line"} ${line} ${pcStr ? `(PC: ${pcStr})` : '(Pending next compilation)'}`);
        }
        this.updateLineNumbers();
        this.updateBreakpointsUi();
    }

    clearBreakpoints() {
        this.breakpoints.clear();
        this.updateLineNumbers();
        this.updateBreakpointsUi();
        this.log("Cleared all breakpoints.");
    }

    isBreakpointHit(pc) {
        if (this.breakpoints.size === 0) return { hit: false };
        if (this.currentLanguage === "c") {
            const cLine = this.assembler.pcToCLine ? this.assembler.pcToCLine[pc] : null;
            if (cLine && this.breakpoints.has(cLine)) {
                return { hit: true, line: cLine, pc };
            }
        } else {
            const asmLine = this.assembler.pcToAsmLine ? this.assembler.pcToAsmLine[pc] : null;
            if (asmLine && this.breakpoints.has(asmLine)) {
                return { hit: true, line: asmLine, pc };
            }
        }
        return { hit: false };
    }

    updateBreakpointsUi() {
        const bpArray = Array.from(this.breakpoints).sort((a, b) => a - b);
        if (this.bpCountBadge) {
            if (bpArray.length > 0) {
                this.bpCountBadge.textContent = `● ${bpArray.length} BP${bpArray.length > 1 ? 's' : ''}`;
                this.bpCountBadge.style.display = "inline-block";
            } else {
                this.bpCountBadge.style.display = "none";
            }
        }

        if (this.btnClearAllBps) {
            this.btnClearAllBps.style.display = (bpArray.length > 0) ? "inline-block" : "none";
        }

        if (this.breakpointsListContainer) {
            if (bpArray.length === 0) {
                this.breakpointsListContainer.innerHTML = `<span style="font-size: 10px; color: var(--text-dim);">No breakpoints set. Click line numbers in editor gutter to toggle.</span>`;
                return;
            }

            let html = "";
            bpArray.forEach(line => {
                const mappedPCs = (this.currentLanguage === "c") ? (this.assembler.cLineToPCs[line] || []) : [this.assembler.asmLineToPC[line]];
                const validPCs = (mappedPCs || []).filter(p => p !== undefined);
                const pcStr = validPCs.map(p => "0x" + p.toString(16).padStart(2, "0").toUpperCase()).join(",");
                html += `
                    <div class="bp-chip" title="Breakpoint on Line ${line}">
                        <span>L${line}${pcStr ? ` (${pcStr})` : ''}</span>
                        <span class="bp-remove" onclick="event.stopPropagation(); window.app?.toggleBreakpoint(${line})" title="Remove Breakpoint">✕</span>
                    </div>
                `;
            });
            this.breakpointsListContainer.innerHTML = html;
        }
    }

    updateBankUsageUi() {
        const bankUsage = this.assembler.bankUsage || [0, 0, 0, 0];
        for (let b = 0; b < 4; b++) {
            const count = bankUsage[b] || 0;
            const pct = Math.min(100, Math.round((count / 32) * 100));
            const isOver = count > 32;

            if (this.bankUsageElems[b]) {
                this.bankUsageElems[b].textContent = `${count} / 32 (${pct}%)${isOver ? ' OVERFLOW' : ''}`;
                this.bankUsageElems[b].style.color = isOver ? "var(--accent-crimson)" : "var(--text-muted)";
            }
            if (this.bankFillElems[b]) {
                this.bankFillElems[b].style.width = `${Math.min(100, pct)}%`;
                if (isOver) this.bankFillElems[b].classList.add("over-limit");
                else this.bankFillElems[b].classList.remove("over-limit");
            }
        }
    }

    assembleCode() {
        const source = this.codeEditor.value;
        let asmSource = source;

        if (this.currentLanguage === "c") {
            this.log(`[Omni-C] Preprocessing & compiling C source with standard libraries (-O${this.optLevel})...`);
            const cResult = this.cCompiler.compile(source, { optimize: this.optLevel });

            if (!cResult.success) {
                this.statusBadge.textContent = "C SYNTAX ERR";
                this.statusBadge.className = "status-badge err";
                this.log(`[Error] Omni-C Compilation failed:`);
                cResult.errors.forEach(err => this.log(`  ${err}`));
                if (this.optSavingsBadge) this.optSavingsBadge.style.display = "none";
                return false;
            }

            asmSource = cResult.asmSource;
            this.lastEmittedAsm = asmSource;
            const asmLines = asmSource.split("\n").filter(l => l.trim()).length;
            
            if (cResult.sourceMap && cResult.sourceMap.unoptimizedLines > 0) {
                const saved = cResult.sourceMap.savedLines;
                const pct = Math.max(0, Math.round((saved / cResult.sourceMap.unoptimizedLines) * 100));
                if (this.optSavingsBadge) {
                    this.optSavingsBadge.textContent = `-${pct}% (${saved} saved)`;
                    this.optSavingsBadge.style.display = "inline-block";
                }
                this.log(`[Omni-C] Generated ${asmLines} lines of 16-bit OmniBus Assembly (Optimizer: -${pct}% words saved, ${cResult.sourceMap.passesRun} passes).`);
            } else {
                if (this.optSavingsBadge) this.optSavingsBadge.style.display = "none";
                this.log(`[Omni-C] Generated ${asmLines} lines of 16-bit OmniBus Assembly.`);
            }
        } else {
            this.lastEmittedAsm = source;
            if (this.optSavingsBadge) this.optSavingsBadge.style.display = "none";
        }

        const result = this.assembler.assemble(asmSource);

        if (this.assembler.errors.length > 0) {
            this.statusBadge.textContent = "ASM SYNTAX ERR";
            this.statusBadge.className = "status-badge err";
            this.log(`[Error] Assembly failed with ${this.assembler.errors.length} error(s):`);
            this.assembler.errors.forEach(err => this.log(`  Line ${err.lineNum}: ${err.message}`));
            return false;
        }

        this.statusBadge.textContent = `OK (${this.assembler.machineCode.length} INST)`;
        this.statusBadge.className = "status-badge ok";
        this.compiledData = this.assembler.machineCode;

        this.emulator.loadProgram(this.compiledData);
        this.log(`[Assemble] Successfully loaded ${this.compiledData.length} instructions into multi-bank IMEM.`);
        this.renderHexDisasm();
        this.updateBankUsageUi();
        this.updateBreakpointsUi();
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
        if (this.btnStepCLine) this.btnStepCLine.disabled = true;

        const loop = () => {
            if (!this.emulator.running) return;

            for (let i = 0; i < this.execSpeed; i++) {
                this.emulator.stepCycle();

                // Breakpoint check across all active cores
                for (let c = 0; c < this.emulator.numCores; c++) {
                    const bpHit = this.isBreakpointHit(this.emulator.cores[c].pc);
                    if (bpHit.hit) {
                        this.pauseSimulation();
                        this.log(`[Breakpoint Hit] Stopped simulation at ${this.currentLanguage === "c" ? "C Line" : "ASM Line"} ${bpHit.line} (Core ${c} PC: 0x${this.emulator.cores[c].pc.toString(16).padStart(2, "0").toUpperCase()})`);
                        return;
                    }
                }
            }

            this.updateUi();
            if (this.waveform?.autoFollow) {
                this.waveform.ensureVisible(this.emulator.totalCycles);
            }
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
        if (this.btnStepCLine) this.btnStepCLine.disabled = false;

        this.log(`Simulation paused at cycle ${this.emulator.totalCycles}.`);
        this.updateUi();
        this.waveform?.render();
    }

    stepCLine() {
        if (!this.compiledData) {
            if (!this.assembleCode()) return;
        }

        const emu = this.emulator;
        const core0 = emu.cores[0];

        if (this.currentLanguage === "c") {
            const startCLine = this.assembler.pcToCLine[core0.pc] || null;
            let maxSteps = 5000;
            let hitBp = false;

            while (maxSteps-- > 0) {
                emu.stepCycle();

                // Check breakpoints
                for (let c = 0; c < emu.numCores; c++) {
                    const bpHit = this.isBreakpointHit(emu.cores[c].pc);
                    if (bpHit.hit) {
                        hitBp = true;
                        this.log(`[Breakpoint Hit] Stopped at C Line ${bpHit.line} (Core ${c} PC: 0x${emu.cores[c].pc.toString(16).padStart(2, "0").toUpperCase()})`);
                        break;
                    }
                }
                if (hitBp) break;

                const currCLine = this.assembler.pcToCLine[core0.pc] || null;
                if (currCLine !== null && currCLine !== startCLine) {
                    break;
                }
                if (core0.state === "HALTED") {
                    this.log("[Debugger] Core 0 HALTED.");
                    break;
                }
            }
        } else {
            this.stepInstruction();
            return;
        }

        this.updateUi();
        if (this.waveform?.autoFollow) {
            this.waveform.ensureVisible(emu.totalCycles);
        }
        this.waveform?.render();
    }

    stepInstruction() {
        if (!this.compiledData) this.assembleCode();
        this.emulator.stepInstruction();
        this.updateUi();
        if (this.waveform?.autoFollow) {
            this.waveform.ensureVisible(this.emulator.totalCycles);
        }
        this.waveform?.render();
    }

    stepCycle() {
        if (!this.compiledData) this.assembleCode();
        this.emulator.stepCycle();
        this.updateUi();
        if (this.waveform?.autoFollow) {
            this.waveform.ensureVisible(this.emulator.totalCycles);
        }
        this.waveform?.render();
    }

    resetSimulation() {
        this.pauseSimulation();
        this.emulator.reset();
        if (this.compiledData) {
            this.emulator.loadProgram(this.compiledData);
        }
        if (this.waveform) {
            this.waveform.viewStartCycle = 0;
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
        const numCores = emu.numCores || 2;
        const core0 = emu.cores[0];

        if (this.valCycles) {
            this.valCycles.textContent = `${emu.totalCycles} Cycles`;
        }

        // Active Source Line Tracking
        const activeLine = (this.currentLanguage === "c") ? (this.assembler.pcToCLine[core0.pc] || null) : (this.assembler.pcToAsmLine[core0.pc] || null);
        if (activeLine !== this.currentExecLine) {
            this.currentExecLine = activeLine;
            this.updateActiveLineGutter();
        }

        // Debug Watch Inspector Panel Update
        if (this.debugPcLoc) {
            this.debugPcLoc.textContent = (this.currentLanguage === "c") ? 
                `C Line: ${this.currentExecLine || '—'} [PC: 0x${core0.pc.toString(16).padStart(2, "0").toUpperCase()}]` : 
                `ASM Line: ${this.currentExecLine || '—'} [PC: 0x${core0.pc.toString(16).padStart(2, "0").toUpperCase()}]`;
        }

        if (this.dbgRegAcc) this.dbgRegAcc.textContent = `0x${core0.acc.toString(16).padStart(2, "0").toUpperCase()}`;
        if (this.dbgRegFlags) this.dbgRegFlags.textContent = `Z:${core0.flags.z ? 1 : 0} C:${core0.flags.c ? 1 : 0} N:${core0.flags.n ? 1 : 0}`;
        if (this.dbgRegLc0) this.dbgRegLc0.textContent = core0.lc0;
        if (this.dbgRegLc1) this.dbgRegLc1.textContent = core0.lc1;

        for (let r = 0; r < 8; r++) {
            if (this.dbgRegR[r]) {
                this.dbgRegR[r].textContent = `0x${(core0.r[r] || 0).toString(16).padStart(2, "0").toUpperCase()}`;
            }
        }

        if (this.dbgRegOsr) this.dbgRegOsr.textContent = `0x${(core0.osr || 0).toString(16).padStart(2, "0").toUpperCase()}`;
        if (this.dbgRegIsr) this.dbgRegIsr.textContent = `0x${(core0.isr || 0).toString(16).padStart(2, "0").toUpperCase()}`;
        if (this.dbgRegStack) this.dbgRegStack.textContent = `Depth: ${core0.callSp || 0}`;
        if (this.dbgRegState) {
            this.dbgRegState.textContent = core0.state;
            this.dbgRegState.style.color = (core0.state === "HALTED") ? "var(--accent-crimson)" : (core0.state === "BARRIER_WAIT" ? "var(--accent-pink)" : "var(--accent-emerald)");
        }

        // Multi-Core Slices
        for (let i = 0; i < 4; i++) {
            if (i >= numCores) continue;

            const core = emu.cores[i];
            const pcElem = document.getElementById(`core-pc-${i}`);
            const accElem = document.getElementById(`core-acc-${i}`);
            const fzElem = document.getElementById(`core-fz-${i}`);
            const lcElem = document.getElementById(`core-lc0-${i}`);
            const instElem = document.getElementById(`core-inst-${i}`);
            const stateElem = document.getElementById(`core-state-${i}`);

            if (pcElem) pcElem.textContent = `0x${core.pc.toString(16).padStart(2, "0").toUpperCase()}`;
            if (accElem) accElem.textContent = `0x${core.acc.toString(16).padStart(2, "0").toUpperCase()}`;
            if (fzElem) fzElem.textContent = core.flags.z ? "1" : "0";
            if (lcElem) lcElem.textContent = core.lc0;

            if (instElem) {
                const currentInst = emu.imem[core.pc] || 0;
                instElem.textContent = emu.disassembleInstruction(currentInst);
            }

            if (stateElem) {
                if (core.state === "BARRIER_WAIT") {
                    stateElem.textContent = "BARRIER";
                    stateElem.className = "core-state-pill barrier";
                } else if (core.delayCnt > 0 || core.state === "DELAY") {
                    stateElem.textContent = `DELAY (${core.delayCnt})`;
                    stateElem.className = "core-state-pill delay";
                } else if (core.state === "HALTED") {
                    stateElem.textContent = "HALTED";
                    stateElem.className = "core-state-pill halted";
                } else {
                    stateElem.textContent = core.state || "RUN";
                    stateElem.className = "core-state-pill";
                }
            }
        }

        // Shared Mailboxes
        for (let i = 0; i < 8; i++) {
            if (this.mbValElements[i]) {
                const val = emu.mailboxes[i] || 0;
                this.mbValElements[i].textContent = `0x${val.toString(16).padStart(2, "0").toUpperCase()}`;
            }
        }

        // Spinlocks
        for (let i = 0; i < 4; i++) {
            const held = emu.spinlocks[i] !== null;
            if (this.lockStatusElements[i]) {
                this.lockStatusElements[i].textContent = held ? `CORE ${emu.spinlocks[i]}` : "FREE";
                this.lockStatusElements[i].className = `lock-status ${held ? "held" : "free"}`;
            }
            if (this.lockCellElements[i]) {
                if (held) this.lockCellElements[i].classList.add("held");
                else this.lockCellElements[i].classList.remove("held");
            }
        }

        // Barrier rendezvous animation
        const allInBarrier = emu.cores.slice(0, numCores).every(s => s.state === "BARRIER_WAIT");
        if (this.barrierPulseElem) {
            if (allInBarrier || emu.barrierReleasePulse) this.barrierPulseElem.classList.add("active");
            else this.barrierPulseElem.classList.remove("active");
        }

        // FIFOs
        this.renderFifo(this.txFifoList, emu.txFifo);
        this.renderFifo(this.rxFifoList, emu.rxFifo);
        for (let i = 0; i < 3; i++) {
            if (this.cascadeFifoLists[i]) {
                this.renderFifo(this.cascadeFifoLists[i], emu.cascadeFifos[i]);
            }
        }

        // Pin Matrix
        const pinDriven = emu.uioOe;
        const pinLevels = emu.getEffectiveGpio();
        for (let i = 0; i < 8; i++) {
            const pinElem = this.pinElements[i];
            if (pinElem) {
                const isDriven = ((pinDriven >> i) & 1) === 1;
                const isHigh = ((pinLevels >> i) & 1) === 1;

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
