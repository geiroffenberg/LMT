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
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

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
      '${projectsDir.path}/${ProjectManager.autoSaveName}',
    );
    final latestRegular = await ProjectManager.getLatestProject();

    final autoSaveExists = await autoSaveDir.exists();
    if (autoSaveExists && latestRegular != null) {
      final autoMod = autoSaveDir.statSync().modified;
      final regularMod = latestRegular.statSync().modified;
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
    if (model != null) {
      model.setCurrentProject(
        ProjectManager.getProjectName(projectToLoad),
        projectToLoad.path,
      );
    }
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
    // Push HP/LP filters too so phrase playback is filtered without
    // needing to open the sampler window first.
    await NativeAudioEngine.setInstrumentFilters(i, s.hpCutoff, s.lpCutoff);
    // Push per-instrument FX sends (REV/DEL/MOD) so they're restored and active
    // before the first note plays — without this they stay 0 until the sampler
    // window is opened, and loaded phrases sound dry.
    await NativeAudioEngine.setInstrumentSends(
      i,
      s.revSend,
      s.delSend,
      s.modSend,
    );
    // Push chord/unison layer 2+3 params (gain 0 = layer off).
    await NativeAudioEngine.setInstrumentLayers(
      i,
      s.layer2PitchCents,
      s.layer2Gain,
      s.layer3PitchCents,
      s.layer3Gain,
    );
    // Restore time-stretch if it was active — the raw WAV was just loaded so
    // the DSP must be re-applied (native engine resets on every app start).
    if (samplePath.isNotEmpty && s.stretchEnabled) {
      await NativeAudioEngine.updateStretch(
        i,
        true,
        s.stretchLines,
        model.song.lpb,
        model.song.bpm.toDouble(),
        s.stretchPreservePitch,
      );
    }
  }

  // Push mixer levels + sends so they're active before the first note plays.
  // Without this the C++ engine starts with defaults (level=1.0, sends=0)
  // and ignores saved mixer settings until the user touches a mixer knob.
  for (int i = 0; i < model.mixerChannels.length; i++) {
    final ch = model.mixerChannels[i];
    NativeAudioEngine.setTrackLevel(i, ch.level / 99.0);
    NativeAudioEngine.setTrackSends(
      i,
      ch.reverbSend / 99.0,
      ch.delaySend / 99.0,
      ch.chorusSend / 99.0,
    );
  }

  // Push master FX (reverb/delay/chorus/EQ/filters/volume) so the engine's
  // values match what's saved and displayed in the FX window. Without this the
  // C++ engine keeps its defaults (e.g. delay 375 ms) that DON'T match the
  // saved tempo-synced value — the delay only "caught up" once a slider was
  // touched, which made it sound like any adjustment jumped to a too-fast time.
  final fx = model.masterFx;
  NativeAudioEngine.setReverbSize(fx.reverbSize);
  NativeAudioEngine.setReverbDamping(fx.reverbDamp);
  NativeAudioEngine.setReverbWidth(fx.reverbWidth);
  // Map delayLines 0..99 → 0.25..4.0 lines (shortest = ¼ line, longest = 4 lines).
  NativeAudioEngine.setDelayTimeMs(
    (0.25 + (fx.delayLines / 99.0) * 3.75) *
        60000.0 /
        (model.song.bpm * model.song.lpb),
  );
  NativeAudioEngine.setDelayFeedback(fx.delayFeedback);
  NativeAudioEngine.setChorusRate((fx.chorusRate - 0.1) / 4.9);
  NativeAudioEngine.setChorusDepth(fx.chorusDepth);
  NativeAudioEngine.setEqBand(0, fx.eqBand1);
  NativeAudioEngine.setEqBand(1, fx.eqBand2);
  NativeAudioEngine.setEqBand(2, fx.eqBand3);
  NativeAudioEngine.setEqBand(3, fx.eqBand4);
  NativeAudioEngine.setEqBand(4, fx.eqBand5);
  NativeAudioEngine.setHpFreq(fx.hpFreq);
  NativeAudioEngine.setHpRes(fx.hpRes);
  NativeAudioEngine.setLpFreq(fx.lpFreq);
  NativeAudioEngine.setLpRes(fx.lpRes);
  NativeAudioEngine.setLimiterThreshold(fx.limiterThreshold);
  NativeAudioEngine.setMasterVolume(fx.masterVolume);

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
