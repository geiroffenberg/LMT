#pragma once

#include <oboe/Oboe.h>
#include <vector>
#include <array>
#include <atomic>
#include <mutex>
#include <cmath>
#include <cstdint>
#include <string>
#include <memory>
#include <jni.h>
#include "../master_fx.h"

static constexpr int kMaxVoices = 99; // one per instrument in LMT

/// WAV sample data container
struct SampleData {
    std::vector<float> mono;           // mono normalized float [-1..1] (may be stretched)
    std::vector<float> originalMono;   // original un-stretched audio for re-baking
    int32_t sampleRate = 48000;
    int32_t numFrames = 0;
    bool isLoaded = false;
};

/// Per-voice state for sampler playback
struct Voice {
    int instrumentIdx = -1;  // -1 = unused
    bool isActive = false;
    double samplePosition = 0.0;  // current playback position in samples
    double startFrame = 0.0;      // start of playable region
    double endFrame = 0.0;        // end of playable region
    float frequency = 440.0f;     // Hz (for pitch control)
    float level = 0.8f;           // 0..1 volume
    float pan = 0.5f;             // 0..1 pan (0=left, 1=right)
    float gainTarget = 0.0f;       // target gain for fade-out
    float gain = 0.0f;             // current smoothed gain (0 = silent/inactive)
    bool isFadingOut = false;
    int samplesUntilStop = 0;
    int32_t elapsedSamples = 0;    // samples since noteOn
    int32_t attackSamples = 0;     // attack duration in samples
    int32_t releaseSamples = 0;    // release duration in samples
    float envLevel = 1.0f;         // exponential envelope level (0..1)
    float releaseK = 0.0f;         // one-pole coefficient for release decay
    int loopMode = 0;              // 0=OFF, 1=LOOP, 2=PING
    bool pingDir = false;          // false=forward, true=backward (for PING mode)

    float reverbSend = 0.0f;       // 0..1 send to reverb
    float delaySend  = 0.0f;       // 0..1 send to delay
    float chorusSend = 0.0f;       // 0..1 send to chorus

    int   trackIdx   = -1;         // 0-7 mixer track (set by fireRow)

    // Per-instrument HP/LP Chamberlin SVF
    float hpCutoff = 0.0f;         // 0..1 norm (0 = bypass)
    float lpCutoff = 1.0f;         // 0..1 norm (1 = bypass)
    // Per-voice biquad filter state (Direct Form II Transposed, mono)
    float hpS1 = 0.0f, hpS2 = 0.0f;  // HP biquad delay elements
    float lpS1 = 0.0f, lpS2 = 0.0f;  // LP biquad delay elements

    // ---- Per-note FX modulation state (set by triggerNote, read in onAudioReady) ----
    // KIL: scheduled note cut
    int32_t kilCountdown = -1;      // samples until voice is cut (-1 = not scheduled)
    // REV: reverse playback (reuses pingDir; set samplePosition = endFrame-1 at note-on)
    // ARP: arpeggio
    float arpBaseFreq   = 0.0f;    // root frequency (Hz) for arp
    int   arpStep       = 0;       // current arp position (0=root, 1=1st, 2=2nd)
    int   arpStepSamples= 0;       // samples per arp step (lineSamples/3)
    int   arpPhase      = 0;       // samples since last step advance
    int   arpInterval1  = 0;       // 1st interval in semitones
    int   arpInterval2  = 0;       // 2nd interval in semitones
    // SLU/SLD: pitch slide
    float slideTargetHz = 0.0f;    // destination frequency
    float slideRateHz   = 0.0f;    // Hz change per sample (0 = inactive)
    // VIB: pitch LFO (sine)
    float vibPhase      = 0.0f;    // 0..2π
    float vibRateRad    = 0.0f;    // radians per sample (0 = off)
    float vibDepthCents = 0.0f;    // ± cents at peak
    // TRE: tremolo (sine amplitude LFO)
    float trePhase      = 0.0f;
    float treRateRad    = 0.0f;    // radians per sample (0 = off)
    float treDepth      = 0.0f;    // 0..1
    // GAT: gate (square wave amplitude LFO)
    float gatPhase      = 0.0f;
    float gatRateRad    = 0.0f;    // radians per sample (0 = off)
    float gatDepth      = 0.0f;    // 0..1
    // RET: retrigger
    int   retCount      = 0;       // remaining retrig events
    int   retPeriodSamples = 0;    // samples between retrigs
    int   retPhase      = 0;       // samples since last retrig
    int   retVolCurve   = 0;       // 0-9: per-retrig level multiplier (0=flat, 9=-90% each)
};

