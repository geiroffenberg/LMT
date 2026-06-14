import 'package:flutter/material.dart';
import 'tracker_styles.dart';

// ── LMT FX Command Registry ───────────────────────────────────────────────
//
// Each entry: 'CMD' → (description, valueHint, windows)
//   windows: 'P' = Phrase only, 'C' = Chain only, 'B' = Both
//
// Value hints:
//   00–99     = single 0–99 byte
//   XY        = high nibble X and low nibble Y, each 0–9
//   —         = no value (flag command)

const Map<String, ({String desc, String value, String windows})> kFxCommands = {

  // ── Playback ─────────────────────────────────────────────────────────────
  'VOL': (desc: 'Per-note/phrase volume override',          value: '00–99', windows: 'B'),
  'PAN': (desc: 'Stereo pan (00=L, 50=C, 99=R)',           value: '00–99', windows: 'B'),
  'REV': (desc: 'Reverse sample playback',                  value: '—',     windows: 'P'),
  'DEL': (desc: 'Delay trigger within row (00=start, 99=end)', value: '00–99', windows: 'P'),
  'RET': (desc: 'Retrigger — X=vol curve (0–9), Y=count',  value: 'XY',    windows: 'P'),
  'KIL': (desc: 'Cut note — % through the row',             value: '00–99', windows: 'P'),
  'CHA': (desc: 'Chance — probability note plays at all',   value: '00–99', windows: 'P'),

  // ── Pitch / Modulation ───────────────────────────────────────────────────
  'ARP': (desc: 'Arpeggio — X=1st interval (semitones), Y=2nd', value: 'XY', windows: 'P'),
  'SLU': (desc: 'Slide up — X=lines, Y=semitones',          value: 'XY',    windows: 'P'),
  'SLD': (desc: 'Slide down — X=lines, Y=semitones',        value: 'XY',    windows: 'P'),
  'VIB': (desc: 'Vibrato — X=speed, Y=depth',               value: 'XY',    windows: 'P'),
  'PIT': (desc: 'Pitch transpose — 01–49=up semitones, 51–99=down semitones', value: '00–99', windows: 'P'),
  'FIN': (desc: 'Fine pitch offset (±1 semitone range)',     value: '00–99', windows: 'P'),

  // ── Volume Modulation ────────────────────────────────────────────────────
  'TRE': (desc: 'Tremolo (sine) — X=speed, Y=depth',        value: 'XY',    windows: 'P'),
  'GAT': (desc: 'Gate (square wave) — X=speed, Y=depth',    value: 'XY',    windows: 'P'),

  // ── FX Sends ─────────────────────────────────────────────────────────────
  'SNR': (desc: 'Send to Reverb',                            value: '00–99', windows: 'B'),
  'SND': (desc: 'Send to Delay',                             value: '00–99', windows: 'B'),
  'SNC': (desc: 'Send to Chorus',                            value: '00–99', windows: 'B'),

  // ── Slice ────────────────────────────────────────────────────────────────
  'SLC': (desc: 'Select slice (0–9)',                        value: '00–09', windows: 'P'),

  // ── Chain-only ───────────────────────────────────────────────────────────
  'BPM': (desc: 'Tempo change (maps to 60–240 BPM)',         value: '00–99', windows: 'B'),
  'TPO': (desc: 'Transpose phrase (00=−12, 50=0, 99=+12)',   value: '00–99', windows: 'C'),
  'LPB': (desc: 'Lines per beat override for this phrase',   value: '01–16', windows: 'C'),
  'HOP': (desc: 'Jump to chain row (non-linear arrangement)',value: '00–99', windows: 'C'),

  // ── Sampler Automation (S01–S11) ─────────────────────────────────────────
  'S01': (desc: 'Sampler: sample start point',               value: '00–99', windows: 'B'),
  'S02': (desc: 'Sampler: sample end point',                 value: '00–99', windows: 'B'),
  'S03': (desc: 'Sampler: pitch / tune',                     value: '00–99', windows: 'B'),
  'S04': (desc: 'Sampler: volume',                           value: '00–99', windows: 'B'),
  'S05': (desc: 'Sampler: attack',                           value: '00–99', windows: 'B'),
  'S06': (desc: 'Sampler: release',                          value: '00–99', windows: 'B'),
  'S07': (desc: 'Sampler: loop on/off',                      value: '00–01', windows: 'B'),
  'S08': (desc: 'Sampler: loop start point',                 value: '00–99', windows: 'B'),
  'S09': (desc: 'Sampler: loop end point',                   value: '00–99', windows: 'B'),
  'S10': (desc: 'Sampler: filter cutoff',                    value: '00–99', windows: 'B'),
  'S11': (desc: 'Sampler: filter resonance',                 value: '00–99', windows: 'B'),

  // ── Mixer Automation (Mxy — X=channel 1–8, Y=param 1–8) ─────────────────
  // Channel param Y values:
  //   1=volume, 2=pan, 3=mute, 4=reverb send, 5=delay send,
  //   6=chorus send, 7=solo, 8=reset to snapshot
  'M11': (desc: 'Ch1 volume',    value: '00–99', windows: 'B'),
  'M12': (desc: 'Ch1 pan',       value: '00–99', windows: 'B'),
  'M13': (desc: 'Ch1 mute',      value: '00–01', windows: 'B'),
  'M14': (desc: 'Ch1 reverb send', value: '00–99', windows: 'B'),
  'M15': (desc: 'Ch1 delay send',  value: '00–99', windows: 'B'),
  'M16': (desc: 'Ch1 chorus send', value: '00–99', windows: 'B'),
  // … M21–M26, M31–M36 … M81–M86 follow the same pattern for channels 2–8
};

