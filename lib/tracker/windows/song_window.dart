import 'package:flutter/material.dart';
import '../tracker_model.dart';
import '../tracker_styles.dart';

const _rowNumW = 32.0;
const _rowH = 28.0;
const _numCols = 8;

class SongWindow extends StatelessWidget {
  final TrackerModel model;
  final VoidCallback onStateChange;

  const SongWindow({
    required this.model,
    required this.onStateChange,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cellW = (constraints.maxWidth - _rowNumW) / _numCols;
        final fontSize = (cellW * 0.55).clamp(16.0, 32.0);

        final textStyle     = trackerStyle(size: fontSize);
        final greenStyle    = trackerStyle(size: fontSize, color: kGreen);
        final playingStyle  = trackerStyle(size: fontSize, color: Colors.orange);

        return Stack(
          children: [
            Column(
              children: [
                // Column headers
                SizedBox(
                  height: _rowH,
                  child: Row(
                    children: [
                      SizedBox(width: _rowNumW),
                      ...List.generate(_numCols, (i) => SizedBox(
                        width: cellW,
                        child: Text(
                          (i + 1).toString().padLeft(2, '0'),
                          style: textStyle,
                          textAlign: TextAlign.center,
                        ),
                      )),
                    ],
                  ),
                ),
                // Grid rows
                Expanded(
                  child: ListView.builder(
                    padding: EdgeInsets.zero,
                    itemCount: 99,
                    itemExtent: _rowH,
                    itemBuilder: (context, rowIndex) {
                      final isRowCursor  = model.cursorRow == rowIndex;
                      final isPlaying    = model.isPlaying && model.playheadRow == rowIndex;
                      final isSelected   = model.isRowInLineSelection(rowIndex);
                      Color? rowColor = isPlaying  ? Colors.orange.withOpacity(0.12)
                                      : isSelected ? Colors.cyan.withOpacity(0.15)
                                      : null;
                      final rowNumStyle  = isPlaying  ? playingStyle
                                         : isSelected ? trackerStyle(size: fontSize, color: Colors.cyan)
                                         : isRowCursor ? greenStyle
                                         : textStyle;
                      return Container(
                        color: rowColor,
                        child: Row(
                          children: [
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () {
                                model.selectLine(rowIndex);
                                onStateChange();
                              },
                              child: SizedBox(
                                width: _rowNumW,
                                child: Text(
                                  (rowIndex + 1).toString().padLeft(2, '0'),
                                  style: rowNumStyle,
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),
                            ...List.generate(_numCols, (colIndex) {
                              final isCursor = isRowCursor && model.cursorCol == colIndex;
                              final chainRef = model.song.chains[rowIndex][colIndex];
                              // Empty cells always show '--', even when the cursor is on them
                              final String text = chainRef == 0
                                  ? '--'
                                  : chainRef.toString().padLeft(2, '0');
                              // Cyan tint when the referenced chain has actual phrase data
                              final bool chainHasData = chainRef > 0 &&
                                  model.chains[chainRef - 1].items
                                      .any((item) => item.phrase != 0);
                              final cellTextStyle = isPlaying
                                  ? playingStyle
                                  : chainHasData
                                      ? trackerStyle(size: fontSize, color: kCyan)
                                      : textStyle;
                              return GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () {
                                  final isDouble = model.isDoubleClick(rowIndex, colIndex, 0);
                                  model.clearLineSelection();
                                  model.cursorRow = rowIndex;
                                  model.cursorCol = colIndex;
                                  if (isDouble && chainRef == 0) {
                                    // Double-tap on empty cell: assign the first
                                    // available empty chain number
                                    final chainNum = model.firstAvailableChain();
                                    if (chainNum > 0) {
                                      model.song.chains[rowIndex][colIndex] = chainNum;
                                    }
                                  }
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
                                  child: Text(
                                    text,
                                    style: cellTextStyle,
                                  ),
                                ),
                              );
                            }),
                          ],
                        ),
                      );
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

