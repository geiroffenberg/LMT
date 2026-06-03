import 'package:flutter/material.dart';
import '../tracker_styles.dart';

// ── In-app user manual ────────────────────────────────────────────────────
//
// Show with:
//   showManual(context);

void showManual(BuildContext context) {
  showDialog<void>(
    context: context,
    barrierColor: Colors.black87,
    builder: (ctx) => const _ManualDialog(),
  );
}

class _ManualDialog extends StatefulWidget {
  const _ManualDialog();

  @override
  State<_ManualDialog> createState() => _ManualDialogState();
}

class _ManualDialogState extends State<_ManualDialog> {
  int _sectionIdx = 0;

  static const _sections = [
    _Section('OVERVIEW',    _overview),
    _Section('NAVIGATION',  _navigation),
    _Section('SONG',        _song),
    _Section('CHAIN',       _chain),
    _Section('PHRASE',      _phrase),
    _Section('INSTRUMENT',  _instrument),
    _Section('MIXER',       _mixer),
    _Section('PLAYBACK',    _playback),
    _Section('UNDO/REDO',   _undoRedo),
    _Section('FX: PLAYBACK',  _fxPlayback),
    _Section('FX: PITCH',     _fxPitch),
    _Section('FX: VOL MOD',   _fxVolMod),
    _Section('FX: SENDS',     _fxSends),
    _Section('FX: CHAIN',     _fxChain),
    _Section('FX: SAMPLER',   _fxSampler),
    _Section('FX: MIXER',     _fxMixer),
    _Section('WORKFLOW TIPS', _tips),
  ];

  @override
  Widget build(BuildContext context) {
    final size   = MediaQuery.of(context).size;
    final isWide = size.width > 500;

    return Dialog(
      backgroundColor: kBarBg,
      insetPadding: const EdgeInsets.all(8),
      child: SizedBox(
        width:  size.width  - 16,
        height: size.height - 40,
        child: Column(children: [
          // ── Title bar ─────────────────────────────────────────────────
          Container(
            height: 40,
            color: Colors.black,
            child: Row(children: [
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'LMT  USER  MANUAL',
                  style: trackerStyle(size: 22, color: kGreen),
                ),
              ),
              GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Text('X', style: trackerStyle(size: 22, color: Colors.white)),
                ),
              ),
            ]),
          ),

          // ── Section tabs (horizontal scroll) ──────────────────────────
          SizedBox(
            height: 32,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              itemCount: _sections.length,
              itemBuilder: (_, i) {
                final active = i == _sectionIdx;
                return GestureDetector(
                  onTap: () => setState(() => _sectionIdx = i),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      color:  active ? kGreen    : Colors.transparent,
                      border: Border.all(color: active ? kGreen : Colors.white38),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      _sections[i].title,
                      style: trackerStyle(size: 14, color: active ? Colors.black : Colors.white70),
                    ),
                  ),
                );
              },
            ),
          ),

          // ── Content ───────────────────────────────────────────────────
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: _ManualContent(
                blocks: _sections[_sectionIdx].content,
                wide:   isWide,
              ),
            ),
          ),

          // ── Prev / Next ────────────────────────────────────────────────
          Container(
            height: 36,
            color: Colors.black,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                GestureDetector(
                  onTap: _sectionIdx > 0
                      ? () => setState(() => _sectionIdx--)
                      : null,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    alignment: Alignment.center,
                    child: Text(
                      '< PREV',
                      style: trackerStyle(
                        size: 18,
                        color: _sectionIdx > 0 ? Colors.white : Colors.white24,
                      ),
                    ),
                  ),
                ),
                Text(
                  '${_sectionIdx + 1} / ${_sections.length}',
                  style: trackerStyle(size: 16, color: Colors.white54),
                ),
                GestureDetector(
                  onTap: _sectionIdx < _sections.length - 1
                      ? () => setState(() => _sectionIdx++)
                      : null,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    alignment: Alignment.center,
                    child: Text(
                      'NEXT >',
                      style: trackerStyle(
                        size: 18,
                        color: _sectionIdx < _sections.length - 1
                            ? Colors.white
                            : Colors.white24,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

// ── Content renderer ─────────────────────────────────────────────────────

class _ManualContent extends StatelessWidget {
  const _ManualContent({required this.blocks, required this.wide});

  final List<_Block> blocks;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: blocks.map((b) => _buildBlock(b)).toList(),
    );
  }

  Widget _buildBlock(_Block b) {
    switch (b.type) {
      case _BT.h1:
        return Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 6),
          child: Text(b.text, style: trackerStyle(size: 24, color: kGreen)),
        );
      case _BT.h2:
        return Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 4),
          child: Text(b.text, style: trackerStyle(size: 18, color: kCyan)),
        );
      case _BT.body:
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            b.text,
            style: trackerStyle(size: 16, color: Colors.white),
          ),
        );
      case _BT.table:
        return _buildTable(b);
      case _BT.divider:
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 6),
          child: Divider(color: Colors.white24, thickness: 1),
        );
    }
  }

  Widget _buildTable(_Block b) {
    // b.rows: first entry = headers, rest = data rows
    if (b.rows.isEmpty) return const SizedBox();
    final headers = b.rows.first;
    final data    = b.rows.skip(1).toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Table(
        border: TableBorder.all(color: Colors.white24, width: 1),
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        columnWidths: {
          0: const IntrinsicColumnWidth(),
        },
        children: [
          TableRow(
            decoration: const BoxDecoration(color: Color(0xFF1A2A1A)),
            children: headers
                .map((h) => Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      child: Text(h, style: trackerStyle(size: 15, color: kGreen)),
                    ))
                .toList(),
          ),
          ...data.map((row) => TableRow(
                children: row
                    .map((cell) => Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                          child: Text(cell, style: trackerStyle(size: 15, color: Colors.white)),
                        ))
                    .toList(),
              )),
        ],
      ),
    );
  }
}

