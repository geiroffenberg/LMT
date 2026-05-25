import 'dart:io';
import 'package:permission_handler/permission_handler.dart';

class StorageService {
  static const String projectsFolderName = 'LMT_PROJECTS';

  /// Request storage permissions
  static Future<bool> requestPermissions() async {
    if (Platform.isAndroid) {
      // For Android 11+, we need MANAGE_EXTERNAL_STORAGE
      final status = await Permission.manageExternalStorage.request();
      print('Storage permission status: $status');
      return status.isGranted;
    } else if (Platform.isIOS) {
      final status = await Permission.photos.request();
      return status.isGranted;
    }
    return true; // Desktop platforms don't need permission
  }

  /// Get the LMT_PROJECTS folder path (at root of internal storage)
  static Future<Directory?> getProjectsFolder() async {
    try {
      // Get the root storage directory
      final rootDir = Directory('/storage/emulated/0');
      final projectsDir = Directory('${rootDir.path}/$projectsFolderName');
      print('Projects folder path: ${projectsDir.path}');
      return projectsDir;
    } catch (e) {
      print('Error getting projects folder: $e');
      return null;
    }
  }

  /// Initialize storage: create LMT_PROJECTS folder if it doesn't exist
  static Future<bool> initializeStorage() async {
    try {
      print('=== Initializing Storage ===');
      
      // First request permissions
      print('Requesting storage permissions...');
      final hasPermission = await requestPermissions();
      if (!hasPermission) {
        print('ERROR: Storage permission denied');
        return false;
      }
      print('✓ Storage permission granted');

      // Get the projects folder
      final projectsDir = await getProjectsFolder();
      if (projectsDir == null) {
        print('ERROR: Could not get projects folder');
        return false;
      }

      // Check if folder exists
      final exists = await projectsDir.exists();
      if (exists) {
        print('✓ LMT_PROJECTS folder already exists at: ${projectsDir.path}');
        return true;
      }

      // Create folder if it doesn't exist
      print('Creating LMT_PROJECTS folder at: ${projectsDir.path}');
      await projectsDir.create(recursive: true);
      
      // Verify creation
      if (await projectsDir.exists()) {
        print('✓ Successfully created LMT_PROJECTS folder');
        return true;
      } else {
        print('ERROR: Failed to create LMT_PROJECTS folder');
        return false;
      }
    } catch (e) {
      print('ERROR: Exception during storage initialization: $e');
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
      print('Error listing songs: $e');
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
      print('Error getting song path: $e');
      return null;
    }
  }
}