// ---------------------------------------------------------------------------
// Sequencer — sample-accurate row-based playback (ported from tracker/tracker)
// ---------------------------------------------------------------------------

/// A note scheduled to fire after a DEL (delay) FX offset within a row.
struct DelayedNote {
    int instrIdx       = -1;
    int midiNote       = -1;
    int vol            = 80;
    int trackIdx       = 0;
    int32_t samplesRemaining = 0;   // counts down per buffer; fires when <= 0
    // Non-DEL FX slots forwarded to triggerNote (up to 2 remaining after removing DEL)
    int fx0cmd = 0, fx0val = 0;
    int fx1cmd = 0, fx1val = 0;
};

/// One pre-built row ready for native playback.
/// noteData: packed as groups of 9 ints per track:
///   [instrIdx, midiNote, vol, fx0cmd, fx0val, fx1cmd, fx1val, fx2cmd, fx2val]
///   instrIdx  = -1  → silence/no change for that track
///   midiNote  = -1  → no note (keep previous)
///   midiNote  = -2  → note off
struct QueuedRow {
    int32_t lineSamples = 0;      // how many audio frames this row lasts
    std::vector<int> noteData;    // track note events (groups of 3)
};

/// Main audio engine: Oboe stream manager + sample playback
class AudioEngine : public oboe::AudioStreamDataCallback,
                    public oboe::AudioStreamErrorCallback {
public:
    AudioEngine() = default;
    ~AudioEngine();

    // Lifecycle
    bool open();
    void close();
    bool start();
    void stop();
    bool isRunning() const { return mRunning; }

    // Sample loading
    bool loadSampleMono16(int instrumentIdx, const std::string& wavPath);
    void clearSample(int instrumentIdx);

    // Playback control
    void noteOn(int instrumentIdx, float frequencyHz, float level);
    void noteOnRegion(int instrumentIdx, float frequency, float level, float startNorm, float endNorm, float attackTime = 0.0f, float releaseTime = 0.05f, int loopMode = 0);
    void noteOff(int instrumentIdx);
    void stopAll();

    // Parameter control
    void setLevel(int instrumentIdx, float level);  // 0..1
    void setPan(int instrumentIdx, float pan);      // 0..1 (0=left, 0.5=center, 1=right)
    void setFilterCutoff(int instrumentIdx, float norm);  // 0..1
    void setFilterResonance(int instrumentIdx, float norm); // 0..1

    // Time stretching
    void updateStretch(int instrumentIdx, bool enabled, int beats, float bpm, bool preservePitch);

    // Monitoring
    bool isVoicePlaying(int instrumentIdx) const;
    int32_t getSampleRate() const { return mSampleRate; }

    // -----------------------------------------------------------------------
    // Sequencer API — sample-accurate song playback
    // -----------------------------------------------------------------------

    /// Load all rows for playback in one call. Clears any existing queue.
    /// [loop] = true: the queue replays from row 0 at the end.
    void enqueueAllRows(bool loop, std::vector<QueuedRow> rows);

    /// Stop sequencer and clear queue.
    void clearQueue();

    /// Consume row-advance ticks accumulated since the last call.
    /// Returns the number of rows the playhead has advanced (for Dart UI update).
    int32_t consumePendingRowAdvances();
    // -----------------------------------------------------------------------
    // Master Effects API
    // -----------------------------------------------------------------------

    void setReverbSize(float norm);      // 0..1
    void setReverbDamping(float norm);   // 0..1
    void setReverbWidth(float norm);     // 0..1

    void setDelayTime(float norm);       // 0..1 → ~10..2000 ms
    void setDelayFeedback(float norm);   // 0..1

    void setChorusRate(float norm);      // 0..1 → ~0.1..8 Hz
    void setChorusDepth(float norm);     // 0..1 → ~0..15 ms

    // Per-track send levels (8 tracks, all 0..1)
    void setTrackSends(int trackIdx, float rev, float del, float cho);

    // Per-track dry level (0..1) — multiplied into the dry voice output
    void setTrackLevel(int trackIdx, float level);

    // Per-track mute (audio-thread atomic). Bypasses the track's dry + send paths.
    void setTrackMute(int trackIdx, bool muted);

    // Per-instrument send levels (0..1); stacked on top of track sends
    void setInstrumentSends(int instrIdx, float rev, float del, float cho);

    // Per-instrument HP/LP filter (0..1 norm; hpNorm 0=bypass, lpNorm 1=bypass)
    void setInstrumentFilters(int instrIdx, float hpNorm, float lpNorm);

    // Per-instrument playback params (mirrors SamplerParams: pitch/vol/start/end/atk/rel/loop)
    void setInstrumentPlaybackParams(int instrIdx, float pitch, float volume,
                                     float startNorm, float endNorm,
                                     float attackSec, float releaseSec, int loopMode);

    // Per-track peak levels for metering (linear 0..1, with slow decay)
    float getTrackPeak(int t) const { return (t >= 0 && t < 8) ? mTrackPeakLinear[t] : 0.0f; }

    // Post-limiter master bus peak for the master VU meter
    float getMasterPeak() const { return mMasterPeakLinear; }

    // WAV export tap — capture final stereo output while playing
    void startExportTap();
    std::vector<float> stopExportTap(int& outSampleRate);

    // Master chain: EQ-5 → HP → LP → Limiter → Volume
    void setEqBand(int band, float dBgain);   // band 0-4, dBgain -12..+12
    void setHpFreq(float hz);                  // 20..1000 Hz
    void setHpRes(float norm);                 // 0..1 → Q 0.5..5.0
    void setLpFreq(float hz);                  // 1000..20000 Hz
    void setLpRes(float norm);                 // 0..1 → Q 0.5..5.0
    void setLimiterThreshold(float dB);        // 0..12 dB drive into -0.3 dBFS ceiling
    void setMasterVolume(float norm);          // 0..1

    /// AudioStreamDataCallback
    oboe::DataCallbackResult onAudioReady(
        oboe::AudioStream *audioStream,
        void *audioData,
        int32_t numFrames) override;

    // AudioStreamErrorCallback
    void onErrorAfterClose(oboe::AudioStream *audioStream, oboe::Result error) override;
    void onErrorBeforeClose(oboe::AudioStream *audioStream, oboe::Result error) override;

private:
    oboe::ManagedStream mStream;
    std::array<SampleData, kMaxVoices> mSamples;
    std::array<Voice, kMaxVoices> mVoices;
    std::mutex mVoiceMutex;

    int32_t mSampleRate = 48000;
    bool mRunning = false;

    // -----------------------------------------------------------------------
    // Sequencer state (protected by mVoiceMutex — same lock as voices)
    // -----------------------------------------------------------------------
    std::vector<QueuedRow> mQueue;
    size_t                 mQueueIndex      = 0;   // current row in queue
    int32_t                mRowSampleCount  = 0;   // samples elapsed in current row
    bool                   mSeqRunning      = false;
    bool                   mSeqLoop         = false;
    std::atomic<int32_t>   mPendingAdvances {0};   // rows advanced since last poll

    // Delayed notes from DEL fx (decremented per buffer, fired when <= 0)
    std::vector<DelayedNote> mPendingDelays;
    int32_t mCurrentRowLineSamples = 0;  // lineSamples of the currently playing row

    // Per-track send levels (8 tracks)
    float mTrackReverbSend[8] = {};
    float mTrackDelaySend[8]  = {};
    float mTrackChorusSend[8] = {};

    // Per-track dry gain + mute (atomic so UI thread can write without locking)
    std::atomic<float> mTrackLevel[8];      // initialized to 1.0 in open()
    std::atomic<bool>  mTrackMuted[8];      // initialized to false in open()

    // Per-instrument send levels (kMaxVoices instruments) — atomic for lock-free UI thread writes
    std::atomic<float> mInstrumentRevSend[kMaxVoices];
    std::atomic<float> mInstrumentDelSend[kMaxVoices];
    std::atomic<float> mInstrumentChoSend[kMaxVoices];

    // Per-instrument HP/LP cutoff (0..1 norm) — atomic so UI thread can write without locking
    std::atomic<float> mInstrumentHpCutoff[kMaxVoices];
    std::atomic<float> mInstrumentLpCutoff[kMaxVoices];  // initialized to 1.0 in open()

    // Per-instrument playback params (set from Dart sampler window, read in fireRow)
    std::atomic<float> mInstrumentPitch[kMaxVoices];      // octave offset -1..+1 (stored as SamplerParams.pitch)
    std::atomic<float> mInstrumentVolume[kMaxVoices];     // base volume 0..1
    std::atomic<float> mInstrumentStartNorm[kMaxVoices];  // playback start 0..1
    std::atomic<float> mInstrumentEndNorm[kMaxVoices];    // playback end 0..1
    std::atomic<float> mInstrumentAttack[kMaxVoices];     // attack time in seconds
    std::atomic<float> mInstrumentRelease[kMaxVoices];    // release time in seconds
    std::atomic<int>   mInstrumentLoopMode[kMaxVoices];   // 0=OFF,1=LOOP,2=PING

    // Per-track peak levels for VU meters (linear 0..1, audio-thread write / JNI read)
    float mTrackPeakLinear[8] = {};
    float mMasterPeakLinear   = 0.0f;

    // Non-interleaved processing buffers (sized in open())
    std::vector<float> mDryL, mDryR;
    std::vector<float> mRevSendL, mRevSendR;
    std::vector<float> mDelSendL, mDelSendR;
    std::vector<float> mChoSendL, mChoSendR;
    std::vector<float> mWetL, mWetR;

    // Master effects (created on open, uses mSampleRate)
    std::unique_ptr<class MasterFX> mMasterFX;

    // Fire note events for a given row (stride-9 noteData)
    void fireRow(const QueuedRow& row);

    // Trigger a single note-on immediately, applying all FX slots
    void triggerNote(int instrIdx, int midiNote, int vol, int trackIdx,
                     int32_t lineSamples,
                     int fx0cmd, int fx0val,
                     int fx1cmd, int fx1val,
                     int fx2cmd, int fx2val);

    // Audio processing helpers
    float processSample(Voice& voice, const SampleData& sample, float effFrequency);

    // WAV file parsing
    bool parseWavMono16(const std::string& path, std::vector<float>& outMono, int32_t& outSampleRate);

    // Export tap state
    static constexpr int kMaxExportFrames = 48000 * 60 * 10; // 10 minutes
    std::mutex           mExportMutex;
    std::atomic<bool>    mExportTapActive{false};
    std::vector<float>   mExportBuffer; // interleaved stereo L,R

    // Last instrument triggered per track (0-7) — used to retrigger at a new
    // pitch when a step has a note but no instrument column set.
    int mLastInstrOnTrack[8] = {-1,-1,-1,-1,-1,-1,-1,-1};
};
