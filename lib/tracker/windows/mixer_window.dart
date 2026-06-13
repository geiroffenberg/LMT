import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../audio/audio_engine.dart';
import '../tracker_model.dart';
import '../tracker_styles.dart';
import 'fx_window.dart';

// Channel grid constants
const _rowLabelW = 40.0;
const _rowH      = 36.0;
const _numCols   = 8;
const _rowLabels = ['LVL', 'RVB', 'DLY', 'CHO'];

class MixerWindow extends StatefulWidget {
  final TrackerModel model;
  final VoidCallback onStateChange;
  final ValueListenable<double>? masterPeak;

  const MixerWindow({
    required this.model,
    required this.onStateChange,
    this.masterPeak,
    super.key,
  });

  @override
  State<MixerWindow> createState() => _MixerWindowState();
}

class _MixerWindowState extends State<MixerWindow> {
  TrackerModel get model => widget.model;
  bool _showFx = false;

  // ── Section spacer — invisible gap ───────────────────────────────────────
  Widget _sectionLabel(String text, double fontSize) =>
      SizedBox(height: _rowH * 0.5);

  // ── Custom drag slider — identical pattern to sampler _buildParamRow ─────
  Widget _paramRow(
    String label,
    double value,
    double min,
    double max,
    String display,
    void Function(double) onChanged,
    double fontSize,
    TextStyle ts,
  ) {
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
              final newValue = (value + details.delta.dx / width * (max - min)).clamp(min, max);
              setState(() => onChanged(newValue));
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

  // ── Display helpers ──────────────────────────────────────────────────────
  String _pct(double v)  => '${(v * 100).round()}%';
  String _db(double v)   => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(1)}dB';
  String _hz(double v)   => v >= 1000
      ? '${(v / 1000).toStringAsFixed(1)}kHz'
      : '${v.round()}Hz';
  String _res(double v)  => 'Q${v.toStringAsFixed(2)}';

  // ── Build ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final fx       = model.masterFx;
    final fontSize = (_rowH * 0.6).clamp(16.0, 28.0);
    final ts       = trackerStyle(size: fontSize);
    final gs       = trackerStyle(size: fontSize, color: kGreen);

    if (_showFx) {
      return FxWindow(
        model: model,
        onStateChange: widget.onStateChange,
        onClose: () => setState(() => _showFx = false),
      );
    }

