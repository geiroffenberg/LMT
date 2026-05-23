import 'package:flutter/material.dart';
import '../tracker_model.dart';
import '../tracker_styles.dart';

const _rowNumW = 32.0;
const _rowH    = 28.0;
const _numCols = 8; // IN VOL FX VL FX VL FX VL
const _headers = ['IN', 'VOL', 'FX', 'VL', 'FX', 'VL', 'FX', 'VL'];

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
                      final cells = [
                        step.instrument == 0 ? '--' : step.instrument.toString().padLeft(2, '0'),
                        step.volume.toString().padLeft(2, '0'),
                        step.fx[0].name,
                        step.fx[0].value.toString().padLeft(2, '0'),
                        step.fx[1].name,
                        step.fx[1].value.toString().padLeft(2, '0'),
                        step.fx[2].name,
                        step.fx[2].value.toString().padLeft(2, '0'),
                      ];
                      return Row(children: [
                        SizedBox(
                          width: _rowNumW,
                          child: Text(
                            (row + 1).toString().padLeft(2, '0'),
                            style: isRowCursor ? gs : ts,
                            textAlign: TextAlign.center,
                          ),
                        ),
                        ...List.generate(_numCols, (col) {
                          final isCursor = isRowCursor && model.cursorCol == col;
                          String text = cells[col];
                          if (isCursor) {
                            // Show actual value if non-zero, otherwise show 00
                            int val = int.tryParse(cells[col].replaceAll('--', '0')) ?? 0;
                            text = val == 0 ? '00' : val.toString().padLeft(2, '0');
                          }
                          return GestureDetector(
                            onTap: () {
                              bool isDouble = model.isDoubleClick(row, col, 2);
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
}
