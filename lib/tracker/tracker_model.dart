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
  List<FxSlot> fx = [FxSlot(), FxSlot(), FxSlot()];
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
      // Phrase: IN VOL FX...
      if (cursorCol == 0) {
        // Instrument
        intValue = intValue.clamp(0, 99);
        phrases[cursorRow].steps[cursorRow].instrument = intValue;
      } else if (cursorCol == 1) {
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
      if (cursorCol == 3) inst.filter = 1;
      else if (cursorCol == 4) inst.resonance = 1;
      else if (cursorCol == 5) inst.treble = 1;
      else if (cursorCol == 6) inst.mid = 1;
      else if (cursorCol == 7) inst.bass = 1;
    } else if (currentWindow == 4) {
      // Mixer: 80
      var ch = mixerChannels[cursorCol];
      if (cursorRow == 0) ch.level = 80;
      else if (cursorRow == 1) ch.reverbSend = 80;
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
      if (cursorCol == 0) return phrases[cursorRow].steps[cursorRow].instrument;
      else if (cursorCol == 1) return phrases[cursorRow].steps[cursorRow].volume;
      else {
        int fxIndex = (cursorCol - 2) ~/ 2;
        int isValue = (cursorCol - 2) % 2;
        if (fxIndex < phrases[cursorRow].steps[cursorRow].fx.length) {
          return isValue == 1 ? phrases[cursorRow].steps[cursorRow].fx[fxIndex].value : 0;
        }
      }
    } else if (currentWindow == 3) {
      var inst = instruments[cursorRow];
      if (cursorCol == 3) return inst.filter;
      else if (cursorCol == 4) return inst.resonance;
      else if (cursorCol == 5) return inst.treble;
      else if (cursorCol == 6) return inst.mid;
      else if (cursorCol == 7) return inst.bass;
    } else if (currentWindow == 4) {
      var ch = mixerChannels[cursorCol];
      if (cursorRow == 0) return ch.level;
      else if (cursorRow == 1) return ch.reverbSend;
      else if (cursorRow == 2) return ch.delaySend;
      else if (cursorRow == 3) return ch.chorusSend;
    }
    return 0;
  }

  String getCurrentCellValueAsString() {
    return getCurrentCellValue().toString().padLeft(2, '0');
  }
}
