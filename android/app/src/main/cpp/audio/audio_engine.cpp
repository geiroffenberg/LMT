#include "audio_engine.h"
#include "stria_sola_stretcher.hpp"
#include <android/log.h>
#include <fstream>
#include <cstring>
#include <algorithm>
#include <jni.h>

#define LOG_TAG "LMT_Audio"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, LOG_TAG, __VA_ARGS__)

// ---------------------------------------------------------------------------
// FX command IDs — must match kFxId in lib/tracker/fx_commands.dart
// ---------------------------------------------------------------------------
static constexpr int FX_VOL = 1,  FX_PAN = 2,  FX_REV = 3,  FX_DEL = 4,  FX_RET = 5;
static constexpr int FX_KIL = 6,  FX_ARP = 8,  FX_SLU = 9,  FX_SLD = 10, FX_VIB = 11;
static constexpr int FX_PIT = 12, FX_TRE = 13, FX_GAT = 14, FX_SNR = 15;
static constexpr int FX_SND = 16, FX_SNC = 17;

// Global audio engine instance (for JNI access)
static AudioEngine* gAudioEngine = nullptr;

AudioEngine::~AudioEngine() {
    close();
}

bool AudioEngine::openOutputStream() {
    oboe::AudioStreamBuilder builder;
    builder.setDirection(oboe::Direction::Output);
    builder.setPerformanceMode(oboe::PerformanceMode::LowLatency);
    builder.setSharingMode(oboe::SharingMode::Exclusive);
    builder.setFormat(oboe::AudioFormat::Float);
    builder.setChannelCount(oboe::ChannelCount::Stereo);
    builder.setDataCallback(this);
    builder.setErrorCallback(this);

    oboe::Result result = builder.openManagedStream(mStream);
    if (result != oboe::Result::OK) {
        LOGE("Failed to open Oboe stream: %s", oboe::convertToText(result));
        return false;
    }

    mSampleRate = mStream->getSampleRate();
    // Keep latency low but glitch-resistant: double-buffer at 2× the burst size.
    mStream->setBufferSizeInFrames(mStream->getFramesPerBurst() * 2);
    LOGD("Oboe stream opened: SR=%d Hz, channels=%d, burst=%d",
         mSampleRate, mStream->getChannelCount(), mStream->getFramesPerBurst());
    return true;
}

bool AudioEngine::open() {
    if (mStream) {
        LOGE("AudioEngine already open");
        return false;
    }

    if (!openOutputStream()) {
        return false;
    }

    // Initialize master effects
    mMasterFX = std::make_unique<MasterFX>(mSampleRate);

    // Pre-allocate non-interleaved processing buffers (4096 frames is safe for Oboe)
    const int maxBufFrames = 4096;
    mDryL.assign(maxBufFrames, 0.0f);    mDryR.assign(maxBufFrames, 0.0f);
    mRevSendL.assign(maxBufFrames, 0.0f); mRevSendR.assign(maxBufFrames, 0.0f);
    mDelSendL.assign(maxBufFrames, 0.0f); mDelSendR.assign(maxBufFrames, 0.0f);
    mChoSendL.assign(maxBufFrames, 0.0f); mChoSendR.assign(maxBufFrames, 0.0f);
    mWetL.assign(maxBufFrames, 0.0f);    mWetR.assign(maxBufFrames, 0.0f);

    // Initialize all voices
    for (int i = 0; i < kMaxVoices; ++i) {
        mVoices[i].instrumentIdx = -1;
    }
    // Initialize per-instrument params
    for (int i = 0; i < kMaxInstruments; ++i) {
        mInstrumentHpCutoff[i].store(0.0f, std::memory_order_relaxed);  // bypass (no HP cut)
        mInstrumentLpCutoff[i].store(1.0f, std::memory_order_relaxed);  // fully open by default
        mInstrumentRevSend[i].store(0.0f, std::memory_order_relaxed);
        mInstrumentDelSend[i].store(0.0f, std::memory_order_relaxed);
        mInstrumentChoSend[i].store(0.0f, std::memory_order_relaxed);
        mInstrumentPitch[i].store(0.0f,  std::memory_order_relaxed);
        mInstrumentVolume[i].store(0.9f,  std::memory_order_relaxed);
        mInstrumentStartNorm[i].store(0.0f,  std::memory_order_relaxed);
        mInstrumentEndNorm[i].store(1.0f,  std::memory_order_relaxed);
        mInstrumentAttack[i].store(0.0f,  std::memory_order_relaxed);
        mInstrumentRelease[i].store(0.05f, std::memory_order_relaxed);
        mInstrumentLoopMode[i].store(0,    std::memory_order_relaxed);
    }

    // Initialize per-track dry gain (unity) and mute flags (off)
    for (int t = 0; t < 8; ++t) {
        mTrackLevel[t].store(1.0f, std::memory_order_relaxed);
        mTrackMuted[t].store(false, std::memory_order_relaxed);
    }

    return true;
}

void AudioEngine::close() {
    closeRecordingStream();
    if (mStream) {
        mStream->close();
        mStream = nullptr;
        mRunning = false;
    }
}

bool AudioEngine::start() {
    if (!mStream) {
        LOGE("Cannot start: stream not open");
        return false;
    }

    oboe::Result result = mStream->requestStart();
    if (result != oboe::Result::OK) {
        LOGE("Failed to start stream: %s", oboe::convertToText(result));
        return false;
    }

    mRunning = true;
    LOGD("Audio stream started");
    return true;
}

void AudioEngine::stop() {
    if (mStream) {
        mStream->requestStop();
        mRunning = false;
        LOGD("Audio stream stopped");
    }
}

bool AudioEngine::loadSampleMono16(int instrumentIdx, const std::string& wavPath) {
    if (instrumentIdx < 0 || instrumentIdx >= kMaxInstruments) {
        LOGE("Invalid instrument index: %d", instrumentIdx);
        return false;
    }

    // Parse WAV entirely OUTSIDE the mutex — file I/O must never block the audio thread
    std::vector<float> monoData;
    int32_t sampleRate = 48000;

    if (!parseWavMono16(wavPath, monoData, sampleRate)) {
        LOGE("Failed to load WAV: %s", wavPath.c_str());
        return false;
    }

    // Only lock for the data swap itself (microseconds, not milliseconds)
    {
        std::lock_guard<std::mutex> lock(mVoiceMutex);
        // Stop the preview voice using this slot before replacing the data
        mVoices[kSeqVoices + instrumentIdx].isActive = false;
        mVoices[kSeqVoices + instrumentIdx].gain = 0.0f;
        mSamples[instrumentIdx].mono = std::move(monoData);
        mSamples[instrumentIdx].originalMono = mSamples[instrumentIdx].mono;  // Store original for stretching
        mSamples[instrumentIdx].sampleRate = sampleRate;
        mSamples[instrumentIdx].numFrames = mSamples[instrumentIdx].mono.size();
        mSamples[instrumentIdx].isLoaded = true;
    }

    LOGD("Loaded sample for instrument %d: %d frames, %d Hz",
         instrumentIdx, mSamples[instrumentIdx].numFrames, sampleRate);

    return true;
}

void AudioEngine::clearSample(int instrumentIdx) {
    if (instrumentIdx < 0 || instrumentIdx >= kMaxInstruments) return;

    std::lock_guard<std::mutex> lock(mVoiceMutex);
    mSamples[instrumentIdx].mono.clear();
    mSamples[instrumentIdx].isLoaded = false;
    mSamples[instrumentIdx].numFrames = 0;
}

void AudioEngine::noteOn(int instrumentIdx, float frequencyHz, float level) {
    if (instrumentIdx < 0 || instrumentIdx >= kMaxInstruments) return;
    if (!mSamples[instrumentIdx].isLoaded) return;

    std::lock_guard<std::mutex> lock(mVoiceMutex);

    Voice& voice = mVoices[kSeqVoices + instrumentIdx];
    voice.instrumentIdx = instrumentIdx;
    voice.isActive = true;
    voice.samplePosition = 0.0;
    voice.endFrame = 0.0;  // 0 = play to end of sample
    voice.frequency = frequencyHz;
    voice.level = level;
    voice.gain = 1.0f;
    voice.gainTarget = 1.0f;
    voice.isFadingOut = false;
    // Per-instrument sends
    voice.reverbSend = mInstrumentRevSend[instrumentIdx].load(std::memory_order_relaxed);
    voice.delaySend  = mInstrumentDelSend[instrumentIdx].load(std::memory_order_relaxed);
    voice.chorusSend = mInstrumentChoSend[instrumentIdx].load(std::memory_order_relaxed);
    // Per-instrument filters (reset biquad state on new note)
    voice.hpCutoff = mInstrumentHpCutoff[instrumentIdx].load(std::memory_order_relaxed);
    voice.lpCutoff = mInstrumentLpCutoff[instrumentIdx].load(std::memory_order_relaxed);
    voice.hpS1 = 0.0f; voice.hpS2 = 0.0f;
    voice.lpS1 = 0.0f; voice.lpS2 = 0.0f;
}

void AudioEngine::noteOnRegion(int instrumentIdx, float frequencyHz, float level, float startNorm, float endNorm, float attackTime, float releaseTime, int loopMode) {
    if (instrumentIdx < 0 || instrumentIdx >= kMaxInstruments) return;
    if (!mSamples[instrumentIdx].isLoaded) return;

    std::lock_guard<std::mutex> lock(mVoiceMutex);

    const int32_t numFrames = mSamples[instrumentIdx].numFrames;
    Voice& voice = mVoices[kSeqVoices + instrumentIdx];
    voice.instrumentIdx = instrumentIdx;
    voice.isActive = true;
    voice.startFrame = startNorm * numFrames;
    voice.samplePosition = voice.startFrame;
    voice.endFrame = endNorm * numFrames;
    voice.frequency = frequencyHz;
    voice.level = level;
    voice.gain = 0.0f;  // Start at 0 for attack envelope
    voice.gainTarget = 1.0f;
    voice.isFadingOut = false;
    voice.elapsedSamples = 0;
    voice.attackSamples = static_cast<int32_t>(attackTime * mSampleRate);
    voice.releaseSamples = static_cast<int32_t>(releaseTime * mSampleRate);
    voice.envLevel = 1.0f;
    voice.loopMode = loopMode;
    voice.pingDir = false;
    // One-pole release coefficient: larger time constant → smaller coefficient → slower decay
    voice.releaseK = 1.0f - std::exp(-1.0f / (static_cast<float>(mSampleRate) * std::max(releaseTime, 1e-4f)));
    // Read per-instrument send levels so preview plays through effects exactly like the sequencer
    voice.reverbSend = mInstrumentRevSend[instrumentIdx].load(std::memory_order_relaxed);
    voice.delaySend  = mInstrumentDelSend[instrumentIdx].load(std::memory_order_relaxed);
    voice.chorusSend = mInstrumentChoSend[instrumentIdx].load(std::memory_order_relaxed);
    // Reset biquad filter state on new note trigger
    voice.hpCutoff = mInstrumentHpCutoff[instrumentIdx].load(std::memory_order_relaxed);
    voice.lpCutoff = mInstrumentLpCutoff[instrumentIdx].load(std::memory_order_relaxed);
    voice.hpS1 = 0.0f; voice.hpS2 = 0.0f;
    voice.lpS1 = 0.0f; voice.lpS2 = 0.0f;

    LOGD("noteOnRegion: idx=%d, attackTime=%.4fs (samples=%d), releaseTime=%.4fs (samples=%d), loopMode=%d, freq=%.1f, level=%.2f",
        instrumentIdx, attackTime, voice.attackSamples, releaseTime, voice.releaseSamples, loopMode, frequencyHz, level);
}

