import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'audio/audio_engine.dart';
import 'audio/wav_encoder.dart';
import 'fx_commands.dart';
import 'models/sampler_params.dart';

// Data models for LMT tracker

class Song {
  // 99 chains x 8 tracks
  final List<List<int>> chains = List.generate(99, (_) => List.filled(8, 0));
  int bpm = 120;
  int lpb = 4; // Lines Per Beat (1–12)
  int swingPercent = 50; // 50 = straight, 66 = triplet swing, 75 = heavy swing
}

class Chain {
  final List<ChainItem> items = List.generate(99, (_) => ChainItem());
  int transpose = 0;
}

class ChainItem {
  int phrase = 0;
  int transpose = 0;
  List<FxSlot> fx = [FxSlot(), FxSlot()];
}

class Phrase {
  final List<PhraseStep> steps = List.generate(99, (i) => PhraseStep()..note = (i == 16 ? PhraseStep.noteEnd : PhraseStep.noteNone));
  int length = 16; // Number of active steps (1-99)
}

class PhraseStep {
  // Special note values
  static const int noteNone = -1;  // empty step — no note triggered
  static const int noteOff  = -2;  // stop the sample on this instrument
  static const int noteEnd  = -3;  // marks end of phrase (not played)

  int instrument = 0;
  int volume = 80;
  int note = noteNone;
  List<FxSlot> fx = [FxSlot(), FxSlot(), FxSlot()];

  // Helper to get note display (e.g., "C-4", "C#4", "---", "OFF", "END")
  String getNoteDisplay() {
    if (note == noteEnd)  return 'END';
    if (note == noteOff)  return 'OFF';
    if (note < 0 || note > 120) return '---';
    const noteNames = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
    final octave = (note ~/ 12) - 1; // MIDI 60 = C-4 (middle C)
    final semitone = note % 12;
    final noteName = noteNames[semitone];
    if (noteName.length == 1) {
      return '$noteName-$octave'.padRight(3);
    } else {
      return '$noteName$octave'.padRight(3);
    }
  }
}

class FxSlot {
  String name = '---';
  int value = 0;
}

class Instrument {
  int filter = 70;
  int resonance = 20;
  int treble = 0;
  int mid = 0;
  int bass = 0;
  String sample = '';
  
  // Sampler state
  SamplerParams sampler = SamplerParams.empty();
}

class MixerChannel {
  int level = 80;
  int reverbSend = 0;
  int delaySend = 0;
  int chorusSend = 0;
}

class MasterFx {
  // Reverb (Freeverb)
  double reverbSize  = 0.5;  // room size 0–1
  double reverbDamp  = 0.5;  // damping   0–1
  double reverbWidth = 1.0;  // stereo width 0–1
  // Delay
  int    delayLines    = 50;    // 0–99: 50 = half a line at current BPM/LPB
  double delayFeedback = 0.4;   // 0–1

  // Chorus
  double chorusRate  = 1.0;  // Hz   (0.1–5)
  double chorusDepth = 0.5;  // 0–1

  // 5-band master EQ gains in dB (−12 … +12)
  double eqBand1 = 0.0;  //  80 Hz  (low shelf)
  double eqBand2 = 0.0;  // 250 Hz
  double eqBand3 = 0.0;  //   1 kHz (mid)
  double eqBand4 = 0.0;  //   4 kHz
  double eqBand5 = 0.0;  //  12 kHz (high shelf)

  // High-pass filter
  double hpFreq = 20.0;   // Hz  (20–1000)
  double hpRes  = 0.5;    // resonance 0–1

  // Low-pass filter
  double lpFreq = 20000.0; // Hz  (1000–20000)
  double lpRes  = 0.5;     // resonance 0–1

  // Master limiter threshold in dB (−24 … 0; 0 = ceiling only)
  double limiterThreshold = 0.0;

  // Master output volume (0–1)
  double masterVolume = 0.8;
}

class TrackerModel {
  Song song = Song();
  List<Chain> chains = List.generate(99, (_) => Chain());
  List<Phrase> phrases = List.generate(99, (_) => Phrase());
  List<Instrument> instruments = List.generate(99, (_) => Instrument());
  List<MixerChannel> mixerChannels = List.generate(8, (_) => MixerChannel());
  MasterFx masterFx = MasterFx();

  // Playback state
  bool isPlaying = false;
  bool isLooping = false;

  // Phrase window — remembered last values for quick insert
  int lastPhraseNote       = 60; // C-4
  int lastPhraseInstrument = 1;
  List<double> audioLevels = List.filled(8, 0.0); // linear peak 0..1 per channel
  double masterPeak = 0.0;                         // post-limiter master bus peak 0..1

  // Per-track mute / solo (M8-style: solo wins). Affects only newly enqueued rows.
  final Set<int> mutedTracks  = <int>{};
  final Set<int> soloedTracks = <int>{};

  /// Returns true if track [t] should be audible given current mute/solo state.
  bool isTrackAudible(int t) {
    if (soloedTracks.isNotEmpty) return soloedTracks.contains(t);
    return !mutedTracks.contains(t);
  }

  /// Toggle solo for track [t]. If t was the only soloed track, clears all solos.
  void toggleSolo(int t) {
    if (soloedTracks.contains(t)) {
      soloedTracks.remove(t);
    } else {
      soloedTracks.add(t);
    }
  }

  // ── Undo / Redo ──────────────────────────────────────────────────────────
  // Snapshots are lightweight Map clones of the editable tracker grids.
  // Cap at 64 snapshots; oldest dropped first.
  static const int _maxUndo = 64;
  final List<Map<String, dynamic>> _undoStack = [];
  final List<Map<String, dynamic>> _redoStack = [];

  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  /// Snapshot the currently editable state (song grid, chains, phrases,
  /// instruments [non-sampler fields], mixer, masterFx). Call BEFORE mutating.
  /// Clears the redo stack — any new edit invalidates redo history.
  void pushUndo() {
    _undoStack.add(_snapshot());
    if (_undoStack.length > _maxUndo) _undoStack.removeAt(0);
    _redoStack.clear();
  }

  void undo() {
    if (_undoStack.isEmpty) return;
    _redoStack.add(_snapshot());
    _restore(_undoStack.removeLast());
  }

  void redo() {
    if (_redoStack.isEmpty) return;
    _undoStack.add(_snapshot());
    _restore(_redoStack.removeLast());
  }

  void clearUndoHistory() {
    _undoStack.clear();
    _redoStack.clear();
  }

  Map<String, dynamic> _snapshot() {
    return {
      'songChains': [for (final r in song.chains) List<int>.from(r)],
      'bpm': song.bpm,
      'lpb': song.lpb,
      'chains': [
        for (final ch in chains)
          [
            for (final it in ch.items)
              {
                'p': it.phrase,
                't': it.transpose,
                'fx': [for (final f in it.fx) [f.name, f.value]],
              }
          ]
      ],
      'phrases': [
        for (final ph in phrases)
          [
            for (final st in ph.steps)
              {
                'n': st.note,
                'i': st.instrument,
                'v': st.volume,
                'fx': [for (final f in st.fx) [f.name, f.value]],
              }
          ]
      ],
      'instruments': [
        for (final inst in instruments)
          {
            'filter': inst.filter,
            'resonance': inst.resonance,
            'treble': inst.treble,
            'mid': inst.mid,
            'bass': inst.bass,
          }
      ],
      'mixer': [
        for (final ch in mixerChannels)
          [ch.level, ch.reverbSend, ch.delaySend, ch.chorusSend]
      ],
    };
  }

