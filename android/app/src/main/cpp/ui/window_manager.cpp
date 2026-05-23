#include "window_manager.h"
#include "renderer/renderer.h"
#include <SDL2/SDL.h>
#include <iomanip>
#include <sstream>

WindowManager::WindowManager() {
    song.name = "New Song";
    song.bpm = 120;
}

void WindowManager::init() {
    // Initialize windows if needed
}

void WindowManager::handleInput(const SDL_Event& event) {
    // Menu mode input handling (for FX selection)
    if (menuMode) {
        switch (event.type) {
            case SDL_KEYDOWN:
                if (event.key.keysym.sym == SDLK_RETURN) {
                    // Confirm FX selection
                    applyMenuSelection();
                    menuMode = false;
                    menuCursor = 0;
                } else if (event.key.keysym.sym == SDLK_ESCAPE) {
                    // Cancel menu
                    menuMode = false;
                    menuCursor = 0;
                } else if (event.key.keysym.sym == SDLK_UP) {
                    if (menuCursor > 0) menuCursor--;
                } else if (event.key.keysym.sym == SDLK_DOWN) {
                    if (menuCursor < static_cast<int>(fxList.size()) - 1) menuCursor++;
                }
                break;
        }
        return;  // Don't process other input while in menu
    }
    
    // Edit mode input handling
    if (editMode) {
        switch (event.type) {
            case SDL_KEYDOWN:
                if (event.key.keysym.sym == SDLK_RETURN) {
                    // Confirm edit
                    applyEdit();
                    editMode = false;
                    editBuffer.clear();
                } else if (event.key.keysym.sym == SDLK_ESCAPE) {
                    // Cancel edit
                    editMode = false;
                    editBuffer.clear();
                } else if (event.key.keysym.sym == SDLK_BACKSPACE) {
                    if (!editBuffer.empty()) {
                        editBuffer.pop_back();
                    }
                } else if (event.key.keysym.sym >= SDLK_0 && event.key.keysym.sym <= SDLK_9) {
                    // Only allow up to editMaxChars digits
                    if (editBuffer.length() < static_cast<size_t>(editMaxChars)) {
                        editBuffer += static_cast<char>('0' + (event.key.keysym.sym - SDLK_0));
                    }
                }
                break;
        }
        return;  // Don't process other input while editing
    }
    
    // Normal navigation input
    switch (event.type) {
        case SDL_KEYDOWN:
            switch (event.key.keysym.sym) {
                case SDLK_RIGHT:
                    nextWindow();
                    break;
                case SDLK_LEFT:
                    prevWindow();
                    break;
                case SDLK_UP:
                    if (cursorRow > 0) {
                        cursorRow--;
                        scrollToShowCursor();
                    }
                    break;
                case SDLK_DOWN:
                    cursorRow++;
                    scrollToShowCursor();
                    break;
                case SDLK_TAB:
                    if (event.key.keysym.mod & KMOD_SHIFT) {
                        if (cursorCol > 0) cursorCol--;
                    } else {
                        cursorCol++;
                    }
                    break;
                case SDLK_RETURN:
                    // Enter edit or menu mode on RETURN key
                    enterEditOrMenuMode();
                    break;
                default:
                    break;
            }
            break;
        case SDL_MOUSEBUTTONDOWN:
            // Handle touch/mouse click to enter edit mode
            handleMouseClick(event.button.x, event.button.y);
            break;
    }
}

void WindowManager::update() {
    // Update current window state
}

void WindowManager::render(Renderer& renderer) {
    renderer.clear();
    
    // Draw navigation bar at top
    int navY = 10;
    int navX = 20;
    int windowWidth = renderer.getWidth();
    
    for (int i = 0; i < 5; i++) {
        const char* name = windowNames[i];
        bool highlighted = (i == static_cast<int>(currentWindow));
        renderer.drawText(navX, navY, name, highlighted, 18);
        navX += 40;
    }
    
    // Draw BPM on right side of nav
    std::ostringstream bpmStr;
    bpmStr << "BPM: " << song.bpm;
    renderer.drawText(windowWidth - 140, navY, bpmStr.str(), false, 14);
    
    // Draw current window content
    switch (currentWindow) {
        case WindowType::Song:
            renderSongWindow(renderer);
            break;
        case WindowType::Chain:
            renderChainWindow(renderer);
            break;
        case WindowType::Phrase:
            renderPhraseWindow(renderer);
            break;
        case WindowType::Instrument:
            renderInstrumentWindow(renderer);
            break;
        case WindowType::Mixer:
            renderMixerWindow(renderer);
            break;
    }
    
    renderer.present();
}