void AudioEngine::noteOff(int instrumentIdx) {
    if (instrumentIdx < 0 || instrumentIdx >= kMaxInstruments) return;

    std::lock_guard<std::mutex> lock(mVoiceMutex);
    Voice& voice = mVoices[kSeqVoices + instrumentIdx];
    if (!voice.isActive || voice.isFadingOut) return; // already silent or already fading
    // Snapshot current envelope so the release starts from the right level
    if (voice.attackSamples > 0 && voice.elapsedSamples < voice.attackSamples)
        voice.envLevel = (float)voice.elapsedSamples / (float)voice.attackSamples;
    else
        voice.envLevel = 1.0f;
    voice.isFadingOut = true;
    // Do NOT set isActive=false here — the render loop keeps the voice alive
    // through the release decay and deactivates it once envLevel reaches zero.
}

void AudioEngine::stopAll() {
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    for (auto& voice : mVoices) {
        voice.isActive = false;
        voice.gain = 0.0f;
    }
}

void AudioEngine::updateStretch(int instrumentIdx, bool enabled, int beats, float bpm, bool preservePitch) {
    const int safe = (instrumentIdx >= 0 && instrumentIdx < kMaxInstruments) ? instrumentIdx : 0;

    // Grab a local copy of the original buffer (under lock, then release)
    std::vector<float> src;
    int srcSampleRate = 48000;
    {
        std::lock_guard<std::mutex> lock(mVoiceMutex);
        src           = mSamples[safe].originalMono;  // copy
        srcSampleRate = mSamples[safe].sampleRate;
    }

    if (src.empty()) {
        LOGD("Stretch: slot %d has no sample, skipping", safe);
        return;
    }

    if (!enabled) {
        // Restore original buffer — instant, no DSP needed.
        std::lock_guard<std::mutex> lock(mVoiceMutex);
        mSamples[safe].mono = mSamples[safe].originalMono;
        mSamples[safe].numFrames = mSamples[safe].mono.size();
        LOGD("Stretch: slot %d restored to original (%zu frames)", safe, mSamples[safe].mono.size());
        return;
    }

    if (bpm <= 0.0f || beats <= 0) {
        LOGE("Stretch: invalid bpm=%.2f beats=%d for slot %d", bpm, beats, safe);
        return;
    }

    // Compute target length
    const size_t origFrames   = src.size();
    const double targetSecs   = (static_cast<double>(beats) * 60.0) / static_cast<double>(bpm);
    const size_t targetFrames = static_cast<size_t>(targetSecs * static_cast<double>(srcSampleRate));

    if (targetFrames < 2) {
        LOGE("Stretch: target too short (%zu frames) for slot %d", targetFrames, safe);
        return;
    }

    LOGD("Stretch: slot %d  orig=%zu  target=%zu  beats=%d  bpm=%.2f  preservePitch=%d",
         safe, origFrames, targetFrames, beats, bpm, preservePitch ? 1 : 0);

    std::vector<float> stretched;

    if (preservePitch) {
        // WSOLA pitch-preserved time-stretch (license-free)
        const double stretchRatio = static_cast<double>(targetFrames) /
                                    static_cast<double>(origFrames);
        StriaSolaStretcher sola(srcSampleRate);
        stretched = sola.process(src, stretchRatio);
        LOGD("Stretch(SOLA): slot %d  orig=%zu  out=%zu  target=%zu",
             safe, origFrames, stretched.size(), targetFrames);

    } else {
        // Linear-interpolation resampler (speed/pitch linked)
        stretched.resize(targetFrames);
        const double ratio = static_cast<double>(origFrames - 1) /
                             static_cast<double>(targetFrames - 1);
        for (size_t i = 0; i < targetFrames; ++i) {
            const double srcIdx  = static_cast<double>(i) * ratio;
            const size_t idxLow  = static_cast<size_t>(srcIdx);
            const size_t idxHigh = (idxLow + 1 < origFrames) ? idxLow + 1 : idxLow;
            const float  t       = static_cast<float>(srcIdx - static_cast<double>(idxLow));
            stretched[i] = src[idxLow] + t * (src[idxHigh] - src[idxLow]);
        }
    }

    // Atomic swap under lock
    {
        std::lock_guard<std::mutex> lock(mVoiceMutex);
        mSamples[safe].mono = std::move(stretched);
        mSamples[safe].numFrames = mSamples[safe].mono.size();
    }
    LOGD("Stretch: slot %d done (%zu frames out)", safe, mSamples[safe].mono.size());
}

void AudioEngine::setLevel(int instrumentIdx, float level) {
    if (instrumentIdx < 0 || instrumentIdx >= kMaxInstruments) return;
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    mVoices[kSeqVoices + instrumentIdx].level = level;
}

void AudioEngine::setPan(int instrumentIdx, float pan) {
    if (instrumentIdx < 0 || instrumentIdx >= kMaxInstruments) return;
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    mVoices[kSeqVoices + instrumentIdx].pan = pan;
}

void AudioEngine::setFilterCutoff(int instrumentIdx, float norm) {
    // Repurposed as LP cutoff (0..1); use setInstrumentFilters for full control
    setInstrumentFilters(instrumentIdx, mInstrumentHpCutoff[instrumentIdx].load(std::memory_order_relaxed), norm);
}

void AudioEngine::setFilterResonance(int instrumentIdx, float norm) {
    // No-op: resonance is fixed at Butterworth Q; kept for API compatibility
    (void)instrumentIdx; (void)norm;
}

bool AudioEngine::isVoicePlaying(int instrumentIdx) const {
    if (instrumentIdx < 0 || instrumentIdx >= kMaxInstruments) return false;
    const auto& voice = mVoices[kSeqVoices + instrumentIdx];
    return voice.isActive || voice.gain > 0.001f;
}

// ---------------------------------------------------------------------------
// Sequencer
// ---------------------------------------------------------------------------

// Convert MIDI note number to frequency in Hz (A4 = MIDI 69 = 440 Hz)
static float midiToHz(int note) {
    return 440.0f * std::pow(2.0f, (note - 69) / 12.0f);
}