  void _restore(Map<String, dynamic> s) {
    final sc = s['songChains'] as List;
    for (int r = 0; r < 99 && r < sc.length; r++) {
      final row = sc[r] as List;
      for (int c = 0; c < 8 && c < row.length; c++) {
        song.chains[r][c] = row[c] as int;
      }
    }
    song.bpm = s['bpm'] as int? ?? song.bpm;
    song.lpb = s['lpb'] as int? ?? song.lpb;
    final ch = s['chains'] as List;
    for (int i = 0; i < 99 && i < ch.length; i++) {
      final items = ch[i] as List;
      for (int j = 0; j < 99 && j < items.length; j++) {
        final m = items[j] as Map;
        chains[i].items[j].phrase    = m['p'] as int;
        chains[i].items[j].transpose = m['t'] as int;
        final fx = m['fx'] as List;
        for (int k = 0; k < chains[i].items[j].fx.length && k < fx.length; k++) {
          chains[i].items[j].fx[k].name  = (fx[k] as List)[0] as String;
          chains[i].items[j].fx[k].value = (fx[k] as List)[1] as int;
        }
      }
    }
    final ph = s['phrases'] as List;
    for (int i = 0; i < 99 && i < ph.length; i++) {
      final steps = ph[i] as List;
      for (int j = 0; j < 99 && j < steps.length; j++) {
        final m = steps[j] as Map;
        phrases[i].steps[j].note       = m['n'] as int;
        phrases[i].steps[j].instrument = m['i'] as int;
        phrases[i].steps[j].volume     = m['v'] as int;
        final fx = m['fx'] as List;
        for (int k = 0; k < phrases[i].steps[j].fx.length && k < fx.length; k++) {
          phrases[i].steps[j].fx[k].name  = (fx[k] as List)[0] as String;
          phrases[i].steps[j].fx[k].value = (fx[k] as List)[1] as int;
        }
      }
    }
    final ins = s['instruments'] as List;
    for (int i = 0; i < 99 && i < ins.length; i++) {
      final m = ins[i] as Map;
      instruments[i].filter    = m['filter']    as int;
      instruments[i].resonance = m['resonance'] as int;
      instruments[i].treble    = m['treble']    as int;
      instruments[i].mid       = m['mid']       as int;
      instruments[i].bass      = m['bass']      as int;
    }
    final mx = s['mixer'] as List;
    for (int i = 0; i < 8 && i < mx.length; i++) {
      final row = mx[i] as List;
      mixerChannels[i].level      = row[0] as int;
      mixerChannels[i].reverbSend = row[1] as int;
      mixerChannels[i].delaySend  = row[2] as int;
      mixerChannels[i].chorusSend = row[3] as int;
    }
  }

  // --- Song playback position ---
  int playheadRow = 0;        // which song row is currently playing
  int playheadChainRow = 0;   // which chain slot (row) is currently playing
  int chainPhraseIndex = 0;   // which phrase-slot index we're on within the chains
  int phraseStep = 0;         // current step within the current phrase slot
  int masterStepLength = 0;   // max phrase length across all active tracks at current slot

  // Derived: per-track phrase indices (which actual phrase each track is playing)
  // computed on demand from song.chains and chains data

  /// Get the Phrase being played on a given track at the current playback position.
  /// Returns null if the track is empty or chain is exhausted.
  Phrase? getPlayingPhrase(int track) {
    final chainRef = song.chains[playheadRow][track];
    if (chainRef == 0) return null;
    final chainIndex = chainRef - 1;
    final chain = chains[chainIndex];
    // Find how many non-zero phrase entries the chain has
    final phraseEntries = chain.items
        .where((item) => item.phrase != 0)
        .toList();
    if (chainPhraseIndex >= phraseEntries.length) return null;
    final phraseRef = phraseEntries[chainPhraseIndex].phrase;
    if (phraseRef == 0) return null;
    return phrases[phraseRef - 1];
  }

  /// Compute master step length = max phrase.length across all active tracks
  int computeMasterStepLength() {
    int maxLen = 0;
    for (int t = 0; t < 8; t++) {
      final phrase = getPlayingPhrase(t);
      if (phrase != null && phrase.length > maxLen) {
        maxLen = phrase.length;
      }
    }
    return maxLen == 0 ? 16 : maxLen;
  }

  /// How many phrase entries does the longest chain on the current row have?
  int computeChainLength() {
    int maxLen = 0;
    for (int t = 0; t < 8; t++) {
      final chainRef = song.chains[playheadRow][t];
      if (chainRef == 0) continue;
      final chain = chains[chainRef - 1];
      final count = chain.items.where((item) => item.phrase != 0).length;
      if (count > maxLen) maxLen = count;
    }
    return maxLen;
  }

  /// Check if a song row is completely empty (all 8 tracks = 0)
  bool isSongRowEmpty(int row) {
    return song.chains[row].every((ref) => ref == 0);
  }

  /// Returns the smallest chain number (1-99) whose chain data is completely
  /// empty (no phrases assigned), or -1 if every chain slot is in use.
  int firstAvailableChain() {
    for (int i = 0; i < 99; i++) {
      if (chains[i].items.every((item) => item.phrase == 0)) {
        return i + 1;
      }
    }
    return -1;
  }

  /// Returns the smallest phrase number (1-99) whose phrase data is completely
  /// empty (all steps have note == noteNone or noteEnd), or -1 if all are in use.
  int firstAvailablePhrase() {
    for (int i = 0; i < 99; i++) {
      if (_isPhraseEmpty(i)) return i + 1;
    }
    return -1;
  }

  /// Call this when PLAY is pressed — initialises playback from cursor row
  void startPlayback() {
    playheadRow = cursorRow;
    chainPhraseIndex = 0;
    phraseStep = 0;
    masterStepLength = computeMasterStepLength();
    isPlaying = true;
  }

  void stopPlayback() {
    isPlaying = false;
  }

  /// Create a new song, clearing all data and resetting UI state
  void newSong() {
    // Clear all song data
    song = Song();
    chains = List.generate(99, (_) => Chain());
    phrases = List.generate(99, (_) => Phrase());
    instruments = List.generate(99, (_) => Instrument());
    mixerChannels = List.generate(8, (_) => MixerChannel());

    // Reset playback state
    isPlaying = false;
    isLooping = false;
    playheadRow = 0;
    chainPhraseIndex = 0;
    phraseStep = 0;
    masterStepLength = 0;
    audioLevels = List.filled(8, 0.0);
    masterPeak = 0.0;

    // Reset UI state
    currentWindow = 0;
    activeChainIdx = 0;
    activePhraseIdx = 0;
    cursorRow = 0;
    cursorCol = 0;
    scrollRow = 0;

    // Reset edit/menu state
    inEditMode = false;
    editingBPM = false;
    projectMenuVisible = false;
    editBuffer = '';
    editMaxChars = 2;
    inMenuMode = false;
    menuCursor = 0;
    editMenuVisible = false;
    editMenuRow = -1;
    editMenuCol = -1;
    editMenuWindow = -1;
    copyBuffer = '';

    mutedTracks.clear();
    soloedTracks.clear();
    clearUndoHistory();
  }

  /// Returns true if phrase [idx] (0-based) is completely empty.
  bool _isPhraseEmpty(int idx) =>
      phrases[idx].steps.every((s) => s.note == PhraseStep.noteNone || s.note == PhraseStep.noteEnd);

  /// Deep-copy phrase [srcIdx] → [dstIdx] (both 0-based).
  void _copyPhrase(int srcIdx, int dstIdx) {
    final src = phrases[srcIdx];
    final dst = phrases[dstIdx];
    dst.length = src.length;
    for (int i = 0; i < src.steps.length && i < dst.steps.length; i++) {
      final s = src.steps[i];
      final d = dst.steps[i];
      d.note       = s.note;
      d.instrument = s.instrument;
      d.volume     = s.volume;
      for (int f = 0; f < s.fx.length && f < d.fx.length; f++) {
        d.fx[f].name  = s.fx[f].name;
        d.fx[f].value = s.fx[f].value;
      }
    }
  }

