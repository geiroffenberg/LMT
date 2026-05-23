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
}

class Phrase {
  final List<PhraseStep> steps = List.generate(99, (_) => PhraseStep());
}

class PhraseStep {
  int instrument = 0;
  int volume = 80;
  int note = -1;  // -1 = no note, 0-120 = MIDI note (C-0 to C-9)
  List<FxSlot> fx = [FxSlot(), FxSlot(), FxSlot()];
  
  // Helper to get note display (e.g., "C-4", "C#4", "---")
  String getNoteDisplay() {
    if (note < 0 || note > 120) return '---';  // Three dashes, matches FX cell format
    const noteNames = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
    final octave = note ~/ 12;
    final semitone = note % 12;
    final noteName = noteNames[semitone];
    // Format: single-letter notes get dash before octave (C-4), accidentals are 3 chars (C#4)
    if (noteName.length == 1) {
      return '$noteName-$octave'.padRight(3);  // Ensure 3 characters
    } else {
      return '$noteName$octave'.padRight(3);   // Ensure 3 characters
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

  // State
  int currentWindow = 0; // 0=Song, 1=Chain, 2=Phrase, 3=Instrument, 4=Mixer
  int cursorRow = 0;
  int cursorCol = 0;
  int scrollRow = 0;

  bool inEditMode = false;
  bool editingBPM = false;
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
      // Chain
      if (cursorCol == 0) {
        // Phrase reference (0-99, where 0 = empty)
        intValue = intValue.clamp(0, 99);
        chains[cursorRow].items[cursorRow].phrase = intValue;
      } else if (cursorCol == 1) {
        // Transpose
        intValue = intValue.clamp(0, 99);
        chains[cursorRow].items[cursorRow].transpose = intValue;
      }
    } else if (currentWindow == 2) {
      // Phrase: NT IN VOL FX...
      if (cursorCol == 0) {
        // Note: -1 (empty) or 0-120 (MIDI notes)
        if (intValue < -1) intValue = -1;
        if (intValue > 120) intValue = 120;
        phrases[cursorRow].steps[cursorRow].note = intValue;
      } else if (cursorCol == 1) {
        // Instrument
        intValue = intValue.clamp(0, 99);
        phrases[cursorRow].steps[cursorRow].instrument = intValue;
      } else if (cursorCol == 2) {
        // Volume 0-99
        intValue = intValue.clamp(0, 99);
        phrases[cursorRow].steps[cursorRow].volume = intValue;
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
      // Chain: 01
      chains[cursorRow].items[cursorRow].phrase = 1;
    } else if (currentWindow == 2) {
      // Phrase
      if (cursorCol == 0) {
        // Instrument: 01
        phrases[cursorRow].steps[cursorRow].instrument = 1;
      } else if (cursorCol == 1) {
        // Volume: 80
        phrases[cursorRow].steps[cursorRow].volume = 80;
      } else if (cursorCol >= 2) {
        // FX: ARP
        int fxIndex = (cursorCol - 2) ~/ 2;
        if (fxIndex < phrases[cursorRow].steps[cursorRow].fx.length) {
          phrases[cursorRow].steps[cursorRow].fx[fxIndex].name = 'ARP';
          phrases[cursorRow].steps[cursorRow].fx[fxIndex].value = 0;
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

    if (action == '+') {
      applyEdit((currentValue + 1).toString());
    } else if (action == '−' || action == '-') {
      applyEdit((currentValue - 1).toString());
    } else if (action == '+10') {
      applyEdit((currentValue + 10).toString());
    } else if (action == '−10' || action == '-10') {
      applyEdit((currentValue - 10).toString());
    } else if (action == '+12') {
      applyEdit((currentValue + 12).toString());
    } else if (action == '−12' || action == '-12') {
      applyEdit((currentValue - 12).toString());
    } else if (action == 'DEL') {
      applyEdit('0');
    } else if (action == 'CPY') {
      copyBuffer = getCurrentCellValueAsString();
    } else if (action == 'CUT') {
      copyBuffer = getCurrentCellValueAsString();
      applyEdit('0');
    } else if (action == 'PST') {
      if (copyBuffer.isNotEmpty) {
        applyEdit(copyBuffer);
      }
    }
  }

  int getCurrentCellValue() {
    if (currentWindow == 0) {
      return song.chains[cursorRow][cursorCol];
    } else if (currentWindow == 1) {
      if (cursorCol == 0) return chains[cursorRow].items[cursorRow].phrase;
      return chains[cursorRow].items[cursorRow].transpose;
    } else if (currentWindow == 2) {
      if (cursorCol == 0) {
        // Note column (NT) - return MIDI note or -1 for empty
        return phrases[cursorRow].steps[cursorRow].note;
      } else if (cursorCol == 1) {
        return phrases[cursorRow].steps[cursorRow].instrument;
      } else if (cursorCol == 2) {
        return phrases[cursorRow].steps[cursorRow].volume;
      } else {
        int fxIndex = (cursorCol - 3) ~/ 2;
        int isValue = (cursorCol - 3) % 2;
        if (fxIndex < phrases[cursorRow].steps[cursorRow].fx.length) {
          return isValue == 1 ? phrases[cursorRow].steps[cursorRow].fx[fxIndex].value : 0;
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
      return phrases[cursorRow].steps[cursorRow].getNoteDisplay();
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
}
