# Rondo Alla Turca — Production Configuration

Derived asset from Mozart Piano Sonata No. 11 in A major, K. 331,
III. Alla Turca. Edited for Mac App Presentation tutorial timing
(~2:08 duration).

## Routing Topology

```
Track 1 (L) ─┐
Track 2 (R) ─┴─► Bus 1 ─► Piano Bus ─┬─► Stereo Out ─► Master
                         (Chroma)    │  (Mastering Assistant)
                                     │
                     post-fader send │
                            │        │
                            ▼        │
                     Bus 2 ─► Reverb ┘
                             (ChromaVerb)
```

Two Software Instrument tracks (Studio Grand) carry only pan and
volume. The Piano Bus collects both tracks; tonal coloration lives
on Bus 1 (Chroma), space lives on a dedicated reverb aux, final stage
on the stereo output.

## Source Layer — Studio Grand

Plugin: Studio Grand (Logic Pro built-in piano sampler)
Preset: Default voicing

Both tracks share identical instrument settings; per-track variation
lives on the channel strip (pan, volume) rather than inside the
sampler. Studio Grand's default tonal balance is left untouched —
Chroma on the Piano Bus shapes character, and the Mastering Assistant
on Stereo Out provides the final polish.

## Track-Level Mixing

Tracks carry pan and volume only — no Channel EQ, no Compressor, no
insert effects. Both route to Bus 1 (Piano Bus).

| Parameter | Track 1 (L) | Track 2 (R) |
|-----------|-------------|-------------|
| Pan       | −15 (left)  | +15 (right) |
| Volume    | −8.7 dB     | −6.3 dB     |
| Output    | Bus 1       | Bus 1       |

## Piano Bus (Bus 1)

Summing bus for both instrument tracks. A single Chroma instance
provides tonal coloration before the signal hits the stereo output.

| Parameter             | Value               |
|-----------------------|---------------------|
| Input                 | Bus 1 (Track 1, 2)  |
| Inserts               | Chroma              |
| Send → Bus 2 (Reverb) | −12 dB, post-fader  |
| Fader                 | −15.6 dB            |
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
from the analyzed default of 100% to 25% — gentle polish only.

| Parameter             | Value         |
|-----------------------|---------------|
| Character             | Transparent   |
| Auto EQ               | 25%           |
| Loudness Compensation | ON            |
| True Peak ceiling     | −1.0 dBTP     |
| Measured loudness     | ~−12.7 LUFS   |
| Fader                 | −1.1 dB       |

Output: Master.

## Project Settings

| Parameter      | Value                       |
|----------------|-----------------------------|
| Tempo          | 120 BPM                     |
| Time Signature | 2/4                         |
| Total Duration | ~2:08                       |
| Output Format  | WAV, 48 kHz, 24-bit, stereo |
