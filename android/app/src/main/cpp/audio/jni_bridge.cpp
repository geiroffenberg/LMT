// JNI Bridge - native audio engine integration with Android
// All JNI methods are implemented in audio_engine.cpp
// This file serves as documentation and potential expansion point

#include <jni.h>

// JNI method declarations are in audio_engine.cpp:
// - nativeCreate() → creates AudioEngine instance
// - nativeDestroy() → deletes instance
// - nativeOpen() → opens Oboe stream
// - nativeClose() → closes stream
// - nativeStart() → starts playback
// - nativeStop() → stops playback
// - nativeLoadSample() → loads WAV file
// - nativeClearSample() → clears loaded sample
// - nativeNoteOn() → starts sample playback at pitch
// - nativeNoteOff() → stops playback with fade-out
// - nativeStopAll() → emergency stop
// - nativeIsPlaying() → check if voice is active
// - nativeSetLevel() → set volume (0..1)
// - nativeSetPan() → set pan (0..1)
