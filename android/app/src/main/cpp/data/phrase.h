#pragma once

#include <array>
#include <string>

// FX slot: name (3 chars max) + value (0-99)
struct FXSlot {
    std::string name;  // "RVB", "DLY", "CHO", "---" for empty
    int value = 0;     // 0-99
};

// One step in a phrase
struct PhraseStep {
    int instrument = 0;        // 0 = empty, 1-99 = instrument slot
    int volume = 99;           // 0-99 (0 = off, 99 = 100%)
    FXSlot fx[3];              // 3 effects per step
    
    PhraseStep() {
        for (int i = 0; i < 3; i++) {
            fx[i].name = "---";
            fx[i].value = 0;
        }
    }
};

// A phrase: 99 steps
struct Phrase {
    std::string id;                           // unique identifier
    std::array<PhraseStep, 99> steps;
    
    Phrase() {
        static int nextId = 0;
        id = "PH" + std::to_string(nextId++);
    }
};
