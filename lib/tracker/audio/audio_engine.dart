import 'package:flutter/services.dart';

/// Dart wrapper for the native Oboe audio engine
class NativeAudioEngine {
  static const platform = MethodChannel('com.example.lmt/audio');

  static Future<bool> initialize() async {
    try {
      final result = await platform.invokeMethod<bool>('initialize');
      return result ?? false;
    } catch (e) {
      print('Error initializing audio engine: $e');
      return false;
    }
  }

  static Future<void> release() async {
    try {
      await platform.invokeMethod<void>('release');
    } catch (e) {
      print('Error releasing audio engine: $e');
    }
  }

  static Future<bool> loadSample(int instrumentIdx, String filePath) async {
    try {
      final result = await platform.invokeMethod<bool>(
        'loadSample',
        {'instrumentIdx': instrumentIdx, 'path': filePath},
      );
      return result ?? false;
    } catch (e) {
      print('Error loading sample: $e');
      return false;
    }
  }

  static Future<void> clearSample(int instrumentIdx) async {
    try {
      await platform.invokeMethod<void>(
        'clearSample',
        {'instrumentIdx': instrumentIdx},
      );
    } catch (e) {
      print('Error clearing sample: $e');
    }
  }

  /// Start playing a sample at the given frequency
  /// [instrumentIdx]: which instrument (0-98)
  /// [frequency]: playback frequency in Hz (e.g., 440 for A4)
  /// [level]: volume level (0..1)
  static Future<void> noteOn(int instrumentIdx, double frequency, double level) async {
    try {
      await platform.invokeMethod<void>(
        'noteOn',
        {
          'instrumentIdx': instrumentIdx,
          'frequency': frequency,
          'level': level,
        },
      );
    } catch (e) {
      print('Error noteOn: $e');
    }
  }

  /// Play a sample from startNorm..endNorm (both 0..1 normalized positions)
  /// [attackTime] and [releaseTime] in seconds (default 0.0 and 0.05 respectively)
  /// [loopMode] 0=OFF, 1=LOOP, 2=PING
  static Future<void> noteOnRegion(int instrumentIdx, double frequency, double level, double startNorm, double endNorm, {double attackTime = 0.0, double releaseTime = 0.05, int loopMode = 0}) async {
    try {
      await platform.invokeMethod<void>(
        'noteOnRegion',
        {
          'instrumentIdx': instrumentIdx,
          'frequency': frequency,
          'level': level,
          'startNorm': startNorm,
          'endNorm': endNorm,
          'attackTime': attackTime,
          'releaseTime': releaseTime,
          'loopMode': loopMode,
        },
      );
    } catch (e) {
      print('Error noteOnRegion: $e');
    }
  }

  /// Stop playing the sample for an instrument
  static Future<void> noteOff(int instrumentIdx) async {
    try {
      await platform.invokeMethod<void>(
        'noteOff',
        {'instrumentIdx': instrumentIdx},
      );
    } catch (e) {
      print('Error noteOff: $e');
    }
  }

  /// Stop all sounds immediately
  static Future<void> stopAll() async {
    try {
      await platform.invokeMethod<void>('stopAll');
    } catch (e) {
      print('Error stopAll: $e');
    }
  }

  /// Check if an instrument is currently playing
  static Future<bool> isPlaying(int instrumentIdx) async {
    try {
      final result = await platform.invokeMethod<bool>(
        'isPlaying',
        {'instrumentIdx': instrumentIdx},
      );
      return result ?? false;
    } catch (e) {
      print('Error isPlaying: $e');
      return false;
    }
  }

  /// Set volume level for an instrument
  static Future<void> setLevel(int instrumentIdx, double level) async {
    try {
      await platform.invokeMethod<void>(
        'setLevel',
        {
          'instrumentIdx': instrumentIdx,
          'level': level,
        },
      );
    } catch (e) {
      print('Error setLevel: $e');
    }
  }

  /// Set stereo pan for an instrument
  /// [pan]: 0.0 = left, 0.5 = center, 1.0 = right
  static Future<void> setPan(int instrumentIdx, double pan) async {
    try {
      await platform.invokeMethod<void>(
        'setPan',
        {
          'instrumentIdx': instrumentIdx,
          'pan': pan,
        },
      );
    } catch (e) {
      print('Error setPan: $e');
    }
  }

