import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'tracker_model.dart';
import 'tracker_styles.dart';
import 'windows/song_window.dart';
import 'windows/chain_window.dart';
import 'windows/phrase_window.dart';
import 'windows/instrument_window.dart';
import 'windows/mixer_window.dart';
import 'windows/sampler_window.dart';
import 'services/project_manager.dart';
import 'audio/audio_engine.dart';

class TrackerScreen extends StatefulWidget {
  final TrackerModel? initialModel;

  const TrackerScreen({super.key, this.initialModel});

  @override
  State<TrackerScreen> createState() => _TrackerScreenState();
}

class _TrackerScreenState extends State<TrackerScreen> {
  late TrackerModel model;
  final List<String> windowNames = ['S', 'C', 'P', 'I', 'M'];
  int _samplerInstrumentOpen = -1;  // -1 = no sampler open, >=0 = instrument index
  Timer? _stepTimer;

  // Playback tracking
  List<int> _songRowMap    = [];  // C++ row index → song row number
  int _currentStepIndex    = 0;   // current position in C++ queue
  bool _playingPhraseMode  = false; // true when playing from Phrase window

  @override
  void initState() {
    super.initState();
    model = widget.initialModel ?? TrackerModel();
  }

  @override
  void dispose() {
    _stepTimer?.cancel();
    super.dispose();
  }

  void _startPollTimer() {
    _stepTimer?.cancel();
    _stepTimer = Timer.periodic(const Duration(milliseconds: 16), (_) async {
      final advanced = await NativeAudioEngine.consumeRowAdvances();
      if (advanced > 0) {
        setState(() {
          if (_playingPhraseMode) {
            // Phrase window: playheadRow tracks the current step within the phrase
            model.playheadRow = (model.playheadRow + advanced).clamp(0, 98);
          } else {
            // Song window: map step index → actual song row
            if (_songRowMap.isNotEmpty) {
              _currentStepIndex = (_currentStepIndex + advanced) % _songRowMap.length;
              model.playheadRow = _songRowMap[_currentStepIndex];
            }
          }
        });
      }
      if (!model.isPlaying) {
        _stepTimer?.cancel();
        _stepTimer = null;
      }
    });
  }

  void _togglePlay() async {
    if (model.isPlaying) {
      model.stopPlayback();
      await NativeAudioEngine.clearQueue();
      await NativeAudioEngine.stopAll();
      _stepTimer?.cancel();
      _stepTimer = null;
      setState(() {});
    } else {
      model.startPlayback();
      _currentStepIndex   = 0;
      _playingPhraseMode  = model.currentWindow == 2;

      List<Map<String, dynamic>> rows;

      if (_playingPhraseMode) {
        // Phrase window: play just the active phrase
        rows = model.buildPhraseRows(model.activePhraseIdx);
        _songRowMap = [];
        model.playheadRow = 0;
      } else {
        // Song (or Chain) window: play from current song cursor row
        final data = model.buildPlaybackData(startRow: model.cursorRow);
        rows = data.rows;
        _songRowMap = data.songRowMap;
        model.playheadRow = model.cursorRow;
      }

      if (rows.isEmpty) {
        model.stopPlayback();
        setState(() {});
        return;
      }
      await NativeAudioEngine.enqueueAllRows(model.isLooping, rows);
      _startPollTimer();
      setState(() {});
    }
  }

