import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

class _TrackerScreenState extends State<TrackerScreen> with WidgetsBindingObserver {
  late TrackerModel model;
  final List<String> windowNames = ['S', 'C', 'P', 'I', 'M'];
  int _samplerInstrumentOpen = -1;  // -1 = no sampler open, >=0 = instrument index
  Timer? _stepTimer;
  Timer? _meterTimer;

  // Playback tracking
  List<int> _songRowMap    = [];  // C++ row index → song row number
  List<int> _chainRowMap   = [];  // C++ row index → chain slot number
  int _currentStepIndex    = 0;   // current position in C++ queue
  bool _playingPhraseMode  = false; // true when playing from Phrase window
  int _phraseLen           = 0;   // step count for phrase-mode loop wrap
  Timer? _autoSaveTimer;
  final FocusNode _keyListenerFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    model = widget.initialModel ?? TrackerModel();
    // Autosave every 60 seconds
    _autoSaveTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => _autoSave(),
    );
    // Poll native audio peaks for LED meters (~12.5 fps)
    _meterTimer = Timer.periodic(const Duration(milliseconds: 80), (_) => _pollMeters());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autoSaveTimer?.cancel();
    _stepTimer?.cancel();
    _meterTimer?.cancel();
    _keyListenerFocusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Save when the app is backgrounded or the process is about to be killed
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _autoSave();
    }
    // Reinitialize the native audio engine when the app comes back to the
    // foreground — the Oboe stream may have been released while backgrounded.
    if (state == AppLifecycleState.resumed) {
      _reinitAudio();
    }
  }

  Future<void> _reinitAudio() async {
    await NativeAudioEngine.initialize();
    for (int i = 0; i < model.instruments.length; i++) {
      final samplePath = model.instruments[i].sample;
      if (samplePath.isNotEmpty) {
        await NativeAudioEngine.loadSample(i, samplePath);
      }
    }
  }

  Future<void> _autoSave() async {
    try {
      await ProjectManager.saveProject(ProjectManager.autoSaveName, model);
    } catch (e) {
      debugPrint('Autosave failed: $e');
    }
  }

  Future<void> _pollMeters() async {
    if (!mounted) return;
    final results = await Future.wait([
      NativeAudioEngine.getTrackPeaks(),
      NativeAudioEngine.getMasterPeak().then((v) => [v]),
    ]);
    if (!mounted) return;
    setState(() {
      final peaks = results[0];
      for (int i = 0; i < 8 && i < peaks.length; i++) {
        model.audioLevels[i] = peaks[i];
      }
      model.masterPeak = results[1][0];
    });
  }

  /// Push all 8 mixer channel send levels to the native audio engine.
  void _syncMixerSendsToNative() {
    for (int i = 0; i < model.mixerChannels.length; i++) {
      final ch = model.mixerChannels[i];
      NativeAudioEngine.setTrackSends(
        i,
        ch.reverbSend / 99.0,
        ch.delaySend  / 99.0,
        ch.chorusSend / 99.0,
      );
    }
  }

  void _startPollTimer() {
    _stepTimer?.cancel();
    _stepTimer = Timer.periodic(const Duration(milliseconds: 16), (_) async {
      final advanced = await NativeAudioEngine.consumeRowAdvances();
      if (advanced > 0) {
        setState(() {
          if (_playingPhraseMode) {
            // Phrase window: wrap playhead around phrase length so loop resets to row 0
            if (_phraseLen > 0) {
              model.playheadRow = (model.playheadRow + advanced) % _phraseLen;
            }
          } else {
            // Song window: map step index → actual song row and chain slot
            if (_songRowMap.isNotEmpty) {
              _currentStepIndex = (_currentStepIndex + advanced) % _songRowMap.length;
              model.playheadRow      = _songRowMap[_currentStepIndex];
              model.playheadChainRow = _chainRowMap[_currentStepIndex];
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
        _chainRowMap = [];
        _phraseLen = rows.length;
        model.playheadRow = 0;
      } else {
        // Song (or Chain) window: play from current song cursor row
        final data = model.buildPlaybackData(startRow: model.cursorRow);
        rows = data.rows;
        _songRowMap  = data.songRowMap;
        _chainRowMap = data.chainRowMap;
        _phraseLen = 0;
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

    // ── Forward navigation rules ─────────────────────────────────────────
    // Chain window: only blocked when coming from Song with no chain selected.
    if (windowIndex == 1) {
      if (fromWindow == 0) {
        final chainRef = model.song.chains[model.cursorRow][model.cursorCol];
        if (chainRef <= 0) return;
        model.activeChainIdx = chainRef - 1;
      }
      // From Phrase, INST, MIXER, or Chain itself: always allowed.
    }
    // Phrase window: only blocked when coming from Chain with no phrase selected.
    else if (windowIndex == 2) {
      if (fromWindow == 1) {
        final item = model.chains[model.activeChainIdx].items[model.cursorRow];
        if (item.phrase <= 0) return;
        model.activePhraseIdx = item.phrase - 1;
      }
      // From Song directly: blocked unless we have a valid activeChainIdx already.
      else if (fromWindow == 0) {
        return; // must go Song → Chain first
      }
      // From INST, MIXER, or Phrase itself: always allowed.
    }

    // ── Always allowed: Song, Instrument, Mixer ──────────────────────────
    _samplerInstrumentOpen = -1; // close sampler when switching windows
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
              if (model.currentWindow == 4) _syncMixerSendsToNative();
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
      focusNode: _keyListenerFocusNode,
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
                              behavior: HitTestBehavior.opaque,
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
            // Content area — Expanded fills exactly the remaining space, no overflow possible
            Expanded(
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
                              // LED meter: 6 blocks × 5 dB, range −30..0 dB
                              Builder(builder: (context) {
                                final double dB = audioLevel > 1e-6
                                    ? 20.0 * math.log(audioLevel) / math.ln10
                                    : -60.0;
                                return Container(
                                  width: meterWidth,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    border: Border.all(color: Colors.white, width: 1),
                                    color: Colors.black,
                                  ),
                                  padding: const EdgeInsets.all(2),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: List.generate(6, (i) {
                                      // i=0 = top block (−5..0 dB), i=5 = bottom (−30..−25 dB)
                                      final int blockIdx = 5 - i;
                                      final double thresh = -30.0 + blockIdx * 5.0;
                                      final bool lit = dB >= thresh;
                                      final bool isHot = blockIdx == 5;
                                      return Container(
                                        width: double.infinity,
                                        height: 5,
                                        margin: EdgeInsets.only(bottom: i < 5 ? 1.0 : 0.0),
                                        color: lit
                                            ? (isHot ? Colors.orange : kGreen)
                                            : const Color(0xFF1A1A1A),
                                      );
                                    }),
                                  ),
                                );
                              }),
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
    const menuItems = ['SAVE SONG', 'SAVE AS...', 'NEW SONG', 'LOAD SONG', 'SONG SETTINGS', 'FOLDER'];

    return Positioned(
      right: 8,
      top: 380,
      child: Container(
        width: 170,
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
                height: 40,
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
                  style: trackerStyle(size: 20, color: Colors.white),
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }).toList(),
        ),
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
            backgroundColor: Colors.black,
            elevation: 0,
            shape: const RoundedRectangleBorder(
              side: BorderSide(color: Colors.white54),
              borderRadius: BorderRadius.zero,
            ),
            title: Text('New Song', style: trackerStyle(size: 22, color: Colors.white)),
            content: Text('Clear all song data and start fresh?', style: trackerStyle(size: 18)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('Cancel', style: trackerStyle(size: 18, color: Colors.white54)),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  model.newSong();
                  setState(() {});
                },
                child: Text('Create', style: trackerStyle(size: 18, color: kGreen)),
              ),
            ],
          ),
        );
        break;

      case 'LOAD SONG':
        _showLoadSongDialog();
        break;

      case 'SONG SETTINGS':
        _showSongSettingsDialog();
        break;

      case 'FOLDER':
        // TODO: Browse projects folder
        print('Folder clicked');
        break;
    }
  }

  Future<void> _showLoadSongDialog() async {
    final projects = await ProjectManager.listProjects();
    if (!mounted) return;

    if (projects.isEmpty) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: Colors.black,
          elevation: 0,
          shape: const RoundedRectangleBorder(
            side: BorderSide(color: Colors.white54),
            borderRadius: BorderRadius.zero,
          ),
          title: Text('Load Song', style: trackerStyle(size: 22, color: Colors.white)),
          content: Text('No saved projects found.', style: trackerStyle(size: 18)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('OK', style: trackerStyle(size: 18, color: kGreen)),
            ),
          ],
        ),
      );
      return;
    }

    // Newest first
    projects.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));

    final selectedDir = await showDialog<Directory>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.black,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          side: BorderSide(color: Colors.white54),
          borderRadius: BorderRadius.zero,
        ),
        title: Text('Load Song', style: trackerStyle(size: 22, color: Colors.white)),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: projects.length,
            itemBuilder: (_, i) {
              final name = ProjectManager.getProjectName(projects[i]);
              return InkWell(
                onTap: () => Navigator.pop(ctx, projects[i]),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                  decoration: const BoxDecoration(
                    border: Border(bottom: BorderSide(color: Colors.white12)),
                  ),
                  child: Text(name, style: trackerStyle(size: 18, color: kGreen)),
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: trackerStyle(size: 18, color: Colors.white54)),
          ),
        ],
      ),
    );

    if (selectedDir == null || !mounted) return;

    final loadedModel = await ProjectManager.loadProject(selectedDir);
    if (loadedModel == null || !mounted) return;

    // Stop any active playback before replacing model
    if (model.isPlaying) {
      model.stopPlayback();
      await NativeAudioEngine.clearQueue();
      await NativeAudioEngine.stopAll();
      _stepTimer?.cancel();
      _stepTimer = null;
    }

    // Push all samples to C++ engine
    for (int i = 0; i < loadedModel.instruments.length; i++) {
      final samplePath = loadedModel.instruments[i].sample;
      if (samplePath.isNotEmpty) {
        await NativeAudioEngine.loadSample(i, samplePath);
      }
    }

    if (!mounted) return;
    setState(() {
      model = loadedModel;
      _samplerInstrumentOpen = -1;
      _currentStepIndex = 0;
      _songRowMap = [];
      _chainRowMap = [];
      _phraseLen = 0;
    });
  }

  Future<void> _showSongSettingsDialog() async {
    int bpmVal = model.song.bpm;
    int lpbVal = model.song.lpb;

    final result = await showDialog<(int, int)>(
      context: context,
      barrierColor: Colors.black54,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            void adjustBpm(int delta) =>
                setDialogState(() => bpmVal = (bpmVal + delta).clamp(60, 300));
            void adjustLpb(int delta) =>
                setDialogState(() => lpbVal = (lpbVal + delta).clamp(1, 12));

            // A single spinner row: label / range hint / [−] [value] [+]
            Widget spinRow({
              required String label,
              required String range,
              required int value,
              required void Function(int) onAdjust,
            }) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Label + range
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(label, style: trackerStyle(size: 26, color: Colors.white)),
                      Text(range, style: trackerStyle(size: 20, color: Colors.white54)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // Spinner
                  Container(
                    decoration: const BoxDecoration(
                      border: Border.fromBorderSide(BorderSide(color: Colors.white, width: 1)),
                    ),
                    child: Row(
                      children: [
                        // − button
                        GestureDetector(
                          onTap: () => onAdjust(-1),
                          child: Container(
                            width: 56,
                            height: 64,
                            decoration: const BoxDecoration(
                              border: Border(right: BorderSide(color: Colors.white, width: 1)),
                            ),
                            alignment: Alignment.center,
                            child: Text('−', style: trackerStyle(size: 40, color: Colors.white)),
                          ),
                        ),
                        // Value display
                        Expanded(
                          child: Text(
                            value.toString(),
                            textAlign: TextAlign.center,
                            style: trackerStyle(size: 28, color: kGreen),
                          ),
                        ),
                        // + button
                        GestureDetector(
                          onTap: () => onAdjust(1),
                          child: Container(
                            width: 56,
                            height: 64,
                            decoration: const BoxDecoration(
                              border: Border(left: BorderSide(color: Colors.white, width: 1)),
                            ),
                            alignment: Alignment.center,
                            child: Text('+', style: trackerStyle(size: 40, color: Colors.white)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            }

            return Dialog(
              backgroundColor: Colors.black,
              elevation: 0,
              insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 80),
              child: Container(
                decoration: const BoxDecoration(
                  color: Colors.black,
                  border: Border.fromBorderSide(BorderSide(color: Colors.white, width: 2)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Title bar
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      decoration: const BoxDecoration(
                        border: Border(bottom: BorderSide(color: Colors.white, width: 1)),
                      ),
                      child: Text(
                        'SONG SETTINGS',
                        style: trackerStyle(size: 28, color: Colors.white),
                      ),
                    ),
                    // Body
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          spinRow(
                            label: 'BPM',
                            range: '60 – 300',
                            value: bpmVal,
                            onAdjust: adjustBpm,
                          ),
                          const SizedBox(height: 24),
                          spinRow(
                            label: 'LPB',
                            range: '1 – 12',
                            value: lpbVal,
                            onAdjust: adjustLpb,
                          ),
                        ],
                      ),
                    ),
                    // Footer buttons
                    Container(
                      decoration: const BoxDecoration(
                        border: Border(top: BorderSide(color: Colors.white, width: 1)),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: GestureDetector(
                              onTap: () => Navigator.pop(ctx),
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                alignment: Alignment.center,
                                child: Text('CANCEL',
                                    style: trackerStyle(size: 24, color: Colors.white54)),
                              ),
                            ),
                          ),
                          Container(width: 1, color: Colors.white),
                          Expanded(
                            child: GestureDetector(
                              onTap: () => Navigator.pop(ctx, (bpmVal, lpbVal)),
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                alignment: Alignment.center,
                                child: Text('OK',
                                    style: trackerStyle(size: 24, color: kGreen)),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    if (result != null) {
      setState(() {
        model.song.bpm = result.$1;
        model.song.lpb = result.$2;
      });
    }
  }

  Future<String?> _showProjectNameDialog(String title) async {
    String projectName = model.currentProjectName;

    return showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: Colors.black,
          elevation: 0,
          shape: const RoundedRectangleBorder(
            side: BorderSide(color: Colors.white54),
            borderRadius: BorderRadius.zero,
          ),
          title: Text(title, style: trackerStyle(size: 22, color: Colors.white)),
          content: TextField(
            autofocus: true,
            onChanged: (value) {
              projectName = value;
            },
            onSubmitted: (value) => Navigator.of(context).pop(value.isNotEmpty ? value : projectName),
            style: trackerStyle(size: 18, color: kGreen),
            cursorColor: kGreen,
            decoration: InputDecoration(
              hintText: model.currentProjectName,
              hintStyle: trackerStyle(size: 18, color: Colors.white30),
              enabledBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: Colors.white38),
              ),
              focusedBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: Colors.green),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: Text('Cancel', style: trackerStyle(size: 18, color: Colors.white54)),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(projectName),
              child: Text('OK', style: trackerStyle(size: 18, color: kGreen)),
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
                            if (model.currentWindow == 4) _syncMixerSendsToNative();
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
                            if (model.currentWindow == 4) _syncMixerSendsToNative();
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
