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

        final textStyle   = trackerStyle(size: fontSize);
        final greenStyle  = trackerStyle(size: fontSize, color: kGreen);

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
                      final isRowCursor = model.cursorRow == rowIndex;
                      return Row(
                        children: [
                          SizedBox(
                            width: _rowNumW,
                            child: Text(
                              (rowIndex + 1).toString().padLeft(2, '0'),
                              style: isRowCursor ? greenStyle : textStyle,
                              textAlign: TextAlign.center,
                            ),
                          ),
                          ...List.generate(_numCols, (colIndex) {
                            final isCursor = isRowCursor && model.cursorCol == colIndex;
                            final chainRef = model.song.chains[rowIndex][colIndex];
                            String text = chainRef == 0
                                ? '--'
                                : chainRef.toString().padLeft(2, '0');
                            if (isCursor) {
                              text = chainRef == 0 ? '00' : chainRef.toString().padLeft(2, '0');
                            }
                            return GestureDetector(
                              onTap: () {
                                model.cursorRow = rowIndex;
                                model.cursorCol = colIndex;
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
                                  style: textStyle,
                                ),
                              ),
                            );
                          }),
                        ],
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