  /// Replicate the selected chain: copy it to the next free chain number and update the cell.
  /// M8-style: each phrase referenced by the source chain is also duplicated into a
  /// new empty phrase number, and the new chain's slots are remapped to those copies.
  /// Phrases listed multiple times in the source chain are deduplicated (one copy each).
  void replicateChain() {
    if (currentWindow != 0) return; // Only for Song window

    final sourceChainNum = song.chains[cursorRow][cursorCol];
    if (sourceChainNum <= 0 || sourceChainNum > 99) return; // Invalid chain

    final sourceIdx = sourceChainNum - 1;

    // Find the next free chain number (one that has no phrase data)
    final targetChainNum = firstAvailableChain();
    if (targetChainNum <= 0) return; // No free chain available
    final targetIdx = targetChainNum - 1;

    // Build a map of original phrase number → new (duplicated) phrase number.
    // Allocate one new empty phrase per unique non-zero phrase ref in the source.
    final Map<int, int> phraseRemap = {};
    final Set<int> reserved = {}; // phrase indices we've already used as targets
    for (final item in chains[sourceIdx].items) {
      final pn = item.phrase;
      if (pn <= 0 || phraseRemap.containsKey(pn)) continue;
      int newPn = -1;
      for (int i = 0; i < 99; i++) {
        if (reserved.contains(i)) continue;
        if (_isPhraseEmpty(i)) { newPn = i + 1; break; }
      }
      if (newPn == -1) break; // out of free phrase slots — keep original ref for the rest
      reserved.add(newPn - 1);
      _copyPhrase(pn - 1, newPn - 1);
      phraseRemap[pn] = newPn;
    }

    // Deep copy chain items, remapping phrase refs through the map.
    for (int i = 0; i < chains[sourceIdx].items.length; i++) {
      final srcItem = chains[sourceIdx].items[i];
      final newPhrase = phraseRemap[srcItem.phrase] ?? srcItem.phrase;
      chains[targetIdx].items[i].phrase    = newPhrase;
      chains[targetIdx].items[i].transpose = srcItem.transpose;
      for (int f = 0; f < srcItem.fx.length; f++) {
        chains[targetIdx].items[i].fx[f].name  = srcItem.fx[f].name;
        chains[targetIdx].items[i].fx[f].value = srcItem.fx[f].value;
      }
    }

    // Update the current cell to point to the new chain
    song.chains[cursorRow][cursorCol] = targetChainNum;
  }

  /// Replicate the phrase in the current chain row: copy it to the first free
  /// phrase slot and update the chain cell to point to the new phrase.
  void replicatePhrase() {
    if (currentWindow != 1) return;

    final sourcePhraseNum = chains[activeChainIdx].items[cursorRow].phrase;
    if (sourcePhraseNum <= 0 || sourcePhraseNum > 99) return;

    final targetPhraseNum = firstAvailablePhrase();
    if (targetPhraseNum <= 0) return;

    _copyPhrase(sourcePhraseNum - 1, targetPhraseNum - 1);
    chains[activeChainIdx].items[cursorRow].phrase = targetPhraseNum;
    activePhraseIdx = targetPhraseNum - 1;
  }

  /// Call this from a BPM timer.
  bool advanceStep() {
    if (!isPlaying) return false;

    phraseStep++;

    if (phraseStep >= masterStepLength) {
      // Current phrase slot finished — advance to next phrase in chain
      phraseStep = 0;
      chainPhraseIndex++;

      final chainLen = computeChainLength();

      if (chainPhraseIndex >= chainLen) {
        // All phrases in chains on this row finished — advance song row
        chainPhraseIndex = 0;
        playheadRow++;

        // Stop if out of bounds or row is empty
        if (playheadRow >= 99 || isSongRowEmpty(playheadRow)) {
          if (isLooping) {
            // Loop: find first non-empty row from cursor
            playheadRow = cursorRow;
            while (playheadRow < 99 && isSongRowEmpty(playheadRow)) {
              playheadRow++;
            }
            if (playheadRow >= 99 || isSongRowEmpty(playheadRow)) {
              stopPlayback();
              return true;
            }
          } else {
            stopPlayback();
            return true;
          }
        }
      }

      masterStepLength = computeMasterStepLength();
    }

    return true;
  }

  // State
  int currentWindow = 0; // 0=Song, 1=Chain, 2=Phrase, 3=Instrument, 4=Mixer

  // Which chain / phrase is currently "open" in the Chain/Phrase windows.
  // Set when the user navigates into those windows.
  int activeChainIdx  = 0;  // 0-based index into model.chains
  int activePhraseIdx = 0;  // 0-based index into model.phrases
  int cursorRow = 0;
  int cursorCol = 0;
  int scrollRow = 0;

  bool inEditMode = false;
  bool editingBPM = false;
  bool projectMenuVisible = false;
  String editBuffer = '';
  int editMaxChars = 2;

  bool inMenuMode = false;
  int menuCursor = 0;

  // Double-click detection
  int lastClickedRow = -1;
  int lastClickedCol = -1;
  int lastClickedWindow = -1;
  DateTime lastClickTime = DateTime.now();

  // Copy/paste buffer
  String copyBuffer = '';

  // ── Line selection (row-level, for move/duplicate) ──────────────────────
  int? lineSelStart;
  int? lineSelEnd;

  bool get hasLineSelection => lineSelStart != null;

  /// Returns (min, max) of the selected row range, always min ≤ max.
  (int, int) get lineSelRange {
    final a = lineSelStart!, b = lineSelEnd ?? lineSelStart!;
    return a <= b ? (a, b) : (b, a);
  }

  bool isRowInLineSelection(int row) {
    if (!hasLineSelection) return false;
    final (min, max) = lineSelRange;
    return row >= min && row <= max;
  }

  /// First tap: anchors selection at [row]. Subsequent taps: extend to [row].
  void selectLine(int row) {
    if (lineSelStart == null) {
      lineSelStart = row;
      lineSelEnd   = row;
    } else {
      lineSelEnd = row;
    }
    // Exit cell edit mode when in line selection
    inEditMode       = false;
    editBuffer       = '';
    editMenuVisible  = true;
  }

  void clearLineSelection() {
    lineSelStart    = null;
    lineSelEnd      = null;
    editMenuVisible = false;
  }

  // ── Row-level helpers ────────────────────────────────────────────────────

  bool _isSongRowEmpty(int row) =>
      song.chains[row].every((v) => v == 0);

  bool _isChainRowEmpty(int row) =>
      chains[activeChainIdx].items[row].phrase == 0;

  bool _isPhraseRowEmpty(int row) =>
      phrases[activePhraseIdx].steps[row].note == PhraseStep.noteNone;

  bool _isCurrentWindowRowEmpty(int row) {
    if (currentWindow == 0) return _isSongRowEmpty(row);
    if (currentWindow == 1) return _isChainRowEmpty(row);
    if (currentWindow == 2) return _isPhraseRowEmpty(row);
    return true;
  }

  /// Copy row [src] content into row [dest] for the active window.
  void _copyRow(int dest, int src) {
    if (currentWindow == 0) {
      for (int c = 0; c < song.chains[src].length; c++) {
        song.chains[dest][c] = song.chains[src][c];
      }
    } else if (currentWindow == 1) {
      final s = chains[activeChainIdx].items[src];
      final d = chains[activeChainIdx].items[dest];
      d.phrase    = s.phrase;
      d.transpose = s.transpose;
      for (int i = 0; i < s.fx.length && i < d.fx.length; i++) {
        d.fx[i].name  = s.fx[i].name;
        d.fx[i].value = s.fx[i].value;
      }
    } else if (currentWindow == 2) {
      final s = phrases[activePhraseIdx].steps[src];
      final d = phrases[activePhraseIdx].steps[dest];
      d.note       = s.note;
      d.instrument = s.instrument;
      d.volume     = s.volume;
      for (int i = 0; i < s.fx.length && i < d.fx.length; i++) {
        d.fx[i].name  = s.fx[i].name;
        d.fx[i].value = s.fx[i].value;
      }
    }
  }

  /// Clear row [row] to its empty state for the active window.
  void _clearRow(int row) {
    if (currentWindow == 0) {
      for (int c = 0; c < song.chains[row].length; c++) {
        song.chains[row][c] = 0;
      }
    } else if (currentWindow == 1) {
      final item = chains[activeChainIdx].items[row];
      item.phrase    = 0;
      item.transpose = 0;
      for (final f in item.fx) { f.name = '---'; f.value = 0; }
    } else if (currentWindow == 2) {
      final step = phrases[activePhraseIdx].steps[row];
      step.note       = PhraseStep.noteNone;
      step.instrument = 0;
      step.volume     = 80;
      for (final f in step.fx) { f.name = '---'; f.value = 0; }
    }
  }