// ── Data types ────────────────────────────────────────────────────────────

enum _BT { h1, h2, body, table, divider }

class _Block {
  const _Block.h1(this.text)
      : type = _BT.h1,
        rows = const [];
  const _Block.h2(this.text)
      : type = _BT.h2,
        rows = const [];
  const _Block.body(this.text)
      : type = _BT.body,
        rows = const [];
  const _Block.table(this.rows)
      : type = _BT.table,
        text = '';
  const _Block.divider()
      : type = _BT.divider,
        text = '',
        rows = const [];

  final _BT            type;
  final String         text;
  final List<List<String>> rows;
}

class _Section {
  const _Section(this.title, this.content);
  final String      title;
  final List<_Block> content;
}

// ═════════════════════════════════════════════════════════════════════════════
// Section content
// ═════════════════════════════════════════════════════════════════════════════

const _overview = [
  _Block.h1('LMT Tracker'),
  _Block.body(
    'A sample-based tracker inspired by the Dirtywave M8. '
    'Music is built from the bottom up:',
  ),
  _Block.table([
    ['Layer', 'What it is'],
    ['Sample',     'A WAV file loaded into an instrument slot'],
    ['Instrument', 'A sampler voice: pitch, envelope, filters, sends'],
    ['Phrase',     'Up to 99 rows of notes for one instrument stream'],
    ['Chain',      'An ordered list of phrases for one track'],
    ['Song',       'An 8-track grid of chains played top-to-bottom'],
    ['Mixer',      'Per-track level, reverb/delay/chorus sends, master EQ'],
  ]),
  _Block.body(
    'The bottom bar holds the 8 VU meters (one per track), BPM display, '
    'undo/redo buttons, and the ☰ hamburger menu.',
  ),
];

const _navigation = [
  _Block.h1('Navigation'),
  _Block.h2('Windows'),
  _Block.table([
    ['Tab', 'Window'],
    ['SNG', 'Song — arrangement grid'],
    ['CHN', 'Chain — phrase sequence for the selected track'],
    ['PHR', 'Phrase — note grid'],
    ['INS', 'Instrument — sampler parameters'],
    ['MIX', 'Mixer — levels and sends'],
  ]),
  _Block.h2('Cursor'),
  _Block.body('Tap a cell to move the cursor to it.'),
  _Block.body('Arrow keys (physical keyboard / USB OTG) move the cursor.'),
  _Block.body('ENTER confirms a value or opens the FX picker.'),
  _Block.body('+/- and +10/-10 buttons increment the value at the cursor.'),
  _Block.h2('Bottom edit bar'),
  _Block.table([
    ['Button', 'Action'],
    ['DEL', 'Clear the value at the cursor to its default'],
    ['X',   'Same as DEL but also collapses line selection'],
    ['REP', 'Replicate the selected row (see per-window notes)'],
    ['OFF', 'Insert note-off (Phrase / NT column only)'],
    ['END', 'Insert phrase-end marker (Phrase / NT column only)'],
  ]),
];