  /// Navigate to a window, setting activeChainIdx / activePhraseIdx from context.
  void _navigateToWindow(int windowIndex) {
    model.exitEditMode();
    model.clearLineSelection();
    final fromWindow = model.currentWindow;

    // Validate navigation: can only go to Chain if current Song cell has a chain reference
    if (windowIndex == 1 && fromWindow == 0) {
      final chainRef = model.song.chains[model.cursorRow][model.cursorCol];
      if (chainRef <= 0) return; // Can't navigate to Chain window without a valid chain
      model.activeChainIdx = chainRef - 1;
    } 
    // Validate navigation: can only go to Phrase if current Chain row has a phrase reference
    else if (windowIndex == 2 && fromWindow == 1) {
      final item = model.chains[model.activeChainIdx].items[model.cursorRow];
      if (item.phrase <= 0) return; // Can't navigate to Phrase window without a valid phrase
      model.activePhraseIdx = item.phrase - 1;
    }

    model.currentWindow = windowIndex;

    if (windowIndex == 0) {
      // Returning to Song: place cursor on the cell that references the active chain
      final targetChain = model.activeChainIdx + 1;
      bool found = false;
      outer:
      for (int r = 0; r < model.song.chains.length; r++) {
        for (int c = 0; c < model.song.chains[r].length; c++) {
          if (model.song.chains[r][c] == targetChain) {
            model.cursorRow = r;
            model.cursorCol = c;
            found = true;
            break outer;
          }
        }
      }
      if (!found) { model.cursorRow = 0; model.cursorCol = 0; }
    } else {
      model.cursorRow = 0;
      model.cursorCol = 0;
    }
  }

