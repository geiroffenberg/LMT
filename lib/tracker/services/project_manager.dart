import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as path_lib;
import '../tracker_model.dart';
import '../models/sampler_params.dart';
import 'storage_service.dart';

/// Project manager - handles project folder structure, save/load operations
class ProjectManager {
  static const String songFileName = 'song.lmt';
  static const String samplesFolder = 'samples';
  /// Reserved name for the auto-save slot — hidden from the user project list.
  static const String autoSaveName = '__AUTOSAVE__';

  /// Get the latest project folder, or null if no projects exist
  static Future<Directory?> getLatestProject() async {
    try {
      final projectsDir = await StorageService.getProjectsFolder();
      if (projectsDir == null || !await projectsDir.exists()) {
        debugPrint('Projects folder does not exist');
        return null;
      }

      final entries = projectsDir.listSync();
      final folders = entries
          .whereType<Directory>()
          .where((d) => !d.path.endsWith('.'))
          .where((d) => path_lib.basename(d.path) != autoSaveName) // Skip autosave slot
          .toList();

      if (folders.isEmpty) {
        debugPrint('No project folders found');
        return null;
      }

      // Sort by modification time, get the most recently modified
      folders.sort(
          (a, b) => b.statSync().modified.compareTo(a.statSync().modified));

      return folders.first;
    } catch (e) {
      debugPrint('Error getting latest project: $e');
      return null;
    }
  }

  /// Create a new project folder with the given name
  static Future<Directory?> createProject(String projectName) async {
    try {
      final projectsDir = await StorageService.getProjectsFolder();
      if (projectsDir == null) {
        debugPrint('ERROR: Could not get projects folder');
        return null;
      }

      final projectDir = Directory('${projectsDir.path}/$projectName');
      if (await projectDir.exists()) {
        debugPrint('Project folder already exists: ${projectDir.path}');
        return projectDir;
      }

      await projectDir.create(recursive: true);

      // Create samples subfolder
      final samplesDir = Directory('${projectDir.path}/$samplesFolder');
      await samplesDir.create(recursive: true);

      debugPrint('✓ Created project folder: ${projectDir.path}');
      return projectDir;
    } catch (e) {
      debugPrint('ERROR creating project: $e');
      return null;
    }
  }

  /// Save a TrackerModel to a project folder
  static Future<bool> saveProject(String projectName, TrackerModel model) async {
    try {
      debugPrint('=== Saving Project: $projectName ===');
      
      final projectDir = await createProject(projectName);
      if (projectDir == null) {
        debugPrint('ERROR: Failed to create project directory');
        return false;
      }

      // Copy samples into the project folder.  Build a path mapping but DO NOT
      // mutate the live model — _modelToJson() uses just the basename anyway,
      // and the model paths only need rewriting on LOAD, not on SAVE.
      final samplesUsed = _getSamplesInUse(model);
      final samplesDir = Directory(path_lib.join(projectDir.path, samplesFolder));
      if (!await samplesDir.exists()) {
        await samplesDir.create(recursive: true);
      }

      for (final samplePath in samplesUsed) {
        if (samplePath.isEmpty) continue;
        try {
          final srcFile = File(samplePath);
          if (!await srcFile.exists()) continue;
          final sampleName = path_lib.basename(samplePath);
          final destPath = path_lib.join(samplesDir.path, sampleName);
          // Skip if source and dest are the same file (already in project)
          if (path_lib.equals(samplePath, destPath)) continue;
          if (!await File(destPath).exists()) {
            await srcFile.copy(destPath);
            debugPrint('✓ Copied sample: $sampleName');
          }
        } catch (e) {
          debugPrint('Warning: Could not copy sample: $e');
        }
      }

      // Convert model to JSON (now with project-relative paths)
      final songData = _modelToJson(model);
      final jsonString = jsonEncode(songData);

      // Write song file
      final songFile = File(path_lib.join(projectDir.path, songFileName));
      await songFile.writeAsString(jsonString);
      debugPrint('✓ Saved song data to: ${songFile.path}');

      // Update model's current project info
      model.setCurrentProject(projectName, projectDir.path);

      debugPrint('✓ Project saved successfully');
      return true;
    } catch (e) {
      debugPrint('ERROR saving project: $e');
      return false;
    }
  }