  /// Move selected lines up by one row (blocked if row above is occupied).
  void moveSelectionUp() {
    if (!hasLineSelection) return;
    final (minR, maxR) = lineSelRange;
    if (minR == 0) return;
    if (!_isCurrentWindowRowEmpty(minR - 1)) return;
    for (int r = minR; r <= maxR; r++) {
      _copyRow(r - 1, r);
    }
    _clearRow(maxR);
    lineSelStart = lineSelStart! - 1;
    lineSelEnd   = (lineSelEnd ?? lineSelStart! + 1) - 1;
  }

  /// Move selected lines down by one row (blocked if row below is occupied).
  void moveSelectionDown() {
    if (!hasLineSelection) return;
    final (minR, maxR) = lineSelRange;
    if (maxR >= 98) return;
    if (!_isCurrentWindowRowEmpty(maxR + 1)) return;
    for (int r = maxR; r >= minR; r--) {
      _copyRow(r + 1, r);
    }
    _clearRow(minR);
    lineSelStart = lineSelStart! + 1;
    lineSelEnd   = (lineSelEnd ?? lineSelStart! - 1) + 1;
  }

  /// Duplicate selected lines into the rows immediately below (if space).
  void duplicateSelection() {
    if (!hasLineSelection) return;
    final (minR, maxR) = lineSelRange;
    final count = maxR - minR + 1;
    if (maxR + count > 98) return; // Not enough room
    for (int i = 1; i <= count; i++) {
      if (!_isCurrentWindowRowEmpty(maxR + i)) return; // Collision
    }
    for (int i = 0; i < count; i++) {
      _copyRow(maxR + 1 + i, minR + i);
    }
  }

  /// Clear (DEL) all rows in the current line selection.
  void clearSelectedLines() {
    if (!hasLineSelection) return;
    final (minR, maxR) = lineSelRange;
    for (int r = minR; r <= maxR; r++) {
      _clearRow(r);
    }
  }

  // Edit menu state
  bool editMenuVisible = false;
  int editMenuRow = -1;
  int editMenuCol = -1;
  int editMenuWindow = -1;

  void enterEditMode() {
    inEditMode = true;
    editBuffer = '';
    editMaxChars = 2;
  }

  void exitEditMode() {
    inEditMode = false;
    editBuffer = '';
  }

  void applyEdit(String value) {
    if (value.isEmpty) return;

    int intValue = int.tryParse(value) ?? 0;

    if (currentWindow == 0) {
      // Song: chain references (0-99, where 0 = empty)
      intValue = intValue.clamp(0, 99);
      song.chains[cursorRow][cursorCol] = intValue;
    } else if (currentWindow == 1) {
      // Chain — edit the active chain's items
      if (cursorCol == 0) {
        intValue = intValue.clamp(0, 99);
        chains[activeChainIdx].items[cursorRow].phrase = intValue;
      } else if (cursorCol == 1) {
        // Valid transpose range: 0–12 (semitones up) and 88–99 (semitones down).
        // Values 13–87 snap to the nearest valid boundary.
        intValue = intValue.clamp(0, 99);
        if (intValue > 12 && intValue < 88) {
          intValue = intValue <= 50 ? 12 : 88;
        }
        chains[activeChainIdx].items[cursorRow].transpose = intValue;
      } else {
        // FX columns: col 2=FX1 name, 3=FX1 val, 4=FX2 name, 5=FX2 val
        final fxIndex = (cursorCol - 2) ~/ 2;
        final isValue = (cursorCol - 2) % 2 == 1;
        if (fxIndex < chains[activeChainIdx].items[cursorRow].fx.length) {
          if (isValue) {
            chains[activeChainIdx].items[cursorRow].fx[fxIndex].value =
                intValue.clamp(0, 99);
          }
          // FX name is set via the FX command picker, not free numeric entry
        }
      }
    } else if (currentWindow == 2) {
      // Phrase — edit the active phrase's steps
      if (cursorCol == 0) {
        if (intValue < -1) intValue = -1;
        if (intValue > 120) intValue = 120;
        phrases[activePhraseIdx].steps[cursorRow].note = intValue;
      } else if (cursorCol == 1) {
        intValue = intValue.clamp(0, 99);
        phrases[activePhraseIdx].steps[cursorRow].instrument = intValue;
      } else if (cursorCol == 2) {
        intValue = intValue.clamp(0, 99);
        phrases[activePhraseIdx].steps[cursorRow].volume = intValue;
      } else if (cursorCol >= 3) {
        // FX columns: col 3=FX1 name, 4=FX1 val, 5=FX2 name, 6=FX2 val
        final fxIndex = (cursorCol - 3) ~/ 2;
        final isValue = (cursorCol - 3) % 2 == 1;
        if (isValue && fxIndex < phrases[activePhraseIdx].steps[cursorRow].fx.length) {
          phrases[activePhraseIdx].steps[cursorRow].fx[fxIndex].value =
              intValue.clamp(0, 99);
        }
      }
    } else if (currentWindow == 3) {
      // Instrument
      intValue = intValue.clamp(0, 99);
      var inst = instruments[cursorRow];
      if (cursorCol == 3) {
        inst.filter = intValue;
      } else if (cursorCol == 4) inst.resonance = intValue;
      else if (cursorCol == 5) inst.treble = intValue;
      else if (cursorCol == 6) inst.mid = intValue;
      else if (cursorCol == 7) inst.bass = intValue;
    } else if (currentWindow == 4) {
      // Mixer: LVL / RVB / DLY / CHO (rows) x CH 01-08 (columns)
      // All values 0-99
      intValue = intValue.clamp(0, 99);
      var ch = mixerChannels[cursorCol]; // cursorCol is the channel (0-7)
      if (cursorRow == 0) {
        // Level 0-99
        ch.level = intValue;
      } else if (cursorRow == 1) {
        // Reverb Send 0-99
        ch.reverbSend = intValue;
      } else if (cursorRow == 2) {
        // Delay Send 0-99
        ch.delaySend = intValue;
      } else if (cursorRow == 3) {
        // Chorus Send 0-99
        ch.chorusSend = intValue;
      }
    }

    exitEditMode();
  }

  bool isDoubleClick(int row, int col, int window) {
    const doubleClickThreshold = 500; // milliseconds
    final now = DateTime.now();
    final elapsed = now.difference(lastClickTime).inMilliseconds;

    if (lastClickedRow == row && lastClickedCol == col && lastClickedWindow == window && elapsed < doubleClickThreshold) {
      return true;
    }

    lastClickedRow = row;
    lastClickedCol = col;
    lastClickedWindow = window;
    lastClickTime = now;
    return false;
  }

  void insertDefaultValue() {
    if (currentWindow == 0) {
      // Song: 01
      song.chains[cursorRow][cursorCol] = 1;
    } else if (currentWindow == 1) {
      // Chain: default phrase = 01
      if (cursorCol == 0) {
        chains[activeChainIdx].items[cursorRow].phrase = 1;
      } else if (cursorCol == 1) {
        chains[activeChainIdx].items[cursorRow].transpose = 0;
      } else {
        final fxIndex = (cursorCol - 2) ~/ 2;
        final isValue = (cursorCol - 2) % 2 == 1;
        if (fxIndex < chains[activeChainIdx].items[cursorRow].fx.length) {
          if (!isValue) {
            chains[activeChainIdx].items[cursorRow].fx[fxIndex].name = 'ARP';
          } else {
            chains[activeChainIdx].items[cursorRow].fx[fxIndex].value = 0;
          }
        }
      }
    } else if (currentWindow == 2) {
      // Phrase
      if (cursorCol == 0) {
        phrases[activePhraseIdx].steps[cursorRow].instrument = 1;
      } else if (cursorCol == 1) {
        phrases[activePhraseIdx].steps[cursorRow].volume = 80;
      } else if (cursorCol >= 2) {
        int fxIndex = (cursorCol - 2) ~/ 2;
        if (fxIndex < phrases[activePhraseIdx].steps[cursorRow].fx.length) {
          phrases[activePhraseIdx].steps[cursorRow].fx[fxIndex].name = 'ARP';
          phrases[activePhraseIdx].steps[cursorRow].fx[fxIndex].value = 0;
        }
      }
    } else if (currentWindow == 3) {
      // Instrument: 01
      var inst = instruments[cursorRow];
      if (cursorCol == 3) {
        inst.filter = 1;
      } else if (cursorCol == 4) inst.resonance = 1;
      else if (cursorCol == 5) inst.treble = 1;
      else if (cursorCol == 6) inst.mid = 1;
      else if (cursorCol == 7) inst.bass = 1;
    } else if (currentWindow == 4) {
      // Mixer: 80
      var ch = mixerChannels[cursorCol];
      if (cursorRow == 0) {
        ch.level = 80;
      } else if (cursorRow == 1) ch.reverbSend = 80;
      else if (cursorRow == 2) ch.delaySend = 80;
      else if (cursorRow == 3) ch.chorusSend = 80;
    }

    editMenuVisible = true;
    editMenuRow = cursorRow;
    editMenuCol = cursorCol;
    editMenuWindow = currentWindow;
  }

