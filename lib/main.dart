import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'tracker/tracker_screen.dart';
import 'tracker/audio/audio_engine.dart';
import 'tracker/services/storage_service.dart';
import 'tracker/services/project_manager.dart';
import 'tracker/tracker_model.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);
  
  // Initialize storage (create LMT_PROJECTS folder if needed)
  print('Starting app initialization...');
  final storageInitialized = await StorageService.initializeStorage();
  print('Storage initialization result: $storageInitialized');
  
  // Load latest project or create new one
  TrackerModel? model;
  final latestProject = await ProjectManager.getLatestProject();
  
  if (latestProject != null) {
    print('Loading latest project: ${ProjectManager.getProjectName(latestProject)}');
    model = await ProjectManager.loadProject(latestProject);
    if (model != null) {
      model.setCurrentProject(
        ProjectManager.getProjectName(latestProject),
        latestProject.path,
      );
    }
  } else {
    print('No projects found, creating new UNTITLED project');
    final untitledDir = await ProjectManager.createProject('UNTITLED');
    if (untitledDir != null) {
      model = TrackerModel();
      model.setCurrentProject('UNTITLED', untitledDir.path);
    }
  }
  
  // Initialize native audio engine
  await NativeAudioEngine.initialize();
  
  runApp(LMTApp(initialModel: model));
}

class LMTApp extends StatelessWidget {
  final TrackerModel? initialModel;

  const LMTApp({super.key, this.initialModel});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Little Moby Tracker',
      theme: ThemeData(
        useMaterial3: false,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
      ),
      home: TrackerScreen(initialModel: initialModel),
      debugShowCheckedModeBanner: false,
    );
  }
}
