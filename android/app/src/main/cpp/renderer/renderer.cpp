#include "renderer.h"
#include <iostream>
#include <cctype>

Renderer::Renderer(int width, int height, const std::string& fontPath_) 
    : screenWidth(width), screenHeight(height), fontPath(fontPath_) {}

Renderer::~Renderer() {
    shutdown();
}

bool Renderer::init() {
    window = SDL_CreateWindow(
        "LMT - Little Moby Tracker",
        SDL_WINDOWPOS_CENTERED,
        SDL_WINDOWPOS_CENTERED,
        screenWidth, screenHeight,
        SDL_WINDOW_SHOWN
    );
    
    if (!window) {
        std::cerr << "Failed to create SDL window: " << SDL_GetError() << std::endl;
        return false;
    }
    
    renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
    
    if (!renderer) {
        std::cerr << "Failed to create SDL renderer: " << SDL_GetError() << std::endl;
        SDL_DestroyWindow(window);
        window = nullptr;
        return false;
    }
    
    // Initialize SDL_ttf
    if (TTF_Init() == -1) {
        std::cerr << "Failed to initialize SDL_ttf: " << TTF_GetError() << std::endl;
        SDL_DestroyRenderer(renderer);
        SDL_DestroyWindow(window);
        renderer = nullptr;
        window = nullptr;
        return false;
    }
    
    // Try to load font — if path is empty or fails, we'll use a default
    if (!fontPath.empty()) {
        font = TTF_OpenFont(fontPath.c_str(), 14);
        if (!font) {
            std::cerr << "Warning: Could not load font from " << fontPath 
                      << ": " << TTF_GetError() << std::endl;
            std::cerr << "Attempting fallback..." << std::endl;
        }
    }
    
    // If no font was loaded, try common system paths
    if (!font) {
        const char* fontPaths[] = {
            "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
            "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
            "/System/Library/Fonts/Courier.dfont",
            "C:\\Windows\\Fonts\\cour.ttf",
        };
        
        for (const char* path : fontPaths) {
            font = TTF_OpenFont(path, 14);
            if (font) {
                std::cout << "Loaded font from: " << path << std::endl;
                break;
            }
        }
    }
    
    if (!font) {
        std::cerr << "Warning: Could not load any font. Text rendering will be disabled." << std::endl;
    }
    
    return true;
}

void Renderer::clear() {
    SDL_SetRenderDrawColor(renderer, colorBg.r, colorBg.g, colorBg.b, colorBg.a);
    SDL_RenderClear(renderer);
}

void Renderer::present() {
    SDL_RenderPresent(renderer);
}

void Renderer::drawText(int x, int y, const std::string& text, bool highlight, int fontSize) {
    if (!font) return;
    
    // Convert text to uppercase
    std::string upperText = text;
    for (char& c : upperText) {
        c = std::toupper(static_cast<unsigned char>(c));
    }
    
    SDL_Color color = highlight ? colorHighlight : colorText;
    SDL_Surface* textSurface = TTF_RenderText_Solid(font, upperText.c_str(), color);
    
    if (!textSurface) {
        std::cerr << "Failed to render text: " << TTF_GetError() << std::endl;
        return;
    }
    
    SDL_Texture* textTexture = SDL_CreateTextureFromSurface(renderer, textSurface);
    SDL_FreeSurface(textSurface);
    
    if (!textTexture) {
        std::cerr << "Failed to create text texture: " << SDL_GetError() << std::endl;
        return;
    }
    
    SDL_Rect dstRect = {x, y, 0, 0};
    SDL_QueryTexture(textTexture, nullptr, nullptr, &dstRect.w, &dstRect.h);
    SDL_RenderCopy(renderer, textTexture, nullptr, &dstRect);
    SDL_DestroyTexture(textTexture);
}

void Renderer::drawRect(int x, int y, int w, int h, bool filled) {
    SDL_Rect rect = {x, y, w, h};
    SDL_SetRenderDrawColor(renderer, colorText.r, colorText.g, colorText.b, colorText.a);
    
    if (filled) {
        SDL_RenderFillRect(renderer, &rect);
    } else {
        SDL_RenderDrawRect(renderer, &rect);
    }
}

void Renderer::drawCell(int x, int y, int w, int h, const std::string& text, bool highlighted) {
    // Draw cell border
    SDL_SetRenderDrawColor(renderer, colorText.r, colorText.g, colorText.b, colorText.a);
    SDL_Rect rect = {x, y, w, h};
    SDL_RenderDrawRect(renderer, &rect);
    
    // Draw background if highlighted
    if (highlighted) {
        SDL_SetRenderDrawColor(renderer, colorHighlight.r, colorHighlight.g, colorHighlight.b, 40);
        SDL_RenderFillRect(renderer, &rect);
    }
    
    // Draw text centered in cell
    drawText(x + 4, y + 4, text, highlighted, 12);
}

void Renderer::shutdown() {
    if (font) {
        TTF_CloseFont(font);
        font = nullptr;
    }
    TTF_Quit();
    if (renderer) {
        SDL_DestroyRenderer(renderer);
        renderer = nullptr;
    }
    if (window) {
        SDL_DestroyWindow(window);
        window = nullptr;
    }
}
