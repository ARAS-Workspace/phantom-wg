# Mozart — Rondo Alla Turca (Piano Sonata No. 11, III. Allegretto)

- **Composition**: Piano Sonata No. 11 in A major, K. 331 / 300i, III.
  Alla Turca (commonly known as "Rondo Alla Turca" or "Turkish March")
- **Composer**: Wolfgang Amadeus Mozart (1756–1791)
- **Composed**: c. 1783 (exact year debated in scholarship)
- **First Published**: 1784 (Artaria, Vienna)
- **Copyright Status**: Public domain (composer died more than 70 years
  ago in all relevant jurisdictions)

## Source MIDI

- **Source**: Mutopia Project, piece ID 108
- **URL**: https://www.mutopiaproject.org/cgibin/piece-info.cgi?id=108
- **Source Edition**: IMSLP (specific edition not identified by Mutopia
  entry)
- **Typesetters**: Rune Zedeler and Chris Sawer
- **License**: Public Domain (CC: No rights reserved)
- **Mutopia Last Updated**: 2015/Aug/13

The Mutopia entry contains only the third movement (Rondo Alla Turca)
of K. 331; it is provided as a single MIDI file rather than as part of
the complete sonata. The Mutopia URL, typesetter credit, and license
badge are recorded in the `sources/SOURCE` file. The MIDI file and
sheet music PDF are stored directly in `sources/`.

## Production

- **DAW**: Logic Pro
- **Instrument Plugin**: Splice INSTRUMENT (AU plugin)
- **Preset**: Intimate Grand Piano - Direct
- **Tempo**: 120 BPM
- **Time Signature**: 2/4
- **Track Volume**: −1 dB
- **Track Pan**: Center
- **Track Audio Chain**: Channel EQ → Compressor → ChromaVerb
- **Master Bus**: Logic Pro Mastering Assistant (Transparent character,
  Auto EQ 100%, Loudness Compensation enabled, reanalyzed after
  track-level mixing)

## Output

- **File**: `output/Mozart - Rondo Alla Turca.wav`
- **Format**: WAV, 48 kHz, 24-bit, stereo

## License Disclosure

For details on third-party tools and licensing terms (Splice INSTRUMENT,
Mutopia Project), see [`../DISCLOSURE.md`](../DISCLOSURE.md).

A Turkish-language version of the disclosure is available at
[`../DISCLOSURE_TR.md`](../DISCLOSURE_TR.md).

The Mutopia Project entry for this piece is dedicated to the public
domain by the typesetters (CC: No rights reserved). The underlying
composition by Mozart is also in the public domain.

## Files

```
rondo-alla-turca/
├── README.md                              # This file
├── Project.logicx/                        # Logic Pro project (gitignored: Media/, Bounces/)
├── sources/
│   ├── SOURCE                             # Mutopia URL and citation details
│   ├── KV331_3_RondoAllaTurca.mid         # LilyPond-generated MIDI from Mutopia
│   └── KV331_3_RondoAllaTurca-a4.pdf      # Sheet music PDF (A4 paper)
├── output/
│   └── Mozart - Rondo Alla Turca.wav
└── .gitignore
```

## Notes

- MIDI source `sources/KV331_3_RondoAllaTurca.mid` imported into Logic
  Pro as a single track.
- Tempo set to 120 BPM (Allegretto).
- MIDI region quantize: Off.
- Mastering Assistant character: Transparent.
- Mastering Assistant Auto EQ: 100%.
- Mastering Assistant Loudness Compensation: enabled.
- Mastering Assistant reanalyzed after final track-level adjustments.
- The Mutopia entry lists "Date of composition: Not known". The
  composition is generally dated to circa 1783 in Mozart scholarship,
  with first publication by Artaria in 1784, as documented by the
  Wikipedia article on Piano Sonata No. 11 (Mozart), which states "The
  sonata was published by Artaria in 1784, alongside Nos. 10 and 12
  (K. 330 and K. 332)."
  (https://en.wikipedia.org/wiki/Piano_Sonata_No._11_(Mozart))
- The Mutopia "Source" field for this entry is listed as "IMSLP"; the
  specific IMSLP edition used as the basis for the LilyPond typesetting
  is not identified in the Mutopia entry.
- The PDF in `sources/KV331_3_RondoAllaTurca-a4.pdf` is included as
  reference only and was not used in production. The MIDI file was the
  sole input for the rendered audio.