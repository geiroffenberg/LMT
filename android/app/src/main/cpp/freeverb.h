// Freeverb implementation (public domain)
// Converted to C++ header by Schism Tracker authors
// Original algorithm by Jezar at Dreampoint.

#ifndef FREEVERB_H
#define FREEVERB_H

#include <cmath>

namespace freeverb {

static constexpr int kNumCombs = 8;
static constexpr int kNumAllpasses = 4;

// Comb filter
class comb {
public:
    comb() = default;

    void setbuffer(float *buf, int sz) {
        buffer = buf;
        size = sz;
        index = 0;
    }

    inline float process(float inp) {
        if (!buffer || size <= 0) return 0.0f;
        float bufout = buffer[index];
        filterstore = (bufout * damp2) + (filterstore * damp1);
        buffer[index] = inp + (filterstore * feedback);
        if (++index >= size) index = 0;
        return bufout;
    }

    void setdamp(float val) {
        damp1 = val;
        damp2 = 1.0f - val;
    }

    void setfeedback(float val) {
        feedback = val;
    }

    void mute();

    float getfeedback() const {
        return feedback;
    }

private:
    float filterstore = 0.0f;
    float damp1 = 0.0f;
    float damp2 = 0.0f;
    float feedback = 0.5f;
    float *buffer = nullptr;
    int index = 0;
    int size = 0;
};

// Allpass filter
class allpass {
public:
    allpass() = default;

    void setbuffer(float *buf, int sz) {
        buffer = buf;
        size = sz;
        index = 0;
    }

    inline float process(float inp) {
        if (!buffer || size <= 0) return inp;
        float bufout = buffer[index];
        float output = -inp + bufout;
        buffer[index] = inp + (bufout * feedback);
        if (++index >= size) index = 0;
        return output;
    }

    void setfeedback(float val) {
        feedback = val;
    }

    void mute();

    float getfeedback() const {
        return feedback;
    }

private:
    float feedback = 0.5f;
    float *buffer = nullptr;
    int index = 0;
    int size = 0;
};

// Main reverb processor
class revmodel {
public:
    revmodel();
    ~revmodel();

    void mute();
    void process(const float *inL, const float *inR, float *outL, float *outR, int nsamples);

    void setroomsize(float value);
    float getroomsize() const { return roomsize; }

    void setdamp(float value);
    float getdamp() const { return damp; }

    void setwet(float value);
    float getwet() const { return wet; }

    void setdry(float value);
    float getdry() const { return dry; }

    void setwidth(float value);
    float getwidth() const { return width; }

    void setmode(float value);
    float getmode() const { return mode; }

private:
    void update();

    float roomsize = 0.5f;
    float damp = 0.5f;
    float wet = 0.3f;
    float dry = 0.7f;
    float width = 1.0f;
    float mode = 0.0f;
    float gain = 0.015f;
    float wet1 = 0.0f;
    float wet2 = 0.0f;

    comb combL[kNumCombs], combR[kNumCombs];
    allpass allpassL[kNumAllpasses], allpassR[kNumAllpasses];

    float bufcombL1[1116];
    float bufcombR1[1139];
    float bufcombL2[1188];
    float bufcombR2[1211];
    float bufcombL3[1277];
    float bufcombR3[1300];
    float bufcombL4[1356];
    float bufcombR4[1379];
    float bufcombL5[1422];
    float bufcombR5[1445];
    float bufcombL6[1491];
    float bufcombR6[1514];
    float bufcombL7[1557];
    float bufcombR7[1580];
    float bufcombL8[1617];
    float bufcombR8[1640];

    float bufallpassL1[556];
    float bufallpassR1[579];
    float bufallpassL2[441];
    float bufallpassR2[464];
    float bufallpassL3[341];
    float bufallpassR3[364];
    float bufallpassL4[225];
    float bufallpassR4[248];
};

} // namespace freeverb

#endif // FREEVERB_H
