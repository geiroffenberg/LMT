import 'package:flutter/material.dart';
import '../tracker_model.dart';
import '../tracker_styles.dart';
import '../fx_commands.dart';

const _rowNumW = 32.0;
const _rowH    = 28.0;
const _numCols = 7; // NT IN VOL FX VL FX VL (removed one FX/VL pair)
const _headers = ['NT', 'IN', 'VOL', 'FX', 'VL', 'FX', 'VL'];

class PhraseWindow extends StatelessWidget {
  final TrackerModel model;
  final VoidCallback onStateChange;

  const PhraseWindow({
    required this.model,
    required this.onStateChange,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cellW    = (constraints.maxWidth - _rowNumW) / _numCols;
        final fontSize = (cellW * 0.55).clamp(12.0, 32.0);
        final ts       = trackerStyle(size: fontSize);
        final gs       = trackerStyle(size: fontSize, color: kGreen);

        return Stack(
          children: [
            Column(
              children: [
                SizedBox(
                  height: _rowH,
                  child: Row(children: [
                    SizedBox(
                      width: _rowNumW,
                      child: Text(
                        (model.activePhraseIdx + 1).toString().padLeft(2, '0'),
                        style: gs,
                        textAlign: TextAlign.center,
                      ),
                    ),
                    ...List.generate(_numCols, (i) => SizedBox(
                      width: cellW,
                      child: Text(_headers[i], style: ts, textAlign: TextAlign.center),
                    )),
                  ]),
                ),
                Expanded(
                  child: ListView.builder(
                    padding: EdgeInsets.zero,
                    itemCount: 99,
                    itemExtent: _rowH,
                    itemBuilder: (context, row) {
                      final isRowCursor = model.cursorRow == row;
                      final isPlaying   = model.isPlaying && model.playheadRow == row;
                      final isSelected  = model.isRowInLineSelection(row);
                      final step = model.phrases[model.activePhraseIdx].steps[row];

                      Color? rowColor = isPlaying  ? Colors.orange.withOpacity(0.12)
                                      : isSelected ? Colors.cyan.withOpacity(0.15)
                                      : null;
                      
                      return Container(
                        color: rowColor,
                        child: Row(children: [
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            model.selectLine(row);
                            onStateChange();
                          },
                          child: SizedBox(
                            width: _rowNumW,
                            child: Text(
                              (row + 1).toString().padLeft(2, '0'),
                              style: isPlaying  ? trackerStyle(size: fontSize, color: Colors.orange)
                                   : isSelected ? trackerStyle(size: fontSize, color: Colors.cyan)
                                   : isRowCursor ? gs
                                   : ts,
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                        // NT column with - and + buttons
                        _buildNoteCell(row, step, isRowCursor, gs, ts, cellW, fontSize, onStateChange),
                        
                        // Other columns
                        ...List.generate(_numCols - 1, (colIdx) {
                          final col = colIdx + 1; // Offset by 1 due to NT
                          final isCursor = isRowCursor && model.cursorCol == col;
                          
                          String text = '';
                          if (colIdx == 0) {
                            // IN column
                            text = step.instrument == 0 ? '--' : step.instrument.toString().padLeft(2, '0');
                          } else if (colIdx == 1) {
                            // VOL column
                            text = step.volume.toString().padLeft(2, '0');
                          } else {
                            // FX and VL columns
                            final fxIdx = (colIdx - 2) ~/ 2;
                            final isValueCol = (colIdx - 2) % 2 == 1;
                            if (fxIdx < step.fx.length) {
                              text = isValueCol
                                ? step.fx[fxIdx].value.toString().padLeft(2, '0')
                                : step.fx[fxIdx].name; // '---', 'ARP', etc.
                            }
                          }

                          // FX name columns (colIdx 2 & 4): never show '00' — always show name.
                          // Value/numeric columns: show '00' when cursor is on them and empty.
                          final isFxNameCol = colIdx >= 2 && (colIdx - 2) % 2 == 0;
                          if (isCursor && colIdx != 0 && !isFxNameCol) {
                            final val = int.tryParse(text.replaceAll('--', '0')) ?? 0;
                            text = val == 0 ? '00' : val.toString().padLeft(2, '0');
                          }

                          return GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () async {
                              final isDouble = model.isDoubleClick(row, col, 2);
                              model.clearLineSelection();
                              model.cursorRow = row;
                              model.cursorCol = col;

                              if (isFxNameCol && isDouble) {
                                // Double-tap on FX name: show picker
                                final fxIdx = (colIdx - 2) ~/ 2;
                                final picked = await showFxCommandPicker(context, isPhrase: true);
                                if (picked != null && fxIdx < step.fx.length) {
                                  if (picked == '---') {
                                    step.fx[fxIdx].name  = '---';
                                    step.fx[fxIdx].value = 0;
                                  } else {
                                    step.fx[fxIdx].name = picked;
                                  }
                                }
                              } else {
                                model.enterEditMode();
                                model.editMenuVisible = true;
                              }
                              onStateChange();
                            },
                            child: Container(
                              width: cellW,
                              height: _rowH,
                              decoration: BoxDecoration(
                                border: isCursor ? Border.all(color: kGreen, width: 2.0) : null,
                              ),
                              alignment: Alignment.center,
                              child: Text(text, style: ts),
                            ),
                          );
                        }),
                      ])); // closes Container + Row
                    },
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _buildNoteCell(int row, PhraseStep step, bool isRowCursor, TextStyle gs, TextStyle ts, 
      double cellW, double fontSize, VoidCallback onStateChange) {
    final isCursor = isRowCursor && model.cursorCol == 0;
    
    return Stack(
      children: [
        // Background container with text display (like other cells)
        Container(
          width: cellW,
          height: _rowH,
          decoration: BoxDecoration(
            border: isCursor ? Border.all(color: kGreen, width: 2.0) : null,
          ),
          alignment: Alignment.center,
          child: Text(
            step.getNoteDisplay(),
            style: ts,
          ),
        ),
        
        // Left third: minus tap zone (invisible)
        Positioned(
          left: 0,
          top: 0,
          width: cellW * 0.33,
          height: _rowH,
          child: GestureDetector(
            onTap: () {
              if (step.note >= 0) {
                step.note = (step.note - 12).clamp(0, 120);
                onStateChange();
              }
            },
            child: Container(color: Colors.transparent),
          ),
        ),
        
        // Center third: toggle tap zone (invisible)
        Positioned(
          left: cellW * 0.33,
          top: 0,
          width: cellW * 0.34,
          height: _rowH,
          child: GestureDetector(
            onTap: () {
              bool isDouble = model.isDoubleClick(row, 0, 2);
              model.clearLineSelection();
              model.cursorRow = row;
              model.cursorCol = 0;
              if (isDouble && step.note < 0) {
                // Second tap: set to C-4
                step.note = 60;
              }
              model.enterEditMode();
              model.editMenuVisible = true;
              onStateChange();
            },
            child: Container(color: Colors.transparent),
          ),
        ),
        
        // Right third: plus tap zone (invisible)
        Positioned(
          right: 0,
          top: 0,
          width: cellW * 0.33,
          height: _rowH,
          child: GestureDetector(
            onTap: () {
              if (step.note >= 0) {
                step.note = (step.note + 12).clamp(0, 120);
                onStateChange();
              }
            },
            child: Container(color: Colors.transparent),
          ),
        ),
      ],
    );
  }
}