  void performMenuAction(String action) {
    int currentValue = getCurrentCellValue();

    // For the note column (window 2, col 0): activating an empty note starts at C-4 (MIDI 60)
    final bool isNoteCol = currentWindow == 2 && cursorCol == 0;

    if (action == '+') {
      if (isNoteCol && currentValue < 0) {
        applyEdit('60'); // C-4
      } else {
        applyEdit((currentValue + 1).toString());
      }
    } else if (action == '−' || action == '-') {
      if (isNoteCol && currentValue < 0) {
        applyEdit('60'); // C-4
      } else {
        applyEdit((currentValue - 1).toString());
      }
    } else if (action == '+10') {
      if (isNoteCol && currentValue < 0) {
        applyEdit('60');
      } else {
        applyEdit((currentValue + 10).toString());
      }
    } else if (action == '−10' || action == '-10') {
      if (isNoteCol && currentValue < 0) {
        applyEdit('60');
      } else {
        applyEdit((currentValue - 10).toString());
      }
    } else if (action == '+12') {
      if (isNoteCol && currentValue < 0) {
        applyEdit('60');
      } else {
        applyEdit((currentValue + 12).toString());
      }
    } else if (action == '−12' || action == '-12') {
      if (isNoteCol && currentValue < 0) {
        applyEdit('60');
      } else {
        applyEdit((currentValue - 12).toString());
      }
    } else if (action == 'DEL') {
      if (currentWindow == 2 && cursorCol == 0) {
        // Phrase note column: empty = noteNone (-1), not MIDI note 0
        phrases[activePhraseIdx].steps[cursorRow].note = PhraseStep.noteNone;
        exitEditMode();
      } else {
        applyEdit('0');
      }
    } else if (action == 'CPY') {
      copyBuffer = getCurrentCellValueAsString();
    } else if (action == 'CUT') {
      copyBuffer = getCurrentCellValueAsString();
      applyEdit('0');
    } else if (action == 'PST') {
      if (copyBuffer.isNotEmpty) {
        applyEdit(copyBuffer);
      }
    } else if (action == 'CLO') {
      if (currentWindow == 0) {
        replicateChain();
      } else if (currentWindow == 1) replicatePhrase();
    } else if (action == 'OFF') {
      // Note off marker — only meaningful in phrase note column
      if (currentWindow == 2 && cursorCol == 0) {
        phrases[activePhraseIdx].steps[cursorRow].note = PhraseStep.noteOff;
      }
    } else if (action == 'END') {
      // End marker — only meaningful in phrase note column
      if (currentWindow == 2 && cursorCol == 0) {
        phrases[activePhraseIdx].steps[cursorRow].note = PhraseStep.noteEnd;
      }
    }
  }

  int getCurrentCellValue() {
    if (currentWindow == 0) {
      return song.chains[cursorRow][cursorCol];
    } else if (currentWindow == 1) {
      if (cursorCol == 0) return chains[activeChainIdx].items[cursorRow].phrase;
      if (cursorCol == 1) return chains[activeChainIdx].items[cursorRow].transpose;
      // FX cols: 2=FX1 name, 3=FX1 val, 4=FX2 name, 5=FX2 val
      final fxIndex = (cursorCol - 2) ~/ 2;
      final isValue = (cursorCol - 2) % 2 == 1;
      if (fxIndex < chains[activeChainIdx].items[cursorRow].fx.length) {
        return isValue ? chains[activeChainIdx].items[cursorRow].fx[fxIndex].value : 0;
      }
      return 0;
    } else if (currentWindow == 2) {
      if (cursorCol == 0) {
        return phrases[activePhraseIdx].steps[cursorRow].note;
      } else if (cursorCol == 1) {
        return phrases[activePhraseIdx].steps[cursorRow].instrument;
      } else if (cursorCol == 2) {
        return phrases[activePhraseIdx].steps[cursorRow].volume;
      } else {
        int fxIndex = (cursorCol - 3) ~/ 2;
        int isValue = (cursorCol - 3) % 2;
        if (fxIndex < phrases[activePhraseIdx].steps[cursorRow].fx.length) {
          return isValue == 1 ? phrases[activePhraseIdx].steps[cursorRow].fx[fxIndex].value : 0;
        }
      }
    } else if (currentWindow == 3) {
      var inst = instruments[cursorRow];
      if (cursorCol == 3) {
        return inst.filter;
      } else if (cursorCol == 4) return inst.resonance;
      else if (cursorCol == 5) return inst.treble;
      else if (cursorCol == 6) return inst.mid;
      else if (cursorCol == 7) return inst.bass;
    } else if (currentWindow == 4) {
      var ch = mixerChannels[cursorCol];
      if (cursorRow == 0) {
        return ch.level;
      } else if (cursorRow == 1) return ch.reverbSend;
      else if (cursorRow == 2) return ch.delaySend;
      else if (cursorRow == 3) return ch.chorusSend;
    }
    return 0;
  }

  String getCurrentCellValueAsString() {
    if (currentWindow == 2 && cursorCol == 0) {
      // Note column: return display format
      return phrases[activePhraseIdx].steps[cursorRow].getNoteDisplay();
    }
    return getCurrentCellValue().toString().padLeft(2, '0');
  }

  // Sample management
  String? defaultSampleFolder;

  String getSampleDisplayName(int instrumentIndex) {
    final sample = instruments[instrumentIndex].sample;
    if (sample.isEmpty) return '--';
    return sample.split(Platform.pathSeparator).last;
  }

  void loadSampleForInstrument(int instrumentIndex, String samplePath) {
    if (instrumentIndex >= 0 && instrumentIndex < instruments.length) {
      instruments[instrumentIndex].sample = samplePath;
      // Also update the sampler with this sample
      final sampleName = samplePath.split(Platform.pathSeparator).last;
      setSamplerSample(instrumentIndex, samplePath, sampleName);
    }
  }