    return LayoutBuilder(builder: (context, constraints) {
      final cellW = (constraints.maxWidth - _rowLabelW) / _numCols;

      return SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [

            // ── Channel grid ──────────────────────────────────────────────
            SizedBox(
              height: _rowH,
              child: Row(children: [
                SizedBox(width: _rowLabelW),
                ...List.generate(_numCols, (ch) => SizedBox(
                  width: cellW,
                  child: Text(
                    (ch + 1).toString().padLeft(2, '0'),
                    style: ts,
                    textAlign: TextAlign.center,
                  ),
                )),
              ]),
            ),

            ...List.generate(4, (paramRow) {
              final isRowCursor = model.cursorRow == paramRow;
              return SizedBox(
                height: _rowH,
                child: Row(children: [
                  SizedBox(
                    width: _rowLabelW,
                    child: Text(
                      _rowLabels[paramRow],
                      style: isRowCursor ? gs : ts,
                      textAlign: TextAlign.center,
                    ),
                  ),
                  ...List.generate(_numCols, (ch) {
                    final isCursor = isRowCursor && model.cursorCol == ch;
                    final channel  = model.mixerChannels[ch];
                    final values   = [
                      channel.level.toString().padLeft(2, '0'),
                      channel.reverbSend.toString().padLeft(2, '0'),
                      channel.delaySend.toString().padLeft(2, '0'),
                      channel.chorusSend.toString().padLeft(2, '0'),
                    ];
                    String text = values[paramRow];
                    if (isCursor) {
                      final val = int.tryParse(text.replaceAll('--', '0')) ?? 0;
                      text = val == 0 ? '00' : val.toString().padLeft(2, '0');
                    }
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        model.cursorRow = paramRow;
                        model.cursorCol = ch;
                        model.enterEditMode();
                        model.editMenuVisible = true;
                        widget.onStateChange();
                      },
                      child: Container(
                        width: cellW,
                        height: _rowH,
                        decoration: BoxDecoration(
                          border: isCursor
                              ? Border.all(color: kGreen, width: 2.0)
                              : null,
                        ),
                        alignment: Alignment.center,
                        child: Text(text, style: ts),
                      ),
                    );
                  }),
                ]),
              );
            }),

            // ── Master EQ ─────────────────────────────────────────────────
            _sectionLabel('MASTER EQ', fontSize),
            _paramRow('80Hz',  fx.eqBand1, -12, 12, _db(fx.eqBand1),
                (v) { fx.eqBand1 = v; NativeAudioEngine.setEqBand(0, v); }, fontSize, ts),
            _paramRow('250Hz', fx.eqBand2, -12, 12, _db(fx.eqBand2),
                (v) { fx.eqBand2 = v; NativeAudioEngine.setEqBand(1, v); }, fontSize, ts),
            _paramRow('1kHz',  fx.eqBand3, -12, 12, _db(fx.eqBand3),
                (v) { fx.eqBand3 = v; NativeAudioEngine.setEqBand(2, v); }, fontSize, ts),
            _paramRow('4kHz',  fx.eqBand4, -12, 12, _db(fx.eqBand4),
                (v) { fx.eqBand4 = v; NativeAudioEngine.setEqBand(3, v); }, fontSize, ts),
            _paramRow('12kHz', fx.eqBand5, -12, 12, _db(fx.eqBand5),
                (v) { fx.eqBand5 = v; NativeAudioEngine.setEqBand(4, v); }, fontSize, ts),

            // ── HP / LP Filters ───────────────────────────────────────────
            _sectionLabel('FILTER', fontSize),
            _paramRow('HP',  fx.hpFreq, 20, 1000,  _hz(fx.hpFreq),
                (v) { fx.hpFreq = v; NativeAudioEngine.setHpFreq(v); }, fontSize, ts),
            _paramRow('RES', fx.hpRes,   0,    1,  _res(fx.hpRes),
                (v) { fx.hpRes  = v; NativeAudioEngine.setHpRes(v); },  fontSize, ts),
            _paramRow('LP',  fx.lpFreq, 1000, 20000, _hz(fx.lpFreq),
                (v) { fx.lpFreq = v; NativeAudioEngine.setLpFreq(v); }, fontSize, ts),
            _paramRow('RES', fx.lpRes,   0,    1,  _res(fx.lpRes),
                (v) { fx.lpRes  = v; NativeAudioEngine.setLpRes(v); },  fontSize, ts),

            // ── Master: limiter + volume ───────────────────────────────────
            _sectionLabel('MASTER', fontSize),
            _paramRow('LMT', fx.limiterThreshold, 0, 12,
                fx.limiterThreshold < 0.05 ? '0dB' : '+${fx.limiterThreshold.toStringAsFixed(1)}dB',
                (v) { fx.limiterThreshold = v; NativeAudioEngine.setLimiterThreshold(v); }, fontSize, ts),

            // ── VOL row with horizontal master meter overlay ───────────────
            ValueListenableBuilder<double>(
              valueListenable: widget.masterPeak ??
                  AlwaysStoppedAnimation<double>(model.masterPeak),
              builder: (context, masterPeak, _) {
              final double dB = masterPeak > 1e-6
                  ? 20.0 * math.log(masterPeak) / math.ln10
                  : -60.0;
              return Container(
                height: _rowH,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                child: Row(children: [
                  SizedBox(
                    width: 60,
                    child: Text('VOL', style: ts, textAlign: TextAlign.left),
                  ),
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragUpdate: (details) {
                        final width = MediaQuery.of(context).size.width - 80;
                        final nv = (fx.masterVolume + details.delta.dx / width).clamp(0.0, 1.0);
                        setState(() {
                          fx.masterVolume = nv;
                          NativeAudioEngine.setMasterVolume(nv);
                        });
                        widget.onStateChange();
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.white, width: 1),
                        ),
                        child: Stack(children: [
                          // Horizontal LED meter (background)
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: List.generate(6, (i) {
                              // i=0 = leftmost block (−30..−25 dB), i=5 = rightmost (−5..0 dB)
                              final double thresh = -30.0 + i * 5.0;
                              final bool lit = dB >= thresh;
                              final bool isHot = i == 5;
                              return Expanded(
                                child: Container(
                                  margin: EdgeInsets.only(right: i < 5 ? 1.0 : 0.0),
                                  color: lit
                                      ? (isHot ? const Color(0xFF7A3000) : const Color(0xFF1A5A1A))
                                      : const Color(0xFF0D0D0D),
                                ),
                              );
                            }),
                          ),
                          // Slider dot (foreground)
                          Align(
                            alignment: Alignment(2 * fx.masterVolume - 1, 0),
                            child: Container(width: 8, height: 8, color: Colors.white),
                          ),
                        ]),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 56,
                    child: Text(
                      _pct(fx.masterVolume),
                      style: trackerStyle(size: fontSize, color: kGreen),
                      textAlign: TextAlign.right,
                    ),
                  ),
                ]),
              );
            }),

            // ── FX button ─────────────────────────────────────────────────
            _sectionLabel('', fontSize),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _showFx = true),
              child: Container(
                height: _rowH,
                margin: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white, width: 1),
                ),
                alignment: Alignment.center,
                child: Text('FX', style: trackerStyle(size: fontSize, color: kGreen)),
              ),
            ),

            const SizedBox(height: 8),
          ],
        ),
      );
    });
  }
}