// ---------------------------------------------------------------------------
// triggerNote — arms a voice with all FX applied.  Called from fireRow (immediate
// notes) and from onAudioReady (DEL-delayed notes).  Must be called under mVoiceMutex.
// ---------------------------------------------------------------------------
void AudioEngine::triggerNote(int instrIdx, int midiNote, int vol, int trackIdx,
                               int32_t lineSamples,
                               int fx0cmd, int fx0val,
                               int fx1cmd, int fx1val,
                               int fx2cmd, int fx2val) {
    if (instrIdx < 0 || instrIdx >= kMaxInstruments) return;
    if (!mSamples[instrIdx].isLoaded) return;
    if (trackIdx < 0 || trackIdx >= kSeqVoices) return;

    const int fxCmds[3] = {fx0cmd, fx1cmd, fx2cmd};
    const int fxVals[3] = {fx0val, fx1val, fx2val};

    // Read per-instrument playback params
    const float pitchOctave = mInstrumentPitch[instrIdx].load(std::memory_order_relaxed);
    const float baseVol     = mInstrumentVolume[instrIdx].load(std::memory_order_relaxed);
    const float startNorm   = mInstrumentStartNorm[instrIdx].load(std::memory_order_relaxed);
    const float endNorm     = mInstrumentEndNorm[instrIdx].load(std::memory_order_relaxed);
    const float attackSec   = mInstrumentAttack[instrIdx].load(std::memory_order_relaxed);
    const float releaseSec  = mInstrumentRelease[instrIdx].load(std::memory_order_relaxed);
    const int   loopMode    = mInstrumentLoopMode[instrIdx].load(std::memory_order_relaxed);

    // VOL FX overrides the step volume column; scan for it first
    float effVol = (vol >= 0) ? (vol / 99.0f) : 1.0f;
    for (int f = 0; f < 3; f++) {
        if (fxCmds[f] == FX_VOL) { effVol = fxVals[f] / 99.0f; break; }
    }

    const float freq  = midiToHz(midiNote) * std::pow(2.0f, pitchOctave);
    const float level = effVol * baseVol;

    // Voice slot is keyed by TRACK, not instrument — this allows the same
    // instrument to play simultaneously on multiple tracks.
    Voice& v = mVoices[trackIdx];
    const int32_t numFrames = mSamples[instrIdx].numFrames;
    const float sf = startNorm * static_cast<float>(numFrames);
    const float ef = endNorm   * static_cast<float>(numFrames);

    // --- Arm voice ---
    v.instrumentIdx    = instrIdx;
    v.isActive         = true;
    v.startFrame       = static_cast<double>(sf);
    v.endFrame         = static_cast<double>(ef > sf ? ef : static_cast<float>(numFrames));
    v.samplePosition   = static_cast<double>(sf);
    v.frequency        = freq;
    v.level            = level;
    v.gain             = 0.0f;
    v.gainTarget       = 1.0f;
    v.isFadingOut      = false;
    v.elapsedSamples   = 0;
    v.attackSamples    = static_cast<int32_t>(attackSec * mSampleRate);
    v.envLevel         = (v.attackSamples > 0) ? 0.0f : 1.0f;
    v.loopMode         = loopMode;
    v.pingDir          = false;
    v.reverbSend       = std::min(1.0f, mTrackReverbSend[trackIdx] + mInstrumentRevSend[instrIdx].load(std::memory_order_relaxed));
    v.delaySend        = std::min(1.0f, mTrackDelaySend[trackIdx]  + mInstrumentDelSend[instrIdx].load(std::memory_order_relaxed));
    v.chorusSend       = std::min(1.0f, mTrackChorusSend[trackIdx] + mInstrumentChoSend[instrIdx].load(std::memory_order_relaxed));
    v.trackIdx         = trackIdx;
    v.hpCutoff         = mInstrumentHpCutoff[instrIdx].load(std::memory_order_relaxed);
    v.lpCutoff         = mInstrumentLpCutoff[instrIdx].load(std::memory_order_relaxed);
    v.hpS1 = v.hpS2 = v.lpS1 = v.lpS2 = 0.0f;
    const float rt     = std::max(releaseSec, 0.001f);
    v.releaseSamples   = static_cast<int32_t>(rt * mSampleRate);
    v.releaseK         = 1.0f - std::exp(-1.0f / (mSampleRate * rt));

    // --- Reset all FX modulation state ---
    v.kilCountdown    = -1;
    v.arpBaseFreq     = freq;
    v.arpStep         = 0;  v.arpStepSamples = 0;  v.arpPhase = 0;
    v.arpInterval1    = 0;  v.arpInterval2   = 0;
    v.slideTargetHz   = 0.0f;  v.slideRateHz = 0.0f;
    v.vibPhase        = 0.0f;  v.vibRateRad  = 0.0f;  v.vibDepthCents = 0.0f;
    v.trePhase        = 0.0f;  v.treRateRad  = 0.0f;  v.treDepth = 0.0f;
    v.gatPhase        = 0.0f;  v.gatRateRad  = 0.0f;  v.gatDepth = 0.0f;
    v.retCount        = 0;     v.retPeriodSamples = 0; v.retPhase = 0;
    v.retVolCurve     = 0;

    // --- Apply FX slots ---
    const float kTwoPi = 6.2831853f;
    for (int f = 0; f < 3; f++) {
        const int cmd = fxCmds[f];
        const int val = fxVals[f];
        switch (cmd) {
            case FX_VOL: /* already applied above */ break;

            case FX_PAN:
                v.pan = val / 99.0f;
                break;

            case FX_REV:
                // Play sample backwards: use pingDir mechanism, start at end
                v.pingDir        = true;
                v.samplePosition = v.endFrame > 1.0 ? v.endFrame - 1.0 : v.endFrame;
                break;

            case FX_KIL:
                // Cut note after val% of the row duration
                v.kilCountdown = static_cast<int32_t>((val / 99.0f) * lineSamples);
                if (v.kilCountdown < 1) v.kilCountdown = 1;
                break;

            case FX_PIT: {
                // Fine pitch: 00=-1 semitone, 50=0, 99=+1 semitone
                const float cents = (val - 50) * 2.0f;   // -100..+100 cents
                v.frequency  *= std::pow(2.0f, cents / 1200.0f);
                v.arpBaseFreq = v.frequency;
                break;
            }

            case FX_SNR: v.reverbSend = val / 99.0f; break;
            case FX_SND: v.delaySend  = val / 99.0f; break;
            case FX_SNC: v.chorusSend = val / 99.0f; break;

            case FX_ARP: {
                // XY: X=1st interval (0-9 semitones), Y=2nd interval (0-9 semitones)
                v.arpInterval1   = val / 10;
                v.arpInterval2   = val % 10;
                v.arpBaseFreq    = v.frequency;
                v.arpStepSamples = std::max(1, lineSamples / 3);
                v.arpStep = 0;  v.arpPhase = 0;
                break;
            }

            case FX_SLU: {
                // XY: X=lines (1-9), Y=semitones (1-9) — slide UP
                const int lines = std::max(1, val / 10);
                const int semis = val % 10;
                v.slideTargetHz = v.frequency * std::pow(2.0f, semis / 12.0f);
                v.slideRateHz   = (v.slideTargetHz - v.frequency) / static_cast<float>(lines * lineSamples);
                break;
            }

            case FX_SLD: {
                // XY: X=lines, Y=semitones — slide DOWN
                const int lines = std::max(1, val / 10);
                const int semis = val % 10;
                v.slideTargetHz = v.frequency * std::pow(2.0f, -semis / 12.0f);
                v.slideRateHz   = (v.slideTargetHz - v.frequency) / static_cast<float>(lines * lineSamples);
                break;
            }

            case FX_VIB: {
                // XY: X=speed (0-9 → 0.5-8 Hz), Y=depth (0-9 → 0-100 cents)
                const float lfoHz = 0.5f + (val / 10) * 0.833f;
                v.vibRateRad    = kTwoPi * lfoHz / static_cast<float>(mSampleRate);
                v.vibDepthCents = (val % 10) * 11.1f;
                v.vibPhase      = 0.0f;
                break;
            }

            case FX_TRE: {
                // XY: X=speed, Y=depth (0-9 → 0-100% amplitude)
                const float lfoHz = 0.5f + (val / 10) * 0.833f;
                v.treRateRad = kTwoPi * lfoHz / static_cast<float>(mSampleRate);
                v.treDepth   = (val % 10) / 9.0f;
                v.trePhase   = 0.0f;
                break;
            }

            case FX_GAT: {
                // XY: X=speed, Y=gate depth
                const float lfoHz = 0.5f + (val / 10) * 0.833f;
                v.gatRateRad = kTwoPi * lfoHz / static_cast<float>(mSampleRate);
                v.gatDepth   = (val % 10) / 9.0f;
                v.gatPhase   = 0.0f;
                break;
            }

            case FX_RET: {
                // XY: X=vol curve (0-9), Y=retrig count (1-9)
                const int curve = val / 10;
                const int count = val % 10;
                if (count > 0) {
                    v.retCount         = count;
                    v.retPeriodSamples = std::max(1, lineSamples / (count + 1));
                    v.retPhase         = 0;
                    v.retVolCurve      = curve;
                }
                break;
            }

            default: break;
        }
    }
}

// ---------------------------------------------------------------------------
// fireRow — dispatch note events for one row (stride = 9 ints per track).
// Must be called under mVoiceMutex.
// ---------------------------------------------------------------------------
void AudioEngine::fireRow(const QueuedRow& row) {
    // Fire any still-pending delayed notes from the previous row immediately
    for (const auto& dn : mPendingDelays) {
        triggerNote(dn.instrIdx, dn.midiNote, dn.vol, dn.trackIdx,
                    mCurrentRowLineSamples,
                    dn.fx0cmd, dn.fx0val, dn.fx1cmd, dn.fx1val, 0, 0);
    }
    mPendingDelays.clear();
    mCurrentRowLineSamples = row.lineSamples;

    // noteData stride = 9: [instrIdx, midiNote, vol, fx0cmd, fx0val, fx1cmd, fx1val, fx2cmd, fx2val]
    const int stride = 9;
    for (int i = 0; i + stride <= static_cast<int>(row.noteData.size()); i += stride) {
        const int instrIdx = row.noteData[i];
        const int midiNote = row.noteData[i + 1];
        const int vol      = row.noteData[i + 2];
        const int fx0cmd   = row.noteData[i + 3];
        const int fx0val   = row.noteData[i + 4];
        const int fx1cmd   = row.noteData[i + 5];
        const int fx1val   = row.noteData[i + 6];
        const int fx2cmd   = row.noteData[i + 7];
        const int fx2val   = row.noteData[i + 8];

        const int trackIdx = std::min((i / stride), 7);

        if (instrIdx < 0 || instrIdx >= kMaxInstruments) {
            if (midiNote == -2 && trackIdx < 8) {
                // OFF with no instrument: stop voice on this track
                Voice& lv = mVoices[trackIdx];
                if (lv.isActive && !lv.isFadingOut) {
                    lv.envLevel = (lv.attackSamples > 0 && lv.elapsedSamples < lv.attackSamples)
                        ? (float)lv.elapsedSamples / (float)lv.attackSamples
                        : 1.0f;
                    lv.isFadingOut = true;
                }
            } else if (midiNote >= 0 && trackIdx < 8) {
                // No instrument on this step — retrigger last instrument at new pitch
                const int lastInstr = mLastInstrOnTrack[trackIdx];
                if (lastInstr >= 0 && lastInstr < kMaxInstruments) {
                    triggerNote(lastInstr, midiNote, vol, trackIdx, row.lineSamples,
                                fx0cmd, fx0val, fx1cmd, fx1val, fx2cmd, fx2val);
                }
            }
            continue;
        }

        if (midiNote == -2) {
            // Note off — start release envelope on this track's voice
            Voice& v = mVoices[trackIdx];
            if (v.isActive && !v.isFadingOut) {
                v.envLevel = (v.attackSamples > 0 && v.elapsedSamples < v.attackSamples)
                    ? (float)v.elapsedSamples / (float)v.attackSamples
                    : 1.0f;
                v.isFadingOut = true;
            }
        } else if (midiNote >= 0) {
            // Track which instrument last fired on this track
            if (trackIdx >= 0 && trackIdx < 8) mLastInstrOnTrack[trackIdx] = instrIdx;

            // Check for DEL: if found, schedule a delayed note instead of firing immediately
            const int fxCmds[3] = {fx0cmd, fx1cmd, fx2cmd};
            const int fxVals[3] = {fx0val, fx1val, fx2val};

            int delaySamples = 0;
            for (int f = 0; f < 3; f++) {
                if (fxCmds[f] == FX_DEL) {
                    delaySamples = static_cast<int32_t>((fxVals[f] / 99.0f) * row.lineSamples);
                    break;
                }
            }

            if (delaySamples > 0) {
                // Build DelayedNote — pack the non-DEL FX (up to 2 slots)
                DelayedNote dn;
                dn.instrIdx        = instrIdx;
                dn.midiNote        = midiNote;
                dn.vol             = vol;
                dn.trackIdx        = trackIdx;
                dn.samplesRemaining = delaySamples;
                int slot = 0;
                for (int f = 0; f < 3; f++) {
                    if (fxCmds[f] == FX_DEL || fxCmds[f] == 0) continue;
                    if (slot == 0) { dn.fx0cmd = fxCmds[f]; dn.fx0val = fxVals[f]; slot++; }
                    else if (slot == 1) { dn.fx1cmd = fxCmds[f]; dn.fx1val = fxVals[f]; slot++; }
                }
                mPendingDelays.push_back(dn);
            } else {
                triggerNote(instrIdx, midiNote, vol, trackIdx, row.lineSamples,
                            fx0cmd, fx0val, fx1cmd, fx1val, fx2cmd, fx2val);
            }
        }
        // midiNote == -1 → hold/no change, skip
    }
}

