import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../tracker_model.dart';
import '../tracker_styles.dart';
import '../sample_browser.dart';
import '../audio/audio_engine.dart';
import '../audio/wav_encoder.dart';

const _rowNumW = 32.0;
const _rowH    = 36.0;

class InstrumentWindow extends StatefulWidget {
  final TrackerModel model;
  final VoidCallback onStateChange;
  final Function(int)? onSamplerOpen;

  const InstrumentWindow({
    required this.model,
    required this.onStateChange,
    this.onSamplerOpen,
    super.key,
  });

  @override
  State<InstrumentWindow> createState() => _InstrumentWindowState();
}

class _InstrumentWindowState extends State<InstrumentWindow> {
  String? _lastBrowserFolder;

  TrackerModel get model => widget.model;
  VoidCallback get onStateChange => widget.onStateChange;

  @override
  void initState() {
    super.initState();
    _loadDefaultSampleFolder();
  }

  Future<void> _loadDefaultSampleFolder() async {
    await model.loadDefaultSampleFolder();
  }

  String _getParentFolder(String filePath) {
    return filePath.replaceAll(RegExp(r'[^${Platform.pathSeparator}]*$'), '');
  }

  /// Record a new sample from the microphone and load it into [instrumentIndex].
  Future<void> _recordSample(int instrumentIndex) async {
    // 1. Request microphone permission.
    if (Platform.isAndroid) {
      final status = await Permission.microphone.request();
      if (!status.isGranted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Microphone permission denied')),
          );
        }
        return;
      }
    }
    if (!mounted) return;

    // 2. Warm up the input stream before recording.
    await NativeAudioEngine.openRecordingStream();
    if (!mounted) {
      await NativeAudioEngine.closeRecordingStream();
      return;
    }

    // 3. Show the recording dialog (it starts/stops the take).
    final shouldSave = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const _RecordingDialog(),
    );

    // 4. Retrieve the captured audio and release the input stream.
    final result = await NativeAudioEngine.stopRecording();
    await NativeAudioEngine.closeRecordingStream();

    if (shouldSave != true || result.samples.isEmpty) return;

    // 5. Encode to WAV and save into the app documents/samples folder.
    final wavBytes = WavEncoder.encodeWav(
      samples: result.samples,
      sampleRate: result.sampleRate,
      numChannels: 1,
    );
    final docsDir = await getApplicationDocumentsDirectory();
    final dir = '${docsDir.path}/samples';
    await Directory(dir).create(recursive: true);
    int n = 1;
    String outName;
    do {
      outName = 'rec_$n.wav';
      n++;
    } while (File('$dir/$outName').existsSync());
    final outPath = '$dir/$outName';
    await File(outPath).writeAsBytes(wavBytes, flush: true);

    // 6. Load the new recording into the instrument slot.
    model.loadSampleForInstrument(instrumentIndex, outPath);
    await NativeAudioEngine.loadSample(instrumentIndex, outPath);
    if (mounted) {
      onStateChange();
      setState(() {});
    }
  }

  void _showSampleEditor(BuildContext context, int instrumentIndex) {
    final currentSample = model.getSampleDisplayName(instrumentIndex);
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black87,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Sample Editor - Instrument ${instrumentIndex + 1}',
                style: trackerStyle(size: 14, color: kGreen),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white, width: 1),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Current Sample:', style: trackerStyle(size: 12, color: Colors.white70)),
                    Text(
                      currentSample.isEmpty ? '(none)' : currentSample,
                      style: trackerStyle(size: 12, color: kGreen),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  ElevatedButton(
                    onPressed: () async {
                      Navigator.pop(ctx);
                      final samplePath = await SampleBrowser.show(
                        context,
                        previewSlot: instrumentIndex,
                        defaultFolder: model.defaultSampleFolder,
                        lastFolder: _lastBrowserFolder,
                        onBookmarkFolder: (folderPath) async {
                          await model.bookmarkSampleFolder(folderPath);
                          setState(() {});
                        },
                        onRemoveBookmark: () async {
                          await model.removeBookmark();
                          setState(() {});
                        },
                      );
                      if (samplePath != null) {
                        _lastBrowserFolder = _getParentFolder(samplePath);
                        model.loadSampleForInstrument(instrumentIndex, samplePath);
                        await NativeAudioEngine.loadSample(instrumentIndex, samplePath);
                        setState(() {});
                      } else {
                        // Restore correct sample — browser preview may have clobbered this slot
                        final orig = model.instruments[instrumentIndex].sample;
                        if (orig.isNotEmpty) await NativeAudioEngine.loadSample(instrumentIndex, orig);
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.grey[800],
                    ),
                    child: Text('Load Sample', style: trackerStyle(size: 11)),
                  ),
                  ElevatedButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.grey[800],
                    ),
                    child: Text('Close', style: trackerStyle(size: 11)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Fixed button width
        const btnW = 42.0;
        const btnSpacing = 5.0;
        final waveformW = constraints.maxWidth - _rowNumW - (btnW + btnSpacing) * 3 - btnSpacing;
        
        // Font sizing based on row height, matching other windows
        final fontSize = (_rowH * 0.6).clamp(16.0, 28.0);
        final ts = trackerStyle(size: fontSize);
        final gs = trackerStyle(size: fontSize, color: kGreen);

        return Column(
          children: [
            Expanded(
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: 99,
                itemExtent: _rowH,
                itemBuilder: (context, row) {
                  final isRowCursor = model.cursorRow == row;
                  final inst = model.instruments[row];
                  final samplePath = inst.sample;
                  final hasSample = samplePath.isNotEmpty;

                  return Row(
                    children: [
                      // Row number
                      SizedBox(
                        width: _rowNumW,
                        child: Text(
                          (row + 1).toString().padLeft(2, '0'),
                          style: isRowCursor ? gs : ts,
                          textAlign: TextAlign.center,
                        ),
                      ),
                      // LOAD button
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () async {
                          model.cursorRow = row;
                          model.cursorCol = 0;
                          onStateChange();
                          final samplePath = await SampleBrowser.show(
                            context,
                            previewSlot: row,
                            defaultFolder: model.defaultSampleFolder,
                            lastFolder: _lastBrowserFolder,
                            onBookmarkFolder: (folderPath) async {
                              await model.bookmarkSampleFolder(folderPath);
                              setState(() {});
                            },
                            onRemoveBookmark: () async {
                              await model.removeBookmark();
                              setState(() {});
                            },
                          );
                          if (samplePath != null) {
                            _lastBrowserFolder = _getParentFolder(samplePath);
                            model.loadSampleForInstrument(row, samplePath);
                            await NativeAudioEngine.loadSample(row, samplePath);
                            onStateChange();
                          } else {
                            // Restore correct sample — browser preview may have clobbered this slot
                            final orig = model.instruments[row].sample;
                            if (orig.isNotEmpty) await NativeAudioEngine.loadSample(row, orig);
                          }
                        },
                        child: Container(
                          width: btnW,
                          margin: EdgeInsets.symmetric(horizontal: btnSpacing / 2),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.white, width: 1.5),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            'LD',
                            style: ts,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                      // EDIT button
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          // Only open sampler if a sample is loaded
                          if (inst.sample.isNotEmpty) {
                            widget.onSamplerOpen?.call(row);
                          }
                        },
                        child: Container(
                          width: btnW,
                          margin: EdgeInsets.symmetric(horizontal: btnSpacing / 2),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.white, width: 1.5),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            'ED',
                            style: inst.sample.isEmpty
                                ? trackerStyle(size: fontSize, color: Colors.grey)
                                : ts,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                      // REC button
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () async {
                          model.cursorRow = row;
                          model.cursorCol = 2;
                          onStateChange();
                          await _recordSample(row);
                        },
                        child: Container(
                          width: btnW,
                          margin: EdgeInsets.symmetric(horizontal: btnSpacing / 2),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.white, width: 1.5),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            'RC',
                            style: ts,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                      // Waveform display area — tap to preview, long-press to clear sample
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: hasSample
                            ? () async {
                                final s = inst.sampler;
                                final pitchFreq = 261.626 * math.pow(2.0, s.pitch);
                                final attackSec = s.attack * 0.5;
                                final releaseSec = s.release * 0.5;
                                await NativeAudioEngine.noteOnRegion(
                                  row, pitchFreq, s.volume,
                                  s.start, s.end,
                                  attackTime: attackSec,
                                  releaseTime: releaseSec,
                                  loopMode: s.loopMode,
                                );
                              }
                            : null,
                        onLongPress: hasSample
                            ? () {
                                model.instruments[row].sample = '';
                                onStateChange();
                              }
                            : null,
                        child: Container(
                          width: waveformW,
                          margin: EdgeInsets.symmetric(horizontal: btnSpacing / 2),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.white, width: 1.5),
                            color: const Color(0xFF0a0a0a),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            hasSample ? model.getSampleDisplayName(row) : 'empty',
                            style: hasSample
                                ? trackerStyle(size: fontSize, color: kGreen)
                                : trackerStyle(size: fontSize, color: Colors.grey),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Modal recording dialog: starts a take on open, shows a red dot + elapsed
/// timer, and pops `true` to keep the recording or `false` to discard it.
class _RecordingDialog extends StatefulWidget {
  const _RecordingDialog();

  @override
  State<_RecordingDialog> createState() => _RecordingDialogState();
}

class _RecordingDialogState extends State<_RecordingDialog> {
  static const int _maxSeconds = 60;
  Timer? _timer;
  int _elapsedMs = 0;
  bool _blink = true;

  @override
  void initState() {
    super.initState();
    NativeAudioEngine.startRecording();
    _timer = Timer.periodic(const Duration(milliseconds: 100), (t) {
      if (!mounted) return;
      setState(() {
        _elapsedMs += 100;
        _blink = (_elapsedMs ~/ 500).isEven;
      });
      if (_elapsedMs >= _maxSeconds * 1000) {
        Navigator.of(context).pop(true);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String get _timeLabel {
    final totalSec = _elapsedMs ~/ 1000;
    final m = (totalSec ~/ 60).toString().padLeft(2, '0');
    final s = (totalSec % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.black,
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: Colors.white, width: 1),
        borderRadius: BorderRadius.zero,
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.circle,
                    color: _blink ? Colors.red : Colors.red.withValues(alpha: 0.2),
                    size: 14),
                const SizedBox(width: 10),
                Text('RECORDING',
                    style: trackerStyle(size: 14, color: Colors.red)),
              ],
            ),
            const SizedBox(height: 16),
            Text(_timeLabel, style: trackerStyle(size: 28, color: kGreen)),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.of(context).pop(false),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white, width: 1.5),
                    ),
                    child: Text('CANCEL',
                        style: trackerStyle(size: 12, color: Colors.white70)),
                  ),
                ),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.of(context).pop(true),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                    decoration: BoxDecoration(
                      border: Border.all(color: kGreen, width: 1.5),
                    ),
                    child:
                        Text('STOP', style: trackerStyle(size: 12, color: kGreen)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