const _song = [
  _Block.h1('Song Window'),
  _Block.body(
    'A 99-row x 8-track grid. Each cell holds a chain number (01-99) '
    'or is empty (--). Playback reads rows top-to-bottom; all 8 tracks '
    'play simultaneously.',
  ),
  _Block.h2('Editing'),
  _Block.table([
    ['Action', 'How'],
    ['Select a cell',           'Tap it'],
    ['Set chain number',        '+/- or +10/-10'],
    ['Clear a cell',            'DEL'],
    ['Replicate a chain',       'REP — copies phrases to new empty phrase slots (M8-style)'],
    ['Double-tap empty cell',   'Creates a new chain and advances cursor'],
  ]),
  _Block.h2('Song Settings'),
  _Block.body('Open the ☰ menu → SONG SETTINGS to change global BPM (60-240) and LPB (lines per beat, 1-16).'),
];

const _chain = [
  _Block.h1('Chain Window'),
  _Block.body(
    'A chain is a list of up to 99 rows, each pointing to one phrase. '
    'Chains play sequentially and loop.',
  ),
  _Block.h2('Columns'),
  _Block.table([
    ['Column', 'Meaning'],
    ['row',    'Row number (01-99)'],
    ['PH',     'Phrase number (01-99), or -- for empty'],
    ['TR',     'Semitone transpose for this row (-12 to +12)'],
    ['FX/VL',  'Two FX command slots: command name + value 00-99'],
  ]),
  _Block.h2('Editing'),
  _Block.body('+/- on PH to select a phrase. +/- on TR to transpose by semitones.'),
  _Block.body('REP — duplicates the selected row. DEL — clears the row.'),
  _Block.h2('Chain FX'),
  _Block.body('BPM  TPO  LPB  HOP — see the FX sections.'),
];

const _phrase = [
  _Block.h1('Phrase Window'),
  _Block.body(
    'A phrase is a grid of up to 99 steps. Steps play at current tempo '
    '(BPM x LPB). Each step can trigger a note on one instrument.',
  ),
  _Block.h2('Columns'),
  _Block.table([
    ['Column',   'Meaning'],
    ['row',      'Step number'],
    ['NT',       'Note: C-4 … --- (empty)  OFF (note-off)  END (stop here)'],
    ['IN',       'Instrument slot 01-16, -- = inherit'],
    ['VOL',      'Per-step volume 00-99, -- = instrument default'],
    ['FX/VL',    'Three FX slots: command + value'],
  ]),
  _Block.h2('Special note values'),
  _Block.table([
    ['Value', 'Meaning'],
    ['---', 'Empty — nothing plays'],
    ['OFF', 'Note-off: starts the release phase'],
    ['END', 'Phrase end: steps after this are ignored'],
  ]),
  _Block.h2('Editing'),
  _Block.body('Tap NT → +/- to change note by semitone; +10/-10 by octave.'),
  _Block.body('OFF and END buttons appear in the edit bar when cursor is on NT.'),
  _Block.body('Tap IN, VOL, or FX/VL cells → +/- to edit.'),
  _Block.body('Tap a row number to select it; tap again to extend selection.'),
  _Block.body('DEL clears the column at the cursor row. REP duplicates the row.'),
];