void AudioEngine::enqueueAllRows(bool loop, std::vector<QueuedRow> rows) {
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    mQueue        = std::move(rows);
    mQueueIndex   = 0;
    mRowSampleCount = 0;
    mSeqLoop      = loop;
    mSeqRunning   = !mQueue.empty();
    mPendingAdvances.store(0);

    // Fire first row immediately
    if (mSeqRunning) {
        fireRow(mQueue[0]);
    }
    LOGD("Sequencer: enqueued %zu rows, loop=%d", mQueue.size(), loop ? 1 : 0);
}

void AudioEngine::clearQueue() {
    std::lock_guard<std::mutex> lock(mVoiceMutex);
    mSeqRunning = false;
    mQueue.clear();
    mQueueIndex = 0;
    mRowSampleCount = 0;
    mPendingAdvances.store(0);
    for (int i = 0; i < 8; i++) mLastInstrOnTrack[i] = -1;
    LOGD("Sequencer: cleared");
}

int32_t AudioEngine::consumePendingRowAdvances() {
    return mPendingAdvances.exchange(0);
}

oboe::DataCallbackResult AudioEngine::onAudioReady(
    oboe::AudioStream *audioStream,
    void *audioData,
    int32_t numFrames) {

    auto *outputData = static_cast<float *>(audioData);

    // Real-time safety: never block the audio thread waiting on the UI thread.
    // If a UI-thread operation (e.g. sample load / time-stretch buffer swap) holds
    // the lock, render silence this buffer instead of stalling and underrunning.
    std::unique_lock<std::mutex> lock(mVoiceMutex, std::try_to_lock);
    if (!lock.owns_lock()) {
        std::fill(outputData, outputData + numFrames * 2, 0.0f);
        return oboe::DataCallbackResult::Continue;
    }

    // Ensure processing buffers are large enough (resize is rare — only first callback if OS chose large buffer)
    if (numFrames > static_cast<int32_t>(mDryL.size())) {
        mDryL.resize(numFrames, 0.0f);    mDryR.resize(numFrames, 0.0f);
        mRevSendL.resize(numFrames, 0.0f); mRevSendR.resize(numFrames, 0.0f);
        mDelSendL.resize(numFrames, 0.0f); mDelSendR.resize(numFrames, 0.0f);
        mChoSendL.resize(numFrames, 0.0f); mChoSendR.resize(numFrames, 0.0f);
        mWetL.resize(numFrames, 0.0f);    mWetR.resize(numFrames, 0.0f);
    }

    // Clear all processing buffers
    std::fill(mDryL.begin(),    mDryL.begin()    + numFrames, 0.0f);
    std::fill(mDryR.begin(),    mDryR.begin()    + numFrames, 0.0f);
    std::fill(mRevSendL.begin(),mRevSendL.begin()+ numFrames, 0.0f);
    std::fill(mRevSendR.begin(),mRevSendR.begin()+ numFrames, 0.0f);
    std::fill(mDelSendL.begin(),mDelSendL.begin()+ numFrames, 0.0f);
    std::fill(mDelSendR.begin(),mDelSendR.begin()+ numFrames, 0.0f);
    std::fill(mChoSendL.begin(),mChoSendL.begin()+ numFrames, 0.0f);
    std::fill(mChoSendR.begin(),mChoSendR.begin()+ numFrames, 0.0f);

    // -------------------------------------------------------------------
    // DEL-delayed notes: decrement per buffer, fire notes that have expired
    // -------------------------------------------------------------------
    for (auto it = mPendingDelays.begin(); it != mPendingDelays.end(); ) {
        it->samplesRemaining -= numFrames;
        if (it->samplesRemaining <= 0) {
            triggerNote(it->instrIdx, it->midiNote, it->vol, it->trackIdx,
                        mCurrentRowLineSamples,
                        it->fx0cmd, it->fx0val, it->fx1cmd, it->fx1val, 0, 0);
            it = mPendingDelays.erase(it);
        } else {
            ++it;
        }
    }

    // -------------------------------------------------------------------
    // Sequencer: advance rows sample-accurately
    // -------------------------------------------------------------------
    if (mSeqRunning && !mQueue.empty()) {
        int framesLeft = numFrames;
        while (framesLeft > 0 && mSeqRunning) {
            const QueuedRow& row = mQueue[mQueueIndex];
            const int32_t rowDur = row.lineSamples > 0 ? row.lineSamples : mSampleRate; // fallback 1s

            const int framesUntilNextRow = rowDur - mRowSampleCount;
            const int consume = std::min(framesLeft, framesUntilNextRow);

            mRowSampleCount += consume;
            framesLeft      -= consume;

            if (mRowSampleCount >= rowDur) {
                // Row complete — advance to next
                mRowSampleCount = 0;
                mQueueIndex++;
                mPendingAdvances.fetch_add(1, std::memory_order_relaxed);

                if (mQueueIndex >= mQueue.size()) {
                    if (mSeqLoop) {
                        mQueueIndex = 0;
                    } else {
                        mSeqRunning = false;
                        break;
                    }
                }
                // Fire notes for the new row
                fireRow(mQueue[mQueueIndex]);
            }
        }
    }

    // Per-sample gain smoothing coefficient (~5ms time constant, same as tracker/tracker)
    const float smoothK = 1.0f - std::exp(-1.0f / (static_cast<float>(mSampleRate) * 0.005f));

    // Per-track peak accumulators for this buffer (filled by voice loop, then decayed into mTrackPeakLinear)
    float trackPeakWork[8] = {};

    // Process each voice — accumulate into non-interleaved dry + send buffers
    for (int v = 0; v < kMaxVoices; ++v) {
        Voice& voice = mVoices[v];
        if (!voice.isActive && voice.gain < 0.001f) continue;

        if (voice.instrumentIdx < 0 || voice.instrumentIdx >= kMaxInstruments) continue;
        const SampleData& sample = mSamples[voice.instrumentIdx];
        if (!sample.isLoaded) continue;

        const float revSend = voice.reverbSend;
        const float delSend = voice.delaySend;
        const float choSend = voice.chorusSend;

        // Per-track dry+send gain (mute kills both dry and sends; level only scales dry).
        // Reading atomics once per voice/buffer is cheap and avoids per-sample loads.
        float trackDryGain  = 1.0f;
        float trackSendGain = 1.0f;
        if (voice.trackIdx >= 0 && voice.trackIdx < 8) {
            if (mTrackMuted[voice.trackIdx].load(std::memory_order_relaxed)) {
                trackDryGain  = 0.0f;
                trackSendGain = 0.0f;
            } else {
                trackDryGain = mTrackLevel[voice.trackIdx].load(std::memory_order_relaxed);
            }
        }

        // Precompute HP/LP Chamberlin SVF coefficients (log-scale freq mapping)
        // HP: hpCutoff 0=bypass (20Hz), 1=max cut (20kHz)
        // LP: lpCutoff 1=bypass (20kHz), 0=max cut (20Hz)
        // Read atomically — filter params can be updated from UI thread without locking.
        // NOTE: index by voice.instrumentIdx, NOT v.  v is the voice slot (== trackIdx
        // for sequencer notes via triggerNote, == instrumentIdx for preview via noteOnRegion).
        // Using v here caused phrase playback to read the wrong instrument's filter.
        const float hpCutoff = mInstrumentHpCutoff[voice.instrumentIdx].load(std::memory_order_relaxed);
        const float lpCutoff = mInstrumentLpCutoff[voice.instrumentIdx].load(std::memory_order_relaxed);
        const bool doHp = hpCutoff > 0.001f;
        const bool doLp = lpCutoff < 0.999f;
        // Audio EQ Cookbook biquad LP/HP — Butterworth Q = 1/√2.
        // Computed once per buffer outside the hot loop; unconditionally stable at any frequency.
        static constexpr float kBqQ = 0.7071f;
        float hp_b0=0, hp_b1=0, hp_b2=0, hp_a1=0, hp_a2=0;
        float lp_b0=0, lp_b1=0, lp_b2=0, lp_a1=0, lp_a2=0;
        if (doHp) {
            const float hz   = 20.0f * std::pow(1000.0f, hpCutoff);
            const float w0   = 2.0f * static_cast<float>(M_PI) * hz / static_cast<float>(mSampleRate);
            const float cosw = std::cos(w0);
            const float alph = std::sin(w0) / (2.0f * kBqQ);
            const float inv  = 1.0f / (1.0f + alph);
            hp_b0 =  (1.0f + cosw) * 0.5f * inv;
            hp_b1 = -(1.0f + cosw) * inv;
            hp_b2 =  (1.0f + cosw) * 0.5f * inv;
            hp_a1 = -2.0f * cosw * inv;
            hp_a2 =  (1.0f - alph) * inv;
        }
        if (doLp) {
            const float hz   = 20.0f * std::pow(1000.0f, lpCutoff);
            const float w0   = 2.0f * static_cast<float>(M_PI) * hz / static_cast<float>(mSampleRate);
            const float cosw = std::cos(w0);
            const float alph = std::sin(w0) / (2.0f * kBqQ);
            const float inv  = 1.0f / (1.0f + alph);
            lp_b0 =  (1.0f - cosw) * 0.5f * inv;
            lp_b1 =  (1.0f - cosw) * inv;
            lp_b2 =  (1.0f - cosw) * 0.5f * inv;
            lp_a1 = -2.0f * cosw * inv;
            lp_a2 =  (1.0f - alph) * inv;
        }

        // Equal-power pan gains — constant for the whole buffer, so compute the
        // two trig calls once here instead of per-sample inside the hot loop.
        const float panAngle = voice.pan * 1.5707963f; // pan * π/2
        const float panGainL = std::cos(panAngle);
        const float panGainR = std::sin(panAngle);

        float voicePeak = 0.0f;
        for (int i = 0; i < numFrames; ++i) {
            // KIL: scheduled note cut
            if (voice.kilCountdown > 0) {
                if (--voice.kilCountdown == 0) {
                    voice.isFadingOut = true;
                    voice.gainTarget  = 0.0f;
                    voice.isActive    = false;
                }
            }
            // RET: retrigger at fixed intervals
            if (voice.retCount > 0) {
                if (++voice.retPhase >= voice.retPeriodSamples) {
                    voice.retPhase       = 0;
                    voice.retCount--;
                    voice.samplePosition = voice.startFrame;
                    voice.elapsedSamples = 0;
                    voice.attackSamples  = 0;
                    voice.envLevel       = 1.0f;
                    // ⚠️ BUG FIX: Do NOT reset isFadingOut if OFF was issued.
                    // If voice.isFadingOut is already true (from an OFF command),
                    // preserve it so the note can release instead of retriggering.
                    if (!voice.isFadingOut) {
                        voice.gainTarget = 1.0f;
                    }
                    if (voice.retVolCurve > 0) {
                        voice.level = std::max(0.0f, voice.level * (1.0f - voice.retVolCurve * 0.1f));
                    }
                }
            }

            // Per-sample exponential gain smoothing — eliminates clicks at buffer edges
            voice.gain += smoothK * (voice.gainTarget - voice.gain);

            // Calculate frames until region end
            const double framesLeft = voice.endFrame - voice.samplePosition;

            // Apply attack/release envelope on top of gain
            float envelope = 1.0f;
            if (!voice.isFadingOut) {
                // Attack phase
                if (voice.attackSamples > 0 && voice.elapsedSamples < voice.attackSamples) {
                    envelope = (float)voice.elapsedSamples / (float)voice.attackSamples;
                }
                
                // Automatic release fade as sample approaches end (tracker/tracker pattern)
                // Only for non-looping regions (looping samples use explicit noteOff for release)
                if (voice.loopMode == 0 && voice.releaseSamples > 0 && framesLeft > 0.0 && framesLeft < voice.releaseSamples) {
                    envelope *= (float)(framesLeft / voice.releaseSamples);
                }
                
                // For looping samples: apply smooth crossfade near loop boundaries (2ms)
                if ((voice.loopMode == 1 || voice.loopMode == 2) && voice.releaseSamples > 0) {
                    const double loopCrossfadeSamples = mSampleRate * 0.002;  // 2ms
                    double distToEnd = voice.endFrame - voice.samplePosition;
                    
                    // Fade out as we approach loop end
                    if (distToEnd >= 0.0 && distToEnd < loopCrossfadeSamples) {
                        float fadeEnv = (float)(distToEnd / loopCrossfadeSamples);
                        envelope *= fadeEnv;
                    }
                }
                
                voice.elapsedSamples++;
            } else {
                // Explicit fade-out: exponential decay toward 0 (click-free)
                voice.envLevel += voice.releaseK * (0.0f - voice.envLevel);
                if (voice.envLevel < 1e-4f) {
                    // Voice is now inaudible — snap gain to zero and deactivate
                    voice.envLevel    = 0.0f;
                    voice.gain        = 0.0f;
                    voice.gainTarget  = 0.0f;
                    voice.isActive    = false;
                    voice.isFadingOut = false;
                    break;
                }
                envelope = voice.envLevel;
            }

            // --- Compute effective frequency (SLU/SLD, ARP, VIB) ---
            float effFreq = voice.frequency;

            // SLU/SLD: ramp frequency toward target
            if (voice.slideRateHz != 0.0f) {
                voice.frequency += voice.slideRateHz;
                if ((voice.slideRateHz > 0.0f && voice.frequency >= voice.slideTargetHz) ||
                    (voice.slideRateHz < 0.0f && voice.frequency <= voice.slideTargetHz)) {
                    voice.frequency   = voice.slideTargetHz;
                    voice.slideRateHz = 0.0f;
                }
                effFreq = voice.frequency;
            }

            // ARP: step through semitone intervals
            if (voice.arpStepSamples > 0) {
                if (++voice.arpPhase >= voice.arpStepSamples) {
                    voice.arpPhase = 0;
                    voice.arpStep  = (voice.arpStep + 1) % 3;
                }
                const int semis = (voice.arpStep == 0) ? 0
                                : (voice.arpStep == 1) ? voice.arpInterval1
                                :                        voice.arpInterval2;
                effFreq = voice.arpBaseFreq * std::pow(2.0f, semis / 12.0f);
            }

            // VIB: pitch LFO (sine, in cents)
            if (voice.vibRateRad > 0.0f) {
                effFreq *= std::pow(2.0f, (voice.vibDepthCents / 1200.0f) * std::sin(voice.vibPhase));
                voice.vibPhase += voice.vibRateRad;
                if (voice.vibPhase >= 6.2831853f) voice.vibPhase -= 6.2831853f;
            }

            float samp = processSample(voice, sample, effFreq);
            samp *= voice.gain * voice.level * envelope;

            // TRE: tremolo (sine amplitude LFO)
            if (voice.treRateRad > 0.0f) {
                samp *= (1.0f - voice.treDepth * (0.5f + 0.5f * std::sin(voice.trePhase)));
                voice.trePhase += voice.treRateRad;
                if (voice.trePhase >= 6.2831853f) voice.trePhase -= 6.2831853f;
            }
            // GAT: gate (square-wave amplitude LFO)
            if (voice.gatRateRad > 0.0f) {
                samp *= (std::sin(voice.gatPhase) >= 0.0f) ? 1.0f : (1.0f - voice.gatDepth);
                voice.gatPhase += voice.gatRateRad;
                if (voice.gatPhase >= 6.2831853f) voice.gatPhase -= 6.2831853f;
            }

            // Biquad HP then LP — Direct Form II Transposed (mono), stable at any frequency
            if (doHp) {
                const float y = hp_b0 * samp + voice.hpS1;
                voice.hpS1 = hp_b1 * samp - hp_a1 * y + voice.hpS2;
                voice.hpS2 = hp_b2 * samp - hp_a2 * y;
                samp = y;
            }
            if (doLp) {
                const float y = lp_b0 * samp + voice.lpS1;
                voice.lpS1 = lp_b1 * samp - lp_a1 * y + voice.lpS2;
                voice.lpS2 = lp_b2 * samp - lp_a2 * y;
                samp = y;
            }

            // Equal-power stereo pan (gains precomputed once per buffer above)
            float sampL = samp * panGainL;
            float sampR = samp * panGainR;

            // Accumulate into dry and effect send buffers
            mDryL[i] += sampL * trackDryGain;
            mDryR[i] += sampR * trackDryGain;
            mRevSendL[i] += sampL * revSend * trackSendGain;
            mRevSendR[i] += sampR * revSend * trackSendGain;
            mDelSendL[i] += sampL * delSend * trackSendGain;
            mDelSendR[i] += sampR * delSend * trackSendGain;
            mChoSendL[i] += sampL * choSend * trackSendGain;
            mChoSendR[i] += sampR * choSend * trackSendGain;

            const float pkSamp = std::max(std::abs(sampL), std::abs(sampR)) * trackDryGain;
            if (pkSamp > voicePeak) voicePeak = pkSamp;
        }

        // Contribute this voice's peak to its track meter
        if (voice.trackIdx >= 0 && voice.trackIdx < 8 && voicePeak > trackPeakWork[voice.trackIdx]) {
            trackPeakWork[voice.trackIdx] = voicePeak;
        }

        // Silence and deactivate fully faded voices
        if (voice.isFadingOut && voice.gain < 0.001f) {
            voice.gain = 0.0f;
            voice.isFadingOut = false;
        }
    }

    // Apply per-track peak decay and update meter state
    {
        // ~300ms release: peak drops to 0.001 (−60dB) in 300ms
        const float decayCoeff = std::pow(0.001f, static_cast<float>(numFrames) / (0.3f * mSampleRate));
        for (int t = 0; t < 8; ++t) {
            mTrackPeakLinear[t] = std::max(trackPeakWork[t], mTrackPeakLinear[t] * decayCoeff);
        }
    }

    // Route through master effects, write interleaved stereo to output
    if (mMasterFX) {
        mMasterFX->process(
            mDryL.data(), mDryR.data(),
            mRevSendL.data(), mRevSendR.data(),
            mDelSendL.data(), mDelSendR.data(),
            mChoSendL.data(), mChoSendR.data(),
            mWetL.data(), mWetR.data(),
            numFrames
        );
        mMasterFX->postProcess(mWetL.data(), mWetR.data(), numFrames);

        // Capture post-limiter master peak with ~300ms decay
        float masterBufPeak = 0.0f;
        for (int i = 0; i < numFrames; ++i) {
            float pk = std::max(std::abs(mWetL[i]), std::abs(mWetR[i]));
            if (pk > masterBufPeak) masterBufPeak = pk;
        }
        const float masterDecay = std::pow(0.001f, static_cast<float>(numFrames) / (0.3f * mSampleRate));
        mMasterPeakLinear = std::max(masterBufPeak, mMasterPeakLinear * masterDecay);

        for (int i = 0; i < numFrames; ++i) {
            outputData[i * 2]     = mWetL[i];
            outputData[i * 2 + 1] = mWetR[i];
        }
    } else {
        for (int i = 0; i < numFrames; ++i) {
            outputData[i * 2]     = mDryL[i];
            outputData[i * 2 + 1] = mDryR[i];
        }
    }

    // Export tap — copy final stereo output to export buffer
    if (mExportTapActive.load()) {
        std::lock_guard<std::mutex> exportLock(mExportMutex);
        if (mExportTapActive.load()) {
            if ((int)mExportBuffer.size() < kMaxExportFrames * 2) {
                mExportBuffer.insert(
                    mExportBuffer.end(),
                    outputData,
                    outputData + numFrames * 2);
            }
        }
    }

    return oboe::DataCallbackResult::Continue;
}

