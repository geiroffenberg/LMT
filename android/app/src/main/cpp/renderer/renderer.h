#pragma once

#include <SDL2/SDL.h>
#include <SDL2/SDL_ttf.h>
#include <string>
#include <memory>

class Renderer {
public:
    Renderer(int width, int height, const std::string& fontPath = "");
    ~Renderer();
    
    bool init();
    void clear();
    void present();
    void drawText(int x, int y, const std::string& text, bool highlight = false, int fontSize = 16);
    void drawRect(int x, int y, int w, int h, bool filled = false);
    void drawCell(int x, int y, int w, int h, const std::string& text, bool highlighted = false);
    void shutdown();
    
    // Getters
    int getWidth() const { return screenWidth; }
    int getHeight() const { return screenHeight; }
    
private:
    SDL_Window* window = nullptr;
    SDL_Renderer* renderer = nullptr;
    TTF_Font* font = nullptr;
    int screenWidth, screenHeight;
    std::string fontPath;
    
    SDL_Color colorBg = {20, 20, 20, 255};        // dark bg
    SDL_Color colorText = {200, 200, 200, 255};   // light gray text
    SDL_Color colorHighlight = {0, 255, 0, 255}; // green for highlights
    SDL_Color colorRed = {255, 0, 0, 255};        // red for alerts
};
