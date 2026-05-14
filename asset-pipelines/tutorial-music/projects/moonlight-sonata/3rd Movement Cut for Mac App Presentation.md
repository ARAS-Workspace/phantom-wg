# 3rd Movement Cut for Mac App Presentation — Production Configuration

Derived asset from Beethoven Piano Sonata No. 14 "Moonlight" Op. 27 No. 2,
III. Presto agitato. Edited for Mac App Presentation tutorial timing
(~1:25 duration). Source MIDI: Mutopia Project piece ID 276
(`moonlight3.mid`).

## Routing Topology

```
Track 1 (up)         ─┐
Track 2 (down)        ├─► Bus 1 ─► Piano Bus ─┬─► Stereo Out ─► Master
Track 3 (transition) ─┘         (no inserts)  │  (Mastering Assistant)
                                              │
                          post-fader send     │
                              −12 dB          │
                                 │            │
                                 ▼            │
                          Bus 2 ─► Reverb ────┘
                                  (ChromaVerb)
```

Three Software Instrument tracks (Splice INSTRUMENT) carry only pan and
volume. All tonal, dynamic, and spatial processing is consolidated:
reverb on a dedicated aux, final stage on the stereo output. The Piano
Bus collects the three tracks and currently carries no inserts.

## Source Layer — Splice INSTRUMENT

Plugin: Splice INSTRUMENT (AU)
Preset: Intimate Grand Piano — Dynamic

Hammers and Tightness are voiced per register; all other parameters are
identical across the three tracks.

| Parameter | Track 1 (up) | Track 2 (down) | Track 3 (transition) |
|-----------|--------------|----------------|----------------------|
| Preset    | Dynamic      | Dynamic        | Dynamic              |
| Reverb    | 20%          | 20%            | 20%                  |
| Tightness | 20%          | 35%            | 35%                  |
| Hammers   | 20%          | 30%            | 30%                  |
| Pedal     | 50%          | 50%            | 50%                  |
| Dynamics  | 65%          | 65%            | 65%                  |

Track 3 (transition) is a short connecting passage and follows the
Track 2 (down) voicing.

## Track-Level Mixing

Tracks carry pan and volume only — no Channel EQ, no Compressor, no
insert effects. All three route to Bus 1 (Piano Bus).

| Parameter | Track 1 (up) | Track 2 (down) | Track 3 (transition) |
|-----------|--------------|----------------|----------------------|
| Pan       | −15 (left)   | +15 (right)    | −15 (left)           |
| Volume    | −6 dB        | −8 dB          | −6 dB                |
| Output    | Bus 1        | Bus 1          | Bus 1                |

## Piano Bus (Bus 1)

Summing bus for the three instrument tracks. No inserts — an A/B check
confirmed bus compression was not required for this material (the
Dynamic preset plus the source MIDI velocity range is already
controlled enough for a music-bed role).

| Parameter             | Value                  |
|-----------------------|------------------------|
| Input                 | Bus 1 (Track 1, 2, 3)  |
| Inserts               | None                   |
| Send → Bus 2 (Reverb) | −12 dB, post-fader     |
| Output                | Stereo Out             |

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
from the analyzed default of 100% to 25% — at full strength the curve
boosted the 2–5 kHz region and scooped the low mids, working against
the source-level voicing; 25% applies gentle polish only.

| Parameter             | Value        |
|-----------------------|--------------|
| Character             | Transparent  |
| Auto EQ               | 25%          |
| Loudness Compensation | ON           |
| True Peak ceiling     | −1.0 dBTP    |
| Measured loudness     | ~−13.7 LUFS  |

Output: Master.

## Project Settings

| Parameter      | Value                       |
|----------------|-----------------------------|
| Tempo          | 160 BPM                     |
| Time Signature | 2/2                         |
| Total Duration | ~1:25                       |
| Output Format  | WAV, 48 kHz, 24-bit, stereo |