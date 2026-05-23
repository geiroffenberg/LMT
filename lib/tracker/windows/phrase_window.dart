import 'package:flutter/material.dart';
import '../tracker_model.dart';
import '../tracker_styles.dart';

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
                    SizedBox(width: _rowNumW),
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
                      final step = model.phrases[row].steps[row];
                      
                      return Row(children: [
                        SizedBox(
                          width: _rowNumW,
                          child: Text(
                            (row + 1).toString().padLeft(2, '0'),
                            style: isRowCursor ? gs : ts,
                            textAlign: TextAlign.center,
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
                                : step.fx[fxIdx].name;
                            }
                          }
                          
                          if (isCursor && colIdx != 0) {
                            // Show actual value if non-zero, otherwise show 00
                            int val = int.tryParse(text.replaceAll('--', '0')) ?? 0;
                            text = val == 0 ? '00' : val.toString().padLeft(2, '0');
                          }
                          
                          return GestureDetector(
                            onTap: () {
                              model.cursorRow = row;
                              model.cursorCol = col;
                              model.enterEditMode();
                              model.editMenuVisible = true;
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
                      ]);
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
