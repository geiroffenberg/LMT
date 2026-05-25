// Freeverb implementation (public domain)

#include "freeverb.h"

#include <algorithm>
#include <cstring>

namespace freeverb {

namespace {
constexpr int kStereoSpread = 23;

constexpr int kCombTuningL[kNumCombs] = {1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617};
constexpr int kCombTuningR[kNumCombs] = {
    1116 + kStereoSpread,
    1188 + kStereoSpread,
    1277 + kStereoSpread,
    1356 + kStereoSpread,
    1422 + kStereoSpread,
    1491 + kStereoSpread,
    1557 + kStereoSpread,
    1617 + kStereoSpread,
};

constexpr int kAllpassTuningL[kNumAllpasses] = {556, 441, 341, 225};
constexpr int kAllpassTuningR[kNumAllpasses] = {
    556 + kStereoSpread,
    441 + kStereoSpread,
    341 + kStereoSpread,
    225 + kStereoSpread,
};

constexpr float kFixedGain = 0.015f;
constexpr float kScaleWet = 3.0f;
constexpr float kScaleDry = 2.0f;
constexpr float kScaleDamp = 0.4f;
constexpr float kScaleRoom = 0.28f;
constexpr float kOffsetRoom = 0.7f;
constexpr float kFreezeMode = 0.5f;
} // namespace

void comb::mute() {
    if (!buffer || size <= 0) return;
    std::fill_n(buffer, size, 0.0f);
    filterstore = 0.0f;
    index = 0;
}

void allpass::mute() {
    if (!buffer || size <= 0) return;
    std::fill_n(buffer, size, 0.0f);
    index = 0;
}

revmodel::revmodel()
    : roomsize(0.5f), damp(0.5f), wet(1.0f / kScaleWet), dry(0.0f), width(1.0f), mode(0.0f) {
    // Initialise combs
    combL[0].setbuffer(bufcombL1, kCombTuningL[0]);
    combL[1].setbuffer(bufcombL2, kCombTuningL[1]);
    combL[2].setbuffer(bufcombL3, kCombTuningL[2]);
    combL[3].setbuffer(bufcombL4, kCombTuningL[3]);
    combL[4].setbuffer(bufcombL5, kCombTuningL[4]);
    combL[5].setbuffer(bufcombL6, kCombTuningL[5]);
    combL[6].setbuffer(bufcombL7, kCombTuningL[6]);
    combL[7].setbuffer(bufcombL8, kCombTuningL[7]);

    combR[0].setbuffer(bufcombR1, kCombTuningR[0]);
    combR[1].setbuffer(bufcombR2, kCombTuningR[1]);
    combR[2].setbuffer(bufcombR3, kCombTuningR[2]);
    combR[3].setbuffer(bufcombR4, kCombTuningR[3]);
    combR[4].setbuffer(bufcombR5, kCombTuningR[4]);
    combR[5].setbuffer(bufcombR6, kCombTuningR[5]);
    combR[6].setbuffer(bufcombR7, kCombTuningR[6]);
    combR[7].setbuffer(bufcombR8, kCombTuningR[7]);

    // Initialise allpasses
    allpassL[0].setbuffer(bufallpassL1, kAllpassTuningL[0]);
    allpassL[1].setbuffer(bufallpassL2, kAllpassTuningL[1]);
    allpassL[2].setbuffer(bufallpassL3, kAllpassTuningL[2]);
    allpassL[3].setbuffer(bufallpassL4, kAllpassTuningL[3]);

    allpassR[0].setbuffer(bufallpassR1, kAllpassTuningR[0]);
    allpassR[1].setbuffer(bufallpassR2, kAllpassTuningR[1]);
    allpassR[2].setbuffer(bufallpassR3, kAllpassTuningR[2]);
    allpassR[3].setbuffer(bufallpassR4, kAllpassTuningR[3]);

    // Set default values
    for (int i = 0; i < kNumAllpasses; ++i) {
        allpassL[i].setfeedback(0.5f);
        allpassR[i].setfeedback(0.5f);
    }

    update();
    mute();
}

revmodel::~revmodel() {}

void revmodel::mute() {
    if (mode >= kFreezeMode) return;
    for (int i = 0; i < kNumCombs; ++i) {
        combL[i].mute();
        combR[i].mute();
    }
    for (int i = 0; i < kNumAllpasses; ++i) {
        allpassL[i].mute();
        allpassR[i].mute();
    }
}

void revmodel::process(const float *inL, const float *inR, float *outL, float *outR, int nsamples) {
    for (int i = 0; i < nsamples; ++i) {
        const float input = (inL[i] + inR[i]) * gain;

        float outSampleL = 0.0f;
        float outSampleR = 0.0f;

        for (int j = 0; j < kNumCombs; ++j) {
            outSampleL += combL[j].process(input);
            outSampleR += combR[j].process(input);
        }

        for (int j = 0; j < kNumAllpasses; ++j) {
            outSampleL = allpassL[j].process(outSampleL);
            outSampleR = allpassR[j].process(outSampleR);
        }

        outL[i] = outSampleL * wet1 + outSampleR * wet2 + inL[i] * dry;
        outR[i] = outSampleR * wet1 + outSampleL * wet2 + inR[i] * dry;
    }
}

void revmodel::setroomsize(float value) {
    roomsize = std::clamp(value, 0.0f, 1.0f);
    update();
}

void revmodel::setdamp(float value) {
    damp = std::clamp(value, 0.0f, 1.0f);
    update();
}

void revmodel::setwet(float value) {
    wet = std::clamp(value, 0.0f, 1.0f) * kScaleWet;
    update();
}

void revmodel::setdry(float value) {
    dry = std::clamp(value, 0.0f, 1.0f) * kScaleDry;
}

void revmodel::setwidth(float value) {
    width = std::clamp(value, 0.0f, 1.0f);
    update();
}

void revmodel::setmode(float value) {
    mode = std::clamp(value, 0.0f, 1.0f);
    update();
}

void revmodel::update() {
    wet1 = wet * (width * 0.5f + 0.5f);
    wet2 = wet * ((1.0f - width) * 0.5f);

    float roomsize1;
    float damp1;

    if (mode >= kFreezeMode) {
        roomsize1 = 1.0f;
        damp1 = 0.0f;
        gain = 0.0f;
    } else {
        roomsize1 = roomsize * kScaleRoom + kOffsetRoom;
        damp1 = damp * kScaleDamp;
        gain = kFixedGain;
    }

    for (int i = 0; i < kNumCombs; ++i) {
        combL[i].setfeedback(roomsize1);
        combR[i].setfeedback(roomsize1);
        combL[i].setdamp(damp1);
        combR[i].setdamp(damp1);
    }
}

} // namespace freeverb
