#pragma once

#include "freeverb.h"
#include <vector>
#include <cmath>
#include <algorithm>

// Master effects: reverb, delay, chorus
// All effects use parallel routing:
//   Input → [Dry Path] ──→ Mix
//        → [Reverb Send] → Reverb → Mix
//        → [Delay Send]  → Delay  → Mix
//        → [Chorus Send] → Chorus → Mix

class MasterFX {
public:
    MasterFX(int sampleRate) : mSampleRate(sampleRate) {
        // Initialize reverb
        mReverb.setroomsize(0.5f);   // 0..1
        mReverb.setdamp(0.5f);       // 0..1
        mReverb.setwidth(1.0f);      // 0..1
        mReverb.setwet(0.3f);        // 0..1
        mReverb.setdry(0.0f);        // 0..1 (we handle dry/wet mix at output)
        mReverb.setmode(0.0f);       // 0 = normal, >0.5 = freeze

        // Initialize delay buffers (max 2 seconds @ 48kHz)
        const int maxDelayFrames = mSampleRate * 2;
        mDelayBufL.resize(maxDelayFrames, 0.0f);
        mDelayBufR.resize(maxDelayFrames, 0.0f);
        mDelayWritePos = 0;

        // Initialize chorus buffers (max 60ms @ 48kHz)
        const int maxChorusFrames = mSampleRate / 16;  // ~60ms
        mChorusBufL.resize(maxChorusFrames, 0.0f);
        mChorusBufR.resize(maxChorusFrames, 0.0f);
        mChorusBufPos = 0;
    }

    ~MasterFX() = default;

    // Set reverb parameters (all 0..1 normalized)
    void setReverbSize(float norm) {
        norm = std::clamp(norm, 0.0f, 1.0f);
        mReverbSize = norm;
        mReverb.setroomsize(norm);
    }

    void setReverbDamping(float norm) {
        norm = std::clamp(norm, 0.0f, 1.0f);
        mReverbDamping = norm;
        mReverb.setdamp(norm);
    }

    void setReverbWidth(float norm) {
        norm = std::clamp(norm, 0.0f, 1.0f);
        mReverbWidth = norm;
        mReverb.setwidth(norm);
    }

    // Set delay parameters (all 0..1 normalized)
    void setDelayTime(float norm) {
        // norm 0..1 → 10..2000 ms (log scale)
        norm = std::clamp(norm, 0.0f, 1.0f);
        const float minMs = 10.0f;
        const float maxMs = 2000.0f;
        const float logMin = std::log(minMs);
        const float logMax = std::log(maxMs);
        mDelayTimeMs = std::exp(logMin + norm * (logMax - logMin));
    }

    /// Set delay time directly in milliseconds (used by the tempo-synced UI).
    void setDelayTimeMs(float ms) {
        mDelayTimeMs = std::clamp(ms, 0.0f, 2000.0f);
    }

    void setDelayFeedback(float norm) {
        norm = std::clamp(norm, 0.0f, 1.0f);
        mDelayFeedback = norm * 0.95f;  // Clamp to 0..0.95 to prevent runaway
    }

    // Set chorus parameters (all 0..1 normalized)
    void setChorusRate(float norm) {
        // norm 0..1 → 0.1..8 Hz LFO speed
        norm = std::clamp(norm, 0.0f, 1.0f);
        mChorusRateHz = 0.1f + norm * 7.9f;
    }

    void setChorusDepth(float norm) {
        // norm 0..1 → 0..15 ms modulation depth
        norm = std::clamp(norm, 0.0f, 1.0f);
        mChorusDepthMs = norm * 15.0f;
    }

    // Process audio: input is already dry signal, we generate wet taps from sends
    // [inL, inR] = input dry signal
    // [sendRevL, sendRevR] = reverb send taps
    // [sendDelL, sendDelR] = delay send taps
    // [sendChoL, sendChoR] = chorus send taps
    // [outL, outR] = output (mix of dry + wet effects)
    void process(
        const float *inL, const float *inR,
        const float *sendRevL, const float *sendRevR,
        const float *sendDelL, const float *sendDelR,
        const float *sendChoL, const float *sendChoR,
        float *outL, float *outR,
        int nsamples
    ) {
        // Temporary buffers for effect outputs
        std::vector<float> revOutL(nsamples, 0.0f);
        std::vector<float> revOutR(nsamples, 0.0f);
        std::vector<float> delOutL(nsamples, 0.0f);
        std::vector<float> delOutR(nsamples, 0.0f);
        std::vector<float> choOutL(nsamples, 0.0f);
        std::vector<float> choOutR(nsamples, 0.0f);

        // Process reverb
        mReverb.process(sendRevL, sendRevR, revOutL.data(), revOutR.data(), nsamples);

        // Process delay
        processDelay(sendDelL, sendDelR, delOutL.data(), delOutR.data(), nsamples);

        // Process chorus
        processChorus(sendChoL, sendChoR, choOutL.data(), choOutR.data(), nsamples);

        // Mix dry + all wet effects
        for (int i = 0; i < nsamples; ++i) {
            outL[i] = inL[i] + revOutL[i] + delOutL[i] + choOutL[i];
            outR[i] = inR[i] + revOutR[i] + delOutR[i] + choOutR[i];
        }
    }

private:
    int mSampleRate = 48000;