void WindowManager::drawGridCell(Renderer& renderer, int x, int y, const std::string& text, bool isCursor) {
    renderer.drawCell(x, y, CELL_WIDTH, CELL_HEIGHT, text, isCursor);
}

void WindowManager::scrollToShowCursor() {
    int visibleRows = 20;
    if (cursorRow < scrollRow) {
        scrollRow = cursorRow;
    } else if (cursorRow >= scrollRow + visibleRows) {
        scrollRow = cursorRow - visibleRows + 1;
    }
}

void WindowManager::enterEditMode() {
    editMode = true;
    editBuffer.clear();
    editMaxChars = 2;  // 01-99 or 00-99 = 2 digits
}

void WindowManager::enterEditOrMenuMode() {
    if (currentWindow == WindowType::Song && cursorCol < 8) {
        // Song: edit chain references
        enterEditMode();
    } else if (currentWindow == WindowType::Chain) {
        // Chain: edit phrase references or transpose
        enterEditMode();
    } else if (currentWindow == WindowType::Phrase) {
        // Phrase: depends on column
        // Columns: STEP | IN | VOL | FX1 | VAL | FX2 | VAL | FX3 | VAL
        int col = cursorCol;
        if (col == 0) {
            // STEP number - read-only, do nothing
            return;
        } else if (col == 1 || col == 3 || col == 5 || col == 7) {
            // FX names - show menu
            menuMode = true;
            menuCursor = 0;
        } else {
            // IN, VOL, FX values - numeric edit
            enterEditMode();
        }
    } else if (currentWindow == WindowType::Instrument) {
        // Instrument: edit parameters
        // Columns: SLOT | LOAD | EDIT | REC | FILT | RES | TREB | MID | BASS | RVB | DLY | CHO
        int col = cursorCol;
        if (col == 0 || col == 1 || col == 2 || col == 3) {
            // Slot number and buttons - skip
            return;
        } else {
            // Filter, EQ, Sends - numeric edit
            editMaxChars = 2;
            enterEditMode();
        }
    } else if (currentWindow == WindowType::Mixer) {
        // Mixer: edit volume and sends
        enterEditMode();
    }
}

void WindowManager::applyMenuSelection() {
    if (currentWindow != WindowType::Phrase) return;
    if (menuCursor >= static_cast<int>(fxList.size())) return;
    
    // For now, just store the selection
    // TODO: integrate with actual phrase data structure
    // The FX names will be applied when we connect the data model
}

void WindowManager::applyEdit() {
    if (editBuffer.empty()) return;
    
    if (currentWindow == WindowType::Song) {
        // Parse chain number (01-99)
        int chainNum = std::stoi(editBuffer);
        if (chainNum < 1 || chainNum > 99) return;
        
        std::ostringstream chainId;
        chainId << "CH" << std::setfill('0') << std::setw(2) << chainNum;
        song.grid[cursorRow][cursorCol].chain = std::make_shared<Chain>();
        song.grid[cursorRow][cursorCol].chain->id = chainId.str();
        
    } else if (currentWindow == WindowType::Chain) {
        // Chain editing - for now just validate
        int value = std::stoi(editBuffer);
        if (cursorCol == 1) {
            // Phrase reference (01-99)
            if (value < 1 || value > 99) return;
        } else if (cursorCol == 2) {
            // Transpose (-12 to +12) - but user enters 0-99 mapped to -12..+12
            // For simplicity, just accept 0-99 for now
            if (value < 0 || value > 99) return;
        }
    } else if (currentWindow == WindowType::Phrase) {
        // Phrase editing
        int value = std::stoi(editBuffer);
        int col = cursorCol;
        
        if (col == 1) {
            // IN (instrument 01-99)
            if (value < 1 || value > 99) return;
        } else if (col == 2 || col == 4 || col == 6 || col == 8) {
            // VOL or FX values (00-99)
            if (value < 0 || value > 99) return;
        }
    }
}

