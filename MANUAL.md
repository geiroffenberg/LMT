# LMT Tracker — User Manual

LMT is a sample-based tracker inspired by the Dirtywave M8. Music is built
from the bottom up: **Samples → Instruments → Phrases → Chains → Song**.

---

## Quick Overview

| Layer | What it is |
|---|---|
| **Sample** | A WAV file loaded into an instrument slot |
| **Instrument** | A sampler voice: pitch, envelope, filters, sends |
| **Phrase** | Up to 99 rows of notes for one instrument stream |
| **Chain** | An ordered list of phrases (the pattern sequence for one track) |
| **Song** | An 8-track grid of chains, played top-to-bottom |
| **Mixer** | Per-track level, reverb/delay/chorus sends, master EQ |

The **bottom bar** holds the 8 VU meters (one per track), BPM display,
undo/redo buttons, and the ☰ hamburger menu.

---

## Navigation

### Windows

Tap a tab to switch the main view:

| Tab | Window |
|---|---|
| **SNG** | Song — arrangement grid |
| **CHN** | Chain — phrase sequence for the selected track |
| **PHR** | Phrase — note grid |
| **INS** | Instrument — sampler parameters |
| **MIX** | Mixer — levels and sends |

### Cursor

- **Tap a cell** to move the cursor to it.
- **Arrow keys** (physical keyboard / USB OTG) move the cursor.
- **ENTER** confirms a value or opens the FX picker.
- **+/−** and **+10/−10** buttons increment the value at the cursor.

### Bottom edit bar

The two rows of buttons below the grid change depending on the active window
and the cursor column:

- **DEL** — clear the value at the cursor to its default (note → `---`, FX → `---`, etc.).
- **X** — same as DEL but also deselects / collapses line selection.
- **REP** — replicate (copy) the selected row/item (see per-window notes).
- **OFF / END** — insert a note-off or phrase-end marker (Phrase window only).

---

## Song Window

The Song window shows a **99-row × 8-track** grid. Each cell holds a
**chain number** (01–99) or is empty (`--`).

Playback reads rows top-to-bottom; all 8 tracks play simultaneously.

### Editing

| Action | How |
|---|---|
| Select a cell | Tap it |
| Set chain number | `+` / `−` or `+10` / `−10` |
| Clear a cell | `DEL` |
| Create and replicate a chain | `REP` — copies the chain's phrases to new empty phrase numbers (M8-style) |
| Double-tap empty cell | Creates a new chain and advances cursor |

### Song Settings

Open ☰ → **SONG SETTINGS** to change:

| Setting | Range | Description |
|---|---|---|
| **BPM** | 60–300 | Tempo |
| **LPB** | 1–12 | Lines per beat |
| **SWING %** | 50–75 | Swing feel: 50 = straight, 66 = triplet, 75 = heavy. Even-numbered steps play longer, odd steps shorter. |

---

## Chain Window

A chain is a list of up to 99 rows, each row pointing to one **phrase** on
one track. Chains play their rows sequentially and then loop.

### Columns

| Column | Meaning |
|---|---|
| **row** | Row number (01–99) |
| **PH** | Phrase number (01–99), or `--` for empty |
| **TR** | Semitone transpose for this row (−12 to +12), `--` = 0 |
| **FX / VL** | Two FX command slots: command name + value 00–99 |

### Editing

- **+/−** on the PH column to select a phrase.
- **+/−** on TR to transpose the phrase by semitones.
- **REP** — duplicates the selected row (copies phrase reference and FX).
- **DEL** — clears the row to empty.

### Chain FX

Chain-level FX affect the whole phrase at that row:

`BPM` `TPO` `LPB` `HOP` — see the **FX Reference** section below.

---

## Phrase Window

A phrase is a grid of up to 99 steps. Steps play at the current tempo
(BPM × LPB = lines per beat). Each step can trigger a note on one instrument.

### Columns

| Column | Meaning |
|---|---|
| **row** | Step number |
| **NT** | Note: `C-4`, `C#4` … `---` (empty), `OFF` (note-off), `END` (end marker) |
| **IN** | Instrument slot (01–16), `--` = inherit |
| **VOL** | Per-step volume (00–99), `--` = use instrument default |
| **FX / VL** | Three FX slots: command + value |

### Special notes

- **`---`** — empty step, nothing plays.
- **`OFF`** — sends a note-off to the instrument (starts the release phase).
- **`END`** — stops reading the phrase here; steps after END are ignored.

### Editing

- Tap **NT** cell → `+` / `−` to change the note by semitone; `+10` / `−10`
  to change by octave.
- **OFF** and **END** buttons appear in the edit bar when the cursor is on NT.
- Tap **IN**, **VOL**, or **FX/VL** cells → `+` / `−` to edit.
- **DEL** clears the column at the cursor row.
- **REP** duplicates the selected row below it.
- Tap a row number to select it; tap again (or drag) to extend line selection.
  Then **DEL** to clear the selection, or ↑/↓ to shift it.

---

## Instrument / Sampler Window