const _instrument = [
  _Block.h1('Instrument / Sampler'),
  _Block.body('Each instrument slot (01-16) is an independent sampler voice.'),
  _Block.h2('Loading a sample'),
  _Block.body(
    'Tap LOAD to open the file browser. Supported format: mono 16-bit WAV. '
    'The sample is copied into the project folder on save.',
  ),
  _Block.h2('Parameters'),
  _Block.table([
    ['Param',   'Range',       'Description'],
    ['PITCH',   '-1 to +1 oct','Coarse tune (stacks with phrase transpose)'],
    ['VOL',     '0-99',        'Base volume'],
    ['START',   '0-99 %',      'Sample start point'],
    ['END',     '0-99 %',      'Sample end point'],
    ['ATTACK',  '0-99',        'Amplitude attack (0 = instant)'],
    ['RELEASE', '0-99',        'Amplitude release'],
    ['LOOP',    'OFF/LOOP/PING','Loop mode'],
    ['HP',      '0-99',        'High-pass filter cutoff'],
    ['LP',      '0-99',        'Low-pass filter cutoff'],
  ]),
  _Block.h2('Per-instrument sends'),
  _Block.table([
    ['Param', 'Description'],
    ['RVB', 'Reverb send (stacks with track send in Mixer)'],
    ['DLY', 'Delay send'],
    ['CHO', 'Chorus send'],
  ]),
  _Block.h2('Chop / Crop'),
  _Block.body('CHOP — divide the sample into equal slices (use SLC FX to select per step).'),
  _Block.body('CROP — trim to current START/END and save in-place.'),
  _Block.body('Tap the play button to audition the sample with current parameters.'),
];

const _mixer = [
  _Block.h1('Mixer Window'),
  _Block.h2('Per-track parameters'),
  _Block.table([
    ['Row', 'Range', 'Description'],
    ['LVL', '0-99',  'Dry track level (attenuated before master)'],
    ['RVB', '0-99',  'Reverb send amount'],
    ['DLY', '0-99',  'Delay send amount'],
    ['CHO', '0-99',  'Chorus send amount'],
  ]),
  _Block.body('Drag left/right on a cell to change its value.'),
  _Block.h2('Master FX'),
  _Block.body('Tap FX inside the Mixer to open the master effects chain.'),
  _Block.table([
    ['Effect',  'Parameters'],
    ['EQ',      'Three bands: low, mid, high (dB gain)'],
    ['HP',      'Master high-pass frequency'],
    ['Reverb',  'Mix, size, width'],
    ['Delay',   'Time, feedback'],
    ['Chorus',  'Rate, depth'],
  ]),
  _Block.h2('Solo Tracks'),
  _Block.body('Tap a VU meter → Toggle solo for that track (yellow border + S).'),
  _Block.body('All other tracks mute automatically when any track is soloed. Solo state is saved with the project.'),
];

const _playback = [
  _Block.h1('Playback'),
  _Block.table([
    ['Control', 'Action'],
    ['▶ / ■',        'Start / stop song playback'],
    ['↺',            'Toggle loop mode'],
    ['▶ (phrase)',   'Play the current phrase in isolation'],
    ['Playhead',     'Orange row highlight shows the currently playing step'],
  ]),
  _Block.body(
    'During song playback the playhead in the Song, Chain, and Phrase '
    'views advances in sync.',
  ),
];

const _undoRedo = [
  _Block.h1('Undo / Redo'),
  _Block.body('↶ Undo and ↷ Redo buttons sit between the BPM display and ☰.'),
  _Block.body('Up to 64 undo steps are kept.'),
  _Block.h2('What is covered'),
  _Block.body('Note edits, FX edits, chain edits, song edits, mixer changes, instrument parameter changes.'),
  _Block.h2('What is NOT undoable'),
  _Block.body('Mute/solo state and playback position (performance controls).'),
  _Block.body('Undo history is cleared when you load or create a new song.'),
];

const _fxPlayback = [
  _Block.h1('FX: Playback'),
  _Block.body('Where: P = Phrase only   B = Both Phrase and Chain'),
  _Block.table([
    ['CMD', 'Where', 'Value',  'Description'],
    ['VOL', 'B', '00-99', 'Per-note volume override'],
    ['PAN', 'B', '00-99', 'Stereo pan: 00=L  50=C  99=R'],
    ['REV', 'P', '—',     'Reverse sample playback'],
    ['DEL', 'P', '00-99', 'Delay trigger within row (00=start 99=end)'],
    ['RET', 'P', 'XY',    'Retrigger: X=vol curve 0-9  Y=count 1-9'],
    ['KIL', 'P', '00-99', 'Cut note at this % through the row'],
    ['CHA', 'P', '00-99', 'Chance: probability the note plays at all'],
  ]),
];

