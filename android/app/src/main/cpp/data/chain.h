#pragma once

#include <array>
#include <memory>
#include <string>

class Phrase;  // forward declaration

// One item in a chain (references a phrase)
struct ChainItem {
    std::shared_ptr<Phrase> phrase;  // nullptr = empty
};

// A chain: 99 items
struct Chain {
    std::string id;
    std::array<ChainItem, 99> items;
    int transpose = 0;  // -12 to +12 semitones
    
    Chain() {
        static int nextId = 0;
        id = "CH" + std::to_string(nextId++);
    }
};
