#pragma once

#include <vector>
#include <string>

struct Sample {
    std::string name;
    std::vector<float> audioData;  // PCM samples, normalized [-1..1]
    int sampleRate = 44100;
    bool loaded = false;
    
    Sample() = default;
    Sample(const std::string& n) : name(n) {}
};
