# Sarı Gelin Guitar — Production Configuration

Derived asset from "Sarı Gelin" (Azerbaijani / Anatolian traditional folk
song, Bayati makam), in a **fingerstyle solo guitar** arrangement sourced
from MuseScore (see Source below).

## Source (Arrangement)

- **Source**: MuseScore (community upload)
- **Title**: Sarı Gelin - Fingerstyle
- **Arranger**: Musa Çetiner
- **Instrumentation**: Guitar (Solo, fingerstyle)
- **URL**: https://musescore.com/user/1185841/scores/5332419
- **License**: Underlying folk melody is traditional / public domain. The
  specific MuseScore arrangement is a community upload — verify the
  uploader's license terms on MuseScore before redistribution.

> Note: this is a **different arrangement** from the piano (Abdullayev) and
> violin (rahmani) versions — different source, meter, and tempo.

## Source MIDI Preparation

If driven from the MuseScore MIDI export, strip the embedded channel
controllers after import (CC7 volume, CC10 pan, CC91 reverb, CC93 chorus,
CC121 reset-all) — as with the prior versions — so the channel-strip mix
holds and Mastering Assistant analysis doesn't reset the fader/pan.

## Routing Topology

```
Guitar (Brady Thumb Notes) ─► Bus 1 ─► Guitar Bus ─┬─► Stereo Out ─► Master
                                      (no inserts)  │  (Mastering Assistant)
                                                    │
                                    post-fader send │
                                        −10 dB      │
                                          │         │
                                          ▼         │
                                   Bus 2 ─► Reverb ─┘
                                          (ChromaVerb)
```

A single instrument track carries pan and volume only. All spatial
processing is consolidated on a dedicated reverb aux; final stage on the
stereo output. The Guitar Bus collects the track and carries no inserts.

## Source Layer — Splice INSTRUMENT

Plugin: Splice INSTRUMENT (AU)
Pack: Unplugged (Spitfire Audio / LABS)
Preset: Brady Thumb Notes

Thumb-plucked articulation chosen for a warm, rounded attack suited to a
folk solo. Internal reverb is fully off so all space comes from the
ChromaVerb aux (single, controllable reverb — no stacked ambiences).

| Parameter       | Value                                   |
|-----------------|-----------------------------------------|
| Preset          | Brady Thumb Notes                       |
| Dynamics        | 75 (bright/defined attack — clean lead) |
| Internal Reverb | 0 (off — space via Bus 2)               |
| Attack          | 0 (immediate pluck transient)           |
| Release         | 80 (note separation; avoids smearing)   |
| Start Point     | 0 (full attack)                         |
| Chorus          | 0                                       |
| Delay           | 0                                       |

Dynamics at 75 gives the sharper transient that reads through the reverb
(definition over intimacy); consider automating it (mod wheel / CC1, e.g.
~65 in soft phrases, ~80 on peaks) for expressive swells.

## Track-Level Mixing

Track carries pan and volume only — no Channel EQ, no Compressor, no insert
effects. Routes to Bus 1 (Guitar Bus).

| Parameter | Value        |
|-----------|--------------|
| Pan       | Center (0)   |
| Volume    | −6 dB        |
| Output    | Bus 1        |

(Center pan — single solo lead, unlike the two-handed L/R piano spread.)

## Guitar Bus (Bus 1)

| Parameter             | Value               |
|-----------------------|---------------------|
| Input                 | Bus 1 (Guitar)      |
| Inserts               | None                |
| Send → Bus 2 (Reverb) | −10 dB, post-fader  |
| Output                | Stereo Out          |

## Reverb Aux (Bus 2)

Single ChromaVerb instance, fed by the post-fader send from the Guitar Bus.
Fully wet — the dry signal reaches Stereo Out via the Guitar Bus.

Preset: Chamber

| Parameter | Value  |
|-----------|--------|
| Attack    | 0%     |
| Size      | 50%    |
| Density   | 85%    |
| Decay     | 1.00 s |
| Distance  | 12%    |
| Predelay  | 25 ms  |
| Dry       | 0%     |
| Wet       | 100%   |

**Damping EQ (low-end tail control):** a single damping band tames the
guitar's body boom so it doesn't linger in the tail.

| Parameter | Value                                          |
|-----------|------------------------------------------------|
| Frequency | 210 Hz                                         |
| Ratio     | ~0.40 (low band decays ~0.4 s vs 1.0 s global) |
| Q         | 0.75 (wide enough to cover ~100–400 Hz)        |

Ear-tuned: ease Ratio up toward 0.5–0.6 if the tail thins out; push down
toward 0.4 if still boomy. Mids/highs left near 100%.

Predelay 25 ms keeps the dry pluck attack distinct from the wet tail
(presence for a lead). Distance 12% keeps the guitar forward/close.

Aux output: Stereo Out.

## Master Bus — Stereo Out

Single plugin: Mastering Assistant (analyzed on a representative section).
Auto EQ held at 25% for gentle polish — at full strength the curve
over-shaped the intimate fingerstyle voicing.

| Parameter             | Value                       |
|-----------------------|-----------------------------|
| Character             | Transparent                 |
| Auto EQ               | 25%                         |
| Loudness Compensation | ON                          |
| True Peak ceiling     | −1.0 dBTP                   |
| Measured loudness     | ~−12.8 LUFS                 |
| LU Range              | 1.8 LU                      |
| Correlation           | 0.0 (verify mono fold-down) |

Output: Master.

Loudness lands at ~−12.8 LUFS, consistent with the piano (~−12.9) and
violin versions — keeps all tutorial music beds at a matched level.

## Project Settings

| Parameter      | Value                                       |
|----------------|---------------------------------------------|
| Tempo          | 126 BPM                                     |
| Time Signature | 10/8 (per source score — verify in project) |
| Total Duration | ~2:36 (confirm final render)                |
| Output File    | `output/Sarı Gelin Guitar.wav`              |
| Output Format  | WAV, 48 kHz, 24-bit, stereo                 |