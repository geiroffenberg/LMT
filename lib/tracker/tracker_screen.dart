import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'tracker_model.dart';
import 'tracker_styles.dart';
import 'windows/song_window.dart';
import 'windows/chain_window.dart';
import 'windows/phrase_window.dart';
import 'windows/instrument_window.dart';
import 'windows/mixer_window.dart';
import 'windows/sampler_window.dart';
import 'windows/manual_window.dart';
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
  List<int> _phraseStepMap = [];  // C++ row index → phrase step number
  int _currentStepIndex    = 0;   // current position in C++ queue
  int _playbackWindow      = 0;   // window that triggered play (0=song, 1=chain, 2=phrase)
  Timer? _autoSaveTimer;
  final FocusNode _keyListenerFocusNode = FocusNode();

  // Saved song-view cursor — persists through instrument/mixer visits
  int _songCursorRow       = 0;
  int _songCursorCol       = 0;
  bool _songCellWasEmpty   = true; // true when saved cell had no chain ref

  // Saved chain-view cursor — persists through phrase/instrument/mixer visits
  int _chainCursorRow      = 0;
  int _chainCursorCol      = 0;

  // Saved chain index — persists when navigating from chain to phrase and back
  int _savedChainIdx       = 0;
  
  // Saved phrase index — persists when navigating from phrase to other views and back
  int _savedPhraseIdx      = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    model = widget.initialModel ?? TrackerModel();
    // Autosave disabled — use SAVE SONG from the menu
    // _autoSaveTimer = Timer.periodic(
    //   const Duration(seconds: 60),
    //   (_) => _autoSave(),
    // );
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
    // Stop playback when the app is backgrounded so the loop doesn't keep
    // running in the background (and can't be stopped on return).
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      if (model.isPlaying) {
        model.stopPlayback();
      }
      _stepTimer?.cancel();
      _stepTimer = null;
      NativeAudioEngine.clearQueue();
      NativeAudioEngine.stopAll();
      if (mounted) setState(() {});
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
      final instr = model.instruments[i];
      if (instr.sample.isNotEmpty) {
        await NativeAudioEngine.loadSample(i, instr.sample);
      }
      // Restore sampler params (start/end/attack/release/loop/pitch/vol)
      final s = instr.sampler;
      await NativeAudioEngine.setInstrumentPlaybackParams(
        i, s.pitch, s.volume, s.start, s.end, s.attack, s.release, s.loopMode,
      );
      // Engine resets on init — restore HP/LP filters too.
      await NativeAudioEngine.setInstrumentFilters(i, s.hpCutoff, s.lpCutoff);
    }
    // Push current mixer + mute state to the engine so the audio side
    // matches the model after init/resume/load.
    _syncMixerSendsToNative();
    _syncTrackMutesToNative();
  }

  // Autosave disabled — use SAVE SONG from the menu
  // Future<void> _autoSave() async {
  //   try {
  //     await ProjectManager.saveProject(ProjectManager.autoSaveName, model);
  //   } catch (e) {
  //     debugPrint('Autosave failed: $e');
  //   }
  // }

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

  /// Preview a note in phrase window when it's edited (note or instrument column)
  void _playPhraseNotePreview() {
    final step = model.phrases[model.activePhraseIdx].steps[model.cursorRow];
    final instIdx = step.instrument;
    final noteVal = step.note;

    // Only play if instrument is assigned and note is valid (0-120)
    if (instIdx <= 0 || noteVal < 0 || noteVal > 120) return;

    final int nativeIdx = instIdx - 1; // instrument is 1-indexed in model
    final freq = 440.0 * math.pow(2.0, (noteVal - 69) / 12.0);
    final vol  = step.volume > 0 ? step.volume / 99.0 : 0.8;

    // Use sampler params so start/end/attack/release/loop are respected
    final s = model.instruments[nativeIdx].sampler;
    NativeAudioEngine.noteOnRegion(
      nativeIdx,
      freq,
      vol * s.volume,
      s.start,
      s.end,
      attackTime:  s.attack,
      releaseTime: s.release,
      loopMode:    s.loopMode,
    );
  }

  void _syncMixerSendsToNative() {
    for (int i = 0; i < model.mixerChannels.length; i++) {
      final ch = model.mixerChannels[i];
      NativeAudioEngine.setTrackSends(
        i,
        ch.reverbSend / 99.0,
        ch.delaySend  / 99.0,
        ch.chorusSend / 99.0,
      );
      NativeAudioEngine.setTrackLevel(i, ch.level / 99.0);
    }
  }

  /// Push effective mute state (mute + solo combined) for all 8 tracks.
  void _syncTrackMutesToNative() {
    for (int i = 0; i < 8; i++) {
      NativeAudioEngine.setTrackMute(i, !model.isTrackAudible(i));
    }
  }

  /// Rebuild and re-enqueue rows from the current playhead so changes to
  /// mute/solo (or other "structural" edits) take effect on the next row.
  Future<void> _reenqueueFromPlayhead() async {
    if (!model.isPlaying) return;
    final data = _playbackWindow == 2
        ? model.buildPhraseData(model.activePhraseIdx)
        : _playbackWindow == 1
            ? model.buildSongRowData(model.playheadRow,
                limitSlots: model.chains[model.activeChainIdx]
                    .items.where((ci) => ci.phrase != 0).length)
            : model.buildPlaybackData(startRow: model.playheadRow);
    if (data.rows.isEmpty) return;
    await NativeAudioEngine.clearQueue();
    await NativeAudioEngine.enqueueAllRows(model.isLooping, data.rows);
    _songRowMap    = data.songRowMap;
    _chainRowMap   = data.chainRowMap;
    _phraseStepMap = data.phraseStepMap;
    _currentStepIndex = 0;
  }

  void _startPollTimer() {
    _stepTimer?.cancel();
    _stepTimer = Timer.periodic(const Duration(milliseconds: 16), (_) async {
      final advanced = await NativeAudioEngine.consumeRowAdvances();
      if (advanced > 0) {
        setState(() {
          // Map step index → actual song row and chain slot
          if (_songRowMap.isNotEmpty) {
            final nextIndex = _currentStepIndex + advanced;
            final wrapped = nextIndex % _songRowMap.length;
            
            // If we wrapped AND loop is off, stop playback
            if (nextIndex >= _songRowMap.length && !model.isLooping) {
              model.stopPlayback();
              _stepTimer?.cancel();
              _stepTimer = null;
              return;
            }
            
            _currentStepIndex = wrapped;
            model.playheadRow      = _songRowMap[_currentStepIndex];
            model.playheadChainRow = _chainRowMap[_currentStepIndex];
            model.phraseStep       = _phraseStepMap.isNotEmpty ? _phraseStepMap[_currentStepIndex] : 0;
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
      _currentStepIndex = 0;
      _playbackWindow   = model.currentWindow;

      // Playback rules — all 8 tracks always play; Solo/Mute to isolate.
      //   Song view  → full song from cursor row; loop wraps to cursor row.
      //   Chain view → one song row, all 8 tracks, all slots; always loops from slot 0.
      //   Phrase view → this phrase solo, loop from step 0.
      late final ({List<Map<String, dynamic>> rows, List<int> songRowMap, List<int> chainRowMap, List<int> phraseStepMap}) data;
      int startOffset = 0;

      if (_playbackWindow == 2) {
        // Phrase view: play this phrase solo, looping from step 0.
        data = model.buildPhraseData(model.activePhraseIdx);
      } else if (_playbackWindow == 1) {
        // Chain view: find the song row containing this chain, then build just
        // that one row (all 8 tracks, all chain slots, shorter chains loop).
        final chainRef = model.activeChainIdx + 1;
        int foundRow = -1;
        for (int r = 0; r < 99; r++) {
          if (model.isSongRowEmpty(r)) break;
          for (int t = 0; t < 8; t++) {
            if (model.song.chains[r][t] == chainRef) { foundRow = r; break; }
          }
          if (foundRow >= 0) break;
        }
        if (foundRow < 0) {
          model.stopPlayback();
          setState(() {});
          return;
        }
        // Limit slots to the active chain's own length so the playhead
        // doesn't advance into slots that are empty in the viewed chain.
        final activeChainSlots = model.chains[model.activeChainIdx]
            .items.where((ci) => ci.phrase != 0).length;
        data = model.buildSongRowData(foundRow, limitSlots: activeChainSlots);
      } else {
        // Song view: full song, start at cursor row.
        data = model.buildPlaybackData(startRow: 0);
        for (int i = 0; i < data.songRowMap.length; i++) {
          if (data.songRowMap[i] == model.cursorRow) { startOffset = i; break; }
        }
      }

      _songRowMap    = data.songRowMap;
      _chainRowMap   = data.chainRowMap;
      _phraseStepMap = data.phraseStepMap;

      // Rotate or trim based on loop state.
      List<Map<String, dynamic>> playRows;
      if (model.isLooping && startOffset > 0) {
        playRows = [
          ...data.rows.sublist(startOffset),
          ...data.rows.sublist(0, startOffset),
        ];
        _songRowMap    = [..._songRowMap.sublist(startOffset),    ..._songRowMap.sublist(0, startOffset)];
        _chainRowMap   = [..._chainRowMap.sublist(startOffset),   ..._chainRowMap.sublist(0, startOffset)];
        _phraseStepMap = [..._phraseStepMap.sublist(startOffset), ..._phraseStepMap.sublist(0, startOffset)];
      } else if (!model.isLooping && startOffset > 0) {
        playRows       = data.rows.sublist(startOffset);
        _songRowMap    = _songRowMap.sublist(startOffset);
        _chainRowMap   = _chainRowMap.sublist(startOffset);
        _phraseStepMap = _phraseStepMap.sublist(startOffset);
      } else {
        playRows = data.rows;
      }
      _currentStepIndex = 0;

      model.playheadRow      = _playbackWindow == 0 ? model.cursorRow : 0;
      model.playheadChainRow = 0;

      if (playRows.isEmpty) {
        model.stopPlayback();
        setState(() {});
        return;
      }
      await NativeAudioEngine.enqueueAllRows(model.isLooping, playRows);
      _startPollTimer();
      setState(() {});
    }
  }

  /// Navigate to a window, setting activeChainIdx / activePhraseIdx from context.
  void _navigateToWindow(int windowIndex) {
    model.exitEditMode();
    model.clearLineSelection();
    final fromWindow = model.currentWindow;

    // ── Save cursor whenever leaving song or chain view ───────────────────
    if (fromWindow == 0) {
      _songCursorRow    = model.cursorRow;
      _songCursorCol    = model.cursorCol;
      _songCellWasEmpty = model.song.chains[model.cursorRow][model.cursorCol] <= 0;
    } else if (fromWindow == 1) {
      _chainCursorRow   = model.cursorRow;
      _chainCursorCol   = model.cursorCol;
      _savedChainIdx    = model.activeChainIdx;
    } else if (fromWindow == 2) {
      _savedPhraseIdx   = model.activePhraseIdx;
    }

    // ── Forward navigation rules ─────────────────────────────────────────
    // Chain window
    if (windowIndex == 1) {
      if (fromWindow == 0) {
        // Direct from song: use current song cursor.
        final chainRef = model.song.chains[model.cursorRow][model.cursorCol];
        if (chainRef <= 0) return;
        model.activeChainIdx = chainRef - 1;
      } else if (fromWindow == 2) {
        // From phrase: restore saved chain index
        model.activeChainIdx = _savedChainIdx;
      } else if (fromWindow == 3 || fromWindow == 4) {
        // From instrument/mixer: use saved song cursor.
        if (_songCellWasEmpty) return;
        final chainRef = model.song.chains[_songCursorRow][_songCursorCol];
        if (chainRef <= 0) return;
        model.activeChainIdx = chainRef - 1;
      }
      // From Chain itself: always allowed, activeChainIdx already set.
    }
    // Phrase window
    else if (windowIndex == 2) {
      if (fromWindow == 1) {
        final item = model.chains[model.activeChainIdx].items[model.cursorRow];
        if (item.phrase <= 0) return;
        model.activePhraseIdx = item.phrase - 1;
      } else if (fromWindow == 0) {
        return; // must go Song → Chain first
      } else if (fromWindow == 3 || fromWindow == 4) {
        // From instrument/mixer: restore saved phrase index
        model.activePhraseIdx = _savedPhraseIdx;
      }
      // From Phrase itself: always allowed.
    }

    // ── Always allowed: Song, Instrument, Mixer ──────────────────────────
    _samplerInstrumentOpen = -1; // close sampler when switching windows
    model.currentWindow = windowIndex;

    if (windowIndex == 0) {
      if (fromWindow == 3 || fromWindow == 4) {
        // Returning from instrument/mixer: restore the exact song cursor the
        // user had before leaving song view.
        model.cursorRow = _songCursorRow;
        model.cursorCol = _songCursorCol;
      } else {
        // Returning from chain/phrase: land on the song cell that references
        // the active chain so the breadcrumb stays consistent.
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
      }
    } else if (windowIndex == 1) {
      // Chain window: start at row 0 when arriving fresh from song view;
      // restore saved cursor when returning from phrase/instrument/mixer.
      if (fromWindow == 0) {
        model.cursorRow = 0;
        model.cursorCol = 0;
      } else {
        model.cursorRow = _chainCursorRow;
        model.cursorCol = _chainCursorCol;
      }
    } else {
      model.cursorRow = 0;
      model.cursorCol = 0;
    }
  }

  void _handleKey(KeyEvent event) {
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
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
              model.pushUndo();
              model.song.bpm = bpm;
              model.editingBPM = false;
              model.inEditMode = false;
              model.editBuffer = '';
            });
          } else {
            setState(() {
              if (model.editBuffer.isNotEmpty) model.pushUndo();
              model.applyEdit(model.editBuffer);
              if (model.currentWindow == 4) _syncMixerSendsToNative();
              // Trigger audio preview for phrase note editing
              _playPhraseNotePreview();
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
    return KeyboardListener(
      focusNode: _keyListenerFocusNode,
      onKeyEvent: _handleKey,
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
                        final bool isMuted  = model.mutedTracks.contains(ch);
                        final bool isSoloed = model.soloedTracks.contains(ch);
                        return Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // LED meter: 6 blocks × 5 dB, range −30..0 dB.
                              // Tap = toggle solo
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () async {
                                  model.toggleSolo(ch);
                                  setState(() {});
                                  _syncTrackMutesToNative();
                                },
                                child: Builder(builder: (context) {
                                  final double dB = audioLevel > 1e-6
                                      ? 20.0 * math.log(audioLevel) / math.ln10
                                      : -60.0;
                                  final Color borderColor = isSoloed
                                      ? Colors.yellow
                                      : Colors.white;
                                  return Container(
                                    width: meterWidth,
                                    height: 40,
                                    decoration: BoxDecoration(
                                      border: Border.all(color: borderColor, width: isSoloed ? 2 : 1),
                                      color: Colors.black,
                                    ),
                                    padding: const EdgeInsets.all(2),
                                    child: Stack(
                                      children: [
                                        Column(
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
                                        if (isSoloed)
                                          const Positioned(
                                            top: 0, left: 0, right: 0,
                                            child: Center(
                                              child: Text('S',
                                                style: TextStyle(
                                                  color: Colors.yellow,
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.bold),
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  );
                                }),
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
                      // Undo
                      GestureDetector(
                        onTap: () {
                          if (!model.canUndo) return;
                          setState(() {
                            model.undo();
                          });
                          _syncMixerSendsToNative();
                          _syncTrackMutesToNative();
                          _reenqueueFromPlayhead();
                        },
                        child: Container(
                          width: 32,
                          height: 36,
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: model.canUndo ? Colors.white : Colors.white24,
                              width: 2,
                            ),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            '↶',
                            style: trackerStyle(
                              size: fontSize,
                              color: model.canUndo ? Colors.white : Colors.white24,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      // Redo
                      GestureDetector(
                        onTap: () {
                          if (!model.canRedo) return;
                          setState(() {
                            model.redo();
                          });
                          _syncMixerSendsToNative();
                          _syncTrackMutesToNative();
                          _reenqueueFromPlayhead();
                        },
                        child: Container(
                          width: 32,
                          height: 36,
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: model.canRedo ? Colors.white : Colors.white24,
                              width: 2,
                            ),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            '↷',
                            style: trackerStyle(
                              size: fontSize,
                              color: model.canRedo ? Colors.white : Colors.white24,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
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
    const menuItems = ['SAVE SONG', 'SAVE AS...', 'NEW SONG', 'LOAD SONG', 'EXPORT WAV', 'EXPORT ZIP', 'IMPORT ZIP', 'SONG SETTINGS', 'MANUAL'];

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
          children: [
            // Project name header
            Container(
              height: 36,
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Colors.white, width: 1)),
              ),
              alignment: Alignment.center,
              child: Text(
                model.currentProjectName,
                style: trackerStyle(size: 18, color: kGreen),
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            ...menuItems.map((item) {
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
          }),
          ],
        ),
      ),
    );
  }

  void _showStatusSnackBar(bool ok, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        duration: const Duration(seconds: 3),
        content: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            border: Border.all(color: ok ? kGreen : Colors.red, width: 2),
          ),
          child: Text(
            message,
            style: trackerStyle(size: 18, color: ok ? kGreen : Colors.red),
          ),
        ),
      ),
    );
  }

  void _handleProjectMenuAction(String action) async {
    switch (action) {
      case 'SAVE SONG':
        final projectName = model.currentProjectName;
        final saveOk = await ProjectManager.saveProject(projectName, model);
        if (!mounted) return;
        setState(() {});
        _showStatusSnackBar(saveOk, saveOk ? 'Saved: $projectName' : 'Save FAILED — check logs');
        break;

      case 'SAVE AS...':
        final newName = await _showProjectNameDialog('SAVE AS');
        if (newName != null && newName.isNotEmpty) {
          // Warn if a project with that name already exists
          final existing = await ProjectManager.listProjects();
          final clash = existing.any((d) =>
              ProjectManager.getProjectName(d).toLowerCase() == newName.toLowerCase());
          if (clash && mounted) {
            final overwrite = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                backgroundColor: Colors.black,
                title: Text('OVERWRITE?',
                    style: trackerStyle(size: 20, color: Colors.red)),
                content: Text(
                  'A project named "$newName" already exists. Overwrite it?',
                  style: trackerStyle(size: 16, color: Colors.white),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text('Cancel',
                        style: trackerStyle(size: 18, color: Colors.white54)),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text('Overwrite',
                        style: trackerStyle(size: 18, color: Colors.red)),
                  ),
                ],
              ),
            );
            if (overwrite != true) break;
          }
          final saveOk = await ProjectManager.saveProject(newName, model);
          if (!mounted) return;
          // Note: ProjectManager.saveProject already calls model.setCurrentProject
          // with the real path — don't override it here.
          setState(() {});
          _showStatusSnackBar(saveOk, saveOk ? 'Saved as: $newName' : 'Save FAILED — check logs');
        }
        break;

      case 'NEW SONG':
        final songName = await _showProjectNameDialog('NEW SONG');
        if (songName != null && songName.isNotEmpty) {
          model.newSong();
          model.setCurrentProject(songName, '');
          final saveOk = await ProjectManager.saveProject(songName, model);
          if (!mounted) return;
          setState(() {});
          _showStatusSnackBar(saveOk, saveOk ? 'Created: $songName' : 'Save FAILED — check logs');
        }
        break;

      case 'LOAD SONG':
        _showLoadSongDialog();
        break;

      case 'EXPORT WAV':
        _exportSongToWav();
        break;

      case 'EXPORT ZIP':
        _exportProjectAsZip();
        break;

      case 'IMPORT ZIP':
        _importProjectFromZip();
        break;

      case 'SONG SETTINGS':
        _showSongSettingsDialog();
        break;

      case 'MANUAL':
        showManual(context);
        break;
    }
  }

  Future<void> _importProjectFromZip() async {
    // Use withData:true — on Android 10+ the picked path may be a content URI
    // that File() cannot read directly; bytes are always populated.
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
      withData: true,
    );
    if (result == null || result.files.single.bytes == null) return;

    final bytes = result.files.single.bytes!;
    final zipBasename = result.files.single.name;

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.black,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          side: BorderSide(color: Colors.white54),
          borderRadius: BorderRadius.zero,
        ),
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: kGreen),
            const SizedBox(width: 16),
            Text('Importing ZIP...', style: trackerStyle(size: 18, color: Colors.white)),
          ],
        ),
      ),
    );

    bool ok = false;
    String message = 'Import failed';

    try {
      // Derive project name from zip filename (strip .zip)
      final projectName = zipBasename.endsWith('.zip')
          ? zipBasename.substring(0, zipBasename.length - 4)
          : zipBasename;

      // Create project folder in LMT_PROJECTS
      final projectDir = await ProjectManager.createProject(projectName);
      if (projectDir == null) throw Exception('Could not create project folder');

      // Extract zip into project folder using archive's built-in extractor
      final archive = ZipDecoder().decodeBytes(bytes);
      extractArchiveToDisk(archive, projectDir.path);

      // Verify song.lmt exists
      final songFile = File('${projectDir.path}/${ProjectManager.songFileName}');
      if (!songFile.existsSync()) {
        // Clean up and bail
        await projectDir.delete(recursive: true);
        throw Exception('ZIP does not contain a valid LMT project (missing song.lmt)');
      }

      // Load the project
      final loadedModel = await ProjectManager.loadProject(projectDir);
      if (loadedModel == null) throw Exception('Could not parse project data');
      loadedModel.setCurrentProject(
        ProjectManager.getProjectName(projectDir),
        projectDir.path,
      );

      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop(); // close spinner

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
        _phraseStepMap = [];
      });
      model.clearUndoHistory();
      _syncMixerSendsToNative();
      _syncTrackMutesToNative();

      _showStatusSnackBar(true, 'Imported: $projectName');
      return;
    } catch (e) {
      message = 'Import failed: $e';
    }

    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    _showStatusSnackBar(ok, message);
  }

  Future<void> _exportProjectAsZip() async {
    if (model.currentProjectName == 'UNTITLED' || !model.hasProjectPath()) {
      _showStatusSnackBar(false, 'Name your song first (use SAVE AS...)');
      return;
    }

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.black,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          side: BorderSide(color: Colors.white54),
          borderRadius: BorderRadius.zero,
        ),
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: kGreen),
            const SizedBox(width: 16),
            Text('Zipping project...', style: trackerStyle(size: 18, color: Colors.white)),
          ],
        ),
      ),
    );

    String? resultMessage;
    bool ok = false;

    try {
      final projectDir = Directory(model.currentProjectPath);
      final zipFileName = '${model.currentProjectName}.zip';

      // Auto-save before zipping so the zip reflects current state
      await ProjectManager.saveProject(model.currentProjectName, model);

      // Write zip to a temp file in app cache
      final cacheDir = await getTemporaryDirectory();
      final tempZipPath = '${cacheDir.path}/$zipFileName';

      final encoder = ZipFileEncoder();
      encoder.create(tempZipPath);
      await encoder.addDirectory(projectDir, includeDirName: false);
      encoder.close();

      // Copy to public Downloads
      final saved = await NativeAudioEngine.saveToDownloads(
          sourcePath: tempZipPath, fileName: zipFileName);
      // Clean up temp file
      File(tempZipPath).deleteSync();

      ok = saved != null;
      resultMessage = ok ? 'ZIP saved to Downloads: $zipFileName' : 'ZIP export failed';
    } catch (e) {
      resultMessage = 'ZIP export failed: $e';
    }

    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    _showStatusSnackBar(ok, resultMessage);
    setState(() {});
  }

  Future<void> _exportSongToWav() async {
    if (model.isPlaying) {
      _showStatusSnackBar(false, 'Stop playback before exporting');
      return;
    }
    if (model.currentProjectName == 'UNTITLED' || !model.hasProjectPath()) {
      _showStatusSnackBar(false, 'Name your song first (use SAVE AS...)');
      return;
    }

    // Show progress indicator
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.black,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          side: BorderSide(color: Colors.white54),
          borderRadius: BorderRadius.zero,
        ),
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: kGreen),
            const SizedBox(width: 16),
            Text('Exporting WAV...', style: trackerStyle(size: 18, color: Colors.white)),
          ],
        ),
      ),
    );

    final filePath = await model.exportSongToWav();

    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // close dialog

    if (filePath != null) {
      _showStatusSnackBar(true, 'WAV saved to Downloads: ${filePath.split('/').last}');
    } else {
      _showStatusSnackBar(false, 'Export failed — is the song empty?');
    }
    setState(() {});
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
      builder: (ctx) {
        final list = List<Directory>.from(projects);
        return StatefulBuilder(
          builder: (ctx, setDlgState) => AlertDialog(
            backgroundColor: Colors.black,
            elevation: 0,
            shape: const RoundedRectangleBorder(
              side: BorderSide(color: Colors.white54),
              borderRadius: BorderRadius.zero,
            ),
            title: Text('Load Song', style: trackerStyle(size: 22, color: Colors.white)),
            content: SizedBox(
              width: double.maxFinite,
              child: list.isEmpty
                  ? Text('No projects.', style: trackerStyle(size: 18, color: Colors.white54))
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: list.length,
                      itemBuilder: (_, i) {
                        final name = ProjectManager.getProjectName(list[i]);
                        return Container(
                          decoration: const BoxDecoration(
                            border: Border(bottom: BorderSide(color: Colors.white12)),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: InkWell(
                                  onTap: () => Navigator.pop(ctx, list[i]),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                                    child: Text(name, style: trackerStyle(size: 18, color: kGreen)),
                                  ),
                                ),
                              ),
                              InkWell(
                                onTap: () async {
                                  // Confirm before deleting
                                  final confirm = await showDialog<bool>(
                                    context: ctx,
                                    builder: (c2) => AlertDialog(
                                      backgroundColor: Colors.black,
                                      elevation: 0,
                                      shape: const RoundedRectangleBorder(
                                        side: BorderSide(color: Colors.red),
                                        borderRadius: BorderRadius.zero,
                                      ),
                                      title: Text('Delete "$name"?',
                                          style: trackerStyle(size: 20, color: Colors.red)),
                                      content: Text('This cannot be undone.',
                                          style: trackerStyle(size: 16, color: Colors.white54)),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.pop(c2, false),
                                          child: Text('CANCEL', style: trackerStyle(size: 16, color: Colors.white54)),
                                        ),
                                        TextButton(
                                          onPressed: () => Navigator.pop(c2, true),
                                          child: Text('DELETE', style: trackerStyle(size: 16, color: Colors.red)),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (confirm == true) {
                                    await list[i].delete(recursive: true);
                                    setDlgState(() => list.removeAt(i));
                                  }
                                },
                                child: const Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                  child: Icon(Icons.delete_outline, color: Colors.red, size: 20),
                                ),
                              ),
                            ],
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
      },
    );

    if (selectedDir == null || !mounted) return;

    final loadedModel = await ProjectManager.loadProject(selectedDir);
    if (loadedModel == null || !mounted) return;

    // Title bar should reflect the loaded project
    loadedModel.setCurrentProject(
      ProjectManager.getProjectName(selectedDir),
      selectedDir.path,
    );

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
      _phraseStepMap = [];
    });
    model.clearUndoHistory();
    _syncMixerSendsToNative();
    _syncTrackMutesToNative();
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
                            model.pushUndo();
                            model.moveSelectionUp();
                          } else if (item == '↓') {
                            model.pushUndo();
                            model.moveSelectionDown();
                          } else if (item == '2x') {
                            model.pushUndo();
                            model.duplicateSelection();
                          } else if (item == 'DEL') {
                            model.pushUndo();
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
    // Chain window PH column with data: REP + DEL + X
    // Phrase note column: OFF + END + DEL + X
    // Phrase other columns: CPY + CUT + PST + DEL + X
    // Chain / Instrument / Mixer: just DEL + X (+/- in line 1 is enough)
    final isChainPhCol = model.currentWindow == 1 && model.cursorCol == 0 &&
        model.chains[model.activeChainIdx].items[model.cursorRow].phrase > 0;
    final line2Items = model.currentWindow == 0
        ? ['CLO', 'DEL', 'X']
        : isChainPhCol
            ? ['CLO', 'DEL', 'X']
            : model.currentWindow == 2
                ? (isNoteColumn
                    ? ['OFF', 'END', 'DEL', 'X']
                    : ['CPY', 'CUT', 'PST', 'DEL', 'X'])
                : ['DEL', 'X'];

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
                            model.pushUndo();
                            model.performMenuAction(item);
                            if (model.currentWindow == 4) _syncMixerSendsToNative();
                            // Preview after pitch nudge in phrase note column
                            if (model.currentWindow == 2 && model.cursorCol == 0) {
                              _playPhraseNotePreview();
                            }
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
                            model.pushUndo();
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
        return PhraseWindow(
          model: model,
          onStateChange: () => setState(() {}),
          onNotePreview: _playPhraseNotePreview,
        );
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
