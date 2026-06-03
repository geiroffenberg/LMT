import 'dart:io';
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
  
  // Determine which project to load:
  //   - If __AUTOSAVE__ is newer than the last explicit save → restore unsaved changes
  //   - Otherwise load the latest explicitly saved project
  TrackerModel? model;
  final projectsDir = await StorageService.getProjectsFolder();
  Directory? projectToLoad;

  if (projectsDir != null) {
    final autoSaveDir = Directory(
        '${projectsDir.path}/${ProjectManager.autoSaveName}');
    final latestRegular = await ProjectManager.getLatestProject();

    final autoSaveExists = await autoSaveDir.exists();
    if (autoSaveExists && latestRegular != null) {
      final autoMod     = autoSaveDir.statSync().modified;
      final regularMod  = latestRegular.statSync().modified;
      projectToLoad = autoMod.isAfter(regularMod) ? autoSaveDir : latestRegular;
    } else if (autoSaveExists) {
      projectToLoad = autoSaveDir;
    } else if (latestRegular != null) {
      projectToLoad = latestRegular;
    }
  }

  if (projectToLoad != null) {
    print('Loading project: ${projectToLoad.path}');
    model = await ProjectManager.loadProject(projectToLoad);
  }

  if (model == null) {
    print('No project to load — creating blank UNTITLED');
    final untitledDir = await ProjectManager.createProject('UNTITLED');
    model = TrackerModel();
    if (untitledDir != null) {
      model.setCurrentProject('UNTITLED', untitledDir.path);
    }
  }

  // Initialize native audio engine
  await NativeAudioEngine.initialize();

  // Push all samples + sampler params to the C++ engine (engine resets on every app start)
  for (int i = 0; i < model.instruments.length; i++) {
    final instr = model.instruments[i];
    final samplePath = instr.sample;
    if (samplePath.isNotEmpty) {
      await NativeAudioEngine.loadSample(i, samplePath);
    }
    // Always push sampler params so start/end/attack/release/loop are restored
    final s = instr.sampler;
    await NativeAudioEngine.setInstrumentPlaybackParams(
      i,
      s.pitch,
      s.volume,
      s.start,
      s.end,
      s.attack,
      s.release,
      s.loopMode,
    );
  }

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
