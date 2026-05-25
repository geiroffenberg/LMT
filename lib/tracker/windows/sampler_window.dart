import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math;
import '../tracker_model.dart';
import '../tracker_styles.dart';
import '../models/sampler_params.dart';
import '../widgets/waveform_painter.dart';
import '../audio/audio_engine.dart';

const _rowH    = 36.0;

class SamplerWindow extends StatefulWidget {
  final TrackerModel model;
  final int instrumentIdx;
  final VoidCallback onStateChange;

  const SamplerWindow({
    required this.model,
    required this.instrumentIdx,
    required this.onStateChange,
    super.key,
  });

  @override
  State<SamplerWindow> createState() => _SamplerWindowState();
}

class _SamplerWindowState extends State<SamplerWindow> {
  TrackerModel get model => widget.model;
  int get instrumentIdx => widget.instrumentIdx;
  VoidCallback get onStateChange => widget.onStateChange;

  late SamplerParams sampler;
  List<double> waveformPeaks = [];
  bool isLoadingWaveform = false;
  bool isPreviewing = false;
  bool _isCropping = false;
  bool _isChopping = false;
  Timer? _previewTimer;

  @override
  void initState() {
    super.initState();
    sampler = model.getSampler(instrumentIdx);
    _loadWaveformPeaks();
  }

