/**
 * =============================================================================
 * File        : chiptune_player.c
 * Description : Omni-C 1-Bit Delta-Sigma Audio DAC & Chiptune Polyphonic Sequencer.
 * License     : MIT License
 * =============================================================================
 */

#include "audio.h"

// Note divisors @ 50 MHz clock
#define NOTE_C4_HI 0x1D
#define NOTE_C4_LO 0xCD  // 261.63 Hz (Divisor = 7635)
#define NOTE_E4_HI 0x17
#define NOTE_E4_LO 0xB7  // 329.63 Hz (Divisor = 6071)
#define NOTE_G4_HI 0x13
#define NOTE_G4_LO 0xF7  // 392.00 Hz (Divisor = 5111)
#define NOTE_C5_HI 0x0E
#define NOTE_C5_LO 0xE6  // 523.25 Hz (Divisor = 3814)

void main() {
    // Set Master Volume (Level 12 / 15)
    audio_set_volume(12);

    while (1) {
        // Play C-Major Arpeggio (C4 -> E4 -> G4 -> C5)
        audio_play_tone(NOTE_C4_HI, NOTE_C4_LO);
        delay_cycles(25000); // Note duration

        audio_play_tone(NOTE_E4_HI, NOTE_E4_LO);
        delay_cycles(25000);

        audio_play_tone(NOTE_G4_HI, NOTE_G4_LO);
        delay_cycles(25000);

        audio_play_tone(NOTE_C5_HI, NOTE_C5_LO);
        delay_cycles(50000);

        // Silence between phrases
        audio_silence();
        delay_cycles(25000);
    }
}
