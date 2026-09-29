// =============================================================================
// File        : webserial.js
// Module      : OmniBus WebSerial Hardware In-System Programmer
// Description : Connects directly from the browser via WebSerial API to
//               OmniBootloader on physical Tang FPGA boards (Console 60K,
//               Nano 20K, Nano 9K) or FTDI adapters to program microcode in silicon.
// License     : MIT License
// =============================================================================

export class OmniBusWebSerial {
    constructor() {
        this.port = null;
        this.reader = null;
        this.writer = null;
        this.isConnected = false;
        this.baudRate = 115200;
        this.logCallback = console.log;
    }

    setLogCallback(cb) {
        this.logCallback = cb;
    }

    log(msg) {
        if (this.logCallback) this.logCallback(msg);
    }

    isSupported() {
        return "serial" in navigator;
    }

    async connect(baudRate = 115200) {
        if (!this.isSupported()) {
            throw new Error("WebSerial API is not supported in this browser. Use Google Chrome or Microsoft Edge.");
        }

        try {
            this.port = await navigator.serial.requestPort();
            await this.port.open({ baudRate: baudRate });
            this.writer = this.port.writable.getWriter();
            this.reader = this.port.readable.getReader();
            this.isConnected = true;
            this.log(`[WebSerial] Connected to serial port at ${baudRate} baud.`);
            return true;
        } catch (err) {
            this.log(`[WebSerial] Connection failed: ${err.message}`);
            this.isConnected = false;
            throw err;
        }
    }

    async disconnect() {
        if (this.reader) {
            await this.reader.cancel();
            this.reader.releaseLock();
            this.reader = null;
        }
        if (this.writer) {
            this.writer.releaseLock();
            this.writer = null;
        }
        if (this.port) {
            await this.port.close();
            this.port = null;
        }
        this.isConnected = false;
        this.log("[WebSerial] Disconnected.");
    }

    async programMicrocode(machineCodeWords) {
        if (!this.isConnected || !this.writer) {
            throw new Error("Not connected to serial port.");
        }

        const count = machineCodeWords.length;
        this.log(`[WebSerial] Flashing ${count} microcode words to OmniBootloader...`);

        // Send 'W' Write command: 'W' (0x57) + Addr(7b) + Count(7b) + Words(MSB, LSB)
        const header = new Uint8Array([0x57, 0x00, count & 0x7F]);
        await this.writer.write(header);

        const dataBytes = new Uint8Array(count * 2);
        for (let i = 0; i < count; i++) {
            const word = machineCodeWords[i];
            dataBytes[i * 2] = (word >> 8) & 0xFF; // MSB
            dataBytes[i * 2 + 1] = word & 0xFF;     // LSB
        }

        await this.writer.write(dataBytes);
        this.log("[WebSerial] Upload complete. Sending 'R' (Run) trigger...");

        // Send 'R' command to trigger execution
        const runCmd = new Uint8Array([0x52]);
        await this.writer.write(runCmd);

        this.log("[WebSerial] Microcode executing in real silicon!");
        return true;
    }
}
