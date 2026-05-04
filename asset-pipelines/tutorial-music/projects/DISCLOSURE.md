# Third-Party Tool Disclosure

This document discloses the third-party tools and software used to produce
the audio assets in the `projects/` directory. Each project's `README.md`
contains the specific tool, preset, and configuration used for that
recording. This document serves as the central reference for the licensing
terms governing those tools.

## Overview

The audio assets in this directory are tutorial background music recordings
produced for use in Phantom-WG video tutorials. Each recording combines:

- A public domain musical composition
- A MIDI transcription sourced from the Mutopia Project
- Splice INSTRUMENT presets used as virtual instruments in Logic Pro
- Production decisions (tempo, panning, volume balance, audio effects,
  mastering) made within Logic Pro

No live performance recording, interpretive humanization, or arrangement
modification is applied. The recordings are deterministic playback of
source MIDI files through selected presets, with mixing and mastering
choices documented per-project.

## Splice INSTRUMENT

The recordings in this directory use **Splice INSTRUMENT**, a virtual
instrument plugin distributed by Splice (Distributed Creation Inc.,
817 Broadway, 4th Floor, New York, NY 10003). Splice INSTRUMENT presets
are loaded as Audio Unit (AU) plugins in Logic Pro and used to render MIDI
files into audio.

### License Terms

The use of Splice INSTRUMENT presets is governed by the Splice Terms of
Use. Section 5.3.2 (Usage) grants users a perpetual right to use
Instrument Presets within New Recordings and Creative Works:

> "Subject to your compliance with the Agreement, we grant you a
> non-exclusive, non-transferable, limited, worldwide, perpetual right to
> perform, display and use/download any Instrument Preset(s), which are
> used in Splice Instrument, solely in New Recordings and/or in Creative
> Works for commercial and non-commercial purposes, except as prohibited
> below. This means that you may modify, publicly perform, distribute,
> transmit, communicate to the public, sublicense and otherwise use the
> Instrument Presets solely as embodied in a New Recording and/or in a
> Creative Work. For the avoidance of doubt, you will not own the
> Instrument Presets." [1]

The audio recordings in this directory are treated as New Recordings
under those terms. Each recording embodies an Instrument Preset within a
musical composition (a public domain classical work), satisfying the
"solely as embodied in a New Recording" requirement.

### Restrictions

The following restrictions from Section 5.3.2.1 (Prohibited Uses) of the
Splice Terms of Use apply [2]:

- The Splice INSTRUMENT presets themselves are NOT redistributed in this
  repository. Only the rendered audio output (`.wav` files) is included.
- The audio output may not be re-extracted as samples, loops, or sound
  effects for redistribution as source material in other works.
- Splice INSTRUMENT presets are not redistributed individually or as
  part of new packs.
- Splice INSTRUMENT presets are not used as training material for any
  generative or other artificial intelligence models.
- The names, images, or likenesses of brands or artists associated with
  Splice INSTRUMENT presets are not used in connection with these
  recordings.

The full text of the prohibited uses clause is reproduced in the
References section below.

### Subscription Status

Splice INSTRUMENT presets were accessed via an active Splice subscription
at the time of recording. Per Section 5.3.2 of the Splice Terms of Use,
the right to use rendered recordings made with Instrument Presets in New
Recordings and Creative Works is **perpetual** and survives subscription
cancellation. The audio outputs in this directory may therefore continue
to be used regardless of the subscription status at any future date.

### Presets Used

The following Splice INSTRUMENT presets were used across the projects in
this directory:

- **Intimate Grand Piano - Direct**: Close-miked grand piano with
  defined attack characteristics. Used as the primary virtual instrument
  across all current recordings, applied to both treble (right hand /
  melody) and bass (left hand / accompaniment) MIDI tracks.

Each project's `README.md` documents the specific preset configuration
used for that recording.

## Source MIDI Files

