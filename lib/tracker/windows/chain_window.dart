import 'package:flutter/material.dart';
import '../tracker_model.dart';
import '../tracker_styles.dart';

const _rowNumW = 32.0;
const _rowH    = 28.0;
const _numCols = 2; // PHR  TRN
const _headers = ['PHR', 'TRN'];

class ChainWindow extends StatelessWidget {
  final TrackerModel model;
  final VoidCallback onStateChange;

  const ChainWindow({
    required this.model,
    required this.onStateChange,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cellW    = (constraints.maxWidth - _rowNumW) / _numCols;
        final fontSize = (cellW * 0.55).clamp(16.0, 32.0);
        final ts       = trackerStyle(size: fontSize);
        final gs       = trackerStyle(size: fontSize, color: kGreen);

        return Stack(
          children: [
            Column(
              children: [
                // Headers
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
                      final item = model.chains[row].items[row];
                      final cells = [
                        item.phrase    == 0 ? '--' : item.phrase.toString().padLeft(2, '0'),
                        item.transpose == 0 ? '--' : item.transpose.toString().padLeft(2, '0'),
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