void AudioEngine::startExportTap() {
    std::lock_guard<std::mutex> lock(mExportMutex);
    mExportBuffer.clear();
    mExportTapActive.store(true);
}

std::vector<float> AudioEngine::stopExportTap(int& outSampleRate) {
    mExportTapActive.store(false);
    std::lock_guard<std::mutex> lock(mExportMutex);
    outSampleRate = mSampleRate;
    return std::move(mExportBuffer);
}

// ---------------------------------------------------------------------------
// Mic recording — independent low-latency mono input stream
// ---------------------------------------------------------------------------

// Dedicated data callback that forwards the input stream to the engine.
class RecordingCallback : public oboe::AudioStreamDataCallback {
public:
    explicit RecordingCallback(AudioEngine* engine) : mEngine(engine) {}
    oboe::DataCallbackResult onAudioReady(
            oboe::AudioStream* stream, void* audioData, int32_t numFrames) override {
        return mEngine->onRecordingAudioReady(stream, audioData, numFrames);
    }
private:
    AudioEngine* mEngine;
};

void AudioEngine::openRecordingStream() {
    if (mRecordingStream) return; // already open

    if (!mRecordingCallback) {
        mRecordingCallback = std::make_unique<RecordingCallback>(this);
    }

    oboe::AudioStreamBuilder builder;
    builder.setDirection(oboe::Direction::Input);
    builder.setPerformanceMode(oboe::PerformanceMode::LowLatency);
    builder.setSharingMode(oboe::SharingMode::Shared);
    builder.setFormat(oboe::AudioFormat::Float);
    builder.setChannelCount(oboe::ChannelCount::Mono);
    builder.setDataCallback(mRecordingCallback.get());

    oboe::Result result = builder.openManagedStream(mRecordingStream);
    if (result != oboe::Result::OK) {
        LOGE("Failed to open recording input stream: %s", oboe::convertToText(result));
        mRecordingStream = nullptr;
        return;
    }

    mRecordingSampleRate = mRecordingStream->getSampleRate();
    LOGD("Recording input stream opened: SR=%d Hz", mRecordingSampleRate);

    result = mRecordingStream->requestStart();
    if (result != oboe::Result::OK) {
        LOGE("Failed to start recording input stream: %s", oboe::convertToText(result));
        mRecordingStream->close();
        mRecordingStream = nullptr;
    }
}

