#pragma once

#include <memory>
#include "data/song.h"
#include "data/instrument.h"

class Renderer;  // forward declaration

enum class WindowType {
    Song,
    Chain,
    Phrase,
    Instrument,
    Mixer
};

class WindowManager {
public:
    WindowManager();
    
    void init();
    void handleInput(const SDL_Event& event);
    void update();
    void render(Renderer& renderer);
    
    WindowType getCurrentWindow() const { return currentWindow; }
    void switchWindow(WindowType window) { currentWindow = window; cursorRow = 0; cursorCol = 0; }
    void nextWindow();
    void prevWindow();
    
    // Data access
    Song& getSong() { return song; }
    Instrument& getInstrument() { return instrument; }
    
private:
    WindowType currentWindow = WindowType::Song;
    
    // Data model
    Song song;
    Instrument instrument;
    
    // UI state
    int cursorRow = 0;
    int cursorCol = 0;
    int scrollRow = 0;  // for vertical scrolling in large lists
    
    // Edit mode
    bool editMode = false;
    std::string editBuffer;
    int editMaxChars = 2;  // max chars for cell editing
    
    // Menu mode (for FX selection)
    bool menuMode = false;
    std::vector<std::string> fxList = {"---", "ARP", "DEL", "REV", "GLI", "PIT", "VOL", "PAN"};
    int menuCursor = 0;
    
    // Window names for nav bar
    const char* windowNames[5] = {"S", "C", "P", "I", "M"};
    
    // Grid layout constants
    static constexpr int CELL_WIDTH = 40;
    static constexpr int CELL_HEIGHT = 24;
    static constexpr int NAV_HEIGHT = 40;
    static constexpr int CONTENT_START_Y = 50;
    static constexpr int CONTENT_START_X = 20;
    
    // Render methods for each window
    void renderSongWindow(Renderer& renderer);
    void renderChainWindow(Renderer& renderer);
    void renderPhraseWindow(Renderer& renderer);
    void renderInstrumentWindow(Renderer& renderer);
    void renderMixerWindow(Renderer& renderer);
    
    // Helper methods
    void drawGridCell(Renderer& renderer, int x, int y, const std::string& text, bool isCursor);
    void scrollToShowCursor();
    void enterEditMode();
    void enterEditOrMenuMode();  // Determines whether to enter edit or menu mode based on context
    void applyEdit();
    void applyMenuSelection();
    void handleMouseClick(int x, int y);
};