  void _handleKey(RawKeyEvent event) {
    if (event is RawKeyDownEvent) {
      final isArrowUp = event.isKeyPressed(LogicalKeyboardKey.arrowUp);
      final isArrowDown = event.isKeyPressed(LogicalKeyboardKey.arrowDown);
      final isTab = event.isKeyPressed(LogicalKeyboardKey.tab);
      final isEnter = event.isKeyPressed(LogicalKeyboardKey.enter);
      final isEscape = event.isKeyPressed(LogicalKeyboardKey.escape);
      final isBackspace = event.isKeyPressed(LogicalKeyboardKey.backspace);

      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        setState(() {
          model.cursorRow = (model.cursorRow - 1).clamp(0, 98);
        });
      } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        setState(() {
          model.cursorRow = (model.cursorRow + 1).clamp(0, 98);
        });
      } else if (event.logicalKey == LogicalKeyboardKey.tab) {
        setState(() {
          int maxCol = _getMaxColumns(model.currentWindow);
          model.cursorCol = (model.cursorCol + 1) % maxCol;
        });
      } else if (event.logicalKey == LogicalKeyboardKey.enter) {
        if (model.inEditMode) {
          if (model.editingBPM) {
            setState(() {
              int bpm = int.tryParse(model.editBuffer) ?? 120;
              bpm = bpm.clamp(60, 300);
              model.song.bpm = bpm;
              model.editingBPM = false;
              model.inEditMode = false;
              model.editBuffer = '';
            });
          } else {
            setState(() {
              model.applyEdit(model.editBuffer);
            });
          }
        } else {
          setState(() {
            model.enterEditMode();
          });
        }
      } else if (event.logicalKey == LogicalKeyboardKey.escape) {
        setState(() {
          model.editingBPM = false;
          model.projectMenuVisible = false;
          model.exitEditMode();
        });
      } else if (event.logicalKey == LogicalKeyboardKey.backspace) {
        if (model.inEditMode && model.editBuffer.isNotEmpty) {
          setState(() {
            model.editBuffer = model.editBuffer.substring(0, model.editBuffer.length - 1);
          });
        }
      } else if (event.character != null && event.character!.contains(RegExp(r'[0-9]'))) {
        if (model.inEditMode && model.editBuffer.length < model.editMaxChars) {
          setState(() {
            model.editBuffer += event.character!;
          });
        }
      }
    }
  }

  int _getMaxColumns(int window) {
    switch (window) {
      case 0: return 8;  // Song: 8 tracks
      case 1: return 6;  // Chain: PH, TR, FX, VL, FX, VL
      case 2: return 8;  // Phrase: IN VOL FX VL FX VL FX VL
      case 3: return 8;  // Instrument: LD ED RC FT RS TR MD BS
      case 4: return 8;  // Mixer: 8 channels (rows = params)
      default: return 1;
    }
  }

  @override
  Widget build(BuildContext context) {
    return RawKeyboardListener(
      focusNode: FocusNode()..requestFocus(),
      onKey: _handleKey,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Stack(
            children: [
              Column(
              children: [
            // Navigation bar
            LayoutBuilder(
              builder: (context, constraints) {
                final fontSize = (constraints.maxWidth * 0.12).clamp(16.0, 32.0);
                final buttonW = (constraints.maxWidth * 0.10).clamp(40.0, 80.0);
                return Container(
                  color: kBarBg,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
                        children: List.generate(
                          windowNames.length * 2 - 1,
                          (i) {
                            if (i.isOdd) {
                              // Spacer between buttons
                              return SizedBox(width: buttonW);
                            }
                            final buttonIndex = i ~/ 2;
                            return GestureDetector(
                              onTap: () {
                                setState(() {
                                  _navigateToWindow(buttonIndex);
                                });
                              },
                              child: Container(
                                width: buttonW,
                                height: 36,
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: model.currentWindow == buttonIndex ? kGreen : Colors.white,
                                    width: 2,
                                  ),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  windowNames[buttonIndex],
                                  style: trackerStyle(
                                    size: fontSize,
                                    color: model.currentWindow == buttonIndex ? kGreen : Colors.white,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            // Spacer between nav and content (one line height)
            const SizedBox(height: 28),
            // Content area (shows rows 0-16)
            SizedBox(
              height: 540, // Header (28) + 18 rows (18*28)
              child: _buildWindow(),
            ),
            // Spacer between content and mixer (one line height)
            const SizedBox(height: 28),
            // Simple mixer strip (persistent, shows meters and levels)
            LayoutBuilder(
              builder: (context, constraints) {
                final fontSize = (constraints.maxWidth * 0.08).clamp(16.0, 32.0);
                final meterWidth = (constraints.maxWidth / 8 * 0.4).clamp(20.0, 40.0);
                return Container(
                  color: kBarBg,
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      // Invisible spacer (for alignment)
                      SizedBox(
                        width: (constraints.maxWidth / 14),
                      ),
                      ...List.generate(8, (ch) {
                        final level = model.mixerChannels[ch].level;
                        final audioLevel = model.audioLevels[ch];
                        return Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Meter (green bar)
                              Container(
                                width: meterWidth,
                                height: 40,
                                decoration: BoxDecoration(
                                  border: Border.all(color: Colors.white, width: 1),
                                  color: Colors.black,
                                ),
                                child: Stack(
                                  alignment: Alignment.bottomCenter,
                                  children: [
                                    Container(
                                      width: meterWidth,
                                      height: 40 * (audioLevel / 100),
                                      color: kGreen,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 2),
                              // Level number
                              GestureDetector(
                                onTap: () {
                                  model.currentWindow = 4; // Switch to Mixer
                                  model.cursorRow = 0; // LVL row
                                  model.cursorCol = ch;
                                  model.enterEditMode();
                                  setState(() {});
                                },
                                child: Text(
                                  level.toString().padLeft(2, '0'),
                                  style: trackerStyle(size: fontSize),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                    ],
                  ),
                );
              },
            ),
            // Spacer between mixer and control bar (one line height)
            const SizedBox(height: 28),
            // Control bar (Play, Stop, Loop buttons)
            LayoutBuilder(
              builder: (context, constraints) {
                final fontSize = (constraints.maxWidth * 0.12).clamp(16.0, 32.0);
                final buttonW = (constraints.maxWidth * 0.15).clamp(40.0, 80.0);
                return Container(
                  color: kBarBg,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          GestureDetector(
                            onTap: () {
                              _togglePlay();
                            },
                            child: Container(
                              width: buttonW,
                              height: 36,
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: model.isPlaying ? kGreen : Colors.white,
                                  width: 2,
                                ),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                model.isPlaying ? 'STOP' : 'PLAY',
                                style: trackerStyle(
                                  size: fontSize,
                                  color: model.isPlaying ? kGreen : Colors.white,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          GestureDetector(
                            onTap: () {
                              setState(() {
                                model.isLooping = !model.isLooping;
                              });
                            },
                            child: Container(
                              width: buttonW,
                              height: 36,
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: model.isLooping ? kGreen : Colors.white,
                                  width: 2,
                                ),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                'LOOP',
                                style: trackerStyle(
                                  size: fontSize,
                                  color: model.isLooping ? kGreen : Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            model.editingBPM = true;
                            model.inEditMode = true;
                            model.editBuffer = '';
                            model.editMaxChars = 3;
                          });
                        },
                        child: Text(
                          'T: ${model.song.bpm.toString().padLeft(3, '0')}',
                          style: trackerStyle(size: fontSize, color: Colors.white),
                        ),
                      ),
                      const SizedBox(width: 16),
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            model.projectMenuVisible = !model.projectMenuVisible;
                          });
                        },
                        child: Container(
                          width: 32,
                          height: 36,
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: model.projectMenuVisible ? kGreen : Colors.white,
                              width: 2,
                            ),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            '☰',
                            style: trackerStyle(size: fontSize, color: Colors.white),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
              // Bottom edit menu popup
              if (model.editMenuVisible)
                _buildBottomEditMenu(),
              // Project menu backdrop
              if (model.projectMenuVisible)
                Positioned.fill(
                  child: GestureDetector(
                    onTap: () {
                      setState(() {
                        model.projectMenuVisible = false;
                      });
                    },
                    child: Container(color: Colors.transparent),
                  ),
                ),
              // Project menu popup
              if (model.projectMenuVisible)
                _buildProjectMenu(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProjectMenu() {
    const menuItems = ['SAVE SONG', 'SAVE AS...', 'NEW SONG', 'LOAD SONG', 'SET TEMPO', 'FOLDER'];

    return Positioned(
      right: 8,
      top: 380,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final fontSize = (constraints.maxWidth * 0.12).clamp(14.0, 24.0);
          final itemHeight = 40.0;
          const itemWidth = 120.0;

          return Container(
            width: itemWidth,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white, width: 2),
              color: kBarBg,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: menuItems.map((item) {
                return GestureDetector(
                  onTap: () {
                    setState(() {
                      model.projectMenuVisible = false;
                    });
                    _handleProjectMenuAction(item);
                  },
                  child: Container(
                    height: itemHeight,
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          color: item == menuItems.last ? Colors.transparent : Colors.white,
                          width: 1,
                        ),
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      item,
                      style: trackerStyle(size: fontSize, color: Colors.white),
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              }).toList(),
            ),
          );
        },
      ),
    );
  }

  void _handleProjectMenuAction(String action) async {
    switch (action) {
      case 'SAVE SONG':
        // Save to current project (or UNTITLED if no project)
        final projectName = model.currentProjectName;
        print('Saving project: $projectName');
        await ProjectManager.saveProject(projectName, model);
        setState(() {});
        break;

      case 'SAVE AS...':
        // Show dialog to enter new project name
        final newName = await _showProjectNameDialog('SAVE AS');
        if (newName != null && newName.isNotEmpty) {
          print('Saving as: $newName');
          await ProjectManager.saveProject(newName, model);
          model.setCurrentProject(newName, '');
          setState(() {});
        }
        break;

      case 'NEW SONG':
        showDialog(
          context: context,
          builder: (BuildContext ctx) => AlertDialog(
            title: const Text('New Song'),
            content: const Text('Clear all song data and start fresh?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  model.newSong();
                  setState(() {});
                },
                child: const Text('Create'),
              ),
            ],
          ),
        );
        break;

      case 'LOAD SONG':
        // TODO: Load song
        print('Load song clicked');
        break;

      case 'SET TEMPO':
        // TODO: Set tempo dialog
        print('Set tempo clicked');
        break;

      case 'FOLDER':
        // TODO: Browse projects folder
        print('Folder clicked');
        break;
    }
  }

  Future<String?> _showProjectNameDialog(String title) async {
    String projectName = model.currentProjectName;

    return showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(title),
          content: TextField(
            onChanged: (value) {
              projectName = value;
            },
            decoration: InputDecoration(
              hintText: model.currentProjectName,
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(projectName),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildBottomEditMenu() {
    // ── Line-selection mode: single row of actions ──
    if (model.hasLineSelection) {
      final items = ['↑', '↓', '2x', 'DEL', 'X'];
      return Positioned(
        bottom: 0,
        left: 0,
        right: 0,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final fontSize = (constraints.maxWidth * 0.10).clamp(14.0, 28.0);
            return Container(
              color: kBarBg,
              padding: const EdgeInsets.all(4),
              child: Row(
                children: items.map((item) {
                  return Expanded(
                    child: GestureDetector(
                      onTap: () {
                        setState(() {
                          if (item == 'X') {
                            model.clearLineSelection();
                          } else if (item == '↑') {
                            model.moveSelectionUp();
                          } else if (item == '↓') {
                            model.moveSelectionDown();
                          } else if (item == '2x') {
                            model.duplicateSelection();
                          } else if (item == 'DEL') {
                            model.clearSelectedLines();
                            model.clearLineSelection();
                          }
                        });
                      },
                      child: Container(
                        margin: const EdgeInsets.all(4),
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.cyan, width: 1),
                          color: Colors.transparent,
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          item,
                          style: trackerStyle(size: fontSize, color: Colors.cyan),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            );
          },
        ),
      );
    }

    // ── Normal cell-edit menu ──
    final isNoteColumn = model.currentWindow == 2 && model.cursorCol == 0;
    final line1Items = isNoteColumn
        ? ['−', '+', '−12', '+12']
        : ['−', '+', '−10', '+10'];

    // Song window: REP + DEL
    // Phrase note column: OFF + END + DEL + X
    // Other: CPY + CUT + PST + DEL + X
    final line2Items = model.currentWindow == 0
        ? ['REP', 'DEL', 'X']
        : isNoteColumn
            ? ['OFF', 'END', 'DEL', 'X']
            : ['CPY', 'CUT', 'PST', 'DEL', 'X'];

    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final fontSize = (constraints.maxWidth * 0.10).clamp(14.0, 28.0);
          final padding = 4.0;
          final spacing = 4.0;

          return Container(
            color: kBarBg,
            padding: const EdgeInsets.all(4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Line 1
                Row(
                  children: line1Items.map((item) {
                    return Expanded(
                      child: GestureDetector(
                        onTap: () {
                          if (item == 'X') {
                            setState(() {
                              model.editMenuVisible = false;
                            });
                          } else {
                            model.performMenuAction(item);
                            setState(() {});
                          }
                        },
                        child: Container(
                          margin: EdgeInsets.all(spacing),
                          padding: EdgeInsets.all(padding),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.white, width: 1),
                            color: Colors.transparent,
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            item,
                            style: trackerStyle(size: fontSize, color: Colors.white),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                // Line 2
                Row(
                  children: line2Items.map((item) {
                    return Expanded(
                      child: GestureDetector(
                        onTap: () {
                          if (item == 'X') {
                            setState(() {
                              model.editMenuVisible = false;
                            });
                          } else {
                            model.performMenuAction(item);
                            setState(() {});
                          }
                        },
                        child: Container(
                          margin: EdgeInsets.all(spacing),
                          padding: EdgeInsets.all(padding),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.white, width: 1),
                            color: Colors.transparent,
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            item,
                            style: trackerStyle(size: fontSize, color: Colors.white),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildWindow() {
    // Show sampler if open
    if (_samplerInstrumentOpen >= 0 && _samplerInstrumentOpen < 99) {
      return Stack(
        children: [
          SamplerWindow(
            model: model,
            instrumentIdx: _samplerInstrumentOpen,
            onStateChange: () => setState(() {}),
          ),
          // Close button
          Positioned(
            top: 8,
            right: 8,
            child: GestureDetector(
              onTap: () {
                setState(() {
                  _samplerInstrumentOpen = -1;
                });
              },
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  border: Border.all(color: kGreen, width: 1),
                ),
                child: Icon(Icons.close, color: kGreen, size: 20),
              ),
            ),
          ),
        ],
      );
    }

    // Show normal windows
    switch (model.currentWindow) {
      case 0:
        return SongWindow(model: model, onStateChange: () => setState(() {}));
      case 1:
        return ChainWindow(model: model, onStateChange: () => setState(() {}));
      case 2:
        return PhraseWindow(model: model, onStateChange: () => setState(() {}));
      case 3:
        return InstrumentWindow(
          model: model,
          onStateChange: () => setState(() {}),
          onSamplerOpen: (idx) {
            setState(() {
              _samplerInstrumentOpen = idx;
            });
          },
        );
      case 4:
        return MixerWindow(model: model, onStateChange: () => setState(() {}));
      default:
        return Container();
    }
  }
}