const _fxPitch = [
  _Block.h1('FX: Pitch & Modulation'),
  _Block.table([
    ['CMD', 'Where', 'Value', 'Description'],
    ['PIT', 'P', '00-99', 'Fine pitch offset (+-1 semitone; 50=centre)'],
    ['ARP', 'P', 'XY',   'Arpeggio: X=1st interval (semitones)  Y=2nd'],
    ['SLU', 'P', 'XY',   'Slide up: X=lines  Y=semitones'],
    ['SLD', 'P', 'XY',   'Slide down: X=lines  Y=semitones'],
    ['VIB', 'P', 'XY',   'Vibrato: X=speed  Y=depth'],
  ]),
];

const _fxVolMod = [
  _Block.h1('FX: Volume Modulation'),
  _Block.table([
    ['CMD', 'Where', 'Value', 'Description'],
    ['TRE', 'P', 'XY', 'Tremolo (sine): X=speed  Y=depth'],
    ['GAT', 'P', 'XY', 'Gate (square wave): X=speed  Y=depth'],
  ]),
];

const _fxSends = [
  _Block.h1('FX: FX Sends'),
  _Block.table([
    ['CMD', 'Where', 'Value',  'Description'],
    ['SNR', 'B', '00-99', 'Send to Reverb'],
    ['SND', 'B', '00-99', 'Send to Delay'],
    ['SNC', 'B', '00-99', 'Send to Chorus'],
  ]),
];

const _fxChain = [
  _Block.h1('FX: Chain / Arrangement'),
  _Block.body('Where: C = Chain only   B = Both'),
  _Block.table([
    ['CMD', 'Where', 'Value',  'Description'],
    ['BPM', 'B', '00-99', 'Tempo change — maps to 60-240 BPM'],
    ['TPO', 'C', '00-99', 'Transpose phrase: 00=-12  50=+0  99=+12'],
    ['LPB', 'C', '01-16', 'Lines per beat override for this phrase'],
    ['HOP', 'C', '00-99', 'Jump to chain row (non-linear arrangement)'],
  ]),
  _Block.divider(),
  _Block.h1('FX: Slice'),
  _Block.table([
    ['CMD', 'Where', 'Value',  'Description'],
    ['SLC', 'P', '00-09', 'Select slice 0-9 from the Chop grid'],
  ]),
];

const _fxSampler = [
  _Block.h1('FX: Sampler Automation (S01-S11)'),
  _Block.body('Override per-instrument sampler parameters for a single note.'),
  _Block.table([
    ['CMD', 'Value',  'Description'],
    ['S01', '00-99', 'Sample start point'],
    ['S02', '00-99', 'Sample end point'],
    ['S03', '00-99', 'Pitch / tune'],
    ['S04', '00-99', 'Volume'],
    ['S05', '00-99', 'Attack'],
    ['S06', '00-99', 'Release'],
    ['S07', '00-01', 'Loop: 01=on  00=off'],
    ['S08', '00-99', 'Loop start point'],
    ['S09', '00-99', 'Loop end point'],
    ['S10', '00-99', 'Filter cutoff'],
    ['S11', '00-99', 'Filter resonance'],
  ]),
];

const _fxMixer = [
  _Block.h1('FX: Mixer Automation (Mxy)'),
  _Block.body('x = channel 1-8   y = parameter (see table below)'),
  _Block.body('Example: M14 50 sets channel 1 reverb send to 50/99.'),
  _Block.table([
    ['y', 'Parameter'],
    ['1', 'Volume'],
    ['2', 'Pan'],
    ['3', 'Mute (00=off  01=mute)'],
    ['4', 'Reverb send'],
    ['5', 'Delay send'],
    ['6', 'Chorus send'],
    ['7', 'Solo (00=off  01=solo)'],
    ['8', 'Reset to snapshot'],
  ]),
];

const _tips = [
  _Block.h1('Workflow Tips'),
  _Block.table([
    ['Step', 'Action'],
    ['1', 'Start with the Sampler — load kick, snare, bass etc into slots 1-8'],
    ['2', 'Build a phrase per instrument — each track gets its own chain'],
    ['3', 'Arrange in Song view — set which chain plays on which track'],
    ['4', 'Use Chain FX for variation — TPO to transpose, BPM for a tempo drop'],
    ['5', 'Use REP in Song view — copies phrases to fresh slots (M8 workflow)'],
    ['6', 'Dial in the Mixer last — levels and reverb/delay once arrangement is locked'],
    ['7', 'Solo tracks while mixing — tap meter to toggle solo on a track'],
  ]),
];
