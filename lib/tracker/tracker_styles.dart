import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

// All tracker text uses VT323 — call trackerStyle() with a size and colour.
TextStyle trackerStyle({
  required double size,
  Color color = Colors.white,
}) =>
    GoogleFonts.vt323(fontSize: size, color: color, height: 1.0);

// Common colour constants
const kGreen  = Colors.green;
const kCyan   = Colors.cyan;
const kBlack  = Colors.black;
const kBg     = Colors.black;
const kBarBg  = Color(0xFF111111);
