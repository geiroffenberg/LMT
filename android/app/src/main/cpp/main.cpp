#include <SDL2/SDL.h>
#include <iostream>
#include "renderer/renderer.h"
#include "ui/window_manager.h"

int main(int argc, char* argv[]) {
    // Initialize SDL
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS) != 0) {
        std::cerr << "SDL_Init failed: " << SDL_GetError() << std::endl;
        return 1;
    }
    
    // Create renderer and window manager
    // For now, we'll let the renderer find a system monospace font
    // Later, we can pass the Perfect DOS VGA 437 font path here
    Renderer renderer(800, 1200);
    if (!renderer.init()) {
        std::cerr << "Renderer initialization failed" << std::endl;
        SDL_Quit();
        return 1;
    }
    
    WindowManager windowManager;
    windowManager.init();
    
    // Main loop
    bool running = true;
    SDL_Event event;
    
    while (running) {
        while (SDL_PollEvent(&event)) {
            if (event.type == SDL_QUIT) {
                running = false;
            } else if (event.type == SDL_KEYDOWN) {
                if (event.key.keysym.sym == SDLK_ESCAPE) {
                    running = false;
                }
            }
            windowManager.handleInput(event);
        }
        
        windowManager.update();
        windowManager.render(renderer);
        
        // Cap at 60 FPS
        SDL_Delay(16);
    }
    
    renderer.shutdown();
    SDL_Quit();
    
    return 0;
}
