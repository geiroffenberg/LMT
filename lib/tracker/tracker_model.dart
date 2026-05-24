import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models/sampler_params.dart';

// Data models for LMT tracker

class Song {
  // 99 chains x 8 tracks
  final List<List<int>> chains = List.generate(99, (_) => List.filled(8, 0));
  int bpm = 120;
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
  final List<PhraseStep> steps = List.generate(99, (_) => PhraseStep());
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
    final octave = note ~/ 12;
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

class TrackerModel {
  Song song = Song();
  List<Chain> chains = List.generate(99, (_) => Chain());
  List<Phrase> phrases = List.generate(99, (_) => Phrase());
  List<Instrument> instruments = List.generate(99, (_) => Instrument());
  List<MixerChannel> mixerChannels = List.generate(8, (_) => MixerChannel());

  // Playback state
  bool isPlaying = false;
  bool isLooping = false;
  List<int> audioLevels = List.filled(8, 0); // 0-100 per channel

  // --- Song playback position ---
  int playheadRow = 0;        // which song row is currently playing
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
    audioLevels = List.filled(8, 0);

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
  }

  /// Replicate the selected chain: copy it to the next free chain number and update the cell
  void replicateChain() {
    if (currentWindow != 0) return; // Only for Song window

    final sourceChainNum = song.chains[cursorRow][cursorCol];
    if (sourceChainNum <= 0 || sourceChainNum > 99) return; // Invalid chain

    final sourceIdx = sourceChainNum - 1;

    // Find the next free chain number (one that has no phrase data)
    int targetChainNum = -1;
    for (int i = 1; i <= 99; i++) {
      bool isFree = true;
      for (int j = 0; j < chains[i - 1].items.length; j++) {
        if (chains[i - 1].items[j].phrase != 0) {
          isFree = false;
          break;
        }
      }
      if (isFree) {
        targetChainNum = i;
        break;
      }
    }

    if (targetChainNum <= 0) return; // No free chain available

    final targetIdx = targetChainNum - 1;

    // Deep copy the source chain to the target
    for (int i = 0; i < chains[sourceIdx].items.length; i++) {
      final srcItem = chains[sourceIdx].items[i];
      chains[targetIdx].items[i].phrase = srcItem.phrase;
      chains[targetIdx].items[i].transpose = srcItem.transpose;
      for (int f = 0; f < srcItem.fx.length; f++) {
        chains[targetIdx].items[i].fx[f].name = srcItem.fx[f].name;
        chains[targetIdx].items[i].fx[f].value = srcItem.fx[f].value;
      }
    }

    // Update the current cell to point to the new chain
    song.chains[cursorRow][cursorCol] = targetChainNum;
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
  List<String> fxList = ['---', 'ARP', 'DEL', 'REV', 'GLI', 'PIT', 'VOL', 'PAN'];
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
        intValue = intValue.clamp(0, 99);
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
          // FX name is set via fxList selection, not free numeric entry
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
    } else if (action == 'REP') {
      if (currentWindow == 0) replicateChain();
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
  // Phrase length: scan for first END marker; fall back to ph.length
  // -----------------------------------------------------------------------
  int _getPhraseLen(Phrase ph) {
    for (int i = 0; i < ph.steps.length; i++) {
      if (ph.steps[i].note == PhraseStep.noteEnd) return i;
    }
    return ph.length;
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
  ({List<Map<String, dynamic>> rows, List<int> songRowMap})
      buildPlaybackData({int startRow = 0}) {
    final rows       = <Map<String, dynamic>>[];
    final songRowMap = <int>[];  // parallel: rows[i] belongs to song row songRowMap[i]

    final int lineSamples = (48000.0 * 60.0 / (song.bpm * 4)).round();

    for (int songRow = startRow; songRow < 99; songRow++) {
      if (isSongRowEmpty(songRow)) break; // stop at first empty row

      // Resolve active phrase-slot list per track (chain items with phrase != 0)
      final trackPhrases = List<List<int>>.generate(8, (t) {
        final chainRef = song.chains[songRow][t];
        if (chainRef == 0) return [];
        return chains[chainRef - 1]
            .items
            .where((ci) => ci.phrase != 0)
            .map((ci) => ci.phrase)
            .toList();
      });

      // maxSlots = longest chain on this song row
      final maxSlots = trackPhrases.fold(0, (m, l) => l.length > m ? l.length : m);
      if (maxSlots == 0) continue;

      for (int slot = 0; slot < maxSlots; slot++) {
        // Each track resolves its effective phrase for this slot (modulo for shorter chains)
        // Then find the longest phrase to determine step count
        int maxSteps = 0;
        for (int t = 0; t < 8; t++) {
          if (trackPhrases[t].isEmpty) continue;
          final effectiveSlot = slot % trackPhrases[t].length;
          final phraseRef = trackPhrases[t][effectiveSlot];
          if (phraseRef == 0) continue;
          final len = _getPhraseLen(phrases[phraseRef - 1]);
          if (len > maxSteps) maxSteps = len;
        }
        if (maxSteps == 0) continue;

        for (int step = 0; step < maxSteps; step++) {
          final noteData = <int>[];
          for (int t = 0; t < 8; t++) {
            if (trackPhrases[t].isEmpty) {
              noteData.addAll([-1, -1, -1]); // silent track
              continue;
            }
            final effectiveSlot = slot % trackPhrases[t].length;
            final phraseRef = trackPhrases[t][effectiveSlot];
            if (phraseRef == 0) { noteData.addAll([-1, -1, -1]); continue; }
            final ph = phrases[phraseRef - 1];
            final phraseLen = _getPhraseLen(ph);
            if (phraseLen == 0) { noteData.addAll([-1, -1, -1]); continue; }
            // Shorter phrases loop within the slot
            final effectiveStep = step % phraseLen;
            final ps = ph.steps[effectiveStep];
            final instrIdx = ps.instrument > 0 ? ps.instrument - 1 : -1;
            noteData.addAll([instrIdx, ps.note, ps.volume]);
          }
          rows.add({'lineSamples': lineSamples, 'noteData': noteData});
          songRowMap.add(songRow);
        }
      }
    }

    return (rows: rows, songRowMap: songRowMap);
  }

  // -----------------------------------------------------------------------
  // Build C++ rows for a single phrase (Phrase window play).
  // Each step fires its instrument; all other tracks are silent.
  // -----------------------------------------------------------------------
  List<Map<String, dynamic>> buildPhraseRows(int phraseIdx) {
    final ph  = phrases[phraseIdx];
    final len = _getPhraseLen(ph);
    if (len == 0) return [];

    final int lineSamples = (48000.0 * 60.0 / (song.bpm * 4)).round();
    final rows = <Map<String, dynamic>>[];

    for (int step = 0; step < len; step++) {
      final ps = ph.steps[step];
      if (ps.note == PhraseStep.noteEnd) break;
      final instrIdx = ps.instrument > 0 ? ps.instrument - 1 : -1;
      // 8 tracks × 3 ints; only track 0 carries the step data
      final noteData = <int>[instrIdx, ps.note, ps.volume];
      for (int t = 1; t < 8; t++) noteData.addAll([-1, -1, -1]);
      rows.add({'lineSamples': lineSamples, 'noteData': noteData});
    }

    return rows;
  }

  // Legacy alias kept so existing callers don't break
  List<Map<String, dynamic>> buildPlaybackRows({int startRow = 0}) =>
      buildPlaybackData(startRow: startRow).rows;
}
