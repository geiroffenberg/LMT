#pragma once

#include <array>
#include <memory>
#include <string>

class Chain;  // forward declaration

// Master FX parameters
struct MasterFX {
    float eqTreble = 0.0f;       // -12..+12 dB
    float eqMids = 0.0f;         // -12..+12 dB
    float eqBass = 0.0f;         // -12..+12 dB
    float compThreshold = 0.8f;  // 0..1
    float compRatio = 4.0f;      // 1..∞
    float limitThreshold = 0.95f; // 0..1
};

// Per-track mixer state
struct TrackMixer {
    int number;  // 1-8
    float volume = 1.0f;  // 0..1 (linear, 0.0 = silent, 1.0 = 100%)
    int reverbSend = 0;   // 0-99
    int delaySend = 0;    // 0-99
    int chorusSend = 0;   // 0-99
    float peakLevel = 0.0f; // current audio level (0..1), updated by audio engine
    
    TrackMixer(int n) : number(n) {}
};

// One cell in the song grid (99 rows × 8 tracks)
struct SongCell {
    std::shared_ptr<Chain> chain;  // nullptr = empty
};

// A song: 99 rows × 8 tracks
struct Song {
    std::string name = "Untitled";
    int bpm = 120;
    std::array<std::array<SongCell, 8>, 99> grid;  // [row][track]
    std::array<TrackMixer, 8> tracks{
        TrackMixer(1), TrackMixer(2), TrackMixer(3), TrackMixer(4),
        TrackMixer(5), TrackMixer(6), TrackMixer(7), TrackMixer(8)
    };
    MasterFX masterFX;
};
