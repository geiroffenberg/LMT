import 'package:flutter/material.dart';
import 'dart:math' as math;

/// Paints a waveform visualization from a list of peak amplitudes
class WaveformPainter extends CustomPainter {
  final List<double> peaks;
  final Color waveColor;
  final Color axisColor;
  final double startNorm;  // 0..1 sample start position
  final double endNorm;    // 0..1 sample end position

  const WaveformPainter({
    required this.peaks,
    required this.waveColor,
    required this.axisColor,
    this.startNorm = 0.0,
    this.endNorm = 1.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (peaks.isEmpty) return;

    // ── Draw dimmed regions outside start/end ──
    final s = startNorm.clamp(0.0, 1.0);
    final e = endNorm.clamp(0.0, 1.0);
    final leftX = size.width * math.min(s, e);
    final rightX = size.width * math.max(s, e);

    final dim = Paint()..color = axisColor.withAlpha(42);
    if (leftX > 0) {
      canvas.drawRect(Rect.fromLTWH(0, 0, leftX, size.height), dim);
    }
    if (rightX < size.width) {
      canvas.drawRect(
        Rect.fromLTWH(rightX, 0, size.width - rightX, size.height),
        dim,
      );
    }

    // ── Draw center axis line ──
    final centerY = size.height / 2;
    final axis = Paint()
      ..color = axisColor.withAlpha(120)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, centerY), Offset(size.width, centerY), axis);

    // ── Draw start/end boundary markers ──
    final marker = Paint()
      ..color = waveColor.withAlpha(180)
      ..strokeWidth = 1.5;
    canvas.drawLine(Offset(leftX, 0), Offset(leftX, size.height), marker);
    canvas.drawLine(Offset(rightX, 0), Offset(rightX, size.height), marker);

    // ── Draw waveform bars ──
    final wave = Paint()
      ..color = waveColor
      ..strokeWidth = math.max(1.0, size.width / peaks.length * 0.8)
      ..strokeCap = StrokeCap.round;

    final step = size.width / peaks.length;
    for (int i = 0; i < peaks.length; i++) {
      final x = (i + 0.5) * step;
      final amp = (peaks[i].clamp(0.0, 1.0)) * (size.height * 0.45);
      canvas.drawLine(Offset(x, centerY - amp), Offset(x, centerY + amp), wave);
    }
  }

  @override
  bool shouldRepaint(WaveformPainter oldDelegate) {
    return oldDelegate.peaks != peaks ||
        oldDelegate.waveColor != waveColor ||
        oldDelegate.startNorm != startNorm ||
        oldDelegate.endNorm != endNorm;
  }
}