  // Bookmark a folder as the default sample folder
  Future<void> bookmarkSampleFolder(String folderPath) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      defaultSampleFolder = folderPath;
      await prefs.setString('default_sample_folder', folderPath);
    } catch (e) {
      debugPrint('Error bookmarking sample folder: $e');
    }
  }

  // Remove the bookmark (clear default folder)
  Future<void> removeBookmark() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      defaultSampleFolder = null;
      await prefs.remove('default_sample_folder');
    } catch (e) {
      debugPrint('Error removing bookmark: $e');
    }
  }

  // Load the default sample folder from storage
  Future<void> loadDefaultSampleFolder() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('default_sample_folder');
      if (saved != null && Directory(saved).existsSync()) {
        defaultSampleFolder = saved;
      } else {
        defaultSampleFolder = null;
      }
    } catch (e) {
      debugPrint('Error loading default sample folder: $e');
      defaultSampleFolder = null;
    }
  }

  // Sampler helpers
  SamplerParams getSampler(int instrumentIndex) {
    if (instrumentIndex >= 0 && instrumentIndex < instruments.length) {
      return instruments[instrumentIndex].sampler;
    }
    return SamplerParams.empty();
  }

  void setSamplerSample(int instrumentIndex, String samplePath, String sampleName) {
    if (instrumentIndex >= 0 && instrumentIndex < instruments.length) {
      final sampler = instruments[instrumentIndex].sampler;
      sampler.samplePath = samplePath;
      sampler.sampleName = sampleName;
    }
  }

  void clearSamplerSample(int instrumentIndex) {
    if (instrumentIndex >= 0 && instrumentIndex < instruments.length) {
      instruments[instrumentIndex].sampler.clear();
    }
  }

  // Project management
  String currentProjectName = 'UNTITLED';
  String currentProjectPath = '';

  void setCurrentProject(String projectName, String projectPath) {
    currentProjectName = projectName;
    currentProjectPath = projectPath;
  }

  bool hasProjectPath() {
    return currentProjectPath.isNotEmpty;
  }

  // ---------------------------------------------------------------------------
  // Sequencer row builder — produces packed row data for the native engine
  // ---------------------------------------------------------------------------

  /// Build a flat list of playback rows covering the entire song from [startRow].
  /// Each returned map has:
  ///   'lineSamples' (int) — audio frames this row lasts
  ///   'noteData'    (List<int>) — flat groups of 3 per track:
  ///                              [instrumentIdx, midiNote, volume_0_99]
  ///                              midiNote -1 = hold,  -2 = note off
  ///
  /// The song hierarchy is: song rows → chains → chain-items (phrase slots)
  /// → phrase steps. We unroll the entire hierarchy into one long list of
  /// pattern rows (one per phrase step).
  // -----------------------------------------------------------------------
  // Phrase length: scan for first END marker; fall back to all 99 lines.
  // -----------------------------------------------------------------------
  int _getPhraseLen(Phrase ph) {
    for (int i = 0; i < ph.steps.length; i++) {
      if (ph.steps[i].note == PhraseStep.noteEnd) return i;
    }
    return ph.steps.length; // 99 — play all lines when no END marker is set
  }

  /// Returns the duration in samples for a given absolute step index, applying
  /// swing. Even steps (0, 2, 4…) are the downbeat (longer when swing > 50%),
  /// odd steps are the upbeat (shorter). The pair always sums to 2 × base so
  /// overall tempo is preserved exactly regardless of swing amount.
  ///
  /// [bpm] and [lpb] are the running values at that point in the song.
  /// [stepIndex] is the global row counter used to decide even/odd.
  int _swingLineSamples(int bpm, int lpb, int stepIndex) {
    final int base = (48000.0 * 60.0 / (bpm * lpb)).round();
    final int swing = song.swingPercent;
    if (swing == 50) return base; // straight — no math needed
    final int totalPair = base * 2;
    final int lineA = (base * swing / 50.0).round(); // downbeat (even)
    final int lineB = totalPair - lineA;               // upbeat (odd)
    return stepIndex.isEven ? lineA : lineB;
  }

  // -----------------------------------------------------------------------
  // Build C++ rows for a single chain (chain view playback).
  // Plays chain [chainIdx] on track 0; tracks 1-7 are silent.
  // -----------------------------------------------------------------------
  ({List<Map<String, dynamic>> rows, List<int> songRowMap, List<int> chainRowMap, List<int> phraseStepMap})
      buildChainData(int chainIdx, {int startSlot = 0}) {
    final rows          = <Map<String, dynamic>>[];
    final songRowMap    = <int>[];
    final chainRowMap   = <int>[];
    final phraseStepMap = <int>[];

    int currentBpm = song.bpm;
    int currentLpb = song.lpb;

    final chainItems = chains[chainIdx].items.where((ci) => ci.phrase != 0).toList();
    final clampedStart = startSlot.clamp(0, chainItems.isEmpty ? 0 : chainItems.length - 1);
    for (int slot = clampedStart; slot < chainItems.length; slot++) {
      final ci = chainItems[slot];
      for (final fx in ci.fx) {
        if (fx.name == 'BPM') {
          currentBpm = fxValToBpm(fx.value);
        } else if (fx.name == 'LPB') currentLpb = fx.value.clamp(1, 16);
      }
      final ph  = phrases[ci.phrase - 1];
      final len = _getPhraseLen(ph);
      if (len == 0) continue;

      for (int step = 0; step < len; step++) {
        final ps = ph.steps[step];
        if (ps.note == PhraseStep.noteEnd) break;
        for (final fx in ps.fx) {
          if (fx.name == 'BPM') {
            currentBpm = fxValToBpm(fx.value);
          } else if (fx.name == 'LPB') currentLpb = fx.value.clamp(1, 16);
        }
        final int lineSamples = _swingLineSamples(currentBpm, currentLpb, rows.length);

        int instrIdx = ps.instrument > 0 ? ps.instrument - 1 : -1;
        int midiNote = ps.note;
        if (instrIdx >= 0 && midiNote >= 0 && ci.transpose != 0) {
          final int semitones = ci.transpose <= 12 ? ci.transpose : ci.transpose - 100;
          midiNote = (midiNote + semitones).clamp(0, 120);
        }
        // Slice mode: C-0 to B-0 (MIDI 0-11) routes to instruments 1-12 at unity pitch
        if (midiNote >= 0 && midiNote <= 11) { instrIdx = midiNote; midiNote = 60; }
        final fxIds  = [0, 0, 0];
        final fxVals = [0, 0, 0];
        for (int i = 0; i < ps.fx.length && i < 3; i++) {
          fxIds[i]  = _fxIdForC(ps.fx[i].name);
          fxVals[i] = ps.fx[i].value;
        }
        final noteData = <int>[instrIdx, midiNote, ps.volume];
        for (int i = 0; i < 3; i++) { noteData.add(fxIds[i]); noteData.add(fxVals[i]); }
        for (int t = 1; t < 8; t++) { noteData.addAll([-1, -1, -1, 0, 0, 0, 0, 0, 0]); }

        rows.add({'lineSamples': lineSamples, 'noteData': noteData});
        songRowMap.add(0);
        chainRowMap.add(slot);
        phraseStepMap.add(step);
      }
    }
    return (rows: rows, songRowMap: songRowMap, chainRowMap: chainRowMap, phraseStepMap: phraseStepMap);
  }

  // -----------------------------------------------------------------------
  // Build C++ rows for a single phrase (phrase view playback).
  // -----------------------------------------------------------------------
  ({List<Map<String, dynamic>> rows, List<int> songRowMap, List<int> chainRowMap, List<int> phraseStepMap})
      buildPhraseData(int phraseIdx) {
    final rows = buildPhraseRows(phraseIdx);
    final n = rows.length;
    return (
      rows: rows,
      songRowMap: List.filled(n, 0),
      chainRowMap: List.filled(n, 0),
      phraseStepMap: List.generate(n, (i) => i),
    );
  }

  // -----------------------------------------------------------------------
  // Build C++ rows for ONE song row (Chain-view playback).
  // All 8 tracks play together. Shorter chains loop by modulo; the longest
  // chain decides the total number of slots. Shorter phrases inside a slot
  // also loop by modulo so the longest phrase drives that slot's step count.
  // -----------------------------------------------------------------------
  ({List<Map<String, dynamic>> rows, List<int> songRowMap, List<int> chainRowMap, List<int> phraseStepMap})
      buildSongRowData(int songRow, {int? limitSlots}) {
    final rows          = <Map<String, dynamic>>[];
    final songRowMap    = <int>[];
    final chainRowMap   = <int>[];
    final phraseStepMap = <int>[];

    if (isSongRowEmpty(songRow)) {
      return (rows: rows, songRowMap: songRowMap, chainRowMap: chainRowMap, phraseStepMap: phraseStepMap);
    }

    int currentBpm = song.bpm;
    int currentLpb = song.lpb;
    final rng = Random();

    final trackItems = List<List<ChainItem>>.generate(8, (t) {
      final chainRef = song.chains[songRow][t];
      if (chainRef == 0) return [];
      return chains[chainRef - 1].items.where((ci) => ci.phrase != 0).toList();
    });

    // Use the longest chain unless a limit is given (e.g. chain view caps at
    // the viewed chain's own length so the playhead doesn't overrun it).
    final rawMaxSlots = trackItems.fold(0, (m, l) => l.length > m ? l.length : m);
    final maxSlots = limitSlots != null ? rawMaxSlots.clamp(0, limitSlots) : rawMaxSlots;

    for (int slot = 0; slot < maxSlots; slot++) {
      // Chain-level FX: BPM and LPB
      for (int t = 0; t < 8; t++) {
        if (trackItems[t].isEmpty) continue;
        final ci = trackItems[t][slot % trackItems[t].length];
        for (final fx in ci.fx) {
          if (fx.name == 'BPM') {
            currentBpm = fxValToBpm(fx.value);
          } else if (fx.name == 'LPB') currentLpb = fx.value.clamp(1, 16);
        }
      }

      int maxSteps = 0;
      for (int t = 0; t < 8; t++) {
        if (trackItems[t].isEmpty) continue;
        final ci = trackItems[t][slot % trackItems[t].length];
        final len = _getPhraseLen(phrases[ci.phrase - 1]);
        if (len > maxSteps) maxSteps = len;
      }
      if (maxSteps == 0) continue;

      for (int step = 0; step < maxSteps; step++) {
        // Step-level BPM/LPB
        for (int t = 0; t < 8; t++) {
          if (trackItems[t].isEmpty) continue;
          final ci = trackItems[t][slot % trackItems[t].length];
          final ph = phrases[ci.phrase - 1];
          final phraseLen = _getPhraseLen(ph);
          if (phraseLen == 0) continue;
          final ps = ph.steps[step % phraseLen];
          for (final fx in ps.fx) {
            if (fx.name == 'BPM') {
              currentBpm = fxValToBpm(fx.value);
            } else if (fx.name == 'LPB') currentLpb = fx.value.clamp(1, 16);
          }
        }

        final int lineSamples = _swingLineSamples(currentBpm, currentLpb, rows.length);
        final noteData = <int>[];

        for (int t = 0; t < 8; t++) {
          if (trackItems[t].isEmpty || !isTrackAudible(t)) {
            noteData.addAll([-1, -1, -1, 0, 0, 0, 0, 0, 0]);
            continue;
          }
          final ci = trackItems[t][slot % trackItems[t].length];
          final ph = phrases[ci.phrase - 1];
          final phraseLen = _getPhraseLen(ph);
          if (phraseLen == 0) { noteData.addAll([-1, -1, -1, 0, 0, 0, 0, 0, 0]); continue; }
          final ps = ph.steps[step % phraseLen];

          int instrIdx = ps.instrument > 0 ? ps.instrument - 1 : -1;
          int midiNote = ps.note;

          if (instrIdx >= 0 && midiNote >= 0 && ci.transpose != 0) {
            final int semitones = ci.transpose <= 12 ? ci.transpose : ci.transpose - 100;
            midiNote = (midiNote + semitones).clamp(0, 120);
          }
          // Slice mode: C-0 to B-0 (MIDI 0-11) routes to instruments 1-12 at unity pitch
          if (midiNote >= 0 && midiNote <= 11) { instrIdx = midiNote; midiNote = 60; }

          if (instrIdx >= 0) {
            for (final fx in ps.fx) {
              if (fx.name == 'CHA') {
                if (rng.nextInt(100) >= fx.value) { instrIdx = -1; midiNote = -1; }
                break;
              }
            }
          }

          int? chainVol, chainPan, chainSnr, chainSnd, chainSnc;
          for (final cfx in ci.fx) {
            if (cfx.name == 'VOL') {
              chainVol = cfx.value;
            } else if (cfx.name == 'PAN') chainPan = cfx.value;
            else if (cfx.name == 'SNR') chainSnr = cfx.value;
            else if (cfx.name == 'SND') chainSnd = cfx.value;
            else if (cfx.name == 'SNC') chainSnc = cfx.value;
          }

          final packedVol = chainVol ?? ps.volume;
          final fxIds  = [0, 0, 0];
          final fxVals = [0, 0, 0];
          for (int i = 0; i < ps.fx.length && i < 3; i++) {
            fxIds[i]  = _fxIdForC(ps.fx[i].name);
            fxVals[i] = ps.fx[i].value;
          }
          for (final entry in [
            (kFxId['PAN'], chainPan),
            (kFxId['SNR'], chainSnr),
            (kFxId['SND'], chainSnd),
            (kFxId['SNC'], chainSnc),
          ]) {
            final id = entry.$1; final val = entry.$2;
            if (id == null || val == null || fxIds.contains(id)) continue;
            final emptyIdx = fxIds.indexOf(0);
            if (emptyIdx == -1) break;
            fxIds[emptyIdx] = id; fxVals[emptyIdx] = val;
          }
          noteData.addAll([instrIdx, midiNote, packedVol]);
          for (int i = 0; i < 3; i++) { noteData.add(fxIds[i]); noteData.add(fxVals[i]); }
        }

        rows.add({'lineSamples': lineSamples, 'noteData': noteData});
        songRowMap.add(songRow);
        chainRowMap.add(slot);
        phraseStepMap.add(step);
      }
    }

    return (rows: rows, songRowMap: songRowMap, chainRowMap: chainRowMap, phraseStepMap: phraseStepMap);
  }

  // -----------------------------------------------------------------------
  // Build all C++ rows for Song playback starting from [startRow].
  // Returns rows + a parallel songRowMap (which song row each C++ row belongs to)
  // so the Dart poll timer can update playheadRow correctly.
  //
  // Looping rules:
  //   - Song: stop at first empty row after startRow (or wrap if isLooping)
  //   - Chains: shorter chains loop via modulo within a song row
  //   - Phrases: shorter phrases loop via modulo within a chain slot
  // -----------------------------------------------------------------------
  /// Returns the C++ integer FX command ID for [name].
  /// Dart-only commands (BPM, LPB, TPO, HOP, CHA) and '---' return 0 so C++ ignores them.
  static int _fxIdForC(String name) {
    const dartOnly = {'---', 'BPM', 'LPB', 'TPO', 'HOP', 'CHA'};
    if (dartOnly.contains(name)) return 0;
    return kFxId[name] ?? 0;
  }

  ({List<Map<String, dynamic>> rows, List<int> songRowMap, List<int> chainRowMap, List<int> phraseStepMap})
      buildPlaybackData({int startRow = 0}) {
    final rows          = <Map<String, dynamic>>[];
    final songRowMap    = <int>[];  // parallel: rows[i] belongs to song row songRowMap[i]
    final chainRowMap   = <int>[];  // parallel: rows[i] belongs to chain slot chainRowMap[i]
    final phraseStepMap = <int>[];  // parallel: rows[i] belongs to phrase step phraseStepMap[i]

    int currentBpm = song.bpm;
    int currentLpb = song.lpb;
    final rng = Random();

    for (int songRow = startRow; songRow < 99; songRow++) {
      if (isSongRowEmpty(songRow)) break; // stop at first empty row

      // Collect full ChainItems per track (items with non-empty phrase ref)
      final trackItems = List<List<ChainItem>>.generate(8, (t) {
        final chainRef = song.chains[songRow][t];
        if (chainRef == 0) return [];
        return chains[chainRef - 1].items.where((ci) => ci.phrase != 0).toList();
      });

      final maxSlots = trackItems.fold(0, (m, l) => l.length > m ? l.length : m);
      if (maxSlots == 0) continue;

      for (int slot = 0; slot < maxSlots; slot++) {
        // ── Chain-level FX: BPM and LPB (scan all tracks for this slot) ──
        for (int t = 0; t < 8; t++) {
          if (trackItems[t].isEmpty) continue;
          final ci = trackItems[t][slot % trackItems[t].length];
          for (final fx in ci.fx) {
            if (fx.name == 'BPM') {
              currentBpm = fxValToBpm(fx.value);
            } else if (fx.name == 'LPB') currentLpb = fx.value.clamp(1, 16);
            // HOP: non-linear chain jump — TODO
          }
        }

        // Resolve max steps across all tracks for this slot
        int maxSteps = 0;
        for (int t = 0; t < 8; t++) {
          if (trackItems[t].isEmpty) continue;
          final ci = trackItems[t][slot % trackItems[t].length];
          final len = _getPhraseLen(phrases[ci.phrase - 1]);
          if (len > maxSteps) maxSteps = len;
        }
        if (maxSteps == 0) continue;

        for (int step = 0; step < maxSteps; step++) {
          // ── Phrase-step BPM/LPB: scan all tracks, update running state ──
          for (int t = 0; t < 8; t++) {
            if (trackItems[t].isEmpty) continue;
            final ci = trackItems[t][slot % trackItems[t].length];
            final ph = phrases[ci.phrase - 1];
            final phraseLen = _getPhraseLen(ph);
            if (phraseLen == 0) continue;
            final ps = ph.steps[step % phraseLen];
            for (final fx in ps.fx) {
              if (fx.name == 'BPM') {
                currentBpm = fxValToBpm(fx.value);
              } else if (fx.name == 'LPB') currentLpb = fx.value.clamp(1, 16);
            }
          }

          final int lineSamples = _swingLineSamples(currentBpm, currentLpb, rows.length);

          final noteData = <int>[];
          for (int t = 0; t < 8; t++) {
            if (trackItems[t].isEmpty || !isTrackAudible(t)) {
              noteData.addAll([-1, -1, -1, 0, 0, 0, 0, 0, 0]); // silent + no FX
              continue;
            }
            final ci = trackItems[t][slot % trackItems[t].length];
            final ph = phrases[ci.phrase - 1];
            final phraseLen = _getPhraseLen(ph);
            if (phraseLen == 0) {
              noteData.addAll([-1, -1, -1, 0, 0, 0, 0, 0, 0]);
              continue;
            }
            final ps = ph.steps[step % phraseLen];

            int instrIdx = ps.instrument > 0 ? ps.instrument - 1 : -1;
            int midiNote = ps.note;

            // TPO: chain-level semitone transpose.
            // Stored: 0=none, 1-12=+semitones, 88-99=-semitones (99=-1, 88=-12).
            if (instrIdx >= 0 && midiNote >= 0 && ci.transpose != 0) {
              final int semitones = ci.transpose <= 12
                  ? ci.transpose
                  : ci.transpose - 100; // 99→-1, 88→-12
              midiNote = (midiNote + semitones).clamp(0, 120);
            }
            // Slice mode: C-0 to B-0 (MIDI 0-11) routes to instruments 1-12 at unity pitch
            if (midiNote >= 0 && midiNote <= 11) { instrIdx = midiNote; midiNote = 60; }

            // CHA: probabilistic note skip
            if (instrIdx >= 0) {
              for (final fx in ps.fx) {
                if (fx.name == 'CHA') {
                  if (rng.nextInt(100) >= fx.value) { instrIdx = -1; midiNote = -1; }
                  break;
                }
              }
            }

            // Chain-level FX overrides for this slot (ci.fx).
            // BPM/LPB already consumed above; handle VOL/PAN/sends here.
            int? chainVol, chainPan, chainSnr, chainSnd, chainSnc;
            for (final cfx in ci.fx) {
              if (cfx.name == 'VOL') {
                chainVol = cfx.value;
              } else if (cfx.name == 'PAN') chainPan = cfx.value;
              else if (cfx.name == 'SNR') chainSnr = cfx.value;
              else if (cfx.name == 'SND') chainSnd = cfx.value;
              else if (cfx.name == 'SNC') chainSnc = cfx.value;
            }

            // Pack: [instrIdx, midiNote, vol, fx0id, fx0val, fx1id, fx1val, fx2id, fx2val]
            // Chain VOL overrides the step's volume column wholesale.
            final packedVol = chainVol ?? ps.volume;

            // Fill FX slots from phrase step first (3 slots).
            // Then inject any chain FX into empty slots, skipping ones the
            // phrase already covers (phrase wins on conflict).
            final fxIds  = [0, 0, 0];
            final fxVals = [0, 0, 0];
            for (int i = 0; i < ps.fx.length && i < 3; i++) {
              fxIds[i]  = _fxIdForC(ps.fx[i].name);
              fxVals[i] = ps.fx[i].value;
            }
            for (final entry in [
              (kFxId['PAN'], chainPan),
              (kFxId['SNR'], chainSnr),
              (kFxId['SND'], chainSnd),
              (kFxId['SNC'], chainSnc),
            ]) {
              final id = entry.$1; final val = entry.$2;
              if (id == null || val == null || fxIds.contains(id)) continue;
              final emptyIdx = fxIds.indexOf(0);
              if (emptyIdx == -1) break;
              fxIds[emptyIdx] = id; fxVals[emptyIdx] = val;
            }
            noteData.addAll([instrIdx, midiNote, packedVol]);
            for (int i = 0; i < 3; i++) {
              noteData.add(fxIds[i]);
              noteData.add(fxVals[i]);
            }
          }
          rows.add({'lineSamples': lineSamples, 'noteData': noteData});
          songRowMap.add(songRow);
          chainRowMap.add(slot);
          phraseStepMap.add(step);
        }
      }
    }

    return (rows: rows, songRowMap: songRowMap, chainRowMap: chainRowMap, phraseStepMap: phraseStepMap);
  }

  // -----------------------------------------------------------------------
  // Build C++ rows for a single phrase (Phrase window play).
  // Each step fires its instrument; all other tracks are silent.
  // -----------------------------------------------------------------------
  List<Map<String, dynamic>> buildPhraseRows(int phraseIdx) {
    final ph  = phrases[phraseIdx];
    final len = _getPhraseLen(ph);
    if (len == 0) return [];

    final rows = <Map<String, dynamic>>[];

    for (int step = 0; step < len; step++) {
      final ps = ph.steps[step];
      if (ps.note == PhraseStep.noteEnd) break;
      final int lineSamples = _swingLineSamples(song.bpm, song.lpb, step);
      int instrIdx = ps.instrument > 0 ? ps.instrument - 1 : -1;
      int midiNote = ps.note;
      // Slice mode: C-0 to B-0 (MIDI 0-11) routes to instruments 1-12 at unity pitch
      if (midiNote >= 0 && midiNote <= 11) { instrIdx = midiNote; midiNote = 60; }
      // Track 0 carries step data (9 ints); tracks 1-7 are silent (9 zeros each)
      final noteData = <int>[instrIdx, midiNote, ps.volume];
      for (final fx in ps.fx) {
        noteData.add(_fxIdForC(fx.name));
        noteData.add(fx.value);
      }
      for (int t = 1; t < 8; t++) {
        noteData.addAll([-1, -1, -1, 0, 0, 0, 0, 0, 0]);
      }
      rows.add({'lineSamples': lineSamples, 'noteData': noteData});
    }

    return rows;
  }

  // Legacy alias kept so existing callers don't break
  List<Map<String, dynamic>> buildPlaybackRows({int startRow = 0}) =>
      buildPlaybackData(startRow: startRow).rows;

  // ---------------------------------------------------------------------------
  // WAV export — record-while-playing tap
  // ---------------------------------------------------------------------------

  /// Export the full song to a WAV file.
  ///
  /// Returns the file path on success, or null if already playing or no
  /// project path is set or there are no rows to export.
  Future<String?> exportSongToWav() async {
    if (isPlaying) return null;
    if (!hasProjectPath()) return null;

    // Build playback data from row 0 (full song, no loop)
    final data = buildPlaybackData(startRow: 0);
    if (data.rows.isEmpty) return null;

    // Compute total duration in seconds (48 kHz sample rate)
    final totalFrames = data.rows.fold<int>(
        0, (sum, row) => sum + (row['lineSamples'] as int));
    final totalSeconds = totalFrames / 48000.0;
    // Extra tail to capture reverb/delay decay
    const tailSeconds = 3.0;

    // Arm the export tap before any audio flows
    await NativeAudioEngine.startExportTap();

    // Start playback from row 0 (non-looping)
    isPlaying = true;
    await NativeAudioEngine.enqueueAllRows(false, data.rows);

    // Wait for song duration + tail (delay/reverb decay)
    await Future<void>.delayed(
        Duration(milliseconds: ((totalSeconds + tailSeconds) * 1000).round()));

    // Stop playback
    isPlaying = false;
    await NativeAudioEngine.clearQueue();
    await NativeAudioEngine.stopAll();

    // Retrieve captured audio
    final tap = await NativeAudioEngine.stopExportTap();
    if (tap.samples.isEmpty) return null;

    // Encode to WAV
    final wavBytes = WavEncoder.encodeWav(
        samples: tap.samples,
        sampleRate: tap.sampleRate,
        numChannels: 2);

    // Save next to project file (app-private storage)
    final fileName = '$currentProjectName.wav';
    final filePath = '$currentProjectPath/$fileName';
    await File(filePath).writeAsBytes(wavBytes, flush: true);

    // Also copy to public Downloads so it appears in the Files app
    await NativeAudioEngine.saveToDownloads(
        sourcePath: filePath, fileName: fileName);

    return filePath;
  }
}
