import 'package:flutter/material.dart';
import '../tracker_model.dart';
import '../tracker_styles.dart';

const _rowNumW = 32.0;
const _rowH    = 28.0;
// Columns: PH  TR  FX  VL  FX  VL
const _numCols = 6;
const _headers = ['PH', 'TR', 'FX', 'VL', 'FX', 'VL'];

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
        final fontSize = (cellW * 0.55).clamp(10.0, 32.0);
        final ts       = trackerStyle(size: fontSize);
        final gs       = trackerStyle(size: fontSize, color: kGreen);

        return Column(
          children: [
            // Header row — row-num area shows active chain number in green
            SizedBox(
              height: _rowH,
              child: Row(children: [
                SizedBox(
                  width: _rowNumW,
                  child: Text(
                    (model.activeChainIdx + 1).toString().padLeft(2, '0'),
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

            // Data rows
            Expanded(
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: 99,
                itemExtent: _rowH,
                itemBuilder: (context, row) {
                  final isRowCursor = model.cursorRow == row;
                  final isSelected  = model.isRowInLineSelection(row);
                  final isPlaying   = model.isPlaying && model.playheadChainRow == row;
                  final item = model.chains[model.activeChainIdx].items[row];

                  String cellText(int col) {
                    switch (col) {
                      case 0: // PH
                        return item.phrase == 0
                            ? '--'
                            : item.phrase.toString().padLeft(2, '0');
                      case 1: // TR
                        return item.transpose == 0
                            ? '--'
                            : item.transpose.toString().padLeft(2, '0');
                      default:
                        final fxIdx   = (col - 2) ~/ 2;
                        final isValue = (col - 2) % 2 == 1;
                        if (fxIdx >= item.fx.length) return '--';
                        if (isValue) {
                          return item.fx[fxIdx].name == '---'
                              ? '--'
                              : item.fx[fxIdx].value.toString().padLeft(2, '0');
                        } else {
                          return item.fx[fxIdx].name; // "---", "ARP", etc.
                        }
                    }
                  }

                  return Container(
                    color: isPlaying  ? Colors.orange.withOpacity(0.25)
                         : isSelected ? Colors.cyan.withOpacity(0.15)
                         : null,
                    child: Row(children: [
                    // Row number — tap to select/extend line selection
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
                          style: isSelected ? trackerStyle(size: fontSize, color: Colors.cyan)
                               : isPlaying  ? trackerStyle(size: fontSize, color: Colors.orange)
                               : isRowCursor ? gs : ts,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),

                    // Data cells
                    ...List.generate(_numCols, (col) {
                      final isCursor = isRowCursor && model.cursorCol == col;
                      String text = cellText(col);
                      // PH column: keep '--' for empty even when cursor is on it;
                      // other columns keep the '00' convention.
                      if (col != 0 && isCursor && text == '--') text = '00';

                      // Cyan tint on PH column when the referenced phrase has note data
                      final bool phraseHasData = col == 0 &&
                          item.phrase > 0 &&
                          model.phrases[item.phrase - 1].steps
                              .any((s) => s.note != PhraseStep.noteNone);
                      final cellStyle = phraseHasData
                          ? trackerStyle(size: fontSize, color: kCyan)
                          : ts;

                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          final isDouble = col == 0
                              ? model.isDoubleClick(row, col, 1)
                              : false;
                          model.clearLineSelection();
                          model.cursorRow = row;
                          model.cursorCol = col;
                          // PH column: double-tap empty cell → first available phrase
                          if (col == 0 && isDouble && item.phrase == 0) {
                            final phraseNum = model.firstAvailablePhrase();
                            if (phraseNum > 0) {
                              model.chains[model.activeChainIdx].items[row].phrase = phraseNum;
                              model.activePhraseIdx = phraseNum - 1;
                            }
                          } else if (col == 0 && item.phrase > 0) {
                            // Single tap on filled PH cell: update activePhraseIdx
                            model.activePhraseIdx = item.phrase - 1;
                          }
                          model.enterEditMode();
                          model.editMenuVisible = true;
                          onStateChange();
                        },
                        child: Container(
                          width: cellW,
                          height: _rowH,
                          decoration: BoxDecoration(
                            border: isCursor
                                ? Border.all(color: kGreen, width: 2.0)
                                : null,
                          ),
                          alignment: Alignment.center,
                          child: Text(text, style: cellStyle),
                        ),
                      );
                    }),
                  ]));
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
