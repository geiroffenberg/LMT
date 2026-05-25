import 'dart:math' show pow;

/// Sampler parameters — holds all sample playback/editing state
class SamplerParams {
  static const int sliceCount = 9;  // 9 slice points max
  static const int sliceMaxValue = 999;

  // Core sample info
  String? sampleName;
  String? samplePath;

  // Playback parameters (0..1 normalized)
  double pitch = 0.0;      // -1..1 = -12..+12 semitones
  double volume = 0.9;     // 0..1
  double start = 0.0;      // sample start position
  double end = 1.0;        // sample end position
  double attack = 0.0;     // fade-in length
  double release = 0.05;   // fade-out length

  // Loop mode: 0=OFF, 1=LOOP, 2=PING
  int loopMode = 0;

  // Slicing: 9 slice points (0..999, 0=unused)
  List<int> sliceStarts = List.filled(9, 0);

  // Time stretching
  bool stretchEnabled = false;
  int stretchLines = 16;          // lines (default 16)
  bool stretchPreservePitch = true;

  // FX sends (0..1 normalized to 0..100%)
  double modSend = 0.0;    // 0..1 → MOD (chorus/modulation)
  double delSend = 0.0;    // 0..1 → DEL (delay)
  double revSend = 0.0;    // 0..1 → REV (reverb)

  // Filters (0..1 normalized)
  double lpCutoff = 1.0;   // 0..1 → Low Pass cutoff (0=closed, 1=open)
  double hpCutoff = 0.0;   // 0..1 → High Pass cutoff (0=open, 1=closed)

  SamplerParams.empty();

  SamplerParams.copy(SamplerParams other)
      : sampleName = other.sampleName,
        samplePath = other.samplePath,
        pitch = other.pitch,
        volume = other.volume,
        start = other.start,
        end = other.end,
        attack = other.attack,
        release = other.release,
        loopMode = other.loopMode,
        sliceStarts = List.from(other.sliceStarts),
        stretchEnabled = other.stretchEnabled,
        stretchLines = other.stretchLines,
        stretchPreservePitch = other.stretchPreservePitch,
        modSend = other.modSend,
        delSend = other.delSend,
        revSend = other.revSend,
        lpCutoff = other.lpCutoff,
        hpCutoff = other.hpCutoff;

  bool get hasValidSample => samplePath != null && samplePath!.isNotEmpty;

  void clear() {
    sampleName = null;
    samplePath = null;
    pitch = 0.0;
    volume = 0.9;
    start = 0.0;
    end = 1.0;
    attack = 0.0;
    release = 0.05;
    loopMode = 0;
    sliceStarts = List.filled(9, 0);
    stretchEnabled = false;
    stretchLines = 16;
    stretchPreservePitch = true;
    modSend = 0.0;
    delSend = 0.0;
    revSend = 0.0;
    lpCutoff = 1.0;
    hpCutoff = 0.0;
  }

  // Helpers for display
  String getPitchDisplay() => (pitch * 12).toStringAsFixed(1);  // semitones
  String getVolumeDisplay() => (volume * 100).toStringAsFixed(0); // %
  String getAttackDisplay() => (attack * 500).toStringAsFixed(0);  // ms
  String getReleaseDisplay() => (release * 500).toStringAsFixed(0); // ms
  String getStartDisplay() => (start * 100).toStringAsFixed(0); // %
  String getEndDisplay() => (end * 100).toStringAsFixed(0); // %

  String getLoopModeLabel() {
    switch (loopMode) {
      case 0: return 'OFF';
      case 1: return 'LOOP';
      case 2: return 'PING';
      default: return '???';
    }
  }

  String getModDisplay() => (modSend * 100).toStringAsFixed(0);  // %
  String getDelDisplay() => (delSend * 100).toStringAsFixed(0);  // %
  String getRevDisplay() => (revSend * 100).toStringAsFixed(0);  // %
  
  String getLpDisplay() {
    if (lpCutoff == 0.0) return 'OFF';
    // Logarithmic scale: 20 Hz to 20 kHz
    final freq = 20.0 * pow(1000.0, lpCutoff);
    if (freq >= 1000) {
      return '${(freq / 1000).toStringAsFixed(1)}k';
    } else {
      return freq.toStringAsFixed(0);
    }
  }
  
  String getHpDisplay() {
    if (hpCutoff == 0.0) return 'OFF';
    // Logarithmic scale: 20 Hz to 20 kHz
    final freq = 20.0 * pow(1000.0, hpCutoff);
    if (freq >= 1000) {
      return '${(freq / 1000).toStringAsFixed(1)}k';
    } else {
      return freq.toStringAsFixed(0);
    }
  }
}