Each instrument slot (01–16) is an independent sampler voice.

### Loading a sample

Each instrument row has three buttons:

| Button | Action |
|---|---|
| **LD** | Open the file browser to load a WAV |
| **ED** | Open the sampler editor (crop, chop, normalize, waveform view) |
| **RC** | Record from the microphone directly into this slot |

Tap **RC** to start recording. A red blinking dot and a timer appear. Tap **STOP** to finish — the recording is saved as a WAV and loaded into the slot automatically. Tap **CANCEL** to discard. Maximum recording length: 60 seconds.

Supported WAV format on load: any sample rate; mono or stereo; 16-bit, 24-bit, or 32-bit PCM. Stereo files are mixed down to mono on load.

### Parameters

| Param | Range | Description |
|---|---|---|
| **PITCH** | −1 to +1 octave | Coarse tune (stacks with phrase transpose) |
| **VOL** | 0–99 | Base volume |
| **START** | 0–99 % | Sample start point |
| **END** | 0–99 % | Sample end point |
| **ATTACK** | 0–99 | Amplitude attack (0 = instant) |
| **RELEASE** | 0–99 | Amplitude release |
| **LOOP** | OFF / LOOP / PING | Loop mode |
| **HP** | 0–99 | High-pass filter cutoff |
| **LP** | 0–99 | Low-pass filter cutoff |

### Sends (per-instrument)

| Param | Description |
|---|---|
| **RVB** | Reverb send (stacks with track send) |
| **DLY** | Delay send |
| **CHO** | Chorus send |

### Chop / Crop / Normalize

- **CROP** — trim the sample to the current START/END range and save as a new file.
- **CHOP** — divide the sample into equal slices (for drum kits / one-shots). Use the `SLC` FX command to select a slice per step.
- **NORM** — normalize the sample so its loudest peak reaches near full scale (0.99). Saves as a new file.

### Preview

Tap ▶ to audition the sample with the current parameters.

---

## Mixer Window

The Mixer shows 8 track channels. Switch to it with the **MIX** tab.

### Per-track parameters

| Row | Range | Description |
|---|---|---|
| **LVL** | 0–99 | Dry track level (attenuates before master) |
| **RVB** | 0–99 | Reverb send amount |
| **DLY** | 0–99 | Delay send amount |
| **CHO** | 0–99 | Chorus send amount |

Drag left/right on a cell to change its value.

### Master FX (FX button)

Tap **FX** inside the mixer to open the master effects chain:

| Effect | Parameters | Notes |
|---|---|---|
| **REVERB** | SIZE, DAMP, WID | Freeverb stereo reverb |
| **DELAY** | TIME (00–99), FDBK | TIME is tempo-synced: 50 = half a line at current BPM/LPB, 25 = quarter line, 99 ≈ one full line |
| **CHORUS** | RATE, DPTH | LFO-modulated delay |

Drag left/right on any parameter row to adjust. All master FX settings are saved with the project.

### Solo Tracks

**Tap** a VU meter → **Toggle solo** for that track (yellow border + S).

All other tracks mute automatically when any track is soloed. Solo state is saved with the project.

---

## Playback

| Control | Action |
|---|---|
| ▶ / ■ | Start / stop song playback (plays all tracks from current cursor) |
| ↺ | Toggle loop mode |
| Playhead | Orange row highlight shows the currently playing step |
| Solo track | Tap any VU meter to toggle solo (yellow border + S) |

Pressing play in **any window** (Song, Chain, or Phrase) plays the full song from
the current cursor position. All 8 tracks play together. Use the meter solo feature
to hear a single track in isolation if needed.

---

## Undo / Redo

- **↶ Undo** and **↷ Redo** buttons sit between the BPM display and ☰.
- Up to 64 undo steps are kept.
- Undo/redo covers: note edits, FX edits, chain edits, song edits, mixer
  changes, instrument parameter changes.
- Mute/solo state and playback position are **not** undoable (they are
  performance controls).
- Undo history is cleared when you load or create a new song.

---

## Project Menu (☰)

| Item | Action |
|---|---|
| **SAVE SONG** | Save to the current project folder |
| **SAVE AS…** | Save under a new name |
| **NEW SONG** | Start a blank project |
| **LOAD SONG** | Open an existing project |
| **EXPORT WAV** | Render the song to a stereo WAV file (saved to Downloads) |
| **EXPORT ZIP** | Bundle the project folder into a ZIP for sharing or backup |
| **IMPORT ZIP** | Load a project from a ZIP file |
| **SONG SETTINGS** | Change BPM, LPB, and Swing % |
| **MANUAL** | Show this manual |

Projects are stored in the app's documents directory, one folder per project.
Each folder contains `song.lmt` (JSON) and a `samples/` sub-folder.

---

## FX Reference

FX slots appear in **Phrase rows** (three slots) and **Chain rows** (two slots).
Each slot has a 3-letter command and a 2-digit value (00–99, or XY nibble).

Commands marked **P** are Phrase-only; **C** are Chain-only; **B** work in both.