void AudioEngine::closeRecordingStream() {
    mIsRecording.store(false);
    if (mRecordingStream) {
        mRecordingStream->stop();
        mRecordingStream->close();
        mRecordingStream = nullptr;
    }
}

void AudioEngine::startRecording() {
    {
        std::lock_guard<std::mutex> lock(mRecordingMutex);
        mRecordingBuffer.clear();
        mRecordingBuffer.reserve(kMaxRecordingFrames);
        mRecordingWarmupFrames = kRecWarmupFrames;
    }
    mIsRecording.store(true);
}

std::vector<float> AudioEngine::stopRecording(int& outSampleRate) {
    mIsRecording.store(false);
    std::lock_guard<std::mutex> lock(mRecordingMutex);
    outSampleRate = mRecordingSampleRate;
    return std::move(mRecordingBuffer);
}

oboe::DataCallbackResult AudioEngine::onRecordingAudioReady(
        oboe::AudioStream* /*stream*/, void* audioData, int32_t numFrames) {
    if (!mIsRecording.load()) {
        // Drain silently to keep the stream warm.
        return oboe::DataCallbackResult::Continue;
    }

    const float* in = static_cast<const float*>(audioData);
    std::lock_guard<std::mutex> lock(mRecordingMutex);

    int32_t start = 0;
    // Skip the warm-up transient at the very start of a take.
    if (mRecordingWarmupFrames > 0) {
        const int32_t skip = std::min<int32_t>(mRecordingWarmupFrames, numFrames);
        mRecordingWarmupFrames -= skip;
        start = skip;
    }

    for (int32_t i = start; i < numFrames; ++i) {
        if (static_cast<int>(mRecordingBuffer.size()) >= kMaxRecordingFrames) {
            mIsRecording.store(false);
            break;
        }
        mRecordingBuffer.push_back(in[i]);
    }

    return oboe::DataCallbackResult::Continue;
}


float AudioEngine::processSample(Voice& voice, const SampleData& sample, float effFrequency) {
    if (sample.numFrames == 0) return 0.0f;

    // Sample rate conversion ratio, adjusted by effective frequency (pitch + all FX LFOs).
    // Reference: C-4 (MIDI 60 = 261.626 Hz) plays the sample at original speed (1×).
    static constexpr double kRootHz = 261.626; // C-4
    double sampleStep = (double)sample.sampleRate / (double)mSampleRate * (double)effFrequency / kRootHz;

    // pingDir: used by both PING loop mode and REV fx — negative step goes backwards
    if (voice.pingDir) {
        sampleStep = -sampleStep;
    }

    // Cubic Hermite (Catmull-Rom) interpolation — eliminates aliasing on pitched samples
    int pos = static_cast<int>(voice.samplePosition);
    if (pos < 0 || pos >= static_cast<int>(sample.numFrames)) {
        voice.isActive = false;
        return 0.0f;
    }

    const int nf = static_cast<int>(sample.numFrames);
    float frac = static_cast<float>(voice.samplePosition - pos);
    float sm1 = (pos > 0)      ? sample.mono[pos - 1] : sample.mono[pos];
    float s0  = sample.mono[pos];
    float s1  = (pos + 1 < nf) ? sample.mono[pos + 1] : s0;
    float s2  = (pos + 2 < nf) ? sample.mono[pos + 2] : s1;

    // Catmull-Rom cubic: exact at integer positions, C1 continuous
    float output = s0 + 0.5f * frac * (s1 - sm1 +
                   frac * (2.0f * sm1 - 5.0f * s0 + 4.0f * s1 - s2 +
                   frac * (3.0f * (s0 - s1) + s2 - sm1)));
    voice.samplePosition += sampleStep;

    // Handle end/start boundary based on loop mode
    double startAt = voice.startFrame;
    double stopAt = (voice.endFrame > 0.0) ? voice.endFrame : (double)sample.numFrames;

    if (voice.loopMode == 0) {
        if (voice.pingDir) {
            // REV (reversed, no loop): stop when position goes below startAt
            if (voice.samplePosition < startAt) {
                voice.isActive    = false;
                voice.gainTarget  = 0.0f;
                voice.isFadingOut = true;
            }
        } else {
            // OFF (forward, no loop): stop at end
            if (voice.samplePosition >= stopAt) {
                voice.isActive    = false;
                voice.gainTarget  = 0.0f;
                voice.isFadingOut = true;
            }
        }
    } else if (voice.loopMode == 1) {
        // LOOP: wrap forward
        if (voice.samplePosition >= stopAt) {
            voice.samplePosition = startAt + (voice.samplePosition - stopAt);
        }
    } else if (voice.loopMode == 2) {
        // PING: bounce back and forth
        if (voice.samplePosition >= stopAt) {
            voice.samplePosition = stopAt - (voice.samplePosition - stopAt);
            voice.pingDir = true;  // reverse direction
        } else if (voice.samplePosition < startAt) {
            voice.samplePosition = startAt + (startAt - voice.samplePosition);
            voice.pingDir = false;  // forward direction
        }
    }

    return output;
}

bool AudioEngine::parseWavMono16(const std::string& path, std::vector<float>& outMono, int32_t& outSampleRate) {
    std::ifstream file(path, std::ios::binary);
    if (!file.is_open()) {
        LOGE("Cannot open WAV file: %s", path.c_str());
        return false;
    }

    // Read RIFF header
    char chunkId[4];
    file.read(chunkId, 4);
    if (std::strncmp(chunkId, "RIFF", 4) != 0) {
        LOGE("Not a RIFF file: %s", path.c_str());
        return false;
    }

    uint32_t chunkSize;
    file.read(reinterpret_cast<char*>(&chunkSize), 4);

    char format[4];
    file.read(format, 4);
    if (std::strncmp(format, "WAVE", 4) != 0) {
        LOGE("Not a WAVE file: %s", path.c_str());
        return false;
    }

    // Find fmt chunk
    bool foundFmt = false;
    uint16_t numChannels = 0, bitsPerSample = 0;

    while (file.good()) {
        file.read(chunkId, 4);
        uint32_t subChunkSize;
        file.read(reinterpret_cast<char*>(&subChunkSize), 4);

        if (std::strncmp(chunkId, "fmt ", 4) == 0) {
            uint16_t audioFormat;
            file.read(reinterpret_cast<char*>(&audioFormat), 2);
            file.read(reinterpret_cast<char*>(&numChannels), 2);
            file.read(reinterpret_cast<char*>(&outSampleRate), 4);

            uint32_t byteRate;
            file.read(reinterpret_cast<char*>(&byteRate), 4);

            uint16_t blockAlign;
            file.read(reinterpret_cast<char*>(&blockAlign), 2);
            file.read(reinterpret_cast<char*>(&bitsPerSample), 2);

            foundFmt = (audioFormat == 1 && (bitsPerSample == 16 || bitsPerSample == 24 || bitsPerSample == 32));
            LOGD("WAV fmt: channels=%u, SR=%u, bps=%u", numChannels, outSampleRate, bitsPerSample);
        } else if (std::strncmp(chunkId, "data", 4) == 0) {
            if (!foundFmt) {
                LOGE("fmt chunk not found before data chunk");
                return false;
            }

            // Read audio data
            int bytesPerSample = bitsPerSample / 8;
            int totalBytes = subChunkSize;
            int totalSamples = totalBytes / (bytesPerSample * numChannels);

            outMono.resize(totalSamples);

            for (int i = 0; i < totalSamples; ++i) {
                float sum = 0.0f;
                for (uint16_t ch = 0; ch < numChannels; ++ch) {
                    if (bitsPerSample == 16) {
                        int16_t sample;
                        file.read(reinterpret_cast<char*>(&sample), 2);
                        sum += static_cast<float>(sample) / 32768.0f;
                    } else if (bitsPerSample == 24) {
                        uint8_t bytes[3];
                        file.read(reinterpret_cast<char*>(bytes), 3);
                        int32_t sample = (bytes[2] << 16) | (bytes[1] << 8) | bytes[0];
                        if (sample & 0x800000) sample |= 0xFF000000;  // sign extend
                        sum += static_cast<float>(sample) / 8388608.0f;
                    } else if (bitsPerSample == 32) {
                        float sample;
                        file.read(reinterpret_cast<char*>(&sample), 4);
                        sum += sample;
                    }
                }
                outMono[i] = sum / numChannels;
            }

            LOGD("Loaded %d samples", totalSamples);
            return true;
        } else {
            // Skip unknown chunk
            file.seekg(subChunkSize, std::ios::cur);
        }
    }

    LOGE("data chunk not found");
    return false;
}

void AudioEngine::onErrorAfterClose(oboe::AudioStream *audioStream, oboe::Result error) {
    LOGE("Audio stream error after close: %s", oboe::convertToText(error));
    // A disconnect (headphones unplugged, Bluetooth route change, USB DAC removed)
    // closes the stream. Rebuild + restart so audio keeps working without a manual
    // app restart. onErrorAfterClose runs on a dedicated Oboe thread, so it is safe
    // to reopen the stream here.
    if (error == oboe::Result::ErrorDisconnected) {
        restartStream();
    }
}

void AudioEngine::onErrorBeforeClose(oboe::AudioStream *audioStream, oboe::Result error) {
    LOGE("Audio stream error before close: %s", oboe::convertToText(error));
}