void WindowManager::handleMouseClick(int x, int y) {
    if (currentWindow != WindowType::Song) return;
    
    int contentX = CONTENT_START_X;
    int contentY = CONTENT_START_Y;
    
    // Check if click is on a cell in the grid
    for (int row = scrollRow; row < scrollRow + 16 && row < 99; row++) {
        for (int col = 0; col < 8; col++) {
            int cellX = contentX + col * (CELL_WIDTH + 2);
            int cellY = contentY + (row - scrollRow) * CELL_HEIGHT;
            
            // Check if click is within cell bounds
            if (x >= cellX && x < cellX + CELL_WIDTH &&
                y >= cellY && y < cellY + CELL_HEIGHT) {
                
                // Move cursor to this cell and enter edit mode
                cursorRow = row;
                cursorCol = col;
                enterEditMode();
                return;
            }
        }
    }
}

// ============================================================================
// SONG WINDOW: 99 rows × 8 tracks
// ============================================================================
void WindowManager::renderSongWindow(Renderer& renderer) {
    int x = CONTENT_START_X;
    int y = CONTENT_START_Y;
    
    int visibleRows = 16;
    int trackCols = 8;
    
    for (int row = scrollRow; row < scrollRow + visibleRows && row < 99; row++) {
        // Row number (2-digit)
        std::ostringstream rowNum;
        rowNum << std::setfill('0') << std::setw(2) << (row + 1);
        renderer.drawText(x - 20, y + (row - scrollRow) * CELL_HEIGHT, rowNum.str(), false, 12);
        
        // 8 track cells
        for (int col = 0; col < trackCols; col++) {
            bool isCursor = (cursorRow == row && cursorCol == col);
            
            // Show edit buffer if in edit mode and this is the cursor cell
            std::string cellText;
            if (editMode && isCursor) {
                cellText = editBuffer.empty() ? "|" : editBuffer + "|";
            } else {
                cellText = "--";
                if (song.grid[row][col].chain) {
                    cellText = song.grid[row][col].chain->id.substr(2);  // show just the number
                }
            }
            
            int cellX = x + col * (CELL_WIDTH + 2);
            int cellY = y + (row - scrollRow) * CELL_HEIGHT;
            
            drawGridCell(renderer, cellX, cellY, cellText, isCursor);
        }
    }
    
    // Draw edit mode indicator
    if (editMode) {
        renderer.drawText(x, y + visibleRows * CELL_HEIGHT + 10, "EDIT MODE (ENTER to confirm, ESC to cancel)", false, 10);
    }
}

// ============================================================================
// CHAIN WINDOW: 01-99 items with transpose
// ============================================================================
void WindowManager::renderChainWindow(Renderer& renderer) {
    int x = CONTENT_START_X;
    int y = CONTENT_START_Y;
    
    renderer.drawText(x, y - 25, "NUM  PHRASE  TRANSPOSE", false, 12);
    
    int visibleRows = 20;
    
    for (int i = scrollRow; i < scrollRow + visibleRows && i < 99; i++) {
        bool isCursor = (cursorRow == i);
        int rowY = y + (i - scrollRow) * CELL_HEIGHT;
        
        std::ostringstream itemNum;
        itemNum << std::setfill('0') << std::setw(2) << (i + 1);
        renderer.drawText(x, rowY, itemNum.str(), isCursor && cursorCol == 0, 14);
        
        // Phrase reference (01-99)
        std::string phraseRef = "--";
        if (editMode && isCursor && cursorCol == 1) {
            phraseRef = editBuffer.empty() ? "|" : editBuffer + "|";
        }
        renderer.drawText(x + 80, rowY, phraseRef, isCursor && cursorCol == 1, 14);
        
        // Transpose value
        std::string transposeVal = "00";
        if (editMode && isCursor && cursorCol == 2) {
            transposeVal = editBuffer.empty() ? "|" : editBuffer + "|";
        }
        renderer.drawText(x + 160, rowY, transposeVal, isCursor && cursorCol == 2, 14);
    }
    
    if (editMode) {
        renderer.drawText(x, y + visibleRows * CELL_HEIGHT + 10, 
                         "EDIT MODE (ENTER to confirm, ESC to cancel)", false, 10);
    }
}

