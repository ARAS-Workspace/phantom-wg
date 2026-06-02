# Sarı Gelin for Mac App Presentation — Production Configuration

Derived asset from "Sarı Gelin" (Azerbaijani: *Sarı Gəlin*), a traditional
folk song of the southern Caucasus / eastern Anatolia, written in the Bayati
makam. Solo-piano arrangement sourced from MuseScore (see `README.md`).
Edited for Mac App Presentation tutorial timing (~1:12 duration at 160 BPM).

## Routing Topology

```
Track 1 (up)   ─┐
Track 2 (down) ─┴─► Bus 1 ─► Piano Bus ─┬─► Stereo Out ─► Master
                          (no inserts)  │  (Mastering Assistant)
                                        │
                        post-fader send │
                            −12 dB      │
                               │        │
                               ▼        │
                        Bus 2 ─► Reverb ┘
                                (ChromaVerb)
```

Two Software Instrument tracks (Splice INSTRUMENT) carry only pan and
volume. All tonal, dynamic, and spatial processing is consolidated:
reverb on a dedicated aux, final stage on the stereo output. The Piano
Bus collects both tracks and currently carries no inserts.

## Source MIDI Preparation

Unlike a clean engraver export, the MuseScore MIDI's melody track shipped
with embedded channel controllers that overrode the manual channel-strip
mix on playback (and during Mastering Assistant analysis). These were
stripped after import so the track-level pan/volume values below hold:

| Controller | Number | Action  | Reason                                    |
|------------|--------|---------|-------------------------------------------|
| Volume     | CC7    | Removed | Was resetting fader to ~+1.8 dB           |
| Pan        | CC10   | Removed | Was recentering pan to 0                  |
| Reverb     | CC91   | Removed | Spatial handled by Bus 2 (ChromaVerb)     |
| Chorus     | CC93   | Removed | Not used                                  |
| Reset All  | CC121  | Removed | Reset controllers mid-region              |

The lower track carried no controller data and needed no cleanup.

## Source Layer — Splice INSTRUMENT

Plugin: Splice INSTRUMENT (AU)
Preset: Intimate Grand Piano — Dynamic

Hammers and Tightness are voiced per register; all other parameters are
identical across both tracks.

| Parameter | Track 1 (up) | Track 2 (down) |
|-----------|--------------|----------------|
| Preset    | Dynamic      | Dynamic        |
| Reverb    | 20%          | 20%            |
| Tightness | 20%          | 35%            |
| Hammers   | 20%          | 30%            |
| Pedal     | 50%          | 50%            |
| Dynamics  | 65%          | 65%            |

## Track-Level Mixing

Tracks carry pan and volume only — no Channel EQ, no Compressor, no
insert effects. Both route to Bus 1 (Piano Bus).

| Parameter | Track 1 (up) | Track 2 (down) |
|-----------|--------------|----------------|
| Pan       | −15 (left)   | +15 (right)    |
| Volume    | −6 dB        | −8 dB          |
| Output    | Bus 1        | Bus 1          |

## Piano Bus (Bus 1)

Summing bus for both instrument tracks. No inserts — an A/B check
confirmed bus compression was not required for this material (the
Dynamic preset plus the source MIDI velocity range is already
controlled enough for a music-bed role).

| Parameter             | Value               |
|-----------------------|---------------------|
| Input                 | Bus 1 (Track 1, 2)  |
| Inserts               | None                |
| Send → Bus 2 (Reverb) | −12 dB, post-fader  |
| Output                | Stereo Out          |

## Reverb Aux (Bus 2)

Single ChromaVerb instance, fed by the post-fader send from the Piano
Bus. Fully wet — the dry signal reaches Stereo Out via the Piano Bus.
The −12 dB send level sets the wet/dry ratio (25% linear ≈ −12 dB);
post-fader routing keeps that ratio constant under volume changes.

Preset: Chamber

| Parameter | Value  |
|-----------|--------|
| Attack    | 0%     |
| Size      | 50%    |
| Density   | 85%    |
| Decay     | 1.00 s |
| Distance  | 20%    |
| Pre-delay | 12 ms  |
| Dry       | 0%     |
| Wet       | 100%   |

Aux output: Stereo Out.

## Master Bus — Stereo Out

Single plugin: Mastering Assistant (analyzed). Auto EQ is pulled back
from the analyzed default of 100% to 25% — the analyzed curve lifted the
low end (~50–100 Hz) and the upper presence band (~5–10 kHz); at full
strength this over-shaped the intimate solo-piano voicing, so 25%
applies gentle polish only.

| Parameter             | Value           |
|-----------------------|-----------------|
| Character             | Transparent     |
| Auto EQ               | 25%             |
| Loudness Compensation | ON              |
| True Peak ceiling     | −1.0 dBTP       |
| Measured loudness     | ~−12.9 LUFS     |
| LU Range              | 2.9 LU          |
| Correlation           | 0.0 (mono-safe) |

Output: Master.

## Project Settings

| Parameter      | Value                       |
|----------------|-----------------------------|
| Tempo          | 160 BPM                     |
| Time Signature | 3/4                         |
| Length         | 64 bars (~192 beats)        |
| Total Duration | ~1:12                       |
| Output File    | `output/Sarı Gelin.wav`     |
| Output Format  | WAV, 48 kHz, 24-bit, stereo |