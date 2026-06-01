import 'dart:typed_data';

/// Encodes raw audio samples as a WAV file.
class WavEncoder {
  /// Encode mono 32-bit float samples as a WAV file.
  /// Returns the complete WAV file as bytes.
  static Uint8List encodeWav({
    required List<double> samples,
    required int sampleRate,
    int numChannels = 1,
  }) {
    // WAV file format: RIFF header + fmt subchunk + data subchunk
    
    // Convert samples to 16-bit PCM
    final pcmData = _encodePcm16(samples);
    
    final dataSize = pcmData.length;
    final byteRate = sampleRate * numChannels * 2; // 2 bytes per sample (16-bit)
    final blockAlign = numChannels * 2;
    
    // Calculate file size: 36 (RIFF + fmt) + 8 (data chunk header) + data
    final fileSize = 36 + 8 + dataSize;
    
    final bytes = BytesBuilder();
    
    // ── RIFF Header ──────────────────────────────────────────────────────────
    bytes.addByte(0x52); // 'R'
    bytes.addByte(0x49); // 'I'
    bytes.addByte(0x46); // 'F'
    bytes.addByte(0x46); // 'F'
    _addLittleEndian32(bytes, fileSize);
    bytes.addByte(0x57); // 'W'
    bytes.addByte(0x41); // 'A'
    bytes.addByte(0x56); // 'V'
    bytes.addByte(0x45); // 'E'
    
    // ── fmt Subchunk ────────────────────────────────────────────────────────
    bytes.addByte(0x66); // 'f'
    bytes.addByte(0x6D); // 'm'
    bytes.addByte(0x74); // 't'
    bytes.addByte(0x20); // ' '
    _addLittleEndian32(bytes, 16); // Subchunk1Size (16 for PCM)
    _addLittleEndian16(bytes, 1);  // AudioFormat (1 = PCM)
    _addLittleEndian16(bytes, numChannels); // NumChannels
    _addLittleEndian32(bytes, sampleRate); // SampleRate
    _addLittleEndian32(bytes, byteRate); // ByteRate
    _addLittleEndian16(bytes, blockAlign); // BlockAlign
    _addLittleEndian16(bytes, 16); // BitsPerSample
    
    // ── data Subchunk ───────────────────────────────────────────────────────
    bytes.addByte(0x64); // 'd'
    bytes.addByte(0x61); // 'a'
    bytes.addByte(0x74); // 't'
    bytes.addByte(0x61); // 'a'
    _addLittleEndian32(bytes, dataSize); // Subchunk2Size
    
    // Add PCM data
    bytes.add(pcmData);
    
    return bytes.toBytes();
  }
  
  /// Convert 32-bit float samples [-1.0, 1.0] to 16-bit PCM bytes.
  static Uint8List _encodePcm16(List<double> samples) {
    final pcm = BytesBuilder();
    for (final sample in samples) {
      // Clamp to [-1, 1] and convert to 16-bit signed integer
      final clamped = (sample).clamp(-1.0, 1.0);
      final pcmValue = (clamped * 32767).toInt();
      _addLittleEndian16(pcm, pcmValue & 0xFFFF);
    }
    return pcm.toBytes();
  }
  
  static void _addLittleEndian16(BytesBuilder bytes, int value) {
    bytes.addByte(value & 0xFF);
    bytes.addByte((value >> 8) & 0xFF);
  }
  
  static void _addLittleEndian32(BytesBuilder bytes, int value) {
    bytes.addByte(value & 0xFF);
    bytes.addByte((value >> 8) & 0xFF);
    bytes.addByte((value >> 16) & 0xFF);
    bytes.addByte((value >> 24) & 0xFF);
  }
}
