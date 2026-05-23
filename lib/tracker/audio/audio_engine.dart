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
}