void AudioEngine::restartStream() {
    if (mRestarting.exchange(true)) return;  // a restart is already in progress

    if (mStream) {
        mStream->close();
        mStream = nullptr;
    }
    mRunning = false;

    // Reopen with the same low-latency config. Samples and per-instrument/track
    // parameters live outside the stream, so they survive the rebuild untouched.
    if (!openOutputStream()) {
        LOGE("restartStream: failed to reopen output stream");
        mRestarting.store(false);
        return;
    }
    oboe::Result result = mStream->requestStart();
    if (result != oboe::Result::OK) {
        LOGE("restartStream: failed to start stream: %s", oboe::convertToText(result));
        mRestarting.store(false);
        return;
    }
    mRunning = true;
    LOGD("Audio stream restarted after route change (SR=%d)", mSampleRate);
    mRestarting.store(false);
}

// ============ JNI Bridge ============

extern "C" {

JNIEXPORT jlong JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeCreate(JNIEnv *env, jobject obj) {
    gAudioEngine = new AudioEngine();
    return reinterpret_cast<jlong>(gAudioEngine);
}

JNIEXPORT void JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeDestroy(JNIEnv *env, jobject obj, jlong handle) {
    auto* engine = reinterpret_cast<AudioEngine*>(handle);
    delete engine;
    if (engine == gAudioEngine) gAudioEngine = nullptr;
}

JNIEXPORT jboolean JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeOpen(JNIEnv *env, jobject obj, jlong handle) {
    auto* engine = reinterpret_cast<AudioEngine*>(handle);
    return engine->open();
}

JNIEXPORT void JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeClose(JNIEnv *env, jobject obj, jlong handle) {
    auto* engine = reinterpret_cast<AudioEngine*>(handle);
    engine->close();
}

JNIEXPORT jboolean JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeStart(JNIEnv *env, jobject obj, jlong handle) {
    auto* engine = reinterpret_cast<AudioEngine*>(handle);
    return engine->start();
}

JNIEXPORT void JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeStop(JNIEnv *env, jobject obj, jlong handle) {
    auto* engine = reinterpret_cast<AudioEngine*>(handle);
    engine->stop();
}

JNIEXPORT jboolean JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeLoadSample(JNIEnv *env, jobject obj, jlong handle,
                                                         jint instrumentIdx, jstring path) {
    auto* engine = reinterpret_cast<AudioEngine*>(handle);
    const char* pathStr = env->GetStringUTFChars(path, nullptr);
    bool result = engine->loadSampleMono16(instrumentIdx, pathStr);
    env->ReleaseStringUTFChars(path, pathStr);
    return result;
}

JNIEXPORT void JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeClearSample(JNIEnv *env, jobject obj, jlong handle,
                                                          jint instrumentIdx) {
    auto* engine = reinterpret_cast<AudioEngine*>(handle);
    engine->clearSample(instrumentIdx);
}

JNIEXPORT void JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeNoteOn(JNIEnv *env, jobject obj, jlong handle,
                                                     jint instrumentIdx, jfloat frequency, jfloat level) {
    auto* engine = reinterpret_cast<AudioEngine*>(handle);
    engine->noteOn(instrumentIdx, frequency, level);
}

JNIEXPORT void JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeNoteOnRegion(JNIEnv *env, jobject obj, jlong handle,
                                                           jint instrumentIdx, jfloat frequency,
                                                           jfloat level, jfloat startNorm, jfloat endNorm,
                                                           jfloat attackTime, jfloat releaseTime, jint loopMode) {
    auto* engine = reinterpret_cast<AudioEngine*>(handle);
    engine->noteOnRegion(instrumentIdx, frequency, level, startNorm, endNorm, attackTime, releaseTime, loopMode);
}

JNIEXPORT void JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeNoteOff(JNIEnv *env, jobject obj, jlong handle,
                                                      jint instrumentIdx) {
    auto* engine = reinterpret_cast<AudioEngine*>(handle);
    engine->noteOff(instrumentIdx);
}

JNIEXPORT void JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeStopAll(JNIEnv *env, jobject obj, jlong handle) {
    auto* engine = reinterpret_cast<AudioEngine*>(handle);
    engine->stopAll();
}

JNIEXPORT jboolean JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeIsPlaying(JNIEnv *env, jobject obj, jlong handle,
                                                        jint instrumentIdx) {
    auto* engine = reinterpret_cast<AudioEngine*>(handle);
    return engine->isVoicePlaying(instrumentIdx);
}

JNIEXPORT void JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeSetLevel(JNIEnv *env, jobject obj, jlong handle,
                                                       jint instrumentIdx, jfloat level) {
    auto* engine = reinterpret_cast<AudioEngine*>(handle);
    engine->setLevel(instrumentIdx, level);
}

JNIEXPORT void JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeSetPan(JNIEnv *env, jobject obj, jlong handle,
                                                     jint instrumentIdx, jfloat pan) {
    auto* engine = reinterpret_cast<AudioEngine*>(handle);
    engine->setPan(instrumentIdx, pan);
}

JNIEXPORT void JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeUpdateStretch(JNIEnv *env, jobject obj, jlong handle,
                                                            jint instrumentIdx, jboolean enabled,
                                                            jint beats, jfloat bpm, jboolean preservePitch) {
    auto* engine = reinterpret_cast<AudioEngine*>(handle);
    engine->updateStretch(instrumentIdx, enabled, beats, bpm, preservePitch);
}

// ---------------------------------------------------------------------------
// Master Effects
// ---------------------------------------------------------------------------

void AudioEngine::setTrackSends(int trackIdx, float rev, float del, float cho) {
    if (trackIdx < 0 || trackIdx >= 8) return;
    mTrackReverbSend[trackIdx] = rev;
    mTrackDelaySend[trackIdx]  = del;
    mTrackChorusSend[trackIdx] = cho;
}

void AudioEngine::setTrackLevel(int trackIdx, float level) {
    if (trackIdx < 0 || trackIdx >= 8) return;
    mTrackLevel[trackIdx].store(std::clamp(level, 0.0f, 1.0f), std::memory_order_relaxed);
}

void AudioEngine::setTrackMute(int trackIdx, bool muted) {
    if (trackIdx < 0 || trackIdx >= 8) return;
    mTrackMuted[trackIdx].store(muted, std::memory_order_relaxed);
}

void AudioEngine::setInstrumentSends(int instrIdx, float rev, float del, float cho) {
    if (instrIdx < 0 || instrIdx >= kMaxInstruments) return;
    // Atomic stores — no mutex needed; audio thread reads these atomically
    mInstrumentRevSend[instrIdx].store(std::clamp(rev, 0.0f, 1.0f), std::memory_order_relaxed);
    mInstrumentDelSend[instrIdx].store(std::clamp(del, 0.0f, 1.0f), std::memory_order_relaxed);
    mInstrumentChoSend[instrIdx].store(std::clamp(cho, 0.0f, 1.0f), std::memory_order_relaxed);
}

void AudioEngine::setInstrumentFilters(int instrIdx, float hpNorm, float lpNorm) {
    if (instrIdx < 0 || instrIdx >= kMaxInstruments) return;
    // Atomic store — no mutex needed; audio callback reads these atomically, so no blocking
    mInstrumentHpCutoff[instrIdx].store(std::clamp(hpNorm, 0.0f, 1.0f), std::memory_order_relaxed);
    mInstrumentLpCutoff[instrIdx].store(std::clamp(lpNorm, 0.0f, 1.0f), std::memory_order_relaxed);
}

void AudioEngine::setInstrumentPlaybackParams(int instrIdx, float pitch, float volume,
                                               float startNorm, float endNorm,
                                               float attackSec, float releaseSec, int loopMode) {
    if (instrIdx < 0 || instrIdx >= kMaxInstruments) return;
    mInstrumentPitch[instrIdx].store(pitch, std::memory_order_relaxed);
    mInstrumentVolume[instrIdx].store(std::clamp(volume, 0.0f, 1.0f), std::memory_order_relaxed);
    mInstrumentStartNorm[instrIdx].store(std::clamp(startNorm, 0.0f, 1.0f), std::memory_order_relaxed);
    mInstrumentEndNorm[instrIdx].store(std::clamp(endNorm, 0.0f, 1.0f), std::memory_order_relaxed);
    mInstrumentAttack[instrIdx].store(std::max(attackSec, 0.0f), std::memory_order_relaxed);
    mInstrumentRelease[instrIdx].store(std::max(releaseSec, 0.001f), std::memory_order_relaxed);
    mInstrumentLoopMode[instrIdx].store(loopMode, std::memory_order_relaxed);
}

void AudioEngine::setReverbSize(float norm) {
    if (mMasterFX) mMasterFX->setReverbSize(norm);
}

void AudioEngine::setReverbDamping(float norm) {
    if (mMasterFX) mMasterFX->setReverbDamping(norm);
}

void AudioEngine::setReverbWidth(float norm) {
    if (mMasterFX) mMasterFX->setReverbWidth(norm);
}

void AudioEngine::setDelayTime(float norm) {
    if (mMasterFX) mMasterFX->setDelayTime(norm);
}

void AudioEngine::setDelayTimeMs(float ms) {
    if (mMasterFX) mMasterFX->setDelayTimeMs(ms);
}

void AudioEngine::setDelayFeedback(float norm) {
    if (mMasterFX) mMasterFX->setDelayFeedback(norm);
}

void AudioEngine::setChorusRate(float norm) {
    if (mMasterFX) mMasterFX->setChorusRate(norm);
}

void AudioEngine::setEqBand(int band, float dBgain)   { if (mMasterFX) mMasterFX->setEqBand(band, dBgain); }
void AudioEngine::setHpFreq(float hz)                  { if (mMasterFX) mMasterFX->setHpFreq(hz); }
void AudioEngine::setHpRes(float norm)                 { if (mMasterFX) mMasterFX->setHpRes(norm); }
void AudioEngine::setLpFreq(float hz)                  { if (mMasterFX) mMasterFX->setLpFreq(hz); }
void AudioEngine::setLpRes(float norm)                 { if (mMasterFX) mMasterFX->setLpRes(norm); }
void AudioEngine::setLimiterThreshold(float dB)        { if (mMasterFX) mMasterFX->setLimiterThreshold(dB); }
void AudioEngine::setMasterVolume(float norm)          { if (mMasterFX) mMasterFX->setMasterVolume(norm); }

void AudioEngine::setChorusDepth(float norm) {
    if (mMasterFX) mMasterFX->setChorusDepth(norm);
}

// ---------------------------------------------------------------------------
// Sequencer JNI
// ---------------------------------------------------------------------------

/// Enqueue all rows for playback.
/// rowData is a flat int array with the following layout per row:
///   [lineSamples, numNoteInts, noteInt0, noteInt1, ..., lineSamples, ...]
JNIEXPORT void JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeEnqueueAllRows(JNIEnv *env, jobject obj, jlong handle,
                                                              jboolean loop, jintArray rowData) {
    auto* engine = reinterpret_cast<AudioEngine*>(handle);

    jsize len = env->GetArrayLength(rowData);
    jint* data = env->GetIntArrayElements(rowData, nullptr);

    std::vector<QueuedRow> rows;
    int i = 0;
    while (i < len) {
        if (i + 2 > len) break; // need at least lineSamples + numNoteInts

        QueuedRow row;
        row.lineSamples = data[i++];
        const int numInts = data[i++];
        if (i + numInts > len) break; // malformed
        row.noteData.assign(data + i, data + i + numInts);
        i += numInts;
        rows.push_back(std::move(row));
    }

    env->ReleaseIntArrayElements(rowData, data, JNI_ABORT);
    engine->enqueueAllRows(loop, std::move(rows));
}

JNIEXPORT jint JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeConsumeRowAdvances(JNIEnv *env, jobject obj, jlong handle) {
    auto* engine = reinterpret_cast<AudioEngine*>(handle);
    return engine->consumePendingRowAdvances();
}

JNIEXPORT void JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeClearQueue(JNIEnv *env, jobject obj, jlong handle) {
    auto* engine = reinterpret_cast<AudioEngine*>(handle);
    engine->clearQueue();
}

// ---------------------------------------------------------------------------
// Master Effects JNI
// ---------------------------------------------------------------------------

JNIEXPORT void JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeSetReverbSize(JNIEnv *env, jobject obj, jlong handle, jfloat norm) {
    auto* engine = reinterpret_cast<AudioEngine*>(handle);
    engine->setReverbSize(norm);
}

JNIEXPORT void JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeSetReverbDamping(JNIEnv *env, jobject obj, jlong handle, jfloat norm) {
    auto* engine = reinterpret_cast<AudioEngine*>(handle);
    engine->setReverbDamping(norm);
}

JNIEXPORT void JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeSetReverbWidth(JNIEnv *env, jobject obj, jlong handle, jfloat norm) {
    auto* engine = reinterpret_cast<AudioEngine*>(handle);
    engine->setReverbWidth(norm);
}

JNIEXPORT void JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeSetDelayTime(JNIEnv *env, jobject obj, jlong handle, jfloat norm) {
    auto* engine = reinterpret_cast<AudioEngine*>(handle);
    engine->setDelayTime(norm);
}

JNIEXPORT void JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeSetDelayTimeMs(JNIEnv *env, jobject obj, jlong handle, jfloat ms) {
    auto* engine = reinterpret_cast<AudioEngine*>(handle);
    engine->setDelayTimeMs(ms);
}

JNIEXPORT void JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeSetDelayFeedback(JNIEnv *env, jobject obj, jlong handle, jfloat norm) {
    auto* engine = reinterpret_cast<AudioEngine*>(handle);
    engine->setDelayFeedback(norm);
}

JNIEXPORT void JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeSetChorusRate(JNIEnv *env, jobject obj, jlong handle, jfloat norm) {
    auto* engine = reinterpret_cast<AudioEngine*>(handle);
    engine->setChorusRate(norm);
}

JNIEXPORT void JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeSetChorusDepth(JNIEnv *env, jobject obj, jlong handle, jfloat norm) {
    auto* engine = reinterpret_cast<AudioEngine*>(handle);
    engine->setChorusDepth(norm);
}

JNIEXPORT void JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeSetTrackSends(JNIEnv *env, jobject obj, jlong handle,
                                                             jint trackIdx, jfloat rev, jfloat del, jfloat cho) {
    auto* engine = reinterpret_cast<AudioEngine*>(handle);
    engine->setTrackSends(static_cast<int>(trackIdx), rev, del, cho);
}

JNIEXPORT void JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeSetTrackLevel(JNIEnv *env, jobject obj, jlong handle,
                                                             jint trackIdx, jfloat level) {
    auto* engine = reinterpret_cast<AudioEngine*>(handle);
    engine->setTrackLevel(static_cast<int>(trackIdx), level);
}

JNIEXPORT void JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeSetTrackMute(JNIEnv *env, jobject obj, jlong handle,
                                                            jint trackIdx, jboolean muted) {
    auto* engine = reinterpret_cast<AudioEngine*>(handle);
    engine->setTrackMute(static_cast<int>(trackIdx), muted == JNI_TRUE);
}

JNIEXPORT jfloatArray JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeGetTrackPeaks(JNIEnv *env, jobject obj, jlong handle) {
    auto* engine = reinterpret_cast<AudioEngine*>(handle);
    jfloatArray result = env->NewFloatArray(8);
    jfloat peaks[8];
    for (int i = 0; i < 8; ++i) peaks[i] = engine->getTrackPeak(i);
    env->SetFloatArrayRegion(result, 0, 8, peaks);
    return result;
}

JNIEXPORT jfloat JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeGetMasterPeak(JNIEnv *env, jobject obj, jlong handle) {
    return reinterpret_cast<AudioEngine*>(handle)->getMasterPeak();
}

JNIEXPORT void JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeSetEqBand(JNIEnv *env, jobject obj, jlong handle, jint band, jfloat dBgain) {
    reinterpret_cast<AudioEngine*>(handle)->setEqBand(static_cast<int>(band), dBgain);
}

JNIEXPORT void JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeSetHpFreq(JNIEnv *env, jobject obj, jlong handle, jfloat hz) {
    reinterpret_cast<AudioEngine*>(handle)->setHpFreq(hz);
}

JNIEXPORT void JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeSetHpRes(JNIEnv *env, jobject obj, jlong handle, jfloat norm) {
    reinterpret_cast<AudioEngine*>(handle)->setHpRes(norm);
}

JNIEXPORT void JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeSetLpFreq(JNIEnv *env, jobject obj, jlong handle, jfloat hz) {
    reinterpret_cast<AudioEngine*>(handle)->setLpFreq(hz);
}

JNIEXPORT void JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeSetLpRes(JNIEnv *env, jobject obj, jlong handle, jfloat norm) {
    reinterpret_cast<AudioEngine*>(handle)->setLpRes(norm);
}

JNIEXPORT void JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeSetLimiterThreshold(JNIEnv *env, jobject obj, jlong handle, jfloat dB) {
    reinterpret_cast<AudioEngine*>(handle)->setLimiterThreshold(dB);
}

JNIEXPORT void JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeSetMasterVolume(JNIEnv *env, jobject obj, jlong handle, jfloat norm) {
    reinterpret_cast<AudioEngine*>(handle)->setMasterVolume(norm);
}

JNIEXPORT void JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeSetInstrumentSends(JNIEnv *env, jobject obj, jlong handle,
                                                                  jint instrIdx, jfloat rev, jfloat del, jfloat cho) {
    reinterpret_cast<AudioEngine*>(handle)->setInstrumentSends(static_cast<int>(instrIdx), rev, del, cho);
}

JNIEXPORT void JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeSetInstrumentFilters(JNIEnv *env, jobject obj, jlong handle,
                                                                    jint instrIdx, jfloat hpNorm, jfloat lpNorm) {
    reinterpret_cast<AudioEngine*>(handle)->setInstrumentFilters(static_cast<int>(instrIdx), hpNorm, lpNorm);
}

JNIEXPORT void JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeSetInstrumentPlaybackParams(JNIEnv *env, jobject obj, jlong handle,
                                                                          jint instrIdx, jfloat pitch, jfloat volume,
                                                                          jfloat startNorm, jfloat endNorm,
                                                                          jfloat attackSec, jfloat releaseSec, jint loopMode) {
    reinterpret_cast<AudioEngine*>(handle)->setInstrumentPlaybackParams(
        static_cast<int>(instrIdx), pitch, volume, startNorm, endNorm, attackSec, releaseSec, static_cast<int>(loopMode));
}

JNIEXPORT void JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeStartExportTap(JNIEnv*, jobject, jlong handle) {
    reinterpret_cast<AudioEngine*>(handle)->startExportTap();
}

JNIEXPORT jfloatArray JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeStopExportTap(
        JNIEnv* env, jobject, jlong handle, jintArray outSampleRate) {
    int sampleRate = 48000;
    std::vector<float> samples = reinterpret_cast<AudioEngine*>(handle)->stopExportTap(sampleRate);
    jint* ratePtr = env->GetIntArrayElements(outSampleRate, nullptr);
    ratePtr[0] = sampleRate;
    env->ReleaseIntArrayElements(outSampleRate, ratePtr, 0);
    jfloatArray result = env->NewFloatArray(static_cast<jsize>(samples.size()));
    if (result != nullptr && !samples.empty()) {
        env->SetFloatArrayRegion(result, 0, static_cast<jsize>(samples.size()), samples.data());
    }
    return result;
}

JNIEXPORT void JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeOpenRecordingStream(JNIEnv*, jobject, jlong handle) {
    reinterpret_cast<AudioEngine*>(handle)->openRecordingStream();
}

JNIEXPORT void JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeCloseRecordingStream(JNIEnv*, jobject, jlong handle) {
    reinterpret_cast<AudioEngine*>(handle)->closeRecordingStream();
}

JNIEXPORT void JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeStartRecording(JNIEnv*, jobject, jlong handle) {
    reinterpret_cast<AudioEngine*>(handle)->startRecording();
}

JNIEXPORT jfloatArray JNICALL
Java_com_metamind_lmt_AudioEnginePlugin_nativeStopRecording(
        JNIEnv* env, jobject, jlong handle, jintArray outSampleRate) {
    int sampleRate = 48000;
    std::vector<float> samples = reinterpret_cast<AudioEngine*>(handle)->stopRecording(sampleRate);
    jint* ratePtr = env->GetIntArrayElements(outSampleRate, nullptr);
    ratePtr[0] = sampleRate;
    env->ReleaseIntArrayElements(outSampleRate, ratePtr, 0);
    jfloatArray result = env->NewFloatArray(static_cast<jsize>(samples.size()));
    if (result != nullptr && !samples.empty()) {
        env->SetFloatArrayRegion(result, 0, static_cast<jsize>(samples.size()), samples.data());
    }
    return result;
}

} // extern "C"
