import 'package:flutter/foundation.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

class StorageService {
  static const String projectsFolderName = 'LMT_PROJECTS';

  /// Get the LMT_PROJECTS folder path inside app-specific external storage.
  /// No permissions needed on any Android version.
  static Future<Directory?> getProjectsFolder() async {
    try {
      final base = await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();
      final projectsDir = Directory('${base.path}/$projectsFolderName');
      debugPrint('Projects folder path: ${projectsDir.path}');
      return projectsDir;
    } catch (e) {
      debugPrint('Error getting projects folder: $e');
      return null;
    }
  }

  /// Initialize storage: create LMT_PROJECTS folder if it doesn't exist
  static Future<bool> initializeStorage() async {
    try {
      debugPrint('=== Initializing Storage ===');

      // Get the projects folder
      final projectsDir = await getProjectsFolder();
      if (projectsDir == null) {
        debugPrint('ERROR: Could not get projects folder');
        return false;
      }

      // Check if folder exists
      final exists = await projectsDir.exists();
      if (exists) {
        debugPrint('✓ LMT_PROJECTS folder already exists at: ${projectsDir.path}');
        return true;
      }

      // Create folder if it doesn't exist
      debugPrint('Creating LMT_PROJECTS folder at: ${projectsDir.path}');
      await projectsDir.create(recursive: true);
      
      // Verify creation
      if (await projectsDir.exists()) {
        debugPrint('✓ Successfully created LMT_PROJECTS folder');
        return true;
      } else {
        debugPrint('ERROR: Failed to create LMT_PROJECTS folder');
        return false;
      }
    } catch (e) {
      debugPrint('ERROR: Exception during storage initialization: $e');
      return false;
    }
  }

  /// List all song files in the projects folder
  static Future<List<String>> listSongs() async {
    try {
      final projectsDir = await getProjectsFolder();
      if (projectsDir == null || !await projectsDir.exists()) {
        return [];
      }

      final files = projectsDir.listSync();
      return files
          .where((file) => file is File && file.path.endsWith('.lmt'))
          .map((file) => file.path.split('/').last)
          .toList();
    } catch (e) {
      debugPrint('Error listing songs: $e');
      return [];
    }
  }

  /// Get full path for a song file
  static Future<String?> getSongPath(String songName) async {
    try {
      final projectsDir = await getProjectsFolder();
      if (projectsDir == null) return null;

      final songFile = File('${projectsDir.path}/$songName');
      return songFile.path;
    } catch (e) {
      debugPrint('Error getting song path: $e');
      return null;
    }
  }
}