  /// Load a project from a project folder
  static Future<TrackerModel?> loadProject(Directory projectDir) async {
    try {
      debugPrint('=== Loading Project: ${projectDir.path} ===');
      
      final songFile = File(path_lib.join(projectDir.path, songFileName));
      if (!await songFile.exists()) {
        debugPrint('ERROR: song.lmt file not found in project');
        return null;
      }

      final jsonString = await songFile.readAsString();
      // Guard against oversize / hostile files (10 MB cap)
      if (jsonString.length > 10 * 1024 * 1024) {
        debugPrint('ERROR: song.lmt exceeds 10 MB safety cap');
        return null;
      }
      final decoded = jsonDecode(jsonString);
      if (decoded is! Map<String, dynamic>) {
        debugPrint('ERROR: song.lmt root is not a JSON object');
        return null;
      }
      final jsonData = decoded;

      final model = _jsonToModel(jsonData, projectDir);
      debugPrint('✓ Project loaded successfully');
      return model;
    } catch (e) {
      debugPrint('ERROR loading project: $e');
      return null;
    }
  }

  /// Get list of all project folders
  static Future<List<Directory>> listProjects() async {
    try {
      final projectsDir = await StorageService.getProjectsFolder();
      if (projectsDir == null || !await projectsDir.exists()) {
        return [];
      }

      final entries = projectsDir.listSync();
      return entries
          .whereType<Directory>()
          .where((d) => !d.path.endsWith('.'))
          .where((d) => path_lib.basename(d.path) != autoSaveName) // Hide autosave slot
          .toList();
    } catch (e) {
      debugPrint('Error listing projects: $e');
      return [];
    }
  }

  /// Get project name from directory path
  static String getProjectName(Directory projectDir) {
    return path_lib.basename(projectDir.path);
  }

  // ==================== Private Helpers ====================

  /// Convert TrackerModel to JSON-serializable map
  /// Stores just filenames for samples to make projects portable
  static Map<String, dynamic> _modelToJson(TrackerModel model) {
    return {
      'version': 1,
      'created': DateTime.now().toIso8601String(),
      'projectName': model.currentProjectName,
      'bpm': model.song.bpm,
      'lpb': model.song.lpb,
      'swingPercent': model.song.swingPercent,
      'chains': [
        for (int i = 0; i < model.song.chains.length; i++)
          List<int>.from(model.song.chains[i])
      ],
      'chainData': [
        for (final chain in model.chains)
          [
            for (final item in chain.items)
              {
                'phrase': item.phrase,
                'transpose': item.transpose,
                'fx': [
                  for (final fx in item.fx)
                    {'name': fx.name, 'value': fx.value}
                ],
              }
          ]
      ],
      'phrases': [
        for (final phrase in model.phrases)
          [
            for (final step in phrase.steps)
              {
                'note': step.note,
                'instrument': step.instrument,
                'volume': step.volume,
                'fx': [
                  for (final fx in step.fx)
                    {'name': fx.name, 'value': fx.value}
                ],
              }
          ]
      ],
      'instruments': [
        for (final inst in model.instruments)
          {
            'filter': inst.filter,
            'resonance': inst.resonance,
            'treble': inst.treble,
            'mid': inst.mid,
            'bass': inst.bass,
            'sample': inst.sample.isNotEmpty ? path_lib.basename(inst.sample) : '',
            'sampler': _samplerToJson(inst.sampler),
          }
      ],
      'mixerChannels': [
        for (final channel in model.mixerChannels)
          {
            'level': channel.level,
            'reverbSend': channel.reverbSend,
            'delaySend': channel.delaySend,
            'chorusSend': channel.chorusSend,
          }
      ],
      'mutedTracks':  model.mutedTracks.toList(),
      'soloedTracks': model.soloedTracks.toList(),
      'masterFx': {
        'reverbSize':        model.masterFx.reverbSize,
        'reverbDamp':        model.masterFx.reverbDamp,
        'reverbWidth':       model.masterFx.reverbWidth,
        'delayLines':        model.masterFx.delayLines,
        'delayFeedback':     model.masterFx.delayFeedback,
        'chorusRate':        model.masterFx.chorusRate,
        'chorusDepth':       model.masterFx.chorusDepth,
        'eqBand1':           model.masterFx.eqBand1,
        'eqBand2':           model.masterFx.eqBand2,
        'eqBand3':           model.masterFx.eqBand3,
        'eqBand4':           model.masterFx.eqBand4,
        'eqBand5':           model.masterFx.eqBand5,
        'hpFreq':            model.masterFx.hpFreq,
        'hpRes':             model.masterFx.hpRes,
        'lpFreq':            model.masterFx.lpFreq,
        'lpRes':             model.masterFx.lpRes,
        'limiterThreshold':  model.masterFx.limiterThreshold,
        'masterVolume':      model.masterFx.masterVolume,
      },
    };
  }

