import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'tracker_styles.dart';
import 'audio/audio_engine.dart';

const _kSampleExts = <String>{
  '.wav',
  '.aif',
  '.aiff',
  '.flac',
  '.ogg',
  '.mp3',
  '.m4a',
  '.aac',
};

class SampleBrowser {
  static bool _isLegalSamplePath(String path) {
    final name = _sampleDisplayName(path).toLowerCase();
    return _kSampleExts.any(name.endsWith);
  }

  static String _sampleDisplayName(String path) =>
      path.split(Platform.pathSeparator).last;

  static String _folderDisplayName(String path) {
    final parts = path.split(Platform.pathSeparator).where((p) => p.isNotEmpty);
    return parts.isEmpty ? path : parts.last;
  }

  static List<String> _collectSubFolders(String folderPath) {
    try {
      final dir = Directory(folderPath);
      if (!dir.existsSync()) return const [];
      final dirs = <String>[];
      try {
        for (final e in dir.listSync()) {
          final t = FileSystemEntity.typeSync(e.path, followLinks: true);
          if (t == FileSystemEntityType.directory) {
            dirs.add(e.path);
          }
        }
      } catch (e) {
        debugPrint('Error listing subfolders in $folderPath: $e');
      }
      dirs.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return dirs;
    } catch (e) {
      debugPrint('Error accessing folder $folderPath: $e');
      return const [];
    }
  }

  static List<String> _collectPlayableSamples(String folderPath) {
    try {
      final dir = Directory(folderPath);
      if (!dir.existsSync()) return const [];
      final samples = <String>[];
      try {
        for (final e in dir.listSync()) {
          final t = FileSystemEntity.typeSync(e.path, followLinks: true);
          if (t != FileSystemEntityType.file) continue;
          if (_isLegalSamplePath(e.path)) samples.add(e.path);
        }
      } catch (e) {
        debugPrint('Error listing samples in $folderPath: $e');
      }
      samples.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return samples;
    } catch (e) {
      debugPrint('Error accessing folder $folderPath: $e');
      return const [];
    }
  }

  static Future<bool> _requestStoragePermission() async {
    PermissionStatus status = PermissionStatus.denied;

    if (Platform.isAndroid) {
      status = await Permission.manageExternalStorage.request();
      if (status.isGranted) return true;

      status = await Permission.storage.request();
      if (status.isGranted) return true;

      status = await Permission.photos.request();
      return status.isGranted;
    }

    return true;
  }

  static String _internalStorageRoot() {
    const candidates = [
      '/storage/emulated/0',
      '/storage/self/primary',
      '/sdcard',
    ];
    for (final p in candidates) {
      try {
        if (Directory(p).existsSync()) return p;
      } catch (_) {}
    }
    return '/storage/emulated/0';
  }

