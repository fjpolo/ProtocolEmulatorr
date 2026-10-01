/**
 * =============================================================================
 * File        : audio.h
 * Description : Omni-C 1-Bit Delta-Sigma Audio DAC & Chiptune APU Driver.
 * License     : MIT License
 * =============================================================================
 */

#ifndef OMNIBUS_AUDIO_H
#define OMNIBUS_AUDIO_H

#include "omnibus.h"

// Set Chiptune Master Volume (0..15)
#define audio_set_volume(vol) assist_audio_vol(vol)

// Play Frequency Tone (note_hi, note_lo = 16-bit clock divisor)
#define audio_play_tone(note_hi, note_lo) assist_audio_play(note_hi, note_lo)

// Stop Audio Output
#define audio_silence() assist_audio_stop()


#endif // OMNIBUS_AUDIO_H