  /// Convert JSON map back to TrackerModel
  /// Resolves sample filenames to project folder paths
  static TrackerModel _jsonToModel(Map<String, dynamic> json, [Directory? projectDir]) {
    final model = TrackerModel();
    final samplesDir = projectDir != null
        ? path_lib.join(projectDir.path, samplesFolder)
        : '';

    // Load BPM / LPB / Swing
    model.song.bpm = json['bpm'] as int? ?? 120;
    model.song.lpb = (json['lpb'] as int? ?? 4).clamp(1, 12);
    model.song.swingPercent = (json['swingPercent'] as int? ?? 50).clamp(50, 75);

    // Load master FX settings (gracefully defaults if absent — old projects)
    if (json['masterFx'] is Map) {
      final fx = json['masterFx'] as Map;
      double d(String k, double def) => (fx[k] as num?)?.toDouble() ?? def;
      int    i2(String k, int    def) => (fx[k] as int?)  ?? def;
      model.masterFx.reverbSize       = d('reverbSize',       0.5).clamp(0.0, 1.0);
      model.masterFx.reverbDamp       = d('reverbDamp',       0.5).clamp(0.0, 1.0);
      model.masterFx.reverbWidth      = d('reverbWidth',      1.0).clamp(0.0, 1.0);
      model.masterFx.delayLines       = i2('delayLines',      50).clamp(0, 99);
      model.masterFx.delayFeedback    = d('delayFeedback',    0.4).clamp(0.0, 1.0);
      model.masterFx.chorusRate       = d('chorusRate',       1.0).clamp(0.1, 5.0);
      model.masterFx.chorusDepth      = d('chorusDepth',      0.5).clamp(0.0, 1.0);
      model.masterFx.eqBand1         = d('eqBand1',          0.0).clamp(-12.0, 12.0);
      model.masterFx.eqBand2         = d('eqBand2',          0.0).clamp(-12.0, 12.0);
      model.masterFx.eqBand3         = d('eqBand3',          0.0).clamp(-12.0, 12.0);
      model.masterFx.eqBand4         = d('eqBand4',          0.0).clamp(-12.0, 12.0);
      model.masterFx.eqBand5         = d('eqBand5',          0.0).clamp(-12.0, 12.0);
      model.masterFx.hpFreq           = d('hpFreq',           20.0).clamp(20.0, 1000.0);
      model.masterFx.hpRes            = d('hpRes',            0.5).clamp(0.0, 1.0);
      model.masterFx.lpFreq           = d('lpFreq',       20000.0).clamp(1000.0, 20000.0);
      model.masterFx.lpRes            = d('lpRes',            0.5).clamp(0.0, 1.0);
      model.masterFx.limiterThreshold = d('limiterThreshold', 0.0).clamp(0.0, 12.0);
      model.masterFx.masterVolume     = d('masterVolume',     0.8).clamp(0.0, 1.0);
    }

    // Load chains (song grid — which chain each song row/track references)
    if (json['chains'] is List) {
      for (int i = 0; i < (json['chains'] as List).length && i < 99; i++) {
        final chainData = (json['chains'] as List)[i] as List?;
        if (chainData != null) {
          for (int j = 0; j < chainData.length && j < 8; j++) {
            model.song.chains[i][j] = (chainData[j] as int?) ?? 0;
          }
        }
      }
    }

    // Load chain item data (phrase slots, transpose, fx)
    if (json['chainData'] is List) {
      final chainDataList = json['chainData'] as List;
      for (int c = 0; c < chainDataList.length && c < 99; c++) {
        final items = chainDataList[c] as List?;
        if (items == null) continue;
        for (int r = 0; r < items.length && r < 99; r++) {
          final itemData = items[r] as Map<String, dynamic>?;
          if (itemData == null) continue;
          model.chains[c].items[r].phrase    = itemData['phrase']    as int? ?? 0;
          model.chains[c].items[r].transpose = itemData['transpose'] as int? ?? 0;
          if (itemData['fx'] is List) {
            final fxList = itemData['fx'] as List;
            for (int f = 0; f < fxList.length && f < 2; f++) {
              final fxData = fxList[f] as Map<String, dynamic>?;
              if (fxData != null) {
                model.chains[c].items[r].fx[f].name  = fxData['name']  as String? ?? '---';
                model.chains[c].items[r].fx[f].value = fxData['value'] as int?    ?? 0;
              }
            }
          }
        }
      }
    }

    // Load phrases
    if (json['phrases'] is List) {
      for (int p = 0; p < (json['phrases'] as List).length && p < 99; p++) {
        final phraseData = (json['phrases'] as List)[p] as List?;
        if (phraseData != null) {
          for (int s = 0; s < phraseData.length && s < 99; s++) {
            final stepData = phraseData[s] as Map<String, dynamic>?;
            if (stepData != null) {
              model.phrases[p].steps[s].note = stepData['note'] as int? ?? -1;
              model.phrases[p].steps[s].instrument =
                  stepData['instrument'] as int? ?? 0;
              model.phrases[p].steps[s].volume = stepData['volume'] as int? ?? 80;

              if (stepData['fx'] is List) {
                for (int f = 0; f < (stepData['fx'] as List).length && f < 3; f++) {
                  final fxData = (stepData['fx'] as List)[f] as Map<String, dynamic>?;
                  if (fxData != null) {
                    model.phrases[p].steps[s].fx[f].name =
                        fxData['name'] as String? ?? '---';
                    model.phrases[p].steps[s].fx[f].value =
                        fxData['value'] as int? ?? 0;
                  }
                }
              }
            }
          }
          // If the phrase has no real notes (saved before END-default was added),
          // restore the END marker at row 17 (index 16).
          final hasRealNote = model.phrases[p].steps.any(
            (s) => s.note != PhraseStep.noteNone && s.note != PhraseStep.noteEnd,
          );
          if (!hasRealNote) {
            model.phrases[p].steps[16].note = PhraseStep.noteEnd;
          }
        }
      }
    }

    // Load instruments
    if (json['instruments'] is List) {
      for (int i = 0; i < (json['instruments'] as List).length && i < 99; i++) {
        final instData = (json['instruments'] as List)[i] as Map<String, dynamic>?;
        if (instData != null) {
          model.instruments[i].filter = instData['filter'] as int? ?? 70;
          model.instruments[i].resonance = instData['resonance'] as int? ?? 20;
          model.instruments[i].treble = instData['treble'] as int? ?? 0;
          model.instruments[i].mid = instData['mid'] as int? ?? 0;
          model.instruments[i].bass = instData['bass'] as int? ?? 0;
          
          // Resolve sample filename to project folder path
          final sampleFilename = instData['sample'] as String? ?? '';
          if (sampleFilename.isNotEmpty && samplesDir.isNotEmpty) {
            model.instruments[i].sample = path_lib.join(samplesDir, sampleFilename);
          } else {
            model.instruments[i].sample = sampleFilename;
          }

          if (instData['sampler'] is Map) {
            model.instruments[i].sampler =
                _jsonToSampler(instData['sampler'] as Map<String, dynamic>, samplesDir);
          }
          // Sync sampler.samplePath from inst.sample if missing (old project format)
          final sp = model.instruments[i].sampler.samplePath;
          if ((sp == null || sp.isEmpty) && model.instruments[i].sample.isNotEmpty) {
            final raw = model.instruments[i].sample;
            model.instruments[i].sampler.samplePath = raw;
            model.instruments[i].sampler.sampleName = path_lib.basename(raw);
          }
        }
      }
    }

    // Restore project name: prefer the name stored inside the JSON (so autosave
    // shows the real project name, not '__AUTOSAVE__').
    final storedName = json['projectName'] as String?;
    if (storedName != null && storedName.isNotEmpty && storedName != autoSaveName) {
      model.currentProjectName = storedName;
    } else if (projectDir != null) {
      final dirName = path_lib.basename(projectDir.path);
      if (dirName != autoSaveName) model.currentProjectName = dirName;
    }
    if (projectDir != null) {
      model.currentProjectPath = projectDir.path;
    }

    // Load mixer channels
    if (json['mixerChannels'] is List) {
      for (int i = 0; i < (json['mixerChannels'] as List).length && i < 8; i++) {
        final chData = (json['mixerChannels'] as List)[i] as Map<String, dynamic>?;
        if (chData != null) {
          model.mixerChannels[i].level = chData['level'] as int? ?? 80;
          model.mixerChannels[i].reverbSend =
              chData['reverbSend'] as int? ?? 0;
          model.mixerChannels[i].delaySend =
              chData['delaySend'] as int? ?? 0;
          model.mixerChannels[i].chorusSend =
              chData['chorusSend'] as int? ?? 0;
        }
      }
    }

    if (json['mutedTracks'] is List) {
      for (final v in json['mutedTracks'] as List) {
        final i = (v as num?)?.toInt();
        if (i != null && i >= 0 && i < 8) model.mutedTracks.add(i);
      }
    }
    if (json['soloedTracks'] is List) {
      for (final v in json['soloedTracks'] as List) {
        final i = (v as num?)?.toInt();
        if (i != null && i >= 0 && i < 8) model.soloedTracks.add(i);
      }
    }

    return model;
  }

