# LMT (Little Moby Tracker) - C++ Implementation

A minimalist grid-based music tracker inspired by Little Piggy Tracker and Dirtywave M8, built with SDL2 and C++ for Android phones.

## Architecture

### Windows
- **S (Song):** 99 rows × 8 tracks, each cell references a Chain
- **C (Chain):** 01-99 chain items, each references a Phrase, with transpose control
- **P (Phrase):** 01-99 steps, each with instrument, volume, and 3 FX slots
- **I (Instrument):** 99 sample slots with filter, EQ, and effect sends
- **M (Mixer):** 8 channels with volume faders, level meters, and master FX

### Navigation
- Top bar always visible: `S C P I M` (current window in green)
- Tap window letter to jump
- Right side: BPM display
- Song window: PROJECT button for load/save/export

### Data Model
```
Song
  ├── 99 rows × 8 tracks (grid of references to Chains)
  ├── 8 TrackMixer (per-channel volume, sends)
  └── MasterFX (EQ, compressor, limiter)

Chain
  ├── 99 items (each references a Phrase)
  └── Transpose (-12 to +12 semitones)

Phrase
  └── 99 steps (each has: instrument, volume, 3× FX)

Instrument
  └── 99 sample slots (each with: sample, filter, EQ, sends)

Sample
  └── Mono audio data + metadata
```

## Project Structure

```
lmt/
├── android/
│   └── app/
│       ├── src/main/cpp/
│       │   ├── CMakeLists.txt       (build config, links SDL2 + SDL2_ttf)
│       │   ├── main.cpp             (SDL2 entry point)
│       │   ├── renderer/
│       │   │   ├── renderer.h       (grid drawing, text rendering)
│       │   │   └── renderer.cpp     (SDL_ttf integration)
│       │   ├── ui/
│       │   │   ├── window_manager.h (window navigation)
│       │   │   └── window_manager.cpp
│       │   ├── data/
│       │   │   ├── song.h           (Song, TrackMixer, MasterFX structs)
│       │   │   ├── chain.h          (Chain, ChainItem)
│       │   │   ├── phrase.h         (Phrase, PhraseStep, FXSlot)
│       │   │   ├── instrument.h     (Instrument, InstrumentSlot)
│       │   │   └── sample.h         (Sample)
│       │   └── audio/
│       │       └── audio_engine.h   (Oboe integration — placeholder)
│       └── src/main/assets/
│           └── fonts/
│               └── perfect_dos_vga_437.ttf  (tracker font)
├── FONT_SETUP.md
├── README_CPP.md
└── lib/
    └── main.dart            (minimal Flutter surface)
```

## Build Instructions

### Desktop (Linux/macOS - for testing)

**Prerequisites:**
```bash
# Ubuntu/Debian
sudo apt-get install libsdl2-dev libsdl2-ttf-dev

# macOS
brew install sdl2 sdl2_ttf

# Arch
sudo pacman -S sdl2 sdl2_ttf
```

**Compile:**
```bash
cd android/app/src/main/cpp
mkdir build && cd build
cmake ..
make
./lmt
```

### Android

```bash
flutter build apk --release
```

(Gradle will automatically compile the C++ code via CMake)

## Dependencies

- **SDL2:** Graphics, input, window management
- **SDL2_ttf:** Font rendering (for Perfect DOS VGA 437)
- **Oboe:** Low-latency audio (added later)
- **C++17:** Standard library features

## Font Setup

See [FONT_SETUP.md](FONT_SETUP.md) for instructions on including Perfect DOS VGA 437.

Key points:
- Download Perfect DOS VGA 437 TTF from FontSpace or similar
- Place in `android/app/src/main/assets/fonts/`
- Renderer will fallback to system monospace fonts if not found
- Text automatically converted to UPPERCASE for tracker aesthetic

## Development Status

### Phase 1: SDL2 Scaffold ✅
- [x] CMakeLists.txt configured with SDL2 + SDL2_ttf
- [x] SDL2 window and event loop
- [x] Data structures (Song, Chain, Phrase, Instrument, Sample)
- [x] WindowManager skeleton
- [x] Renderer with SDL_ttf integration

### Phase 2: Font & Navigation Bar ✅
- [x] SDL_ttf text rendering setup
- [x] Perfect DOS VGA 437 integration
- [x] Automatic uppercase conversion
- [x] Navigation bar rendering (S C P I M with highlighting)
- [x] BPM display on right side of nav bar
- [x] Keyboard input for window switching (LEFT/RIGHT arrows)

### Phase 3: Window Navigation & Stubs (IN PROGRESS)
- [x] Window switching logic
- [ ] Proper grid cell layout
- [ ] Touch/mouse input handling
- [ ] Placeholder content for each window

### Phase 4: Grid Rendering & Cell Editing ✅
- [x] Song view: 99×8 grid with chain references
- [x] Chain view: 01-99 list with transpose
- [x] Phrase view: 01-99 steps with IN/VOL/FX
- [x] Instrument view: 99 slots with parameters
- [x] Mixer view: 8 channels with levels and sends
- [x] Cell highlighting and cursor management
- [x] **Number input for cell editing (Song window)**
- [x] Edit mode with RETURN/ESC controls
- [x] Mouse click to select and edit cells
- [x] Input validation (01-99 range)

### Phase 5: Data Persistence (TODO)
- [ ] JSON serialization/deserialization
- [ ] Save/load project files
- [ ] Sample file I/O (WAV loading)

### Phase 6: Audio (Post-UI)
- [ ] Oboe stream setup
- [ ] Voice playback
- [ ] Sample loading and playback
- [ ] Level meter integration

## Notes

- All lists are numbered **01-99** (decimal), not hex
- Numbers are pre-allocated to save memory
- Sparse data model: Chains/Phrases created on-demand
- UI-first approach: All UI and data structures before audio integration
