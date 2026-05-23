import 'package:flutter/material.dart';
import '../tracker_model.dart';
import '../tracker_styles.dart';

// Mixer is oriented as: rows = params (LVL RVB DLY CHO), cols = 8 channels
const _rowLabelW = 40.0;
const _rowH      = 36.0;
const _numCols   = 8;
const _rowLabels = ['LVL', 'RVB', 'DLY', 'CHO'];

class MixerWindow extends StatelessWidget {
  final TrackerModel model;
  final VoidCallback onStateChange;

  const MixerWindow({
    required this.model,
    required this.onStateChange,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cellW    = (constraints.maxWidth - _rowLabelW) / _numCols;
        final fontSize = (cellW * 0.55).clamp(12.0, 32.0);
        final ts       = trackerStyle(size: fontSize);
        final gs       = trackerStyle(size: fontSize, color: kGreen);

        // cursorRow = param row (0-3), cursorCol = channel (0-7)
        return Stack(
          children: [
            Column(
              children: [
                // Channel headers: 01-08
                SizedBox(
                  height: _rowH,
                  child: Row(children: [
                    SizedBox(width: _rowLabelW),
                    ...List.generate(_numCols, (ch) => SizedBox(
                      width: cellW,
                      child: Text(
                        (ch + 1).toString().padLeft(2, '0'),
                        style: ts,
                        textAlign: TextAlign.center,
                      ),
                    )),
                  ]),
                ),
                // 4 param rows
                ...List.generate(4, (paramRow) {
                  final isRowCursor = model.cursorRow == paramRow;
                  return SizedBox(
                    height: _rowH,
                    child: Row(children: [
                      SizedBox(
                        width: _rowLabelW,
                        child: Text(
                          _rowLabels[paramRow],
                          style: isRowCursor ? gs : ts,
                          textAlign: TextAlign.center,
                        ),
                      ),
                      ...List.generate(_numCols, (ch) {
                        final isCursor = isRowCursor && model.cursorCol == ch;
                        final channel  = model.mixerChannels[ch];
                        final values   = [
                          channel.level.toString().padLeft(2, '0'),
                          channel.reverbSend.toString().padLeft(2, '0'),
                          channel.delaySend.toString().padLeft(2, '0'),
                          channel.chorusSend.toString().padLeft(2, '0'),
                        ];
                        String text = values[paramRow];
                        if (isCursor) {
                          int val = int.tryParse(values[paramRow].replaceAll('--', '0')) ?? 0;
                          text = val == 0 ? '00' : val.toString().padLeft(2, '0');
                        }
                        return GestureDetector(
                          onTap: () {
                            model.cursorRow = paramRow;
                            model.cursorCol = ch;
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
                    ]),
                  );
                }),
              ],
            ),
          ],
        );
      },
    );
  }
}
