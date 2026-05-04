# Beethoven — Moonlight Sonata, I. Adagio sostenuto

- **Composition**: Piano Sonata No. 14 in C-sharp minor, "Moonlight",
  Op. 27 No. 2, I. Adagio sostenuto
- **Composer**: Ludwig van Beethoven (1770–1827)
- **Composed**: 1801
- **First Published**: 1802 (Giovanni Cappi, Vienna)
- **Copyright Status**: Public domain (composer died more than 70 years
  ago in all relevant jurisdictions)

## Source MIDI

- **Source**: Mutopia Project, piece ID 276
- **URL**: https://www.mutopiaproject.org/cgibin/piece-info.cgi?id=276
- **Source Edition**: Berners, 1908 (edited by A. Winterberger)
- **Typesetter**: Stewart Holmes
- **License**: Creative Commons Attribution-ShareAlike 2.5 (CC BY-SA 2.5)
- **Mutopia Last Updated**: 2007/Feb/11

The Mutopia entry contains the complete sonata as three separate MIDI
files (one per movement). Only `moonlight1.mid` (I. Adagio sostenuto)
was used for this recording. The Mutopia URL, typesetter credit, and
license badge are recorded in the `sources/SOURCE` file. The MIDI files
are stored in `sources/moonlight-mids/` and the sheet music PDF in
`sources/`.

## Production

- **DAW**: Logic Pro
- **Instrument Plugin**: Splice INSTRUMENT (AU plugin)
- **Treble Preset**: Intimate Grand Piano - Direct
- **Bass Preset**: Intimate Grand Piano - Direct
- **Tempo**: 60 BPM
- **Time Signature**: 2/2 (alla breve)
- **Volume — Treble**: −3 dB
- **Volume — Bass**: −5 dB
- **Pan — Treble**: −20 (left)
- **Pan — Bass**: +20 (right)
- **Track Audio Chain**: Channel EQ → Compressor → ChromaVerb
- **Master Bus**: Logic Pro Mastering Assistant (Transparent character,
  Auto EQ 100%, Loudness Compensation enabled, reanalyzed after
  track-level mixing)

## Output

- **File**: `output/Beethoven - Moonlight Sonata.wav`
- **Format**: WAV, 48 kHz, 24-bit, stereo

## License Disclosure

For details on third-party tools and licensing terms (Splice INSTRUMENT,
Mutopia Project), see [`../DISCLOSURE.md`](../DISCLOSURE.md).

A Turkish-language version of the disclosure is available at
[`../DISCLOSURE_TR.md`](../DISCLOSURE_TR.md).

The Mutopia Project entry for this piece is licensed under Creative
Commons Attribution-ShareAlike 2.5 (CC BY-SA 2.5). This license applies
to the LilyPond typesetting and MIDI rendering by Stewart Holmes. The
underlying composition by Beethoven is in the public domain.

## Files

```
moonlight-sonata/
├── README.md                       # This file
├── Project.logicx/                 # Logic Pro project (gitignored: Media/, Bounces/)
├── sources/
│   ├── SOURCE                      # Mutopia URL and citation details
│   ├── moonlight-mids/
│   │   ├── moonlight1.mid          # I. Adagio sostenuto (used)
│   │   ├── moonlight2.mid          # II. Allegretto (not used)
│   │   └── moonlight3.mid          # III. Presto agitato (not used)
│   └── moonlight-a4.pdf            # Sheet music PDF (full sonata, A4 paper)
├── output/
│   └── Beethoven - Moonlight Sonata.wav
└── .gitignore
```

## Notes

- MIDI source `sources/moonlight-mids/moonlight1.mid` imported into
  Logic Pro as two tracks: `treble` (right hand / melody) and `bass`
  (left hand / triplet ostinato).
- Both tracks use Intimate Grand Piano - Direct preset (single preset
  across both voices).
- Volume hierarchy: 2 dB (treble louder than bass).
- Stereo width: ±20 (audience perspective — treble panned left, bass
  panned right).
- Tempo set to 60 BPM (Adagio sostenuto).
- MIDI region quantize: Off.
- Mastering Assistant character: Transparent.
- Mastering Assistant Auto EQ: 100%.
- Mastering Assistant Loudness Compensation: enabled.
- Mastering Assistant reanalyzed after final track-level adjustments.
- Output filename uses the general work title ("Beethoven - Moonlight
  Sonata.wav") rather than a movement-specific designation; only the
  first movement is included in the rendered audio.
- The Mutopia entry lists "Date of composition: 1802", which corresponds
  to the first publication year (Cappi, Vienna). The composition itself
  was completed by Beethoven in 1801, as documented by the Wikipedia
  article on Piano Sonata No. 14 (Beethoven), which states the work was
  "completed in 1801 and dedicated in 1802 to his pupil Countess Julie
  'Giulietta' Guicciardi."
  (https://en.wikipedia.org/wiki/Piano_Sonata_No._14_(Beethoven))
- The PDF in `sources/moonlight-a4.pdf` is included as reference only
  and was not used in production. The MIDI file `moonlight1.mid` was
  the sole input for the rendered audio.