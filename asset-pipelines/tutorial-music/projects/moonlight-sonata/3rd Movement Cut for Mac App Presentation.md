# 3rd Movement Cut for Mac App Presentation — Production Configuration

Derived asset from Beethoven Piano Sonata No. 14 "Moonlight" Op. 27 No. 2,
III. Presto agitato. Edited for Mac App Presentation tutorial timing
(~1:25 duration). Source MIDI: Mutopia Project piece ID 276
(`moonlight3.mid`).

## Source Layer — Splice INSTRUMENT

Plugin: Splice INSTRUMENT (AU)
Preset: Intimate Grand Piano — **Dynamic**

| Parameter | Track 1 (up) | Track 2 (down) | Track 3 (transition) |
|-----------|--------------|----------------|----------------------|
| Preset    | Dynamic      | Dynamic        | Dynamic              |
| Reverb    | 20%          | 20%            | 20%                  |
| Tightness | 20%          | 35%            | 35%                  |
| Hammers   | 50%          | 50%            | 50%                  |
| Pedal     | 50%          | 50%            | 50%                  |
| Dynamics  | 65%          | 65%            | 65%                  |

## Track-Level Mixing

| Parameter | Track 1 (up) | Track 2 (down) | Track 3 (transition) |
|-----------|--------------|----------------|----------------------|
| Pan       | −15 (left)   | +15 (right)    | −15 (left)           |
| Volume    | −5 dB        | −7 dB          | −5 dB                |

## Track-Level Channel EQ

| Band                | Track 1 (up)             | Track 2 (down)           | Track 3 (transition)     |
|---------------------|--------------------------|--------------------------|--------------------------|
| Band 1 (HP)         | Deactive                 | 60 Hz, 18 dB/Oct, Q 0.71 | 60 Hz, 18 dB/Oct, Q 0.71 |
| Band 4 (parametric) | Deactive                 | 250 Hz, −1.5 dB, Q 1.00  | 250 Hz, −1.5 dB, Q 1.00  |
| Band 6 (parametric) | 4000 Hz, −2.5 dB, Q 1.20 | Deactive                 | Deactive                 |
| Other bands         | Deactive                 | Deactive                 | Deactive                 |

## Track-Level Compressor

Preset: Studio VCA (base preset, custom values)

| Parameter | Track 1 (up) | Track 2 (down) | Track 3 (transition) |
|-----------|--------------|----------------|----------------------|
| Ratio     | 2.5:1        | 2.9:1          | 2.9:1                |
| Threshold | −5.0 dB      | −4.0 dB        | −4.0 dB              |
| Attack    | 30 ms        | 10 ms          | 10 ms                |

## Track-Level ChromaVerb

Preset: Chamber (applied identically to all three tracks)

| Parameter | Value  |
|-----------|--------|
| Attack    | 0%     |
| Size      | 50%    |
| Density   | 85%    |
| Decay     | 1.00 s |
| Distance  | 20%    |
| Pre-delay | 12 ms  |
| Dry       | 100%   |
| Wet       | 25%    |

## Master Bus Plugin Chain

Signal flow: DeEsser 2 → Multipressor → Mastering Assistant → Limiter (Legacy)

### DeEsser 2

| Parameter     | Value    |
|---------------|----------|
| Frequency     | 4500 Hz  |
| Threshold     | −12 dB   |
| Max Reduction | 4 dB     |
| Mode          | Relative |
| Range         | Split    |
| Filter        | Type 2   |

### Multipressor (4-Band Multiband Compressor)

Active band: Band 3 only (2500-6600 Hz). Bands 1, 2, 4 disabled.

**Band 3 Compressor:**

| Parameter       | Value  |
|-----------------|--------|
| Compr Threshold | −18 dB |
| Compr Ratio     | 3      |
| Peak/RMS        | 4 ms   |
| Attack          | 2 ms   |
| Release         | 82 ms  |
| Gain Make-up    | +1 dB  |

**Band 3 Expander (inactive, pass-through):**

| Parameter       | Value  |
|-----------------|--------|
| Expnd Threshold | −60 dB |
| Expnd Ratio     | 1      |
| Expnd Reduction | 0 dB   |

**Output section:**

| Parameter | Value |
|-----------|-------|
| Auto Gain | OFF   |
| Lookahead | 5 ms  |
| Out       | 0 dB  |

### Mastering Assistant

| Parameter             | Value       |
|-----------------------|-------------|
| Character             | Transparent |
| Custom EQ             | 100%        |
| Loudness              | +0.10 dB    |
| Loudness Compensation | **OFF**     |
| Excite                | OFF         |

### Limiter (Legacy Mode)

| Parameter    | Value  |
|--------------|--------|
| Mode         | Legacy |
| Soft Knee    | ON     |
| Gain         | 0 dB   |
| Release      | 49 ms  |
| Output Level | −1 dB  |
| Lookahead    | 10 ms  |

## Project Settings

| Parameter      | Value                       |
|----------------|-----------------------------|
| Tempo          | 160 BPM                     |
| Time Signature | 2/2                         |
| Total Duration | ~1:25                       |
| Output Format  | WAV, 48 kHz, 24-bit, stereo |