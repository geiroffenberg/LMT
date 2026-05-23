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

class TrackerScreen extends StatefulWidget {
  const TrackerScreen({super.key});

  @override
  State<TrackerScreen> createState() => _TrackerScreenState();
}

class _TrackerScreenState extends State<TrackerScreen> {
  late TrackerModel model;
  final List<String> windowNames = ['S', 'C', 'P', 'I', 'M'];
  int _samplerInstrumentOpen = -1;  // -1 = no sampler open, >=0 = instrument index

  @override
  void initState() {
    super.initState();
    model = TrackerModel();
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
      case 1: return 2;  // Chain: PHR, TRN
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
                                  model.currentWindow = buttonIndex;
                                  model.cursorRow = 0;
                                  model.cursorCol = 0;
                                  model.exitEditMode();
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
                              setState(() {
                                model.isPlaying = !model.isPlaying;
                              });
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
                        child: Text.rich(
                          TextSpan(children: [
                            TextSpan(
                              text: 'T: ',
                              style: trackerStyle(size: fontSize, color: Colors.white),
                            ),
                            TextSpan(
                              text: '−',
                              style: trackerStyle(size: fontSize, color: Colors.white),
                              recognizer: TapGestureRecognizer()
                                ..onTap = () {
                                  setState(() {
                                    model.song.bpm = (model.song.bpm - 1).clamp(60, 300);
                                  });
                                },
                            ),
                            TextSpan(text: ' ', style: trackerStyle(size: fontSize)),
                            TextSpan(
                              text: model.editingBPM
                                  ? (model.editBuffer.isEmpty ? '  |' : '${model.editBuffer.padLeft(3, " ")}|')
                                  : model.song.bpm.toString().padLeft(3, '0'),
                              style: trackerStyle(size: fontSize, color: Colors.white),
                            ),
                            TextSpan(text: ' ', style: trackerStyle(size: fontSize)),
                            TextSpan(
                              text: '+',
                              style: trackerStyle(size: fontSize, color: Colors.white),
                              recognizer: TapGestureRecognizer()
                                ..onTap = () {
                                  setState(() {
                                    model.song.bpm = (model.song.bpm + 1).clamp(60, 300);
                                  });
                                },
                            ),
                          ]),
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
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomEditMenu() {
    // Determine menu items based on current cell
    final isNoteColumn = model.currentWindow == 2 && model.cursorCol == 0;
    final line1Items = isNoteColumn 
      ? ['−', '+', '−12', '+12']
      : ['−', '+', '−10', '+10'];
    const line2Items = ['CPY', 'CUT', 'PST', 'DEL', 'X'];

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
