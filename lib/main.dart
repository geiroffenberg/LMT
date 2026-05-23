import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'tracker/tracker_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);
  runApp(const LMTApp());
}

class LMTApp extends StatelessWidget {
  const LMTApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Little Moby Tracker',
      theme: ThemeData(
        useMaterial3: false,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
      ),
      home: const TrackerScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