  Future<void> _loadWaveformPeaks() async {
    if (!sampler.hasValidSample || sampler.samplePath == null) {
      setState(() => waveformPeaks = []);
      return;
    }

    setState(() => isLoadingWaveform = true);
    try {
      final peaks = await _readWavPeaks(sampler.samplePath!, 220);
      if (mounted) {
        setState(() {
          waveformPeaks = peaks ?? [];
          isLoadingWaveform = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          waveformPeaks = [];
          isLoadingWaveform = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _previewTimer?.cancel();
    if (isPreviewing) {
      NativeAudioEngine.noteOff(instrumentIdx);
    }
    super.dispose();
  }

  /// Calculate the duration of the current preview region (start → end)
  Future<Duration?> _calculateRegionDuration() async {
    if (!sampler.hasValidSample || sampler.samplePath == null) return null;
    try {
      final file = File(sampler.samplePath!);
      if (!file.existsSync()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.length < 44) return null;

      bool matchAscii(int off, String s) {
        if (off + s.length > bytes.length) return false;
        for (int i = 0; i < s.length; i++) {
          if (bytes[off + i] != s.codeUnitAt(i)) return false;
        }
        return true;
      }

      if (!matchAscii(0, 'RIFF') || !matchAscii(8, 'WAVE')) return null;

      final bd = ByteData.sublistView(bytes);
      int readLe16(int o) => bd.getUint16(o, Endian.little);
      int readLe32(int o) => bd.getUint32(o, Endian.little);

      int sampleRate = 0, bitsPerSample = 0, channels = 0;
      int dataOffset = -1, dataSize = 0;

      int pos = 12;
      while (pos + 8 <= bytes.length) {
        final chunkSize = readLe32(pos + 4);
        final body = pos + 8;
        if (body + chunkSize > bytes.length) break;
        if (matchAscii(pos, 'fmt ') && chunkSize >= 16) {
          channels = readLe16(body + 2);
          sampleRate = readLe32(body + 4);
          bitsPerSample = readLe16(body + 14);
        } else if (matchAscii(pos, 'data')) {
          dataOffset = body;
          dataSize = chunkSize;
        }
        pos = body + chunkSize + (chunkSize.isOdd ? 1 : 0);
      }

      if (sampleRate <= 0 || channels <= 0 || bitsPerSample <= 0 || dataOffset < 0) {
        return null;
      }

      final bytesPerSample = bitsPerSample ~/ 8;
      final frameSize = bytesPerSample * channels;
      final totalFrames = dataSize ~/ frameSize;
      if (totalFrames <= 0) return null;

      // Calculate frame range from start/end
      final startFrame = (sampler.start.clamp(0.0, 1.0) * (totalFrames - 1))
          .round().clamp(0, totalFrames - 1);
      final endFrame = (sampler.end.clamp(0.0, 1.0) * totalFrames)
          .round().clamp(startFrame + 1, totalFrames);
      final regionFrames = endFrame - startFrame;

      // Duration = region frames / sample rate
      final durationMs = ((regionFrames / sampleRate) * 1000).toInt();
      return Duration(milliseconds: durationMs);
    } catch (e) {
      return null;
    }
  }

  Future<void> _cropSample() async {
    if (_isCropping || !sampler.hasValidSample) return;
    final srcPath = sampler.samplePath!;

    setState(() => _isCropping = true);
    try {
      // ── Read source WAV ──────────────────────────────────────────────────
      final srcFile = File(srcPath);
      if (!srcFile.existsSync()) return;
      final bytes = await srcFile.readAsBytes();
      if (bytes.length < 44) return;

      bool matchAscii(int off, String s) {
        if (off + s.length > bytes.length) return false;
        for (int i = 0; i < s.length; i++) {
          if (bytes[off + i] != s.codeUnitAt(i)) return false;
        }
        return true;
      }

      if (!matchAscii(0, 'RIFF') || !matchAscii(8, 'WAVE')) return;

      final bd = ByteData.sublistView(bytes);
      int readLe16(int o) => bd.getUint16(o, Endian.little);
      int readLe32(int o) => bd.getUint32(o, Endian.little);

      int audioFormat = 0, channels = 0, sampleRate = 0, bitsPerSample = 0;
      int dataOffset = -1, dataSize = 0;
      int pos = 12;
      while (pos + 8 <= bytes.length) {
        final chunkSize = readLe32(pos + 4);
        final body = pos + 8;
        if (body + chunkSize > bytes.length) break;
        if (matchAscii(pos, 'fmt ') && chunkSize >= 16) {
          audioFormat = readLe16(body + 0);
          channels    = readLe16(body + 2);
          sampleRate  = readLe32(body + 4);
          bitsPerSample = readLe16(body + 14);
        } else if (matchAscii(pos, 'data')) {
          dataOffset = body;
          dataSize   = chunkSize;
        }
        pos = body + chunkSize + (chunkSize.isOdd ? 1 : 0);
      }

      if (dataOffset < 0 || channels <= 0 || bitsPerSample <= 0 ||
          !(audioFormat == 1 || audioFormat == 3)) {
        return;
      }

      final bytesPerSample = bitsPerSample ~/ 8;
      final frameSize   = bytesPerSample * channels;
      final totalFrames = dataSize ~/ frameSize;
      if (totalFrames <= 0) return;

      // ── Frame range from start/end normalised values ──────────────────────
      final startFrame = (sampler.start.clamp(0.0, 1.0) * (totalFrames - 1))
          .round().clamp(0, totalFrames - 1);
      final endFrame   = (sampler.end.clamp(0.0, 1.0) * totalFrames)
          .round().clamp(startFrame + 1, totalFrames);
      final cropFrames = endFrame - startFrame;
      if (cropFrames <= 0) return;

      // ── Decode region → mono 16-bit ───────────────────────────────────────
      final outSamples = List<int>.filled(cropFrames, 0);
      for (int f = 0; f < cropFrames; f++) {
        final frameOff = dataOffset + (startFrame + f) * frameSize;
        double mono = 0.0;
        for (int ch = 0; ch < channels; ch++) {
          final off = frameOff + ch * bytesPerSample;
          double s = 0.0;
          if (audioFormat == 1 && bitsPerSample == 8) {
            s = (bytes[off] - 128) / 128.0;
          } else if (audioFormat == 1 && bitsPerSample == 16) {
            s = bd.getInt16(off, Endian.little) / 32768.0;
          } else if (audioFormat == 1 && bitsPerSample == 24) {
            int raw = bytes[off] | (bytes[off + 1] << 8) | (bytes[off + 2] << 16);
            if (raw & 0x800000 != 0) raw |= ~0xFFFFFF;
            s = raw / 8388608.0;
          } else if (audioFormat == 3 && bitsPerSample == 32) {
            s = bd.getFloat32(off, Endian.little);
          }
          mono += s;
        }
        outSamples[f] = ((mono / channels).clamp(-1.0, 1.0) * 32767.0)
            .round().clamp(-32768, 32767);
      }

      // ── Write mono 16-bit PCM WAV ─────────────────────────────────────────
      final dataBytes = cropFrames * 2;
      final wavOut = ByteData(44 + dataBytes);
      void fourCC(int off, String s) {
        for (int i = 0; i < 4; i++) {
          wavOut.setUint8(off + i, s.codeUnitAt(i));
        }
      }
      fourCC(0, 'RIFF');
      wavOut.setUint32( 4, 36 + dataBytes, Endian.little);
      fourCC(8, 'WAVE'); fourCC(12, 'fmt ');
      wavOut.setUint32(16, 16,           Endian.little); // chunk size
      wavOut.setUint16(20,  1,           Endian.little); // PCM
      wavOut.setUint16(22,  1,           Endian.little); // mono
      wavOut.setUint32(24, sampleRate,   Endian.little);
      wavOut.setUint32(28, sampleRate * 2, Endian.little);
      wavOut.setUint16(32,  2,           Endian.little); // block align
      wavOut.setUint16(34, 16,           Endian.little); // bits
      fourCC(36, 'data');
      wavOut.setUint32(40, dataBytes, Endian.little);
      for (int f = 0; f < cropFrames; f++) {
        wavOut.setInt16(44 + f * 2, outSamples[f], Endian.little);
      }

      // ── Choose output filename: <base>_crop_N.wav ────────────────────────
      final srcName = sampler.sampleName ?? srcPath.split(Platform.pathSeparator).last;
      final dot  = srcName.lastIndexOf('.');
      final base = dot > 0 ? srcName.substring(0, dot) : srcName;
      final dir  = srcPath.substring(0, srcPath.lastIndexOf(Platform.pathSeparator));
      int n = 1;
      String outName;
      do {
        outName = '${base}_crop_$n.wav';
        n++;
      } while (File('$dir/$outName').existsSync());
      final outPath = '$dir/$outName';
      await File(outPath).writeAsBytes(wavOut.buffer.asUint8List(), flush: true);

      // ── Update model + reload audio engine ───────────────────────────────
      sampler.start = 0.0;
      sampler.end   = 1.0;
      model.loadSampleForInstrument(instrumentIdx, outPath);
      await NativeAudioEngine.loadSample(instrumentIdx, outPath);

      if (!mounted) return;
      setState(() {});
      // Reload waveform for the new file
      await _loadWaveformPeaks();
    } finally {
      if (mounted) setState(() => _isCropping = false);
    }
  }

  Future<void> _chopSample() async {
    if (_isChopping || !sampler.hasValidSample) return;
    final srcPath = sampler.samplePath!;

    setState(() => _isChopping = true);
    try {
      // ─── Read source WAV ─────────────────────────────────────────────────────
      final srcFile = File(srcPath);
      if (!srcFile.existsSync()) return;
      final bytes = await srcFile.readAsBytes();
      if (bytes.length < 44) return;

      bool matchAscii(int off, String s) {
        if (off + s.length > bytes.length) return false;
        for (int i = 0; i < s.length; i++) {
          if (bytes[off + i] != s.codeUnitAt(i)) return false;
        }
        return true;
      }

      if (!matchAscii(0, 'RIFF') || !matchAscii(8, 'WAVE')) return;

      final bd = ByteData.sublistView(bytes);
      int readLe16(int o) => bd.getUint16(o, Endian.little);
      int readLe32(int o) => bd.getUint32(o, Endian.little);

      int audioFormat = 0, channels = 0, sampleRate = 0, bitsPerSample = 0;
      int dataOffset = -1, dataSize = 0;
      int pos = 12;
      while (pos + 8 <= bytes.length) {
        final chunkSize = readLe32(pos + 4);
        final body = pos + 8;
        if (body + chunkSize > bytes.length) break;
        if (matchAscii(pos, 'fmt ') && chunkSize >= 16) {
          audioFormat = readLe16(body + 0);
          channels    = readLe16(body + 2);
          sampleRate  = readLe32(body + 4);
          bitsPerSample = readLe16(body + 14);
        } else if (matchAscii(pos, 'data')) {
          dataOffset = body;
          dataSize   = chunkSize;
        }
        pos = body + chunkSize + (chunkSize.isOdd ? 1 : 0);
      }

      if (dataOffset < 0 || channels <= 0 || bitsPerSample <= 0 ||
          !(audioFormat == 1 || audioFormat == 3)) {
        return;
      }

      final bytesPerSample = bitsPerSample ~/ 8;
      final frameSize   = bytesPerSample * channels;
      final totalFrames = dataSize ~/ frameSize;
      if (totalFrames <= 0) return;

      // ─── Frame range from start/end normalised values ─────────────────────
      final startFrame = (sampler.start.clamp(0.0, 1.0) * (totalFrames - 1))
          .round().clamp(0, totalFrames - 1);
      final endFrame   = (sampler.end.clamp(0.0, 1.0) * totalFrames)
          .round().clamp(startFrame + 1, totalFrames);
      final cropFrames = endFrame - startFrame;
      if (cropFrames <= 0) return;

      // ─── Decode region → mono 16-bit ────────────────────────────────────
      final outSamples = List<int>.filled(cropFrames, 0);
      for (int f = 0; f < cropFrames; f++) {
        final frameOff = dataOffset + (startFrame + f) * frameSize;
        double mono = 0.0;
        for (int ch = 0; ch < channels; ch++) {
          final off = frameOff + ch * bytesPerSample;
          double s = 0.0;
          if (audioFormat == 1 && bitsPerSample == 8) {
            s = (bytes[off] - 128) / 128.0;
          } else if (audioFormat == 1 && bitsPerSample == 16) {
            s = bd.getInt16(off, Endian.little) / 32768.0;
          } else if (audioFormat == 1 && bitsPerSample == 24) {
            int raw = bytes[off] | (bytes[off + 1] << 8) | (bytes[off + 2] << 16);
            if (raw & 0x800000 != 0) raw |= ~0xFFFFFF;
            s = raw / 8388608.0;
          } else if (audioFormat == 3 && bitsPerSample == 32) {
            s = bd.getFloat32(off, Endian.little);
          }
          mono += s;
        }
        outSamples[f] = ((mono / channels).clamp(-1.0, 1.0) * 32767.0)
            .round().clamp(-32768, 32767);
      }

      // ─── Write mono 16-bit PCM WAV ───────────────────────────────────────
      final dataBytes = cropFrames * 2;
      final wavOut = ByteData(44 + dataBytes);
      void fourCC(int off, String s) {
        for (int i = 0; i < 4; i++) {
          wavOut.setUint8(off + i, s.codeUnitAt(i));
        }
      }
      fourCC(0, 'RIFF');
      wavOut.setUint32( 4, 36 + dataBytes, Endian.little);
      fourCC(8, 'WAVE'); fourCC(12, 'fmt ');
      wavOut.setUint32(16, 16,           Endian.little);
      wavOut.setUint16(20,  1,           Endian.little);
      wavOut.setUint16(22,  1,           Endian.little);
      wavOut.setUint32(24, sampleRate,   Endian.little);
      wavOut.setUint32(28, sampleRate * 2, Endian.little);
      wavOut.setUint16(32,  2,           Endian.little);
      wavOut.setUint16(34, 16,           Endian.little);
      fourCC(36, 'data');
      wavOut.setUint32(40, dataBytes, Endian.little);
      for (int f = 0; f < cropFrames; f++) {
        wavOut.setInt16(44 + f * 2, outSamples[f], Endian.little);
      }

      // ─── Choose output filename: <base>_chop_N.wav ────────────────────────
      final srcName = sampler.sampleName ?? srcPath.split(Platform.pathSeparator).last;
      final dot  = srcName.lastIndexOf('.');
      final base = dot > 0 ? srcName.substring(0, dot) : srcName;
      final dir  = srcPath.substring(0, srcPath.lastIndexOf(Platform.pathSeparator));
      int n = 1;
      String outName;
      do {
        outName = '${base}_chop_$n.wav';
        n++;
      } while (File('$dir/$outName').existsSync());
      final outPath = '$dir/$outName';
      await File(outPath).writeAsBytes(wavOut.buffer.asUint8List(), flush: true);

      // ─── Find next free slot and copy params ──────────────────────────────
      int freeSlot = -1;
      for (int i = 0; i < 99; i++) {
        if (i == instrumentIdx) continue; // skip current
        final s = model.getSampler(i);
        if (s.samplePath == null || s.samplePath!.isEmpty) {
          freeSlot = i;
          break;
        }
      }
      if (freeSlot < 0) return; // No free slot

      // ─── Load sample to new slot (updates instrument.sample + sampler path) ──
      model.loadSampleForInstrument(freeSlot, outPath);

      // ─── Copy all params from current to new slot (except start/end) ────────
      final newSampler = model.getSampler(freeSlot);
      newSampler.pitch = sampler.pitch;
      newSampler.volume = sampler.volume;
      newSampler.start = 0.0;  // Reset start/end
      newSampler.end = 1.0;
      newSampler.attack = sampler.attack;
      newSampler.release = sampler.release;
      newSampler.loopMode = sampler.loopMode;
      newSampler.sliceStarts = List<int>.from(sampler.sliceStarts);
      newSampler.stretchEnabled = sampler.stretchEnabled;
      newSampler.stretchLines = sampler.stretchLines;
      newSampler.stretchPreservePitch = sampler.stretchPreservePitch;

      // Load audio engine
      await NativeAudioEngine.loadSample(freeSlot, outPath);

      onStateChange();
      if (mounted) setState(() {});
    } finally {
      if (mounted) setState(() => _isChopping = false);
    }
  }

  /// Extract peak envelope from WAV file (adapted from tracker/tracker)
  Future<List<double>?> _readWavPeaks(String path, int bins) async {
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.length < 44) return null;

      // Check RIFF/WAVE headers
      bool matchAscii(int off, String s) {
        if (off + s.length > bytes.length) return false;
        for (int i = 0; i < s.length; i++) {
          if (bytes[off + i] != s.codeUnitAt(i)) return false;
        }
        return true;
      }

      if (!matchAscii(0, 'RIFF') || !matchAscii(8, 'WAVE')) return null;

      final bd = ByteData.sublistView(bytes);
      int readLe16(int o) => bd.getUint16(o, Endian.little);
      int readLe32(int o) => bd.getUint32(o, Endian.little);

      // Parse fmt and data chunks
      int audioFormat = 0;
      int channels = 0;
      int bitsPerSample = 0;
      int dataOffset = -1;
      int dataSize = 0;

      int pos = 12;
      while (pos + 8 <= bytes.length) {
        final chunkSize = readLe32(pos + 4);
        final body = pos + 8;
        if (body + chunkSize > bytes.length) break;

        if (matchAscii(pos, 'fmt ') && chunkSize >= 16) {
          audioFormat = readLe16(body + 0);
          channels = readLe16(body + 2);
          bitsPerSample = readLe16(body + 14);
        } else if (matchAscii(pos, 'data')) {
          dataOffset = body;
          dataSize = chunkSize;
        }

        pos = body + chunkSize + (chunkSize.isOdd ? 1 : 0);
      }

      if (dataOffset < 0 ||
          dataSize <= 0 ||
          channels <= 0 ||
          bitsPerSample <= 0) {
        return null;
      }

      final bytesPerSample = bitsPerSample ~/ 8;
      final frameBytes = bytesPerSample * channels;
      if (bytesPerSample <= 0 || frameBytes <= 0) return null;

      final frameCount = dataSize ~/ frameBytes;
      if (frameCount <= 0) return null;

      // Calculate bins and extract peaks
      final safeBins = bins.clamp(32, 480);
      final peaks = List<double>.filled(safeBins, 0.0);
      final framesPerBin = (frameCount / safeBins).ceil().clamp(1, frameCount);

      for (int b = 0; b < safeBins; b++) {
        final startFrame = b * framesPerBin;
        if (startFrame >= frameCount) break;
        final endFrame = math.min(frameCount, startFrame + framesPerBin);
        double maxAbs = 0.0;

        for (int f = startFrame; f < endFrame; f++) {
          final frameBase = dataOffset + f * frameBytes;
          double mono = 0.0;

          // Read each channel and mix to mono
          for (int ch = 0; ch < channels; ch++) {
            final sampleOff = frameBase + ch * bytesPerSample;
            double sample = 0.0;

            if (audioFormat == 1 && bitsPerSample == 8) {
              sample = (bytes[sampleOff] - 128) / 128.0;
            } else if (audioFormat == 1 && bitsPerSample == 16) {
              sample = bd.getInt16(sampleOff, Endian.little) / 32768.0;
            } else if (audioFormat == 1 && bitsPerSample == 24) {
              final raw = bytes[sampleOff] |
                  (bytes[sampleOff + 1] << 8) |
                  (bytes[sampleOff + 2] << 16);
              final signed = (raw & 0x800000) != 0 ? (raw | ~0xFFFFFF) : raw;
              sample = signed / 8388608.0;
            } else if (audioFormat == 3 && bitsPerSample == 32) {
              sample = bd.getFloat32(sampleOff, Endian.little);
            } else {
              return null;
            }
            mono += sample;
          }

          mono /= channels;
          final absV = mono.abs();
          if (absV > maxAbs) maxAbs = absV;
        }

        peaks[b] = maxAbs.clamp(0.0, 1.0);
      }

      return peaks;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final fontSize = (_rowH * 0.6).clamp(16.0, 28.0);
        final ts = trackerStyle(size: fontSize);

        return Column(
          children: [
            // Header: Waveform display
            Padding(
              padding: const EdgeInsets.all(8),
              child: Container(
                height: 100,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
                child: Column(
                  children: [
                    // Top row: label + sample name
                    Padding(
                      padding: const EdgeInsets.all(4),
                      child: Row(
                        children: [
                          Text('SAMPLER', style: trackerStyle(size: 12, color: kGreen)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              sampler.hasValidSample 
                                  ? (sampler.sampleName ?? 'UNNAMED')
                                  : '(no sample)',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: trackerStyle(
                                size: 11,
                                color: sampler.hasValidSample ? Colors.white70 : Colors.grey,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Waveform display — tap to play/stop region
                    Expanded(
                      child: GestureDetector(
                        onTap: () async {
                          if (!sampler.hasValidSample) return;
                          if (isPreviewing) {
                            _previewTimer?.cancel();
                            _previewTimer = null;
                            await NativeAudioEngine.noteOff(instrumentIdx);
                            setState(() => isPreviewing = false);
                          } else {
                            // Read fresh from model to get current slider values
                            final currentSampler = model.getSampler(instrumentIdx);
                            
                            // For OFF mode (loopMode=0), set auto-stop timer
                            // For LOOP/PING modes, no timer needed (click again to stop)
                            if (currentSampler.loopMode == 0) {
                              Duration? regionDuration;
                              
                              if (currentSampler.stretchEnabled) {
                                // Stretched: use stretchLines and BPM to calculate duration
                                final durationSecs = (currentSampler.stretchLines * 60.0) / model.song.bpm;
                                regionDuration = Duration(milliseconds: (durationSecs * 1000).toInt());
                              } else {
                                // Original: read from WAV file
                                regionDuration = await _calculateRegionDuration();
                              }
                              
                              if (regionDuration != null && mounted) {
                                _previewTimer?.cancel();
                                _previewTimer = Timer(regionDuration, () {
                                  if (mounted) {
                                    setState(() => isPreviewing = false);
                                  }
                                });
                              }
                            }
                            
                            // Apply pitch: frequency * 2^(pitch/12)
                            final baseFreq = 440.0;
                            final pitchFreq = baseFreq * math.pow(2.0, currentSampler.pitch);
                            // Convert attack/release from 0..1 normalized (0..500ms) to seconds
                            final attackSec = currentSampler.attack * 0.5;  // 0..1 → 0..500ms → 0..0.5s
                            final releaseSec = currentSampler.release * 0.5;
                            await NativeAudioEngine.noteOnRegion(
                              instrumentIdx,
                              pitchFreq,
                              currentSampler.volume,
                              currentSampler.start,
                              currentSampler.end,
                              attackTime: attackSec,
                              releaseTime: releaseSec,
                              loopMode: currentSampler.loopMode,
                            );
                            setState(() => isPreviewing = true);
                          }
                        },
                        child: Container(
                          color: Colors.black26,
                          child: Stack(
                            children: [
                              // Waveform or placeholder
                              if (isLoadingWaveform)
                                Center(child: Text('loading...', style: trackerStyle(size: 10, color: Colors.grey)))
                              else if (waveformPeaks.isEmpty)
                                Center(child: Text('no waveform', style: trackerStyle(size: 10, color: Colors.grey)))
                              else
                                CustomPaint(
                                  painter: WaveformPainter(
                                    peaks: waveformPeaks,
                                    waveColor: kGreen,
                                    axisColor: Colors.white30,
                                    startNorm: sampler.start,
                                    endNorm: sampler.end,
                                  ),
                                  child: const SizedBox.expand(),
                                ),
                              // Play/stop indicator overlay (top-right corner)
                              if (sampler.hasValidSample)
                                Positioned(
                                  top: 4,
                                  right: 6,
                                  child: Icon(
                                    isPreviewing ? Icons.stop : Icons.play_arrow,
                                    color: isPreviewing ? kGreen : Colors.white38,
                                    size: 16,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    // CROP / CHOP button row
                    Container(
                      height: _rowH,
                      decoration: BoxDecoration(
                        border: Border(
                          top: BorderSide(color: Colors.white, width: 1),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: _isCropping ? null : _cropSample,
                              child: Container(
                                decoration: BoxDecoration(
                                  border: Border(
                                    right: BorderSide(color: Colors.white, width: 1),
                                  ),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  _isCropping ? 'CROP...' : 'CROP',
                                  style: trackerStyle(
                                    size: fontSize - 4,
                                    color: _isCropping ? Colors.grey : kGreen,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: _isChopping ? null : _chopSample,
                              child: Container(
                                alignment: Alignment.center,
                                child: Text(
                                  _isChopping ? 'CHOP...' : 'CHOP',
                                  style: trackerStyle(
                                    size: fontSize - 4,
                                    color: _isChopping ? Colors.grey : kGreen,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Parameters grid
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  // Spacer
                  SizedBox(height: _rowH),

                  // Row 1: PITCH
                  _buildParamRow(
                    'PITCH',
                    sampler.pitch,
                    (newVal) => sampler.pitch = newVal,
                    sampler.getPitchDisplay(),
                    'st',  // semitones
                    -1.0,
                    1.0,
                    fontSize,
                    ts,
                  ),

                  // Row 2: VOLUME
                  _buildParamRow(
                    'VOL',
                    sampler.volume,
                    (newVal) => sampler.volume = newVal,
                    sampler.getVolumeDisplay(),
                    '%',
                    0.0,
                    1.0,
                    fontSize,
                    ts,
                  ),

                  // Row 3: START
                  _buildParamRow(
                    'START',
                    sampler.start,
                    (newVal) {
                      sampler.start = newVal.clamp(0.0, sampler.end - 0.01);
                      _loadWaveformPeaks();  // Refresh waveform
                    },
                    sampler.getStartDisplay(),
                    '%',
                    0.0,
                    1.0,
                    fontSize,
                    ts,
                  ),

                  // Row 4: END
                  _buildParamRow(
                    'END',
                    sampler.end,
                    (newVal) {
                      sampler.end = newVal.clamp(sampler.start + 0.01, 1.0);
                      _loadWaveformPeaks();  // Refresh waveform
                    },
                    sampler.getEndDisplay(),
                    '%',
                    0.0,
                    1.0,
                    fontSize,
                    ts,
                  ),

                  // Row 5: ATTACK
                  _buildParamRow(
                    'ATK',
                    sampler.attack,
                    (newVal) {
                      sampler.attack = newVal;
                      setState(() {});
                    },
                    sampler.getAttackDisplay(),
                    'ms',
                    0.0,
                    1.0,
                    fontSize,
                    ts,
                  ),

                  // Row 6: RELEASE
                  _buildParamRow(
                    'REL',
                    sampler.release,
                    (newVal) {
                      sampler.release = newVal;
                      setState(() {});
                    },
                    sampler.getReleaseDisplay(),
                    'ms',
                    0.0,
                    1.0,
                    fontSize,
                    ts,
                  ),

                  // Spacer
                  SizedBox(height: _rowH),

                  // Row 7: LOOP MODE
                  _buildLoopModeRow(fontSize, ts),

                  // Spacer
                  SizedBox(height: _rowH),

                  // Row 8: SYNC
                  _buildSyncRow(fontSize, ts),

                  // Spacer
                  SizedBox(height: _rowH),

                  // Row 9: MOD (Modulation/Chorus send)
                  _buildParamRow(
                    'MOD',
                    sampler.modSend,
                    (newVal) => sampler.modSend = newVal,
                    sampler.getModDisplay(),
                    '%',
                    0.0,
                    1.0,
                    fontSize,
                    ts,
                  ),

                  // Row 10: DEL (Delay send)
                  _buildParamRow(
                    'DEL',
                    sampler.delSend,
                    (newVal) => sampler.delSend = newVal,
                    sampler.getDelDisplay(),
                    '%',
                    0.0,
                    1.0,
                    fontSize,
                    ts,
                  ),

                  // Row 11: REV (Reverb send)
                  _buildParamRow(
                    'REV',
                    sampler.revSend,
                    (newVal) => sampler.revSend = newVal,
                    sampler.getRevDisplay(),
                    '%',
                    0.0,
                    1.0,
                    fontSize,
                    ts,
                  ),

                  // Row 12: LP (Low Pass filter)
                  _buildParamRow(
                    'LP',
                    sampler.lpCutoff,
                    (newVal) => sampler.lpCutoff = newVal,
                    sampler.getLpDisplay(),
                    '',
                    0.0,
                    1.0,
                    fontSize,
                    ts,
                  ),

                  // Row 13: HP (High Pass filter)
                  _buildParamRow(
                    'HP',
                    sampler.hpCutoff,
                    (newVal) => sampler.hpCutoff = newVal,
                    sampler.getHpDisplay(),
                    '',
                    0.0,
                    1.0,
                    fontSize,
                    ts,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildParamRow(
    String label,
    double value,
    Function(double) onChanged,
    String displayValue,
    String unit,
    double min,
    double max,
    double fontSize,
    TextStyle ts,
  ) {
    return Container(
      height: _rowH,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        children: [
          // Label
          SizedBox(
            width: 60,
            child: Text(label, style: ts, textAlign: TextAlign.left),
          ),
          // Slider
          Expanded(
            child: GestureDetector(
              onHorizontalDragUpdate: (details) {
                final width = MediaQuery.of(context).size.width - 80;
                final newValue = value + (details.delta.dx / width);
                onChanged(newValue.clamp(min, max));
                setState(() {});
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
                  child: Container(
                    width: 8,
                    height: 8,
                    color: kGreen,
                  ),
                ),
              ),
            ),
          ),
          // Value display
          SizedBox(
            width: 50,
            child: Text(
              '$displayValue$unit',
              style: trackerStyle(size: fontSize, color: kGreen),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoopModeRow(double fontSize, TextStyle ts) {
    const modes = ['OFF', 'LOOP', 'PING'];
    return Container(
      height: _rowH,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        children: [
          // Label
          SizedBox(
            width: 60,
            child: Text('LOOP', style: ts, textAlign: TextAlign.left),
          ),
          const SizedBox(width: 8),
          // Mode buttons
          for (int i = 0; i < modes.length; i++)
            Padding(
              padding: EdgeInsets.only(right: i < modes.length - 1 ? 8 : 0),
              child: GestureDetector(
                onTap: () {
                  setState(() {
                    sampler.loopMode = i;
                  });
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: sampler.loopMode == i ? kGreen : Colors.white,
                      width: 1.5,
                    ),
                  ),
                  child: Text(
                    modes[i],
                    style: trackerStyle(
                      size: fontSize,
                      color: sampler.loopMode == i ? kGreen : Colors.white70,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSyncRow(double fontSize, TextStyle ts) {
    return Container(
      height: _rowH,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        children: [
          // Label
          SizedBox(
            width: 60,
            child: Text('SYNC', style: ts, textAlign: TextAlign.left),
          ),
          const SizedBox(width: 8),

          // ON/OFF toggle
          GestureDetector(
            onTap: () {
              setState(() {
                sampler.stretchEnabled = !sampler.stretchEnabled;
              });
              _applyStretch();
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                border: Border.all(
                  color: sampler.stretchEnabled ? kGreen : Colors.white,
                  width: 1,
                ),
              ),
              child: Text(
                sampler.stretchEnabled ? 'ON' : 'OFF',
                style: trackerStyle(
                  size: fontSize,
                  color: sampler.stretchEnabled ? kGreen : Colors.white70,
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),

          // LINES label and control
          Text('LINES', style: trackerStyle(size: fontSize, color: Colors.white70)),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: () {
              setState(() {
                sampler.stretchLines = (sampler.stretchLines - 1).clamp(1, 99);
              });
            },
            child: Icon(Icons.remove, color: Colors.white70, size: fontSize),
          ),
          SizedBox(
            width: 28,
            child: Text(
              '${sampler.stretchLines}',
              style: trackerStyle(size: fontSize, color: kGreen),
              textAlign: TextAlign.center,
            ),
          ),
          GestureDetector(
            onTap: () {
              setState(() {
                sampler.stretchLines = (sampler.stretchLines + 1).clamp(1, 99);
              });
            },
            child: Icon(Icons.add, color: Colors.white70, size: fontSize),
          ),
          const SizedBox(width: 16),

          // PITCH toggle
          GestureDetector(
            onTap: () {
              setState(() {
                sampler.stretchPreservePitch = !sampler.stretchPreservePitch;
              });
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                border: Border.all(
                  color: sampler.stretchPreservePitch ? kGreen : Colors.white,
                  width: 1,
                ),
              ),
              child: Text(
                'PITCH',
                style: trackerStyle(
                  size: fontSize,
                  color: sampler.stretchPreservePitch ? kGreen : Colors.white70,
                ),
              ),
            ),
          ),
          const Spacer(),

          // APPLY button
          GestureDetector(
            onTap: _applyStretch,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                border: Border.all(color: kGreen, width: 1),
              ),
              child: Text(
                'APPLY',
                style: trackerStyle(
                  size: fontSize,
                  color: kGreen,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _applyStretch() async {
    if (!sampler.hasValidSample) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No sample loaded')),
      );
      return;
    }

    // Stop any currently playing voice to avoid double playback
    await NativeAudioEngine.noteOff(instrumentIdx);

    try {
      await NativeAudioEngine.updateStretch(
        instrumentIdx,
        sampler.stretchEnabled,
        sampler.stretchLines,
        model.song.bpm.toDouble(),
        sampler.stretchPreservePitch,
      );
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(sampler.stretchEnabled 
              ? 'Stretched to ${sampler.stretchLines} beats @ ${model.song.bpm} BPM'
              : 'Restored to original'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Stretch failed: $e')),
        );
      }
    }
  }
}
