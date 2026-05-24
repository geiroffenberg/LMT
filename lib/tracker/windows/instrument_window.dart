import 'package:flutter/material.dart';
import '../tracker_model.dart';
import '../tracker_styles.dart';
import '../sample_browser.dart';
import '../audio/audio_engine.dart';

const _rowNumW = 32.0;
const _rowH    = 36.0;

class InstrumentWindow extends StatefulWidget {
  final TrackerModel model;
  final VoidCallback onStateChange;
  final Function(int)? onSamplerOpen;

  const InstrumentWindow({
    required this.model,
    required this.onStateChange,
    this.onSamplerOpen,
    super.key,
  });

  @override
  State<InstrumentWindow> createState() => _InstrumentWindowState();
}

class _InstrumentWindowState extends State<InstrumentWindow> {
  String? _lastBrowserFolder;

  TrackerModel get model => widget.model;
  VoidCallback get onStateChange => widget.onStateChange;

  @override
  void initState() {
    super.initState();
    _loadDefaultSampleFolder();
  }

  Future<void> _loadDefaultSampleFolder() async {
    await model.loadDefaultSampleFolder();
  }

  String _getParentFolder(String filePath) {
    return filePath.replaceAll(RegExp(r'[^${Platform.pathSeparator}]*$'), '');
  }

  void _showSampleEditor(BuildContext context, int instrumentIndex) {
    final currentSample = model.getSampleDisplayName(instrumentIndex);
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black87,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Sample Editor - Instrument ${instrumentIndex + 1}',
                style: trackerStyle(size: 14, color: kGreen),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white, width: 1),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Current Sample:', style: trackerStyle(size: 12, color: Colors.white70)),
                    Text(
                      currentSample.isEmpty ? '(none)' : currentSample,
                      style: trackerStyle(size: 12, color: kGreen),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  ElevatedButton(
                    onPressed: () async {
                      Navigator.pop(ctx);
                      final samplePath = await SampleBrowser.show(
                        context,
                        previewSlot: instrumentIndex,
                        defaultFolder: model.defaultSampleFolder,
                        lastFolder: _lastBrowserFolder,
                        onBookmarkFolder: (folderPath) async {
                          await model.bookmarkSampleFolder(folderPath);
                          setState(() {});
                        },
                        onRemoveBookmark: () async {
                          await model.removeBookmark();
                          setState(() {});
                        },
                      );
                      if (samplePath != null) {
                        _lastBrowserFolder = _getParentFolder(samplePath);
                        model.loadSampleForInstrument(instrumentIndex, samplePath);
                        await NativeAudioEngine.loadSample(instrumentIndex, samplePath);
                        setState(() {});
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.grey[800],
                    ),
                    child: Text('Load Sample', style: trackerStyle(size: 11)),
                  ),
                  ElevatedButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.grey[800],
                    ),
                    child: Text('Close', style: trackerStyle(size: 11)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Fixed button width
        const btnW = 42.0;
        const btnSpacing = 5.0;
        final waveformW = constraints.maxWidth - _rowNumW - (btnW + btnSpacing) * 4;
        
        // Font sizing based on row height, matching other windows
        final fontSize = (_rowH * 0.6).clamp(16.0, 28.0);
        final ts = trackerStyle(size: fontSize);
        final gs = trackerStyle(size: fontSize, color: kGreen);

        return Column(
          children: [
            Expanded(
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: 99,
                itemExtent: _rowH,
                itemBuilder: (context, row) {
                  final isRowCursor = model.cursorRow == row;
                  final inst = model.instruments[row];
                  final samplePath = inst.sample;
                  final hasSample = samplePath.isNotEmpty;

                  return Row(
                    children: [
                      // Row number
                      SizedBox(
                        width: _rowNumW,
                        child: Text(
                          (row + 1).toString().padLeft(2, '0'),
                          style: isRowCursor ? gs : ts,
                          textAlign: TextAlign.center,
                        ),
                      ),
                      // LOAD button
                      GestureDetector(
                        onTap: () async {
                          model.cursorRow = row;
                          model.cursorCol = 0;
                          onStateChange();
                          final samplePath = await SampleBrowser.show(
                            context,
                            previewSlot: row,
                            defaultFolder: model.defaultSampleFolder,
                            lastFolder: _lastBrowserFolder,
                            onBookmarkFolder: (folderPath) async {
                              await model.bookmarkSampleFolder(folderPath);
                              setState(() {});
                            },
                            onRemoveBookmark: () async {
                              await model.removeBookmark();
                              setState(() {});
                            },
                          );
                          if (samplePath != null) {
                            _lastBrowserFolder = _getParentFolder(samplePath);
                            model.loadSampleForInstrument(row, samplePath);
                            await NativeAudioEngine.loadSample(row, samplePath);
                            onStateChange();
                          }
                        },
                        child: Container(
                          width: btnW,
                          margin: EdgeInsets.symmetric(horizontal: btnSpacing / 2),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.white, width: 1.5),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            'LD',
                            style: ts,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                      // EDIT button
                      GestureDetector(
                        onTap: () {
                          // Only open sampler if a sample is loaded
                          if (inst.sample.isNotEmpty) {
                            widget.onSamplerOpen?.call(row);
                          }
                        },
                        child: Container(
                          width: btnW,
                          margin: EdgeInsets.symmetric(horizontal: btnSpacing / 2),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.white, width: 1.5),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            'ED',
                            style: inst.sample.isEmpty
                                ? trackerStyle(size: fontSize, color: Colors.grey)
                                : ts,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                      // REC button
                      GestureDetector(
                        onTap: () {
                          // TODO: Recording functionality
                          model.cursorRow = row;
                          model.cursorCol = 2;
                          onStateChange();
                        },
                        child: Container(
                          width: btnW,
                          margin: EdgeInsets.symmetric(horizontal: btnSpacing / 2),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.white, width: 1.5),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            'RC',
                            style: ts,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                      // Waveform display area
                      Container(
                        width: waveformW,
                        margin: EdgeInsets.symmetric(horizontal: btnSpacing / 2),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.white, width: 1.5),
                          color: const Color(0xFF0a0a0a),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          hasSample ? model.getSampleDisplayName(row) : 'empty',
                          style: hasSample
                              ? trackerStyle(size: fontSize, color: kGreen)
                              : trackerStyle(size: fontSize, color: Colors.grey),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                        ),
                      ),
                      // Delete button (X)
                      GestureDetector(
                        onTap: () {
                          // Delete sample
                          model.instruments[row].sample = '';
                          onStateChange();
                        },
                        child: Container(
                          width: btnW,
                          margin: EdgeInsets.symmetric(horizontal: btnSpacing / 2),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.white, width: 1.5),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            'X',
                            style: ts,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