  /// Convert SamplerParams to JSON
  /// Stores just filenames for samples to make projects portable
  static Map<String, dynamic> _samplerToJson(dynamic sampler) {
    // This is a reference to SamplerParams
    return {
      'sampleName': sampler.sampleName,
      'samplePath': sampler.samplePath != null && sampler.samplePath.isNotEmpty 
        ? path_lib.basename(sampler.samplePath) 
        : '',
      'pitch': sampler.pitch,
      'volume': sampler.volume,
      'start': sampler.start,
      'end': sampler.end,
      'attack': sampler.attack,
      'release': sampler.release,
      'loopMode': sampler.loopMode,
      'sliceStarts': List<int>.from(sampler.sliceStarts),
      'stretchEnabled': sampler.stretchEnabled,
      'stretchLines': sampler.stretchLines,
      'stretchPreservePitch': sampler.stretchPreservePitch,
      'modSend': sampler.modSend,
      'delSend': sampler.delSend,
      'revSend': sampler.revSend,
      'lpCutoff': sampler.lpCutoff,
      'hpCutoff': sampler.hpCutoff,
    };
  }

  /// Convert JSON to SamplerParams
  /// Resolves sample filename to project folder path
  static SamplerParams _jsonToSampler(Map<String, dynamic> json, [String? samplesDir]) {
    final sampler = SamplerParams.empty();
    
    sampler.sampleName = json['sampleName'] as String?;
    
    // Resolve samplePath filename to project folder if we have samplesDir
    final samplePathStr = json['samplePath'] as String?;
    if (samplePathStr != null && samplePathStr.isNotEmpty && samplesDir != null && samplesDir.isNotEmpty) {
      final filename = path_lib.basename(samplePathStr);
      sampler.samplePath = path_lib.join(samplesDir, filename);
    } else {
      sampler.samplePath = samplePathStr;
    }
    
    sampler.pitch = (json['pitch'] as num?)?.toDouble() ?? 0.0;
    sampler.volume = (json['volume'] as num?)?.toDouble() ?? 0.9;
    sampler.start = (json['start'] as num?)?.toDouble() ?? 0.0;
    sampler.end = (json['end'] as num?)?.toDouble() ?? 1.0;
    sampler.attack = (json['attack'] as num?)?.toDouble() ?? 0.0;
    sampler.release = (json['release'] as num?)?.toDouble() ?? 0.05;
    sampler.loopMode = json['loopMode'] as int? ?? 0;
    
    if (json['sliceStarts'] is List) {
      sampler.sliceStarts = List<int>.from(
        (json['sliceStarts'] as List).map((x) => (x as num?)?.toInt() ?? 0),
      );
    }
    
    sampler.stretchEnabled = json['stretchEnabled'] as bool? ?? false;
    sampler.stretchLines = json['stretchLines'] as int? ?? 16;
    sampler.stretchPreservePitch = json['stretchPreservePitch'] as bool? ?? true;
    sampler.modSend = (json['modSend'] as num?)?.toDouble() ?? 0.0;
    sampler.delSend = (json['delSend'] as num?)?.toDouble() ?? 0.0;
    sampler.revSend = (json['revSend'] as num?)?.toDouble() ?? 0.0;
    sampler.lpCutoff = (json['lpCutoff'] as num?)?.toDouble() ?? 1.0;
    sampler.hpCutoff = (json['hpCutoff'] as num?)?.toDouble() ?? 0.0;
    
    return sampler;
  }

  /// Get list of all samples in use across all instruments (including sampler samples)
  static List<String> _getSamplesInUse(TrackerModel model) {
    final samples = <String>{};
    for (final instrument in model.instruments) {
      if (instrument.sample.isNotEmpty) {
        samples.add(instrument.sample);
      }
      // Also include samples from the sampler
      if (instrument.sampler.samplePath != null && 
          instrument.sampler.samplePath!.isNotEmpty) {
        samples.add(instrument.sampler.samplePath!);
      }
    }
    return samples.toList();
  }
}