// ============================================================================
// PHRASE WINDOW: 01-99 steps with IN, VOL, FX
// ============================================================================
void WindowManager::renderPhraseWindow(Renderer& renderer) {
    int x = CONTENT_START_X;
    int y = CONTENT_START_Y;
    
    renderer.drawText(x, y - 25, "STEP IN  VOL FX1 VAL FX2 VAL FX3 VAL", false, 10);
    
    int visibleRows = 20;
    
    for (int i = scrollRow; i < scrollRow + visibleRows && i < 99; i++) {
        bool isCursor = (cursorRow == i);
        int rowY = y + (i - scrollRow) * CELL_HEIGHT;
        int colX = x;
        
        std::ostringstream stepNum;
        stepNum << std::setfill('0') << std::setw(2) << (i + 1);
        renderer.drawText(colX, rowY, stepNum.str(), isCursor && cursorCol == 0, 11);
        colX += 50;
        
        // IN (instrument) - numeric edit
        std::string inText = "01";
        if (editMode && isCursor && cursorCol == 1) {
            inText = editBuffer.empty() ? "|" : editBuffer + "|";
        }
        renderer.drawText(colX, rowY, inText, isCursor && cursorCol == 1, 11);
        colX += 40;
        
        // VOL - numeric edit
        std::string volText = "99";
        if (editMode && isCursor && cursorCol == 2) {
            volText = editBuffer.empty() ? "|" : editBuffer + "|";
        }
        renderer.drawText(colX, rowY, volText, isCursor && cursorCol == 2, 11);
        colX += 40;
        
        // FX1 name - menu selector
        std::string fx1Text = "---";
        if (menuMode && isCursor && cursorCol == 3) {
            fx1Text = ">>";  // indicator that menu is open
        }
        renderer.drawText(colX, rowY, fx1Text, isCursor && cursorCol == 3, 10);
        colX += 35;
        
        // FX1 value - numeric edit
        std::string fx1ValText = "00";
        if (editMode && isCursor && cursorCol == 4) {
            fx1ValText = editBuffer.empty() ? "|" : editBuffer + "|";
        }
        renderer.drawText(colX, rowY, fx1ValText, isCursor && cursorCol == 4, 11);
        colX += 30;
        
        // FX2 name - menu selector
        std::string fx2Text = "---";
        if (menuMode && isCursor && cursorCol == 5) {
            fx2Text = ">>";
        }
        renderer.drawText(colX, rowY, fx2Text, isCursor && cursorCol == 5, 10);
        colX += 35;
        
        // FX2 value - numeric edit
        std::string fx2ValText = "00";
        if (editMode && isCursor && cursorCol == 6) {
            fx2ValText = editBuffer.empty() ? "|" : editBuffer + "|";
        }
        renderer.drawText(colX, rowY, fx2ValText, isCursor && cursorCol == 6, 11);
        colX += 30;
        
        // FX3 name - menu selector
        std::string fx3Text = "---";
        if (menuMode && isCursor && cursorCol == 7) {
            fx3Text = ">>";
        }
        renderer.drawText(colX, rowY, fx3Text, isCursor && cursorCol == 7, 10);
        colX += 35;
        
        // FX3 value - numeric edit
        std::string fx3ValText = "00";
        if (editMode && isCursor && cursorCol == 8) {
            fx3ValText = editBuffer.empty() ? "|" : editBuffer + "|";
        }
        renderer.drawText(colX, rowY, fx3ValText, isCursor && cursorCol == 8, 11);
    }
    
    // Draw menu if active
    if (menuMode) {
        int menuX = CONTENT_START_X + 150;
        int menuY = CONTENT_START_Y + 100;
        
        renderer.drawText(menuX, menuY - 20, "FX SELECTOR", false, 12);
        
        for (size_t i = 0; i < fxList.size(); i++) {
            bool highlighted = (static_cast<int>(i) == menuCursor);
            int itemY = menuY + static_cast<int>(i) * 20;
            renderer.drawText(menuX, itemY, fxList[i], highlighted, 11);
        }
        
        renderer.drawText(menuX, menuY + static_cast<int>(fxList.size()) * 20 + 10, 
                         "(UP/DOWN to select, ENTER to confirm, ESC to cancel)", false, 9);
    } else if (editMode) {
        // Draw edit mode indicator
        renderer.drawText(x, y + visibleRows * CELL_HEIGHT + 10, 
                         "EDIT MODE (ENTER to confirm, ESC to cancel)", false, 10);
    }
}

