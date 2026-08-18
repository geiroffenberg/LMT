import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../tracker_model.dart';
import '../tracker_styles.dart';
import '../audio/audio_engine.dart';

const _rowNumW = 32.0;
const _rowH = 36.0;

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


  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Fixed button width
        const btnW = 42.0;
        const btnSpacing = 5.0;
        // One button instead of three: the row is now [EDIT][sample title].
        final waveformW =
            constraints.maxWidth - _rowNumW - (btnW + btnSpacing * 2);

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
                      // EDIT button — always active; opens the sampler
                      // where Load and Record now both live.
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          widget.onSamplerOpen?.call(row);
                        },
                        child: Container(
                          width: btnW,
                          margin: EdgeInsets.symmetric(
                            horizontal: btnSpacing / 2,
                          ),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.white, width: 1.5),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            'EDIT',
                            style: trackerStyle(
                              size: fontSize - 4,
                              color: kGreen,
                            ),
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
                                final pitchFreq =
                                    261.626 * math.pow(2.0, s.pitch);
                                final attackSec = s.attack * 0.5;
                                final releaseSec = s.release * 0.5;
                                await NativeAudioEngine.noteOnRegion(
                                  row,
                                  pitchFreq,
                                  s.volume,
                                  s.start,
                                  s.end,
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
                          margin: EdgeInsets.symmetric(
                            horizontal: btnSpacing / 2,
                          ),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.white, width: 1.5),
                            color: const Color(0xFF0a0a0a),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            hasSample
                                ? model.getSampleDisplayName(row)
                                : 'empty',
                            style: hasSample
                                ? trackerStyle(size: fontSize, color: kGreen)
                                : trackerStyle(
                                    size: fontSize,
                                    color: Colors.grey,
                                  ),
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

