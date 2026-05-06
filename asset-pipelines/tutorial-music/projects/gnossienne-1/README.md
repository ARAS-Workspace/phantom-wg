# Satie — Gnossienne No. 1

- **Composition**: Gnossienne No. 1, from the Gnossiennes
- **Composer**: Erik Satie (1866–1925)
- **Composed**: c. 1889 (exact year debated in scholarship)
- **First Published**: 1893 (Paris)
- **Tempo Marking**: Lent
- **Copyright Status**: Public domain (composer died more than 70 years
  ago in all relevant jurisdictions)

## Source MIDI

- **Source**: Mutopia Project, piece ID 2035
- **URL**: https://www.mutopiaproject.org/cgibin/piece-info.cgi?id=2035
- **Source Edition**: EDITIONS SALABERT, 22 Rue Chauchat, Paris, 1913
- **Typesetter**: Knute Snortum
- **License**: Creative Commons Attribution-ShareAlike 4.0 (CC BY-SA 4.0)
- **Mutopia Last Updated**: 2015/Jul/23

The Mutopia URL, typesetter credit, and license badge are recorded in
the `sources/SOURCE` file. The MIDI file and sheet music PDF are stored
directly in `sources/`.

## Production

- **DAW**: Logic Pro
- **Instrument Plugin**: Splice INSTRUMENT (AU plugin)
- **Treble Preset**: Intimate Grand Piano - Direct
- **Bass Preset**: Intimate Grand Piano - Direct
- **Tempo**: 73 BPM
- **Time Signature**: 4/4
- **Volume — Treble**: −3 dB
- **Volume — Bass**: −7 dB
- **Pan — Treble**: −10 (left)
- **Pan — Bass**: +10 (right)
- **Track Audio Chain**: Channel EQ → Compressor (Studio VCA preset) →
  ChromaVerb (Concert Hall preset)
- **Master Bus**: Logic Pro Mastering Assistant (Transparent character,
  Auto EQ 100%, Loudness Compensation enabled, reanalyzed after
  track-level mixing)

## Output

- **File**: `output/Satie - Gnossienne No. 1.wav`
- **Format**: WAV, 48 kHz, 24-bit, stereo

## License Disclosure

For details on third-party tools and licensing terms (Splice INSTRUMENT,
Mutopia Project), see [`../DISCLOSURE.md`](../DISCLOSURE.md).

A Turkish-language version of the disclosure is available at
[`../DISCLOSURE_TR.md`](../DISCLOSURE_TR.md).

The Mutopia Project entry for this piece is licensed under Creative
Commons Attribution-ShareAlike 4.0 (CC BY-SA 4.0). This license applies
to the LilyPond typesetting and MIDI rendering by Knute Snortum. The
underlying composition by Satie is in the public domain.

## Files

```
gnossienne-1/
├── README.md                       # This file
├── Project.logicx/                 # Logic Pro project (gitignored: Media/, Bounces/)
├── sources/
│   ├── SOURCE                      # Mutopia URL and citation details
│   ├── no_1.mid                    # LilyPond-generated MIDI from Mutopia
│   └── no_1-a4.pdf                 # Sheet music PDF (A4 paper)
├── output/
│   └── Satie - Gnossienne No. 1.wav
└── .gitignore
```

## Notes

- MIDI source `sources/no_1.mid` imported into Logic Pro as two tracks:
  `upper` (right hand / melody) and `lower` (left hand / accompaniment).
- Both tracks use Intimate Grand Piano - Direct preset (single preset
  across both voices).
- Volume hierarchy: 4 dB (treble louder than bass).
- Stereo width: ±10 (audience perspective — treble panned left, bass
  panned right).
- Tempo set to 73 BPM (Lent).
- MIDI region quantize: Off.
- Compressor preset: Studio VCA.
- ChromaVerb preset: Concert Hall.
- Mastering Assistant character: Transparent.
- Mastering Assistant Auto EQ: 100%.
- Mastering Assistant Loudness Compensation: enabled.
- Mastering Assistant reanalyzed after final track-level adjustments.
- Performance practice for Gnossienne No. 1 admits a wide tempo range
  under the "Lent" marking. Reference recordings and published editions
  range from approximately 47 BPM (very slow Largo interpretations) to
  76 BPM (more flowing readings). The 73 BPM tempo used in this
  recording falls within this established range.
- The Mutopia entry lists "Date of composition: 1890". Wikipedia and
  other scholarly sources generally date the composition to circa 1889,
  with first publication in 1893 in Paris, as documented by the
  Wikipedia article on Gnossiennes.
  (https://en.wikipedia.org/wiki/Gnossiennes)
- The Gnossiennes are written in free time (lacking time signatures or
  bar divisions in the original score). The Mutopia LilyPond typesetting
  uses a 4/4 time signature for notational practicality; this is a
  typesetting convention rather than an authorial mark.
- The PDF in `sources/no_1-a4.pdf` is included as reference only and was
  not used in production. The MIDI file was the sole input for the
  rendered audio.