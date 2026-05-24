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
    float gain = 1.0f;             // current smoothed gain
    bool isFadingOut = false;
    int samplesUntilStop = 0;
    int32_t elapsedSamples = 0;    // samples since noteOn
    int32_t attackSamples = 0;     // attack duration in samples
    int32_t releaseSamples = 0;    // release duration in samples
    float envLevel = 1.0f;         // exponential envelope level (0..1)
    float releaseK = 0.0f;         // one-pole coefficient for release decay
    int loopMode = 0;              // 0=OFF, 1=LOOP, 2=PING
    bool pingDir = false;          // false=forward, true=backward (for PING mode)

    float cutoffNorm = 0.7f;       // 0..1 filter cutoff
    float resonanceNorm = 0.2f;    // 0..1 filter resonance

    // State-variable filter state
    float filterLow = 0.0f;
    float filterBand = 0.0f;
};

// ---------------------------------------------------------------------------
// Sequencer — sample-accurate row-based playback (ported from tracker/tracker)
// ---------------------------------------------------------------------------

/// One pre-built row ready for native playback.
/// noteData: packed as groups of 3 ints per track:
///   [instrumentIdx, midiNote, volume_0_99]
///   instrumentIdx = -1  → silence/no change for that track
///   midiNote      = -1  → no note (keep previous)
///   midiNote      = -2  → note off
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

    // Fire note events for a given row
    void fireRow(const QueuedRow& row);

    // Audio processing helpers
    float processSample(Voice& voice, const SampleData& sample);

    // WAV file parsing
    bool parseWavMono16(const std::string& path, std::vector<float>& outMono, int32_t& outSampleRate);
};