### Playback

| CMD | Where | Value | Description |
|---|---|---|---|
| `VOL` | B | 00–99 | Per-note volume override |
| `PAN` | B | 00–99 | Stereo pan: 00=L  50=C  99=R |
| `REV` | P | — | Reverse sample playback |
| `DEL` | P | 00–99 | Delay trigger within row (0=start, 99=end) |
| `RET` | P | XY | Retrigger: X=volume curve 0–9, Y=count 1–9 |
| `KIL` | P | 00–99 | Cut note at this % through the row |
| `CHA` | P | 00–99 | Chance: probability the note plays at all |

### Pitch & Modulation

| CMD | Where | Value | Description |
|---|---|---|---|
| `FIN` | P | 00–99 | Fine pitch offset (±1 semitone range, 50=no change) |
| `PIT` | P | 00–99 | Semitone transpose (01–49=+1 to +49 semitones, 50=no change, 51–99=−1 to −49 semitones) |
| `ARP` | P | XY | Arpeggio: X=1st interval (semitones), Y=2nd |
| `SLU` | P | XY | Slide up: X=lines, Y=semitones |
| `SLD` | P | XY | Slide down: X=lines, Y=semitones |
| `VIB` | P | XY | Vibrato: X=speed, Y=depth |

### Volume Modulation

| CMD | Where | Value | Description |
|---|---|---|---|
| `TRE` | P | XY | Tremolo (sine): X=speed, Y=depth |
| `GAT` | P | XY | Gate (square wave): X=speed, Y=depth |

### FX Sends

| CMD | Where | Value | Description |
|---|---|---|---|
| `SNR` | B | 00–99 | Send to Reverb |
| `SND` | B | 00–99 | Send to Delay |
| `SNC` | B | 00–99 | Send to Chorus |

### Chain / Arrangement

| CMD | Where | Value | Description |
|---|---|---|---|
| `BPM` | B | 00–99 | Tempo change (maps to 60–240 BPM) |
| `TPO` | C | 00–99 | Transpose phrase: 00=−12  50=±0  99=+12 |
| `LPB` | C | 01–16 | Lines per beat override for this phrase |
| `HOP` | C | 00–99 | Jump to chain row (non-linear arrangement) |

### Slice Player Mode

The bottom octave (MIDI notes 0–11) is reserved as a **slice player**.
Instead of playing a pitched note, these entries directly trigger instruments
1–12 at their original pitch:

| Display | Triggers |
|---|---|
| `I01` | Instrument 1 |
| `I02` | Instrument 2 |
| … | … |
| `I12` | Instrument 12 |

**Typical workflow:** Chop a breakbeat or sample into pieces, load each piece
into instruments 1–12, then enter `I01`–`I12` in a phrase to sequence the
slices. The instrument column is ignored for these entries — the note itself
selects the instrument. Any FX commands (VOL, PIT, VIB, etc.) still apply
normally.

### Slice

| CMD | Where | Value | Description |
|---|---|---|---|
| `SLC` | P | 00–09 | Select slice (0–9 from the Chop grid) |

### Sampler Automation (S01–S11)

Override per-instrument sampler parameters for a single note.

| CMD | Value | Description |
|---|---|---|
| `S01` | 00–99 | Sample start point |
| `S02` | 00–99 | Sample end point |
| `S03` | 00–99 | Pitch / tune |
| `S04` | 00–99 | Volume |
| `S05` | 00–99 | Attack |
| `S06` | 00–99 | Release |
| `S07` | 00–01 | Loop on (01) / off (00) |
| `S08` | 00–99 | Loop start point |
| `S09` | 00–99 | Loop end point |
| `S10` | 00–99 | Filter cutoff |
| `S11` | 00–99 | Filter resonance |

### Mixer Automation (Mxy)

Automate a mixer channel parameter at a specific chain row.
`x` = channel 1–8, `y` = parameter:

| y | Parameter |
|---|---|
| 1 | Volume |
| 2 | Pan |
| 3 | Mute (00=off, 01=mute) |
| 4 | Reverb send |
| 5 | Delay send |
| 6 | Chorus send |
| 7 | Solo (00=off, 01=solo) |
| 8 | Reset to snapshot |

Example: `M14 50` sets channel 1 reverb send to 50/99.

---

## Tips & Workflow

1. **Start with the sampler** — load a kick, snare, bass, etc. into slots 1–8.
2. **Build a phrase per instrument** — each track gets its own chain of phrases.
3. **Arrange in Song view** — set which chain plays on which track at which row.
4. **Use Chain FX for variation** — `TPO` to transpose a phrase, `BPM` for a
   tempo drop, `HOP` to create loops within a chain.
5. **Use REP in Song view** — copies a chain's phrases to fresh slots so you
   can edit the variation without touching the original (M8 workflow).
6. **Use the Mixer last** — dial in levels and reverb/delay sends once the
   arrangement is locked.
7. **Mute/Solo while mixing** — double-tap a meter to solo, long-press to mute.