    // Reverb state
    freeverb::revmodel mReverb;
    float mReverbSize = 0.5f;
    float mReverbDamping = 0.5f;
    float mReverbWidth = 1.0f;

    // Delay state
    std::vector<float> mDelayBufL;
    std::vector<float> mDelayBufR;
    int mDelayWritePos = 0;
    float mDelayTimeMs = 375.0f;
    float mDelayFeedback = 0.4f;

    // Chorus state
    std::vector<float> mChorusBufL;
    std::vector<float> mChorusBufR;
    int mChorusBufPos = 0;
    float mChorusRateHz = 1.0f;
    float mChorusDepthMs = 5.0f;
    double mChorusLfoPhaseL = 0.0;
    double mChorusLfoPhaseR = 0.0;

    // Process delay effect (ping-pong stereo delay)
    void processDelay(const float *inL, const float *inR, float *outL, float *outR, int nsamples) {
        const int maxDelayFrames = static_cast<int>(mDelayBufL.size());
        const int delayFrames = std::max(1, static_cast<int>(mDelayTimeMs * mSampleRate / 1000.0f));

        for (int i = 0; i < nsamples; ++i) {
            const int readPos = (mDelayWritePos - delayFrames + maxDelayFrames) % maxDelayFrames;
            
            // Read delayed samples
            outL[i] = mDelayBufL[readPos];
            outR[i] = mDelayBufR[readPos];
            
            // Write new samples with feedback
            mDelayBufL[mDelayWritePos] = inL[i] + outL[i] * mDelayFeedback;
            mDelayBufR[mDelayWritePos] = inR[i] + outR[i] * mDelayFeedback;
            
            // Advance write position
            mDelayWritePos = (mDelayWritePos + 1) % maxDelayFrames;
        }
    }

public:
    // === Post-processing chain: EQ-5 → HP → LP → Limiter → MasterVolume ===
    // 5 peaking biquads at fixed frequencies (60/250/1k/4k/12kHz), Q = 1.0, no shelves.

    void setEqBand(int band, float dBgain) {
        if (band < 0 || band >= 5) return;
        mEqGain[band]  = std::clamp(dBgain, -12.0f, 12.0f);
        mEqDirty[band] = true;
    }

    // HP filter: freqHz 20..1000, norm 0..1 → Q 0.5..5.0
    void setHpFreq(float hz)   { mHpFreq  = std::clamp(hz,   20.0f, 20000.0f); mHpDirty = true; }
    void setHpRes(float norm)  { mHpQ     = 0.5f + std::clamp(norm, 0.0f, 1.0f) * 4.5f; mHpDirty = true; }

    // LP filter: freqHz 1000..20000, norm 0..1 → Q 0.5..5.0
    void setLpFreq(float hz)   { mLpFreq  = std::clamp(hz,  20.0f, 20000.0f); mLpDirty = true; }
    void setLpRes(float norm)  { mLpQ     = 0.5f + std::clamp(norm, 0.0f, 1.0f) * 4.5f; mLpDirty = true; }

    void setLimiterThreshold(float dB)  { mLimDriveDB = std::clamp(dB, 0.0f, 12.0f); }
    void setMasterVolume(float norm)    { mMasterVol   = std::clamp(norm, 0.0f, 1.0f); }