// ── FX command integer IDs (packed into C++ wire format) ─────────────────
// BPM, LPB, TPO, HOP, CHA are Dart-only — consumed at row-build time, id=0 for C++.
const Map<String, int> kFxId = {
  'VOL':  1,  'PAN':  2,  'REV':  3,  'DEL':  4,  'RET':  5,
  'KIL':  6,  'CHA':  7,  'ARP':  8,  'SLU':  9,  'SLD': 10,
  'VIB': 11,  'FIN': 12,  'TRE': 13,  'GAT': 14,  'SNR': 15,
  'SND': 16,  'SNC': 17,  'SLC': 18,  'PIT': 19,
};

/// Map BPM FX value (00–99) to BPM (60–240).
int fxValToBpm(int val) => (60 + val * 180 ~/ 99).clamp(60, 240);

// ── Mixer command helper ───────────────────────────────────────────────────
// Returns the description for any Mxy command dynamically.
String? mixerCommandDesc(String cmd) {
  if (cmd.length != 3 || cmd[0] != 'M') return null;
  final ch = int.tryParse(cmd[1]);
  final param = int.tryParse(cmd[2]);
  if (ch == null || ch < 1 || ch > 8) return null;
  const params = {
    1: 'volume', 2: 'pan', 3: 'mute',
    4: 'reverb send', 5: 'delay send', 6: 'chorus send',
    7: 'solo', 8: 'reset to snapshot',
  };
  final p = params[param];
  if (p == null) return null;
  return 'Ch$ch $p';
}

// ── FX command picker dialog ───────────────────────────────────────────────
// Opens a tracker-styled dialog listing all commands available in the given
// window context.  Returns the chosen command name, '---' to clear, or null
// if cancelled.
Future<String?> showFxCommandPicker(
  BuildContext context, {
  required bool isPhrase, // true = phrase window, false = chain window
}) async {
  final commands = kFxCommands.entries
      .where((e) => isPhrase
          ? e.value.windows == 'P' || e.value.windows == 'B'
          : e.value.windows == 'C' || e.value.windows == 'B')
      .toList();

  return showDialog<String>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black,
          border: Border.all(color: Colors.white, width: 2),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Title bar
            Container(
              height: 40,
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Colors.white, width: 1)),
              ),
              alignment: Alignment.center,
              child: Text('SELECT FX', style: trackerStyle(size: 20, color: Colors.white)),
            ),
            // "---" clear row
            GestureDetector(
              onTap: () => Navigator.pop(ctx, '---'),
              child: Container(
                height: 36,
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: Colors.white, width: 1)),
                ),
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text('---  clear', style: trackerStyle(size: 18, color: Colors.white54)),
              ),
            ),
            // Command list
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: commands.length,
                itemBuilder: (_, i) {
                  final entry = commands[i];
                  final isLast = i == commands.length - 1;
                  return GestureDetector(
                    onTap: () => Navigator.pop(ctx, entry.key),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                      decoration: BoxDecoration(
                        border: isLast
                            ? null
                            : const Border(bottom: BorderSide(color: Colors.white24, width: 1)),
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 46,
                            child: Text(entry.key, style: trackerStyle(size: 18, color: kGreen)),
                          ),
                          Expanded(
                            child: Text(
                              entry.value.desc,
                              style: trackerStyle(size: 16, color: Colors.white70),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            entry.value.value,
                            style: trackerStyle(size: 16, color: Colors.white38),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
