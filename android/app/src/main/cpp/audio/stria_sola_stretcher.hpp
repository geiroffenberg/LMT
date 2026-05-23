#ifndef STRIA_SOLA_STRETCHER_HPP
#define STRIA_SOLA_STRETCHER_HPP

#include <vector>
#include <cmath>
#include <algorithm>

/**
 * Stria WSOLA Time-Stretcher
 * License-free Waveform Similarity Overlap-Add (WSOLA) implementation.
 * Mono (single-channel) float input/output. Designed for offline baking.
 *
 * process(src, ratio):
 *   ratio > 1.0  →  slower / longer output
 *   ratio < 1.0  →  faster / shorter output
 *   ratio == 1.0 →  passthrough (still re-synthesised)
 */
class StriaSolaStretcher {
public:
    /**
     * @param sampleRate   Sample rate of the audio (Hz).
     * @param frameMsec    Grain size in milliseconds. 30ms balances transient
     *                     sharpness against pitch stability — good for drums.
     * @param searchMsec   ±search window for best-match scan (ms).
     */
    explicit StriaSolaStretcher(int   sampleRate  = 44100,
                                float frameMsec   = 30.0f,
                                float searchMsec  = 8.0f)
    {
        mFrame  = static_cast<size_t>(sampleRate * frameMsec  * 0.001f);
        mHop    = mFrame / 4;  // 25% hop → 75% overlap per grain (high quality)
        mSearch = static_cast<size_t>(sampleRate * searchMsec * 0.001f);
        buildHann();
    }

    std::vector<float> process(const std::vector<float>& src, double ratio) const
    {
        if (src.size() < mFrame || ratio <= 0.0) return {};

        const size_t inLen  = src.size();
        const size_t outLen = static_cast<size_t>(static_cast<double>(inLen) * ratio);
        if (outLen < mFrame) return {};

        std::vector<float> out (outLen, 0.0f);
        std::vector<float> norm(outLen, 0.0f);  // accumulated window weights

        // Input advances by hopIn per grain, output by mHop.
        // hopIn / mHop = 1/ratio → correct time-scale modification.
        const double hopIn = static_cast<double>(mHop) / ratio;

        double inNominal = 0.0;
        size_t outPos    = 0;

        while (outPos + mFrame <= outLen) {

            // ── Clamp search window so we can always read a full grain ────────
            const size_t inPos = static_cast<size_t>(inNominal);
            const size_t lo    = (inPos >= mSearch) ? inPos - mSearch : 0;
            size_t       hi    = inPos + mSearch;

            // hi must leave room for a full mFrame read
            if (hi + mFrame > inLen) {
                hi = (inLen >= mFrame) ? inLen - mFrame : 0;
            }
            // If lo overshot hi (very near end of file), clamp it
            const size_t clampedLo = (lo <= hi) ? lo : hi;

            // Safety: ensure lo itself is a valid grain start
            if (clampedLo + mFrame > inLen) break;

            // ── Find best-matching grain position ─────────────────────────────
            const size_t bestPos = (outPos > 0)
                ? findBest(src, inLen, clampedLo, hi, out, outPos)
                : clampedLo;   // first grain: no reference yet, use nominal start

            // ── Hann-windowed overlap-add ─────────────────────────────────────
            addGrain(src, bestPos, out, norm, outPos);

            outPos    += mHop;
            inNominal += hopIn;
        }

        // ── Normalise amplitude to remove overlap-add scaling ─────────────────
        for (size_t i = 0; i < outLen; ++i) {
            if (norm[i] > 1e-7f) out[i] /= norm[i];
        }

        return out;
    }

private:
    size_t             mFrame, mHop, mSearch;
    std::vector<float> mWin;   // Hann window, length = mFrame

    void buildHann() {
        mWin.resize(mFrame);
        const double twoPi = 2.0 * M_PI;
        for (size_t i = 0; i < mFrame; ++i) {
            mWin[i] = static_cast<float>(
                0.5 * (1.0 - std::cos(twoPi * static_cast<double>(i)
                                     / static_cast<double>(mFrame - 1))));
        }
    }

    /**
     * Scan input positions [lo, hi] and return the one whose first mHop samples
     * best correlate (normalised cross-correlation) with the last mHop samples
     * already written to the output.  This is the core WSOLA alignment step.
     */
    size_t findBest(const std::vector<float>& src, size_t inLen,
                    size_t lo, size_t hi,
                    const std::vector<float>& out, size_t outPos) const
    {
        // Reference: the tail of output written so far.
        // cmpLen is capped by how much output we have and by mHop.
        const size_t cmpLen = std::min(mHop, outPos);
        if (cmpLen == 0) return lo;

        const float* ref = out.data() + (outPos - cmpLen);

        float  bestScore = -2.0f;
        size_t bestPos   = lo;

        for (size_t s = lo; s <= hi; ++s) {
            // Bounds check: we must be able to read cmpLen samples from src[s]
            if (s + cmpLen > inLen) break;

            const float* sp = src.data() + s;

            float corr = 0.0f, eRef = 1e-9f, eSrc = 1e-9f;
            for (size_t i = 0; i < cmpLen; ++i) {
                corr += ref[i] * sp[i];
                eRef += ref[i] * ref[i];
                eSrc += sp[i]  * sp[i];
            }
            // Normalised cross-correlation — ignores level differences between frames.
            const float score = corr / std::sqrtf(eRef * eSrc);
            if (score > bestScore) { bestScore = score; bestPos = s; }
        }
        return bestPos;
    }

    /**
     * Add a Hann-windowed grain from src[srcPos .. srcPos+mFrame-1]
     * into out[outPos .. outPos+mFrame-1], accumulating weights into norm[].
     * Uses std::min guards — can never overrun either buffer.
     */
    void addGrain(const std::vector<float>& src, size_t srcPos,
                  std::vector<float>& out, std::vector<float>& norm,
                  size_t outPos) const
    {
        const size_t n = std::min(mFrame,
                         std::min(src.size() - srcPos,
                                  out.size() - outPos));
        for (size_t i = 0; i < n; ++i) {
            const float w = mWin[i];
            out [outPos + i] += src[srcPos + i] * w;
            norm[outPos + i] += w;
        }
    }
};

#endif // STRIA_SOLA_STRETCHER_HPP
