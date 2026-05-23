#pragma once

#include <array>
#include <memory>
#include "sample.h"

struct InstrumentParams {
    float filterCutoff = 0.7f;    // 0..1
    float filterResonance = 0.2f; // 0..1
    float eqTreble = 0.0f;        // -12..+12 dB
    float eqMids = 0.0f;          // -12..+12 dB
    float eqBass = 0.0f;          // -12..+12 dB
    int reverbSend = 0;           // 0-99
    int delaySend = 0;            // 0-99
    int chorusSend = 0;           // 0-99
};

struct InstrumentSlot {
    int number;  // 1-99
    std::shared_ptr<Sample> sample;
    InstrumentParams params;
    bool loaded = false;
    
    InstrumentSlot(int n) : number(n) {}
};

// Instrument: 99 sample slots
struct Instrument {
    std::array<InstrumentSlot, 99> slots{
        InstrumentSlot(1), InstrumentSlot(2), InstrumentSlot(3),
        InstrumentSlot(4), InstrumentSlot(5), InstrumentSlot(6),
        InstrumentSlot(7), InstrumentSlot(8), InstrumentSlot(9),
        InstrumentSlot(10), InstrumentSlot(11), InstrumentSlot(12),
        InstrumentSlot(13), InstrumentSlot(14), InstrumentSlot(15),
        InstrumentSlot(16), InstrumentSlot(17), InstrumentSlot(18),
        InstrumentSlot(19), InstrumentSlot(20), InstrumentSlot(21),
        InstrumentSlot(22), InstrumentSlot(23), InstrumentSlot(24),
        InstrumentSlot(25), InstrumentSlot(26), InstrumentSlot(27),
        InstrumentSlot(28), InstrumentSlot(29), InstrumentSlot(30),
        InstrumentSlot(31), InstrumentSlot(32), InstrumentSlot(33),
        InstrumentSlot(34), InstrumentSlot(35), InstrumentSlot(36),
        InstrumentSlot(37), InstrumentSlot(38), InstrumentSlot(39),
        InstrumentSlot(40), InstrumentSlot(41), InstrumentSlot(42),
        InstrumentSlot(43), InstrumentSlot(44), InstrumentSlot(45),
        InstrumentSlot(46), InstrumentSlot(47), InstrumentSlot(48),
        InstrumentSlot(49), InstrumentSlot(50), InstrumentSlot(51),
        InstrumentSlot(52), InstrumentSlot(53), InstrumentSlot(54),
        InstrumentSlot(55), InstrumentSlot(56), InstrumentSlot(57),
        InstrumentSlot(58), InstrumentSlot(59), InstrumentSlot(60),
        InstrumentSlot(61), InstrumentSlot(62), InstrumentSlot(63),
        InstrumentSlot(64), InstrumentSlot(65), InstrumentSlot(66),
        InstrumentSlot(67), InstrumentSlot(68), InstrumentSlot(69),
        InstrumentSlot(70), InstrumentSlot(71), InstrumentSlot(72),
        InstrumentSlot(73), InstrumentSlot(74), InstrumentSlot(75),
        InstrumentSlot(76), InstrumentSlot(77), InstrumentSlot(78),
        InstrumentSlot(79), InstrumentSlot(80), InstrumentSlot(81),
        InstrumentSlot(82), InstrumentSlot(83), InstrumentSlot(84),
        InstrumentSlot(85), InstrumentSlot(86), InstrumentSlot(87),
        InstrumentSlot(88), InstrumentSlot(89), InstrumentSlot(90),
        InstrumentSlot(91), InstrumentSlot(92), InstrumentSlot(93),
        InstrumentSlot(94), InstrumentSlot(95), InstrumentSlot(96),
        InstrumentSlot(97), InstrumentSlot(98), InstrumentSlot(99)
    };
};
