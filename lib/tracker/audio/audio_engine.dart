import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Dart wrapper for the native Oboe audio engine.
///
/// Most methods are thin wrappers around a single MethodChannel call. To keep
/// the code small and uniform, the actual `invokeMethod` + try/catch logic is
/// centralised in [_invoke] and [_invokeReturning].
class NativeAudioEngine {
  static const platform = MethodChannel('com.example.lmt/audio');

  /// Fire-and-forget invocation with uniform error logging.
  static Future<void> _invoke(String method, [Map<String, dynamic>? args]) async {
    try {
      await platform.invokeMethod<void>(method, args);
    } catch (e) {
      debugPrint('Error $method: $e');
    }
  }

  /// Invocation with a typed return; returns [fallback] on error.
  static Future<T> _invokeReturning<T>(String method, T fallback,
      [Map<String, dynamic>? args]) async {
    try {
      final result = await platform.invokeMethod<T>(method, args);
      return result ?? fallback;
    } catch (e) {
      debugPrint('Error $method: $e');
      return fallback;
    }
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  static Future<bool> initialize() =>
      _invokeReturning<bool>('initialize', false);

  static Future<void> release() => _invoke('release');

  // ---------------------------------------------------------------------------
  // Sample loading
  // ---------------------------------------------------------------------------

  static Future<bool> loadSample(int instrumentIdx, String filePath) =>
      _invokeReturning<bool>('loadSample', false,
          {'instrumentIdx': instrumentIdx, 'path': filePath});

  static Future<void> clearSample(int instrumentIdx) =>
      _invoke('clearSample', {'instrumentIdx': instrumentIdx});

  // ---------------------------------------------------------------------------
  // Manual triggering (sampler preview)
  // ---------------------------------------------------------------------------

  /// Start playing a sample at the given frequency.
  /// [instrumentIdx]: which instrument (0-98)
  /// [frequency]: playback frequency in Hz (e.g., 440 for A4)
  /// [level]: volume level (0..1)
  static Future<void> noteOn(int instrumentIdx, double frequency, double level) =>
      _invoke('noteOn', {
        'instrumentIdx': instrumentIdx,
        'frequency': frequency,
        'level': level,
      });

  /// Play a sample from startNorm..endNorm (both 0..1 normalized positions).
  /// [attackTime] / [releaseTime] in seconds.
  /// [loopMode] 0=OFF, 1=LOOP, 2=PING.
  static Future<void> noteOnRegion(int instrumentIdx, double frequency, double level,
      double startNorm, double endNorm,
      {double attackTime = 0.0, double releaseTime = 0.05, int loopMode = 0}) =>
      _invoke('noteOnRegion', {
        'instrumentIdx': instrumentIdx,
        'frequency': frequency,
        'level': level,
        'startNorm': startNorm,
        'endNorm': endNorm,
        'attackTime': attackTime,
        'releaseTime': releaseTime,
        'loopMode': loopMode,
      });

  static Future<void> noteOff(int instrumentIdx) =>
      _invoke('noteOff', {'instrumentIdx': instrumentIdx});

  static Future<void> stopAll() => _invoke('stopAll');

  static Future<bool> isPlaying(int instrumentIdx) =>
      _invokeReturning<bool>('isPlaying', false, {'instrumentIdx': instrumentIdx});

  static Future<void> setLevel(int instrumentIdx, double level) =>
      _invoke('setLevel', {'instrumentIdx': instrumentIdx, 'level': level});

  /// [pan]: 0.0 = left, 0.5 = center, 1.0 = right.
  static Future<void> setPan(int instrumentIdx, double pan) =>
      _invoke('setPan', {'instrumentIdx': instrumentIdx, 'pan': pan});

  /// Apply time-stretching to a sample (line-sync).
  /// [preservePitch] true → WSOLA (keeps pitch); false → resampling.
  static Future<void> updateStretch(int instrumentIdx, bool enabled, int lines,
          int lpb, double bpm, bool preservePitch) =>
      _invoke('updateStretch', {
        'instrumentIdx': instrumentIdx,
        'enabled': enabled,
        'lines': lines,
        'lpb': lpb,
        'bpm': bpm,
        'preservePitch': preservePitch,
      });

  // ---------------------------------------------------------------------------
  // Sequencer API — sample-accurate row-based playback
  // ---------------------------------------------------------------------------

  /// Pre-build and enqueue all song rows. Sends packed int array to native.
  ///
  /// [loop]: if true the song loops after the last row.
  /// [rows]: each element is a map with:
  ///   'lineSamples' (int) — audio frames this row lasts
  ///   'noteData'    (List<int>) — packed as groups of 9 ints per track:
  ///                              [instrIdx, midiNote, vol, fx0Id, fx0Val,
  ///                               fx1Id, fx1Val, fx2Id, fx2Val]
  static Future<void> enqueueAllRows(bool loop, List<Map<String, dynamic>> rows) async {
    // Wire format: [lineSamples, numNoteInts, ...noteInts, ...] × rows.length
    final flat = <int>[];
    for (final row in rows) {
      final ls = (row['lineSamples'] as int?) ?? 0;
      final nd = (row['noteData'] as List?)?.cast<int>() ?? <int>[];
      flat.add(ls);
      flat.add(nd.length);
      flat.addAll(nd);
    }
    await _invoke('enqueueAllRows', {'loop': loop, 'rowData': flat});
  }

  /// Returns how many rows the audio engine has advanced since the last call.
  static Future<int> consumeRowAdvances() =>
      _invokeReturning<int>('consumeRowAdvances', 0);

  /// Stop sequencer and discard queued rows.
  static Future<void> clearQueue() => _invoke('clearQueue');

  // ---------------------------------------------------------------------------
  // Per-track mixer (live — affects audio mid-row when wired native-side)
  // ---------------------------------------------------------------------------

  /// Set per-track effect send levels (trackIdx 0-7, all 0..1 normalized).
  static Future<void> setTrackSends(int trackIdx, double rev, double del, double cho) =>
      _invoke('setTrackSends',
          {'trackIdx': trackIdx, 'rev': rev, 'del': del, 'cho': cho});

  /// Set per-track dry level (0..1).  Multiplies the dry signal in the audio thread.
  static Future<void> setTrackLevel(int trackIdx, double level) =>
      _invoke('setTrackLevel', {'trackIdx': trackIdx, 'level': level});

  /// Set per-track mute (1 = audible, 0 = muted).  Applied as a gain in the audio
  /// thread, so changes take effect on the next audio buffer (~5 ms).
  static Future<void> setTrackMute(int trackIdx, bool muted) =>
      _invoke('setTrackMute', {'trackIdx': trackIdx, 'muted': muted});

  // ---------------------------------------------------------------------------
  // Per-instrument settings (sampler / FX)
  // ---------------------------------------------------------------------------

  static Future<void> setInstrumentSends(int instrIdx, double rev, double del, double cho) =>
      _invoke('setInstrumentSends',
          {'instrIdx': instrIdx, 'rev': rev, 'del': del, 'cho': cho});

  // Coalesce rapid filter updates: only one MethodChannel call in-flight at a
  // time.  Subsequent calls update the pending value; the do-while ensures the
  // final value is always flushed after the in-flight call returns.
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
      await _invoke('setInstrumentFilters', {
        'instrIdx': _filterPendingIdx,
        'hpNorm': _filterPendingHp,
        'lpNorm': _filterPendingLp,
      });
      _filterCallInFlight = false;
    } while (_filterPendingUpdate);
  }

  /// Push all per-instrument sampler playback params to the native engine.
  /// fireRow() uses these so phrase playback matches the sampler preview exactly.
  /// [pitch]: SamplerParams.pitch — octave offset −1..+1 (−12..+12 semitones)
  /// [attackSec] / [releaseSec]: already in seconds.
  static Future<void> setInstrumentPlaybackParams(
          int instrIdx, double pitch, double volume,
          double startNorm, double endNorm,
          double attackSec, double releaseSec, int loopMode) =>
      _invoke('setInstrumentPlaybackParams', {
        'instrIdx': instrIdx,
        'pitch': pitch,
        'volume': volume,
        'startNorm': startNorm,
        'endNorm': endNorm,
        'attackSec': attackSec,
        'releaseSec': releaseSec,
        'loopMode': loopMode,
      });

  // ---------------------------------------------------------------------------
  // Master Effects API
  // ---------------------------------------------------------------------------

  static Future<void> setReverbSize(double norm)    => _invoke('setReverbSize',    {'norm': norm});
  static Future<void> setReverbDamping(double norm) => _invoke('setReverbDamping', {'norm': norm});
  static Future<void> setReverbWidth(double norm)   => _invoke('setReverbWidth',   {'norm': norm});
  static Future<void> setDelayTime(double norm)     => _invoke('setDelayTime',     {'norm': norm});
  static Future<void> setDelayTimeMs(double ms)     => _invoke('setDelayTimeMs',   {'ms': ms});
  static Future<void> setDelayFeedback(double norm) => _invoke('setDelayFeedback', {'norm': norm});
  static Future<void> setChorusRate(double norm)    => _invoke('setChorusRate',    {'norm': norm});
  static Future<void> setChorusDepth(double norm)   => _invoke('setChorusDepth',   {'norm': norm});

  // === Master chain: EQ-5 → HP → LP → Limiter → Volume ===

  static Future<void> setEqBand(int band, double dBgain) =>
      _invoke('setEqBand', {'band': band, 'dBgain': dBgain});

  static Future<void> setHpFreq(double hz)   => _invoke('setHpFreq', {'hz': hz});
  static Future<void> setHpRes(double norm)  => _invoke('setHpRes',  {'norm': norm});
  static Future<void> setLpFreq(double hz)   => _invoke('setLpFreq', {'hz': hz});
  static Future<void> setLpRes(double norm)  => _invoke('setLpRes',  {'norm': norm});

  static Future<void> setLimiterThreshold(double dB) =>
      _invoke('setLimiterThreshold', {'dB': dB});

  static Future<void> setMasterVolume(double norm) =>
      _invoke('setMasterVolume', {'norm': norm});

  // ---------------------------------------------------------------------------
  // Metering
  // ---------------------------------------------------------------------------

  static Future<List<double>> getTrackPeaks() async {
    try {
      final raw = await platform.invokeMethod<List<dynamic>>('getTrackPeaks');
      if (raw != null) {
        return raw.map((v) => (v as num).toDouble().clamp(0.0, 1.0)).toList();
      }
    } catch (e) {
      debugPrint('Error getTrackPeaks: $e');
    }
    return List.filled(8, 0.0);
  }

  static Future<double> getMasterPeak() async {
    try {
      final raw = await platform.invokeMethod('getMasterPeak');
      if (raw != null) return (raw as num).toDouble().clamp(0.0, 1.0);
    } catch (e) {
      debugPrint('Error getMasterPeak: $e');
    }
    return 0.0;
  }

  // ---------------------------------------------------------------------------
  // WAV export tap
  // ---------------------------------------------------------------------------

  static Future<void> startExportTap() async {
    try {
      await platform.invokeMethod<void>('startExportTap');
    } catch (e) {
      debugPrint('Error startExportTap: $e');
    }
  }

  static Future<({List<double> samples, int sampleRate})> stopExportTap() async {
    try {
      final result = await platform.invokeMethod<Map>('stopExportTap');
      final rawSamples = result?['samples'] as List? ?? const [];
      final sampleRate = (result?['sampleRate'] as int?) ?? 48000;
      final samples = rawSamples.map((e) => (e as num).toDouble()).toList();
      return (samples: samples, sampleRate: sampleRate);
    } catch (e) {
      debugPrint('Error stopExportTap: $e');
      return (samples: const <double>[], sampleRate: 48000);
    }
  }

  // ---------------------------------------------------------------------------
  // Mic recording
  // ---------------------------------------------------------------------------

  /// Open + start the mic input stream so it stays warm before recording.
  static Future<void> openRecordingStream() async {
    try {
      await platform.invokeMethod<void>('openRecordingStream');
    } catch (e) {
      debugPrint('Error openRecordingStream: $e');
    }
  }

  /// Stop + close the mic input stream.
  static Future<void> closeRecordingStream() async {
    try {
      await platform.invokeMethod<void>('closeRecordingStream');
    } catch (e) {
      debugPrint('Error closeRecordingStream: $e');
    }
  }

  /// Begin accumulating mic input into the recording buffer.
  /// The stream must already be open (via [openRecordingStream]).
  static Future<void> startRecording() async {
    try {
      await platform.invokeMethod<void>('startRecording');
    } catch (e) {
      debugPrint('Error startRecording: $e');
    }
  }

  /// Stop recording and return the captured mono samples + sample rate.
  static Future<({List<double> samples, int sampleRate})> stopRecording() async {
    try {
      final result = await platform.invokeMethod<Map>('stopRecording');
      final rawSamples = result?['samples'] as List? ?? const [];
      final sampleRate = (result?['sampleRate'] as int?) ?? 48000;
      final samples = rawSamples.map((e) => (e as num).toDouble()).toList();
      return (samples: samples, sampleRate: sampleRate);
    } catch (e) {
      debugPrint('Error stopRecording: $e');
      return (samples: const <double>[], sampleRate: 48000);
    }
  }

  /// Copy a file from app-private storage to the public Downloads folder.
  /// [sourcePath]: absolute path to the source file.
  /// [fileName]: desired filename in Downloads (e.g. "MySong.wav").
  /// Returns the filename on success, null on failure.
  static Future<String?> saveToDownloads(
      {required String sourcePath, required String fileName}) async {
    try {
      final result = await platform.invokeMethod<String>(
          'saveToDownloads', {'sourcePath': sourcePath, 'fileName': fileName});
      return result;
    } catch (e) {
      debugPrint('Error saveToDownloads: $e');
      return null;
    }
  }
}