    // Run EQ-5 → HP → LP → Limiter → Volume in-place on the master stereo bus.
    void postProcess(float *outL, float *outR, int nsamples) {
        constexpr float pi = 3.14159265358979f;
        const float sr = static_cast<float>(mSampleRate);

        // ── 5-band peaking EQ ──────────────────────────────────────────────
        static constexpr float kFreqs[5] = {60.f, 250.f, 1000.f, 4000.f, 12000.f};
        static constexpr float kQ = 1.0f;
        for (int b = 0; b < 5; ++b) {
            if (mEqDirty[b]) {
                const float A    = std::pow(10.0f, mEqGain[b] / 40.0f);
                const float w0   = 2.0f * pi * kFreqs[b] / sr;
                const float alph = std::sin(w0) / (2.0f * kQ);
                const float b0   =  1.0f + alph * A;
                const float b1   = -2.0f * std::cos(w0);
                const float b2   =  1.0f - alph * A;
                const float a0   =  1.0f + alph / A;
                const float a1   = -2.0f * std::cos(w0);
                const float a2   =  1.0f - alph / A;
                const float inv  =  1.0f / a0;
                mEqCoeffs[b][0]  = b0*inv; mEqCoeffs[b][1] = b1*inv; mEqCoeffs[b][2] = b2*inv;
                mEqCoeffs[b][3]  = a1*inv; mEqCoeffs[b][4] = a2*inv;
                mEqDirty[b]      = false;
            }
            applyBiquad(mEqCoeffs[b], mEqZx[b], mEqZy[b], outL, outR, nsamples);
        }

        // ── HP filter ─────────────────────────────────────────────────────
        if (mHpDirty) {
            const float w0   = 2.0f * pi * mHpFreq / sr;
            const float cosw = std::cos(w0);
            const float alph = std::sin(w0) / (2.0f * mHpQ);
            const float b0   =  (1.0f + cosw) * 0.5f;
            const float b1   = -(1.0f + cosw);
            const float b2   =  (1.0f + cosw) * 0.5f;
            const float a0   =   1.0f + alph;
            const float a1   =  -2.0f * cosw;
            const float a2   =   1.0f - alph;
            const float inv  =   1.0f / a0;
            mHpCoeffs[0] = b0*inv; mHpCoeffs[1] = b1*inv; mHpCoeffs[2] = b2*inv;
            mHpCoeffs[3] = a1*inv; mHpCoeffs[4] = a2*inv;
            mHpDirty = false;
        }
        applyBiquad(mHpCoeffs, mHpZx, mHpZy, outL, outR, nsamples);

        // ── LP filter ─────────────────────────────────────────────────────
        if (mLpDirty) {
            const float w0   = 2.0f * pi * mLpFreq / sr;
            const float cosw = std::cos(w0);
            const float alph = std::sin(w0) / (2.0f * mLpQ);
            const float b0   =  (1.0f - cosw) * 0.5f;
            const float b1   =   1.0f - cosw;
            const float b2   =  (1.0f - cosw) * 0.5f;
            const float a0   =   1.0f + alph;
            const float a1   =  -2.0f * cosw;
            const float a2   =   1.0f - alph;
            const float inv  =   1.0f / a0;
            mLpCoeffs[0] = b0*inv; mLpCoeffs[1] = b1*inv; mLpCoeffs[2] = b2*inv;
            mLpCoeffs[3] = a1*inv; mLpCoeffs[4] = a2*inv;
            mLpDirty = false;
        }
        applyBiquad(mLpCoeffs, mLpZx, mLpZy, outL, outR, nsamples);

        // ── Soft-knee peak limiter ────────────────────────────────────────
        // Drive (mLimDriveDB): 0-12 dB input gain before the ceiling.
        // Ceiling: -0.3 dBFS.  Knee: 6 dB wide.  Attack: ~0.3ms, Release: ~200ms.
        // Algorithm: linked-stereo ballistic envelope → gain reduction in dB space
        // with standard soft-knee formula → no hard clip artefacts.
        static constexpr float kKneeDB   = 6.0f;           // knee width in dB
        static constexpr float kThreshDB = -0.3f;          // ceiling in dBFS
        static constexpr float kLn10_20  = 0.115129254f;   // ln(10)/20

        const float drive        = std::pow(10.0f, mLimDriveDB / 20.0f);
        const float sr_f         = static_cast<float>(mSampleRate);
        const float attackCoeff  = std::exp(-1.0f / (0.0003f * sr_f));   // ~0.3 ms
        const float releaseCoeff = std::exp(-1.0f / (0.200f  * sr_f));   // ~200 ms

        for (int i = 0; i < nsamples; ++i) {
            const float inL  = outL[i] * drive;
            const float inR  = outR[i] * drive;
            const float peak = std::max(std::abs(inL), std::abs(inR));

            // Ballistic envelope follower — fast attack, slow release
            if (peak > mLimEnv)
                mLimEnv = attackCoeff  * mLimEnv + (1.0f - attackCoeff)  * peak;
            else
                mLimEnv = releaseCoeff * mLimEnv + (1.0f - releaseCoeff) * peak;

            // Soft-knee gain reduction (standard compressor knee formula, ratio = ∞)
            float gain = 1.0f;
            if (mLimEnv > 1e-6f) {
                const float envDB = std::log(mLimEnv) / kLn10_20;   // 20*log10
                const float diff  = envDB - kThreshDB;
                float gainDB = 0.0f;
                if (diff > kKneeDB * 0.5f) {
                    gainDB = -diff;                                   // full limiting
                } else if (diff > -kKneeDB * 0.5f) {
                    const float x = diff + kKneeDB * 0.5f;           // 0..kKneeDB
                    gainDB = -(x * x) / (2.0f * kKneeDB);            // smooth knee
                }
                gain = std::exp(gainDB * kLn10_20);
            }

            outL[i] = inL * gain;
            outR[i] = inR * gain;
        }

        // ── Master volume ─────────────────────────────────────────────────
        for (int i = 0; i < nsamples; ++i) {
            outL[i] *= mMasterVol;
            outR[i] *= mMasterVol;
        }
    }

private:
    // ── EQ-5 state ────────────────────────────────────────────────────────
    float mEqGain[5]      = {};
    bool  mEqDirty[5]     = {true, true, true, true, true};
    float mEqCoeffs[5][5] = {};          // [band][b0,b1,b2,a1,a2]
    float mEqZx[5][2][2]  = {};          // [band][ch][z1,z2] input delay
    float mEqZy[5][2][2]  = {};          // [band][ch][z1,z2] output delay

