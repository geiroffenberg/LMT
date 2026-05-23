# Font Setup for LMT

## Perfect DOS VGA 437

We're using **Perfect DOS VGA 437** for that classic tracker aesthetic.

### Installation

1. **Download the font:**
   - Visit: https://www.fontspace.com/perfect-dos-vga-437-font-family
   - Or search "Perfect DOS VGA 437 TTF" in your favorite font repository

2. **Place the TTF file:**
   ```
   lmt/
   └── android/
       └── app/
           └── src/
               └── main/
                   ├── assets/
                   │   └── fonts/
                   │       └── perfect_dos_vga_437.ttf  ← Place here
   ```

3. **Update the renderer initialization:**
   In `main.cpp`, pass the font path when creating the Renderer:
   ```cpp
   Renderer renderer(800, 1200, "assets/fonts/perfect_dos_vga_437.ttf");
   ```

### Desktop Testing

For Linux/macOS desktop builds, the Renderer will automatically fall back to system monospace fonts if Perfect DOS VGA 437 is not found.

### Android Packaging

When building for Android, SDL2 will access the font from the app's assets folder automatically.

### Font License

Perfect DOS VGA 437 is available under various licenses depending on the source. Check the original source for licensing information.