  /// Apply time-stretching to a sample (beat-sync)
  /// [instrumentIdx]: which instrument (0-98)
  /// [enabled]: whether to apply stretch (true) or restore original (false)
  /// [beats]: number of beats to fit the sample into
  /// [bpm]: tempo in beats per minute
  /// [preservePitch]: if true, uses WSOLA (keeps pitch); if false, uses resampling (changes pitch)
  static Future<void> updateStretch(int instrumentIdx, bool enabled, int beats, double bpm, bool preservePitch) async {
    try {
      await platform.invokeMethod<void>(
        'updateStretch',
        {
          'instrumentIdx': instrumentIdx,
          'enabled': enabled,
          'beats': beats,
          'bpm': bpm,
          'preservePitch': preservePitch,
        },
      );
    } catch (e) {
      print('Error updateStretch: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Sequencer API — sample-accurate row-based playback
  // ---------------------------------------------------------------------------

  /// Pre-build and enqueue all song rows. Sends packed int array to native.
  ///
  /// [loop]: if true the song loops after the last row.
  /// [rows]: each element is a map with:
  ///   'lineSamples' (int) — audio frames this row lasts
  ///   'noteData'    (List<int>) — packed as groups of 3:
  ///                              [instrIdx, midiNote, volume_0_99]
  ///                              midiNote -1 = hold, -2 = note off
  static Future<void> enqueueAllRows(bool loop, List<Map<String, dynamic>> rows) async {
    // Flatten into the wire format:
    // [lineSamples, numNoteInts, ...noteInts, lineSamples, numNoteInts, ...noteInts, ...]
    final flat = <int>[];
    for (final row in rows) {
      final ls = (row['lineSamples'] as int?) ?? 0;
      final nd = (row['noteData'] as List?)?.cast<int>() ?? <int>[];
      flat.add(ls);
      flat.add(nd.length);
      flat.addAll(nd);
    }
    try {
      await platform.invokeMethod<void>(
        'enqueueAllRows',
        {'loop': loop, 'rowData': flat},
      );
    } catch (e) {
      print('Error enqueueAllRows: $e');
    }
  }

  /// Returns how many rows the audio engine has advanced since the last call.
  /// Call this from a 16ms Dart timer for sample-accurate UI updates.
  static Future<int> consumeRowAdvances() async {
    try {
      final result = await platform.invokeMethod<int>('consumeRowAdvances');
      return result ?? 0;
    } catch (e) {
      print('Error consumeRowAdvances: $e');
      return 0;
    }
  }

  /// Stop sequencer and discard queued rows.
  static Future<void> clearQueue() async {
    try {
      await platform.invokeMethod<void>('clearQueue');
    } catch (e) {
      print('Error clearQueue: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Master Effects API
  // ---------------------------------------------------------------------------

  /// Set reverb room size (0..1)
  static Future<void> setReverbSize(double norm) async {
    try {
      await platform.invokeMethod<void>(
        'setReverbSize',
        {'norm': norm},
      );
    } catch (e) {
      print('Error setReverbSize: $e');
    }
  }

  /// Set reverb damping (0..1)
  static Future<void> setReverbDamping(double norm) async {
    try {
      await platform.invokeMethod<void>(
        'setReverbDamping',
        {'norm': norm},
      );
    } catch (e) {
      print('Error setReverbDamping: $e');
    }
  }

  /// Set reverb width (0..1)
  static Future<void> setReverbWidth(double norm) async {
    try {
      await platform.invokeMethod<void>(
        'setReverbWidth',
        {'norm': norm},
      );
    } catch (e) {
      print('Error setReverbWidth: $e');
    }
  }

  /// Set delay time (0..1 → ~10..2000 ms)
  static Future<void> setDelayTime(double norm) async {
    try {
      await platform.invokeMethod<void>(
        'setDelayTime',
        {'norm': norm},
      );
    } catch (e) {
      print('Error setDelayTime: $e');
    }
  }

  /// Set delay feedback (0..1)
  static Future<void> setDelayFeedback(double norm) async {
    try {
      await platform.invokeMethod<void>(
        'setDelayFeedback',
        {'norm': norm},
      );
    } catch (e) {
      print('Error setDelayFeedback: $e');
    }
  }

  /// Set chorus rate (0..1 → ~0.1..8 Hz)
  static Future<void> setChorusRate(double norm) async {
    try {
      await platform.invokeMethod<void>(
        'setChorusRate',
        {'norm': norm},
      );
    } catch (e) {
      print('Error setChorusRate: $e');
    }
  }

  /// Set chorus depth (0..1 → ~0..15 ms)
  static Future<void> setChorusDepth(double norm) async {
    try {
      await platform.invokeMethod<void>(
        'setChorusDepth',
        {'norm': norm},
      );
    } catch (e) {
      print('Error setChorusDepth: $e');
    }
  }

  /// Set per-track effect send levels (trackIdx 0-7, all 0..1 normalized)
  static Future<void> setTrackSends(
      int trackIdx, double rev, double del, double cho) async {
    try {
      await platform.invokeMethod<void>(
        'setTrackSends',
        {'trackIdx': trackIdx, 'rev': rev, 'del': del, 'cho': cho},
      );
    } catch (e) {
      print('Error setTrackSends: $e');
    }
  }

  static Future<void> setInstrumentSends(
      int instrIdx, double rev, double del, double cho) async {
    try {
      await platform.invokeMethod<void>(
        'setInstrumentSends',
        {'instrIdx': instrIdx, 'rev': rev, 'del': del, 'cho': cho},
      );
    } catch (e) {
      print('Error setInstrumentSends: $e');
    }
  }

  // Coalesce rapid filter updates: only one MethodChannel call in-flight at a time.
  // Calls that arrive while one is pending update the stored value; the do-while
  // ensures the final value is always flushed after the in-flight call returns.
  static bool _filterCallInFlight = false;
  static bool _filterPendingUpdate = false;
  static int _filterPendingIdx = -1;
  static double _filterPendingHp = 0.0;
  static double _filterPendingLp = 1.0;

  static Future<void> setInstrumentFilters(
      int instrIdx, double hpNorm, double lpNorm) async {
    _filterPendingIdx = instrIdx;
    _filterPendingHp = hpNorm;
    _filterPendingLp = lpNorm;
    if (_filterCallInFlight) {
      _filterPendingUpdate = true;
      return;
    }
    do {
      _filterPendingUpdate = false;
      _filterCallInFlight = true;
      try {
        await platform.invokeMethod<void>(
          'setInstrumentFilters',
          {
            'instrIdx': _filterPendingIdx,
            'hpNorm': _filterPendingHp,
            'lpNorm': _filterPendingLp,
          },
        );
      } catch (e) {
        print('Error setInstrumentFilters: $e');
      }
      _filterCallInFlight = false;
    } while (_filterPendingUpdate);
  }

  /// Push all per-instrument sampler playback params to the native engine.
  /// fireRow() uses these so phrase playback matches the sampler preview exactly.
  /// [pitch]: SamplerParams.pitch — octave offset -1..+1 (-12..+12 semitones)
  /// [attackSec] / [releaseSec]: already in seconds (multiply by 0.5 on the call site)
  static Future<void> setInstrumentPlaybackParams(
      int instrIdx, double pitch, double volume,
      double startNorm, double endNorm,
      double attackSec, double releaseSec, int loopMode) async {
    try {
      await platform.invokeMethod<void>(
        'setInstrumentPlaybackParams',
        {
          'instrIdx': instrIdx,
          'pitch': pitch,
          'volume': volume,
          'startNorm': startNorm,
          'endNorm': endNorm,
          'attackSec': attackSec,
          'releaseSec': releaseSec,
          'loopMode': loopMode,
        },
      );
    } catch (e) {
      print('Error setInstrumentPlaybackParams: $e');
    }
  }

  // === Master chain: EQ-5 → HP → LP → Limiter → Volume ===

  /// Set one of the 5 master EQ bands (band 0-4, dBgain -12..+12)
  static Future<void> setEqBand(int band, double dBgain) async {
    try {
      await platform.invokeMethod<void>('setEqBand', {'band': band, 'dBgain': dBgain});
    } catch (e) {
      print('Error setEqBand: $e');
    }
  }

  static Future<void> setHpFreq(double hz) async {
    try {
      await platform.invokeMethod<void>('setHpFreq', {'hz': hz});
    } catch (e) {
      print('Error setHpFreq: $e');
    }
  }

  static Future<void> setHpRes(double norm) async {
    try {
      await platform.invokeMethod<void>('setHpRes', {'norm': norm});
    } catch (e) {
      print('Error setHpRes: $e');
    }
  }

  static Future<void> setLpFreq(double hz) async {
    try {
      await platform.invokeMethod<void>('setLpFreq', {'hz': hz});
    } catch (e) {
      print('Error setLpFreq: $e');
    }
  }

  static Future<void> setLpRes(double norm) async {
    try {
      await platform.invokeMethod<void>('setLpRes', {'norm': norm});
    } catch (e) {
      print('Error setLpRes: $e');
    }
  }

  static Future<void> setLimiterThreshold(double dB) async {
    try {
      await platform.invokeMethod<void>('setLimiterThreshold', {'dB': dB});
    } catch (e) {
      print('Error setLimiterThreshold: $e');
    }
  }

  static Future<void> setMasterVolume(double norm) async {
    try {
      await platform.invokeMethod<void>('setMasterVolume', {'norm': norm});
    } catch (e) {
      print('Error setMasterVolume: $e');
    }
  }

  static Future<List<double>> getTrackPeaks() async {
    try {
      final List<dynamic>? raw = await platform.invokeMethod<List<dynamic>>('getTrackPeaks');
      if (raw != null) {
        return raw.map((v) => (v as num).toDouble().clamp(0.0, 1.0)).toList();
      }
    } catch (e) {
      print('Error getTrackPeaks: $e');
    }
    return List.filled(8, 0.0);
  }

  static Future<double> getMasterPeak() async {
    try {
      final dynamic raw = await platform.invokeMethod('getMasterPeak');
      if (raw != null) return (raw as num).toDouble().clamp(0.0, 1.0);
    } catch (e) {
      print('Error getMasterPeak: $e');
    }
    return 0.0;
  }
}
