# Cell Editing Guide

## Song Window Cell Editing

### How to Edit a Song Cell

1. **Navigate to a cell** using arrow keys (UP/DOWN for rows, TAB for columns)
2. **Enter edit mode** by pressing RETURN or clicking on the cell
3. **Type a chain number** (01-99)
   - Each keystroke adds a digit
   - Backspace removes the last digit
   - Maximum 2 digits
4. **Confirm the edit** by pressing ENTER
   - The cell will now show the chain reference (e.g., "CH01")
5. **Cancel the edit** by pressing ESC
   - The cell returns to its previous value

### Edit Mode Indicator

When editing, a message appears at the bottom: `EDIT MODE (ENTER to confirm, ESC to cancel)`

The active cell shows a cursor: `|` (or the partial number you've typed, e.g., `7|`)

### Supported Input

- **Numbers (0-9):** Add digits to the edit buffer
- **Backspace:** Remove the last digit
- **ENTER:** Confirm and apply the edit
- **ESC:** Cancel without saving

### Validation

- Chain numbers must be 01-99
- Invalid numbers (00, 100+) are silently ignored
- Empty cells remain as "--"

### Future Enhancements

- [ ] Bottom menu bar with +/- buttons (increment/decrement)
- [ ] DELETE button to clear a cell
- [ ] COPY/PASTE for chain patterns
- [ ] Cell validation feedback (visual errors)