The MIDI files used as input for these recordings are sourced from the
**Mutopia Project** (https://www.mutopiaproject.org/), a non-profit
volunteer-driven repository of public domain and Creative Commons
licensed sheet music and MIDI files. As described on the Mutopia Project
homepage:

> "All of the music on Mutopia may be freely downloaded, printed, copied,
> distributed, modified, performed and recorded. ... Most of our music
> is distributed under Creative Commons licenses. Each piece clearly
> lists what license it is distributed under." [3]

Mutopia Project files are typeset by volunteers from public domain sheet
music editions using LilyPond software, with audio previews generated
programmatically as MIDI files [3]. Each project's `README.md` specifies
the exact Mutopia URL, typesetter credit, and license badge for the MIDI
source used.

## Compositions

The musical compositions performed in these recordings are works by
classical composers whose deaths occurred more than 70 years ago. These
compositions are in the public domain in most jurisdictions, including
the European Union, United Kingdom, Turkey, and the United States. Each
project's `README.md` documents the specific composition, composer,
publication year, and copyright status.

## Output Format

All audio outputs are rendered as:

- File Format: WAV
- Sample Rate: 48 kHz
- Bit Depth: 24-bit
- Channels: Stereo

## Disclosure Updates

This disclosure reflects the third-party tools used as of the date of the
last project added to this directory. If new tools are introduced or
existing tools change their terms, this disclosure will be updated
accordingly. The Splice Terms of Use referenced here are dated September
29, 2025; users are advised to consult the current version at
https://splice.com/terms for any updates.

## References

**[1]** Splice Terms of Use, Section II.5.3.2 (Usage), as published by
Distributed Creation Inc.:

> "Subject to your compliance with the Agreement, we grant you a
> non-exclusive, non-transferable, limited, worldwide, perpetual right to
> perform, display and use/download any Instrument Preset(s), which are
> used in Splice Instrument, solely in New Recordings and/or in Creative
> Works for commercial and non-commercial purposes, except as prohibited
> below. This means that you may modify, publicly perform, distribute,
> transmit, communicate to the public, sublicense and otherwise use the
> Instrument Presets solely as embodied in a New Recording and/or in a
> Creative Work. For the avoidance of doubt, you will not own the
> Instrument Presets."

Source: https://splice.com/terms (Last Updated: September 29, 2025)

**[2]** Splice Terms of Use, Section II.5.3.2.1 (Prohibited Uses):

> "Notwithstanding anything to the contrary and solely with respect to
> Instrument Presets, you may not (a) sublicense the Instrument Presets
> in isolation as sound effects, loops, or as source material for any
> other form of sample (even if you modify the Instrument Presets), (b)
> use or sublicense Instrument Presets in a manner competitive to Splice
> or its licensors, (c) sublicense, sell, loan, share, lend, broadcast,
> rent, lease, assign, distribute, or transfer the Instrument Presets to
> a third party except as incorporated into a New Recording or Creative
> Work as noted above; (d) redistribute Instrument Presets either
> individually and/or in a new pack(s); (e) use any Instrument Presets
> or portions of Instrument Presets identified as made available for
> 'preview' other than to internally and locally (on the Service)
> preview the applicable Instrument Presets (and for the avoidance of
> doubt, 'preview' Instrument Presets may not be modified, reproduced,
> publicly performed, distributed, transmitted, communicated to the
> public, sublicensed, or otherwise used, including for commercial
> purposes); or (f) use the Instrument Presets as source or training
> material for generative or other types of artificial intelligence
> models. Additionally, you may not use the name, image, or likeness of
> any brand and/or artist associated with Instrument Presets in any way."

Source: https://splice.com/terms (Last Updated: September 29, 2025)

**[3]** Mutopia Project, homepage:

> "All of the music on Mutopia may be freely downloaded, printed, copied,
> distributed, modified, performed and recorded. ... Most of our music
> is distributed under Creative Commons licenses. Each piece clearly
> lists what license it is distributed under."

> "These are based on editions in the public domain. A team of
> volunteers typesets the music using LilyPond software. ... Computer-
> generated audio previews of the music are available as MIDI files."

Source: https://www.mutopiaproject.org/

---

A Turkish-language version of this document is available at
[`DISCLOSURE_TR.md`](./DISCLOSURE_TR.md). The original English citations
of the Splice Terms of Use and the Mutopia Project description are
preserved verbatim in both versions; only the surrounding contextual
text is translated.