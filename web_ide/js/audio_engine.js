// =============================================================================
// File        : audio_engine.js
// Module      : OmniBus Web Audio API Synthesizer Bridge
// Description : Real-time audio engine converting simulated 1-bit Delta-Sigma
//               PDM bits and Chiptune square-wave tones into audible sound.
// License     : MIT License
// =============================================================================

export class OmniBusAudioEngine {
    constructor() {
        this.ctx = null;
        this.gainNode = null;
        this.filterNode = null;
        this.workletNode = null;
        this.isMuted = false;
        this.volume = 0.2;
    }

    init() {
        if (this.ctx) return;
        try {
            const AudioContext = window.AudioContext || window.webkitAudioContext;
            this.ctx = new AudioContext({ sampleRate: 44100 });

            // Low-pass filter simulating external RC reconstruction filter
            this.filterNode = this.ctx.createBiquadFilter();
            this.filterNode.type = "lowpass";
            this.filterNode.frequency.value = 12000;

            this.gainNode = this.ctx.createGain();
            this.gainNode.gain.value = this.volume;

            this.filterNode.connect(this.gainNode);
            this.gainNode.connect(this.ctx.destination);
        } catch (e) {
            console.warn("Web Audio API not supported or blocked by browser policy:", e);
        }
    }

    playTone(frequencyHz, durationMs = 100) {
        this.init();
        if (!this.ctx || this.isMuted) return;

        if (this.ctx.state === "suspended") {
            this.ctx.resume();
        }

        const osc = this.ctx.createOscillator();
        osc.type = "square";
        osc.frequency.value = frequencyHz;

        const oscGain = this.ctx.createGain();
        oscGain.gain.setValueAtTime(this.volume, this.ctx.currentTime);
        oscGain.gain.exponentialRampToValueAtTime(0.001, this.ctx.currentTime + (durationMs / 1000));

        osc.connect(oscGain);
        oscGain.connect(this.filterNode);

        osc.start();
        osc.stop(this.ctx.currentTime + (durationMs / 1000));
    }

    setMute(mute) {
        this.isMuted = mute;
        if (this.gainNode) {
            this.gainNode.gain.value = mute ? 0 : this.volume;
        }
    }

    setVolume(vol) {
        this.volume = Math.max(0, Math.min(1, vol));
        if (this.gainNode && !this.isMuted) {
            this.gainNode.gain.value = this.volume;
        }
    }
}
