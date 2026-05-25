import 'package:flutter/material.dart';
import '../tracker_model.dart';
import '../tracker_styles.dart';
import '../audio/audio_engine.dart';

const _rowH = 36.0;

class FxWindow extends StatefulWidget {
  final TrackerModel model;
  final VoidCallback onStateChange;
  final VoidCallback? onClose;

  const FxWindow({
    required this.model,
    required this.onStateChange,
    this.onClose,
    super.key,
  });

  @override
  State<FxWindow> createState() => _FxWindowState();
}

class _FxWindowState extends State<FxWindow> {
  MasterFx get fx => widget.model.masterFx;

  final double fontSize = (_rowH * 0.6).clamp(16.0, 28.0);

  Widget _paramRow(
    String label,
    double value,
    double min,
    double max,
    String display,
    void Function(double) onChanged,
  ) {
    final ts = trackerStyle(size: fontSize);
    return Container(
      height: _rowH,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(children: [
        SizedBox(
          width: 60,
          child: Text(label, style: ts, textAlign: TextAlign.left),
        ),
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: (details) {
              final width = MediaQuery.of(context).size.width - 80;
              final newVal = (value + details.delta.dx / width * (max - min))
                  .clamp(min, max);
              setState(() => onChanged(newVal));
              widget.onStateChange();
            },
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 1),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Align(
                alignment: Alignment(
                  2 * ((value - min) / (max - min)) - 1,
                  0,
                ),
                child: Container(width: 8, height: 8, color: kGreen),
              ),
            ),
          ),
        ),
        SizedBox(
          width: 56,
          child: Text(
            display,
            style: trackerStyle(size: fontSize, color: kGreen),
            textAlign: TextAlign.right,
          ),
        ),
      ]),
    );
  }

  Widget _sectionHeader(String text) {
    return Container(
      height: _rowH,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.centerLeft,
      child: Text(text, style: trackerStyle(size: fontSize)),
    );
  }

  String _pct(double v) => '${(v * 100).round()}%';
  String _hz(double v)  => v >= 1 ? '${v.toStringAsFixed(1)}Hz' : '${(v * 1000).round()}mHz';
  String _lines(double v) => '${v.round()}ln';
  String _fmt1(double v) => v.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [

          // ── Reverb ──────────────────────────────────────────────────────
          _sectionHeader('REVERB'),
          _paramRow('SIZE', fx.reverbSize,  0, 1, _pct(fx.reverbSize),
              (v) { fx.reverbSize = v; NativeAudioEngine.setReverbSize(v); }),
          _paramRow('DAMP', fx.reverbDamp,  0, 1, _pct(fx.reverbDamp),
              (v) { fx.reverbDamp = v; NativeAudioEngine.setReverbDamping(v); }),
          _paramRow('WID',  fx.reverbWidth, 0, 1, _pct(fx.reverbWidth),
              (v) { fx.reverbWidth = v; NativeAudioEngine.setReverbWidth(v); }),

          // ── Delay ────────────────────────────────────────────────────────
          _sectionHeader('DELAY'),
          _paramRow('L TM', fx.delayTimeL,    1, 16, _lines(fx.delayTimeL),
              (v) { fx.delayTimeL = v; NativeAudioEngine.setDelayTime((v - 1) / 15); }),
          _paramRow('R TM', fx.delayTimeR,    1, 16, _lines(fx.delayTimeR),
              (v) { fx.delayTimeR = v; NativeAudioEngine.setDelayTime((v - 1) / 15); }),
          _paramRow('FDBK', fx.delayFeedback,  0,    1, _pct(fx.delayFeedback),
              (v) { fx.delayFeedback = v; NativeAudioEngine.setDelayFeedback(v); }),

          // ── Chorus ───────────────────────────────────────────────────────
          _sectionHeader('CHORUS'),
          _paramRow('RATE', fx.chorusRate,  0.1, 5,   _hz(fx.chorusRate),
              (v) { fx.chorusRate = v; NativeAudioEngine.setChorusRate((v - 0.1) / 4.9); }),
          _paramRow('DPTH', fx.chorusDepth, 0,   1,   _pct(fx.chorusDepth),
              (v) { fx.chorusDepth = v; NativeAudioEngine.setChorusDepth(v); }),

          const SizedBox(height: 8),

          // ── Back button ───────────────────────────────────────────────
          if (widget.onClose != null)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onClose,
              child: Container(
                height: _rowH,
                margin: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white, width: 1),
                ),
                alignment: Alignment.center,
                child: Text('BACK', style: trackerStyle(size: fontSize)),
              ),
            ),

          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