  static Future<String?> show(
    BuildContext context, {
    int previewSlot = 0,
    String? defaultFolder,
    String? lastFolder,
    Future<void> Function(String folderPath)? onBookmarkFolder,
    Future<void> Function()? onRemoveBookmark,
  }) async {
    if (Platform.isAndroid) {
      final status = await _requestStoragePermission();
      if (!status) {
        if (!context.mounted) return null;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Storage permission denied. Grant permission in Settings > Apps > LMT > Permissions.',
            ),
            duration: const Duration(seconds: 5),
            backgroundColor: Colors.red,
            action: SnackBarAction(
              label: 'Settings',
              textColor: Colors.white,
              onPressed: () {
                openAppSettings();
              },
            ),
          ),
        );
        return null;
      }
    }

    final internalRoot = _internalStorageRoot();
    final startFolder = (defaultFolder != null &&
            Directory(defaultFolder).existsSync())
        ? defaultFolder
        : internalRoot;

    return showModalBottomSheet<String?>(
      context: context,
      backgroundColor: const Color(0xFF111111),
      isScrollControlled: true,
      builder: (ctx) {
        String currentFolder = lastFolder ?? startFolder;
        String? previewingSample;  // outside StatefulBuilder so it survives rebuilds
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final ts = trackerStyle(size: 18, color: Colors.white70);
            final headerTs = trackerStyle(size: 20, color: kGreen);
            
            return SafeArea(
              child: SizedBox(
                height: MediaQuery.of(ctx).size.height * 0.75,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                      child: Row(
                        children: [
                          IconButton(
                            tooltip: 'Up one folder',
                            onPressed: () {
                              final parent = Directory(
                                currentFolder,
                              ).parent.path;
                              if (parent == currentFolder ||
                                  parent.isEmpty ||
                                  currentFolder == internalRoot) {
                                Navigator.of(ctx).pop();
                                return;
                              }
                              currentFolder = parent;
                              setSheetState(() {});
                            },
                            icon: const Icon(Icons.arrow_upward),
                            color: kGreen,
                          ),
                          Expanded(
                            child: Text(
                              currentFolder == internalRoot
                                  ? 'INTERNAL STORAGE'
                                  : currentFolder,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: headerTs,
                            ),
                          ),
                          IconButton(
                            tooltip: currentFolder == defaultFolder
                                ? 'Remove bookmark'
                                : 'Set as default folder',
                            onPressed: () async {
                              if (currentFolder == defaultFolder) {
                                await onRemoveBookmark?.call();
                              } else {
                                await onBookmarkFolder?.call(currentFolder);
                              }
                              setSheetState(() {});
                            },
                            icon: Icon(
                              currentFolder == defaultFolder
                                  ? Icons.bookmark
                                  : Icons.bookmark_border,
                            ),
                            color: currentFolder == defaultFolder
                                ? kGreen
                                : Colors.white70,
                          ),
                          IconButton(
                            tooltip: 'Close browser',
                            onPressed: () => Navigator.of(ctx).pop(),
                            icon: const Icon(Icons.close),
                            color: kGreen,
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1, color: Color(0xFF222222)),
                    Expanded(
                      child: Builder(
                        builder: (_) {
                          final activeFolder = currentFolder;
                          final folders = _collectSubFolders(activeFolder);
                          final samples = _collectPlayableSamples(activeFolder);

                          return ListView(
                            children: [
                              for (final folderPath in folders)
                                ListTile(
                                  dense: false,
                                  leading: Icon(
                                    Icons.folder,
                                    color: kGreen,
                                  ),
                                  title: Text(
                                    _folderDisplayName(folderPath),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: ts,
                                  ),
                                  onTap: () {
                                    currentFolder = folderPath;
                                    setSheetState(() {});
                                  },
                                ),
                              if (samples.isEmpty && folders.isEmpty)
                                Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Text(
                                    'No subfolders or playable samples in this folder.',
                                    style: trackerStyle(
                                      size: 16,
                                      color: Colors.grey,
                                    ),
                                  ),
                                ),
                              for (final samplePath in samples)
                                ListTile(
                                  dense: false,
                                  onTap: null,
                                  leading: IconButton(
                                    icon: Icon(
                                      previewingSample == samplePath
                                          ? Icons.stop
                                          : Icons.play_arrow,
                                      color: previewingSample == samplePath
                                          ? kGreen
                                          : Colors.white70,
                                    ),
                                    onPressed: () async {
                                      if (previewingSample == samplePath) {
                                        // Stop playback
                                        await NativeAudioEngine.noteOff(previewSlot);
                                        setSheetState(() {
                                          previewingSample = null;
                                        });
                                      } else {
                                        // Stop any current preview first
                                        if (previewingSample != null) {
                                          await NativeAudioEngine.noteOff(previewSlot);
                                        }
                                        // Load and play
                                        final loaded = await NativeAudioEngine.loadSample(previewSlot, samplePath);
                                        if (loaded) {
                                          await NativeAudioEngine.noteOn(previewSlot, 261.626, 0.8);
                                          setSheetState(() {
                                            previewingSample = samplePath;
                                          });
                                        }
                                      }
                                    },
                                  ),
                                  title: Text(
                                    _sampleDisplayName(samplePath),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: ts,
                                  ),
                                  trailing: TextButton(
                                    onPressed: () async {
                                      // Stop playback before selecting
                                      if (previewingSample != null) {
                                        await NativeAudioEngine.noteOff(previewSlot);
                                      }
                                      Navigator.of(ctx).pop(samplePath);
                                    },
                                    style: TextButton.styleFrom(
                                      foregroundColor: kGreen,
                                    ),
                                    child: Text(
                                      'SELECT',
                                      style: trackerStyle(
                                        size: 16,
                                        color: kGreen,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
