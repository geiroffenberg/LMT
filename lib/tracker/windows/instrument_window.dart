import 'package:flutter/material.dart';
import '../tracker_model.dart';
import '../tracker_styles.dart';

const _rowNumW = 32.0;
const _rowH    = 28.0;
const _numCols = 8; // LD ED RC FT RS TR MD BS
const _headers = ['LD', 'ED', 'RC', 'FT', 'RS', 'TR', 'MD', 'BS'];

class InstrumentWindow extends StatelessWidget {
  final TrackerModel model;
  final VoidCallback onStateChange;

  const InstrumentWindow({
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
                      final inst = model.instruments[row];
                      // cols 0-2 are buttons (LD ED RC), cols 3-7 are editable
                      final cells = [
                        'LD', 'ED', 'RC',
                        inst.filter.toString().padLeft(2, '0'),
                        inst.resonance.toString().padLeft(2, '0'),
                        inst.treble.toString().padLeft(2, '0'),
                        inst.mid.toString().padLeft(2, '0'),
                        inst.bass.toString().padLeft(2, '0'),
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
                              if (col < 3) return; // buttons not editable yet
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