// ============================================================================
// INSTRUMENT WINDOW: 99 slots with parameters
// ============================================================================
void WindowManager::renderInstrumentWindow(Renderer& renderer) {
    int x = CONTENT_START_X;
    int y = CONTENT_START_Y;
    
    renderer.drawText(x, y - 25, "SLOT LOAD EDIT REC  FILT RES  TREB MID BASS  RVB DLY CHO", false, 9);
    
    int visibleRows = 16;
    
    for (int i = scrollRow; i < scrollRow + visibleRows && i < 99; i++) {
        bool isCursor = (cursorRow == i);
        int rowY = y + (i - scrollRow) * CELL_HEIGHT;
        int colX = x;
        
        std::ostringstream slotNum;
        slotNum << std::setfill('0') << std::setw(2) << (i + 1);
        renderer.drawText(colX, rowY, slotNum.str(), false, 11);
        colX += 45;
        
        renderer.drawText(colX, rowY, "[LD]", isCursor && cursorCol == 0, 10);
        colX += 45;
        
        renderer.drawText(colX, rowY, "[ED]", isCursor && cursorCol == 1, 10);
        colX += 45;
        
        renderer.drawText(colX, rowY, "[RC]", isCursor && cursorCol == 2, 10);
        colX += 50;
        
        // FILT (editable)
        std::string filt = "70";
        if (editMode && isCursor && cursorCol == 3) {
            filt = editBuffer.empty() ? "|" : editBuffer + "|";
        }
        renderer.drawText(colX, rowY, filt, isCursor && cursorCol == 3, 11);
        colX += 35;
        
        // RES (editable)
        std::string res = "20";
        if (editMode && isCursor && cursorCol == 4) {
            res = editBuffer.empty() ? "|" : editBuffer + "|";
        }
        renderer.drawText(colX, rowY, res, isCursor && cursorCol == 4, 11);
        colX += 40;
        
        // TREB (editable)
        std::string treb = "00";
        if (editMode && isCursor && cursorCol == 5) {
            treb = editBuffer.empty() ? "|" : editBuffer + "|";
        }
        renderer.drawText(colX, rowY, treb, isCursor && cursorCol == 5, 11);
        colX += 35;
        
        // MID (editable)
        std::string mid = "00";
        if (editMode && isCursor && cursorCol == 6) {
            mid = editBuffer.empty() ? "|" : editBuffer + "|";
        }
        renderer.drawText(colX, rowY, mid, isCursor && cursorCol == 6, 11);
        colX += 35;
        
        // BASS (editable)
        std::string bass = "00";
        if (editMode && isCursor && cursorCol == 7) {
            bass = editBuffer.empty() ? "|" : editBuffer + "|";
        }
        renderer.drawText(colX, rowY, bass, isCursor && cursorCol == 7, 11);
        colX += 45;
        
        // RVB (editable)
        std::string rvb = "00";
        if (editMode && isCursor && cursorCol == 8) {
            rvb = editBuffer.empty() ? "|" : editBuffer + "|";
        }
        renderer.drawText(colX, rowY, rvb, isCursor && cursorCol == 8, 11);
        colX += 35;
        
        // DLY (editable)
        std::string dly = "00";
        if (editMode && isCursor && cursorCol == 9) {
            dly = editBuffer.empty() ? "|" : editBuffer + "|";
        }
        renderer.drawText(colX, rowY, dly, isCursor && cursorCol == 9, 11);
        colX += 35;
        
        // CHO (editable)
        std::string cho = "00";
        if (editMode && isCursor && cursorCol == 10) {
            cho = editBuffer.empty() ? "|" : editBuffer + "|";
        }
        renderer.drawText(colX, rowY, cho, isCursor && cursorCol == 10, 11);
    }
    
    if (editMode) {
        renderer.drawText(x, y + visibleRows * CELL_HEIGHT + 10, 
                         "EDIT MODE (ENTER to confirm, ESC to cancel)", false, 10);
    }
}

