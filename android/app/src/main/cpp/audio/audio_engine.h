#pragma once

// Audio engine skeleton — to be filled with Oboe integration later

class AudioEngine {
public:
    AudioEngine() = default;
    ~AudioEngine() = default;
    
    void initialize() {}
    void start() {}
    void stop() {}
    void setTempo(float bpm) {}
    
private:
    // Will contain Oboe stream and Voice management later
};
