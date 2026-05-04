# Satie — Gymnopédie No. 1

- **Composition**: Gymnopédie No. 1 (1ère Gymnopédie), from Trois
  Gymnopédies
- **Composer**: Erik Satie (1866–1925)
- **Composed**: 1888
- **First Published**: 1888 (in the magazine *La Musique des familles*)
- **Tempo Marking**: Lent et douloureux ("slow and painful")
- **Copyright Status**: Public domain (composer died more than 70 years
  ago in all relevant jurisdictions)

## Source MIDI

- **Source**: Mutopia Project, piece ID 37
- **URL**: https://www.mutopiaproject.org/cgibin/piece-info.cgi?id=37
- **Source Edition**: Dover Edition
- **Typesetter**: Evin Robertson
- **License**: Public Domain (CC: No rights reserved)
- **Mutopia Last Updated**: 2014/Dec/14

The Mutopia URL, typesetter credit, and license badge are recorded in
the `sources/SOURCE` file. The MIDI file and sheet music PDF are stored
directly in `sources/`.

## Production

- **DAW**: Logic Pro
- **Instrument Plugin**: Splice INSTRUMENT (AU plugin)
- **Treble Preset**: Intimate Grand Piano - Direct
- **Bass Preset**: Intimate Grand Piano - Direct
- **Tempo**: 76 BPM
- **Time Signature**: 3/4
- **Volume — Treble**: −4 dB
- **Volume — Bass**: −8 dB
- **Pan — Treble**: −10 (left)
- **Pan — Bass**: +10 (right)
- **Track Audio Chain**: Channel EQ → Compressor (Studio VCA preset) →
  ChromaVerb (Concert Hall preset)
- **Master Bus**: Logic Pro Mastering Assistant (Transparent character,
  Auto EQ 100%, Loudness Compensation enabled, reanalyzed after
  track-level mixing)

## Output

- **File**: `output/Satie - Gymnopedie.wav`
- **Format**: WAV, 48 kHz, 24-bit, stereo

## License Disclosure

For details on third-party tools and licensing terms (Splice INSTRUMENT,
Mutopia Project), see [`../DISCLOSURE.md`](../DISCLOSURE.md).

A Turkish-language version of the disclosure is available at
[`../DISCLOSURE_TR.md`](../DISCLOSURE_TR.md).

The Mutopia Project entry for this piece is dedicated to the public
domain by the typesetter (CC: No rights reserved). The underlying
composition by Satie is also in the public domain.

## Files

```
gymnopedie/
├── README.md                       # This file
├── Project.logicx/                 # Logic Pro project (gitignored: Media/, Bounces/)
├── sources/
│   ├── SOURCE                      # Mutopia URL and citation details
│   ├── gymnopedie_1.mid            # LilyPond-generated MIDI from Mutopia
│   └── gymnopedie_1-a4.pdf         # Sheet music PDF (A4 paper)
├── output/
│   └── Satie - Gymnopedie.wav
└── .gitignore
```

## Notes

- MIDI source `sources/gymnopedie_1.mid` imported into Logic Pro as
  two tracks: `treble` (right hand / melody) and `bass` (left hand /
  sustained chord ostinato).
- Both tracks use Intimate Grand Piano - Direct preset (single preset
  across both voices).
- Volume hierarchy: 4 dB (treble louder than bass).
- Stereo width: ±10 (audience perspective — treble panned left, bass
  panned right).
- Tempo set to 76 BPM (Lent et douloureux).
- MIDI region quantize: Off.
- Compressor preset: Studio VCA.
- ChromaVerb preset: Concert Hall.
- Mastering Assistant character: Transparent.
- Mastering Assistant Auto EQ: 100%.
- Mastering Assistant Loudness Compensation: enabled.
- Mastering Assistant reanalyzed after final track-level adjustments.
- Performance practice for Gymnopédie No. 1 admits a wide tempo range
  under the "Lent et douloureux" marking. Published editions and
  reference recordings range from approximately 40 BPM (Reinbert de
  Leeuw's notably slow interpretation) to 100 BPM (some published
  performance editions, e.g., 8notes). The 76 BPM tempo used in this
  recording falls within this established range.
- The PDF in `sources/gymnopedie_1-a4.pdf` is included as reference
  only and was not used in production. The MIDI file was the sole
  input for the rendered audio.