// ============================================================================
// MIXER WINDOW: 8 channels with volume, sends, master FX
// ============================================================================
void WindowManager::renderMixerWindow(Renderer& renderer) {
    int x = CONTENT_START_X;
    int y = CONTENT_START_Y;
    
    for (int ch = 0; ch < 8; ch++) {
        int chX = x + ch * 90;
        int chY = y + 20;
        
        bool isCursor = (cursorRow == ch);
        
        std::ostringstream chNum;
        chNum << "CH" << (ch + 1);
        renderer.drawText(chX, chY, chNum.str(), false, 12);
        
        renderer.drawText(chX, chY + 30, "LVL", false, 10);
        std::string lvl = "100";
        if (editMode && isCursor && cursorCol == 0) {
            lvl = editBuffer.empty() ? "|" : editBuffer + "|";
        }
        renderer.drawText(chX + 5, chY + 50, lvl, isCursor && cursorCol == 0, 12);
        
        renderer.drawText(chX, chY + 70, "RVB:", false, 9);
        std::string rvb = "00";
        if (editMode && isCursor && cursorCol == 1) {
            rvb = editBuffer.empty() ? "|" : editBuffer + "|";
        }
        renderer.drawText(chX + 35, chY + 70, rvb, isCursor && cursorCol == 1, 11);
        
        renderer.drawText(chX, chY + 85, "DLY:", false, 9);
        std::string dly = "00";
        if (editMode && isCursor && cursorCol == 2) {
            dly = editBuffer.empty() ? "|" : editBuffer + "|";
        }
        renderer.drawText(chX + 35, chY + 85, dly, isCursor && cursorCol == 2, 11);
        
        renderer.drawText(chX, chY + 100, "CHO:", false, 9);
        std::string cho = "00";
        if (editMode && isCursor && cursorCol == 3) {
            cho = editBuffer.empty() ? "|" : editBuffer + "|";
        }
        renderer.drawText(chX + 35, chY + 100, cho, isCursor && cursorCol == 3, 11);
    }
    
    int masterY = y + 140;
    renderer.drawText(x, masterY, "MASTER FX:", false, 12);
    renderer.drawText(x, masterY + 25, "EQ: TREB MID BASS", false, 10);
    renderer.drawText(x, masterY + 40, "+0   +0  +0", false, 11);
    renderer.drawText(x, masterY + 60, "COMP: THRESH RATIO", false, 10);
    renderer.drawText(x, masterY + 75, "80    4.0", false, 11);
    renderer.drawText(x, masterY + 95, "LIMIT: THRESH", false, 10);
    renderer.drawText(x, masterY + 110, "95", false, 11);
    
    if (editMode) {
        renderer.drawText(x, y + 220, 
                         "EDIT MODE (ENTER to confirm, ESC to cancel)", false, 10);
    }
}

void WindowManager::nextWindow() {
    int current = static_cast<int>(currentWindow);
    current = (current + 1) % 5;
    currentWindow = static_cast<WindowType>(current);
    cursorRow = 0;
    cursorCol = 0;
    scrollRow = 0;
}

void WindowManager::prevWindow() {
    int current = static_cast<int>(currentWindow);
    current = (current - 1 + 5) % 5;
    currentWindow = static_cast<WindowType>(current);
    cursorRow = 0;
    cursorCol = 0;
    scrollRow = 0;
}