    // ── HP state ──────────────────────────────────────────────────────────
    float mHpFreq    = 20.0f;
    float mHpQ       = 0.5f;
    bool  mHpDirty   = true;
    float mHpCoeffs[5] = {};
    float mHpZx[2][2]  = {};
    float mHpZy[2][2]  = {};

    // ── LP state ──────────────────────────────────────────────────────────
    float mLpFreq    = 20000.0f;
    float mLpQ       = 0.5f;
    bool  mLpDirty   = true;
    float mLpCoeffs[5] = {};
    float mLpZx[2][2]  = {};
    float mLpZy[2][2]  = {};

    // ── Limiter & volume ──────────────────────────────────────────────────
    float mLimDriveDB  = 0.0f;   // 0..12 dB pre-gain driving into -0.3 dBFS ceiling
    float mMasterVol   = 0.8f;   // 0..1
    float mLimEnv      = 0.0f;   // linked-stereo peak envelope (linear, ballistic follower)

    // Apply one biquad filter in-place (Direct Form I, stereo)
    void applyBiquad(const float coeff[5], float zx[2][2], float zy[2][2],
                     float *L, float *R, int n) {
        const float b0 = coeff[0], b1 = coeff[1], b2 = coeff[2];
        const float a1 = coeff[3], a2 = coeff[4];
        for (int i = 0; i < n; ++i) {
            float xL = L[i];
            float yL = b0*xL + b1*zx[0][0] + b2*zx[0][1] - a1*zy[0][0] - a2*zy[0][1];
            zx[0][1] = zx[0][0]; zx[0][0] = xL;
            zy[0][1] = zy[0][0]; zy[0][0] = yL;
            L[i] = yL;
            float xR = R[i];
            float yR = b0*xR + b1*zx[1][0] + b2*zx[1][1] - a1*zy[1][0] - a2*zy[1][1];
            zx[1][1] = zx[1][0]; zx[1][0] = xR;
            zy[1][1] = zy[1][0]; zy[1][0] = yR;
            R[i] = yR;
        }
    }

    // Process chorus effect (LFO-modulated delay)
    void processChorus(const float *inL, const float *inR, float *outL, float *outR, int nsamples) {
        const int maxChorusFrames = static_cast<int>(mChorusBufL.size());
        const float baseDelayMs = 10.0f;  // ~10 ms base delay
        const int baseDelaySamples = std::max(1, static_cast<int>(baseDelayMs * mSampleRate / 1000.0f));
        const float maxModSamples = (mChorusDepthMs / 1000.0f) * mSampleRate;
        const double lfoIncL = 2.0 * M_PI * mChorusRateHz / mSampleRate;
        const double lfoIncR = lfoIncL;  // Mono LFO (could be 90° offset for stereo)

        for (int i = 0; i < nsamples; ++i) {
            // Left channel LFO
            const float lfoL = std::sin(static_cast<float>(mChorusLfoPhaseL));
            const int delayL = baseDelaySamples + static_cast<int>(lfoL * maxModSamples);
            const int readPosL = (mChorusBufPos - delayL + maxChorusFrames) % maxChorusFrames;
            outL[i] = mChorusBufL[readPosL];
            mChorusBufL[mChorusBufPos] = inL[i];
            mChorusLfoPhaseL += lfoIncL;

            // Right channel LFO
            const float lfoR = std::sin(static_cast<float>(mChorusLfoPhaseR));
            const int delayR = baseDelaySamples + static_cast<int>(lfoR * maxModSamples);
            const int readPosR = (mChorusBufPos - delayR + maxChorusFrames) % maxChorusFrames;
            outR[i] = mChorusBufR[readPosR];
            mChorusBufR[mChorusBufPos] = inR[i];
            mChorusLfoPhaseR += lfoIncR;

            // Advance write position
            mChorusBufPos = (mChorusBufPos + 1) % maxChorusFrames;
        }
    }
};
