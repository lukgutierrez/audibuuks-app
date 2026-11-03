import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';

/// Sintetizador acústico de notas de piano y arpa clásica con envolvente ADSR real (0% ruido)
class LoFiGeneratorService {
  static double _acousticPianoNote(double freq, double noteAge, double duration) {
    if (noteAge < 0 || noteAge > duration) return 0.0;
    final double attack = (noteAge / 0.035).clamp(0.0, 1.0);
    final double release = ((duration - noteAge) / 0.25).clamp(0.0, 1.0);
    final double decay = exp(-noteAge * 1.65);
    final double env = attack * decay * release;

    final double f1 = sin(2 * pi * freq * noteAge);
    final double f2 = sin(2 * pi * (freq * 2.0) * noteAge) * 0.22 * exp(-noteAge * 2.8);
    final double f3 = sin(2 * pi * (freq * 3.0) * noteAge) * 0.06 * exp(-noteAge * 4.5);
    return (f1 + f2 + f3) * env;
  }

  static Future<String> ensureAmbientTrack(String trackId) async {
    final docDir = await getApplicationDocumentsDirectory();
    final wavFile = File('${docDir.path}/audiomind_classical_${trackId}_v3.wav');
    if (await wavFile.exists() && await wavFile.length() > 40000) {
      return wavFile.path;
    }

    const int sampleRate = 22050;
    const int seconds = 16;
    const int numSamples = sampleRate * seconds;
    const int numChannels = 1;
    const int byteRate = sampleRate * numChannels * 2;
    const int dataSize = numSamples * numChannels * 2;

    final bd = ByteData(44 + dataSize);
    bd.setUint8(0, 0x52);
    bd.setUint8(1, 0x49);
    bd.setUint8(2, 0x46);
    bd.setUint8(3, 0x46);
    bd.setUint32(4, 36 + dataSize, Endian.little);
    bd.setUint8(8, 0x57);
    bd.setUint8(9, 0x41);
    bd.setUint8(10, 0x56);
    bd.setUint8(11, 0x45);
    bd.setUint8(12, 0x66);
    bd.setUint8(13, 0x6D);
    bd.setUint8(14, 0x74);
    bd.setUint8(15, 0x20);
    bd.setUint32(16, 16, Endian.little);
    bd.setUint16(20, 1, Endian.little);
    bd.setUint16(22, numChannels, Endian.little);
    bd.setUint32(24, sampleRate, Endian.little);
    bd.setUint32(28, byteRate, Endian.little);
    bd.setUint16(32, numChannels * 2, Endian.little);
    bd.setUint16(34, 16, Endian.little);
    bd.setUint8(36, 0x64);
    bd.setUint8(37, 0x61);
    bd.setUint8(38, 0x74);
    bd.setUint8(39, 0x61);
    bd.setUint32(40, dataSize, Endian.little);

    List<List<double>> bars;
    if (trackId == 'classical_adagio') {
      bars = [
        [196.00, 246.94, 293.66, 369.99, 293.66, 246.94],
        [146.83, 220.00, 277.18, 329.63, 277.18, 220.00],
        [196.00, 246.94, 293.66, 392.00, 369.99, 293.66],
        [146.83, 220.00, 277.18, 369.99, 329.63, 220.00],
      ];
    } else if (trackId == 'debussy_harp') {
      bars = [
        [261.63, 329.63, 392.00, 493.88, 523.25, 392.00],
        [220.00, 261.63, 329.63, 392.00, 440.00, 329.63],
        [174.61, 220.00, 261.63, 349.23, 392.00, 261.63],
        [196.00, 246.94, 293.66, 392.00, 329.63, 246.94],
      ];
    } else if (trackId == 'canon_chamber') {
      bars = [
        [130.81, 196.00, 261.63, 329.63, 261.63, 196.00],
        [196.00, 246.94, 293.66, 392.00, 293.66, 246.94],
        [220.00, 261.63, 329.63, 440.00, 329.63, 261.63],
        [174.61, 220.00, 261.63, 349.23, 261.63, 220.00],
      ];
    } else {
      bars = [
        [220.00, 329.63, 440.00, 493.88, 523.25, 440.00],
        [174.61, 261.63, 349.23, 440.00, 392.00, 349.23],
        [261.63, 329.63, 392.00, 523.25, 493.88, 392.00],
        [196.00, 293.66, 392.00, 440.00, 392.00, 293.66],
      ];
    }

    for (int i = 0; i < numSamples; i++) {
      final double t = i / sampleRate;
      final int barIdx = ((t / 4.0).floor()) % bars.length;
      final double barTime = t % 4.0;
      final List<double> notes = bars[barIdx];

      double sample = 0.0;
      sample += _acousticPianoNote(notes[0] * 0.5, barTime, 3.95) * 0.26;

      const double stepSec = 4.0 / 6.0;
      for (int n = 0; n < notes.length; n++) {
        final double noteStart = n * stepSec;
        if (barTime >= noteStart) {
          final double age = barTime - noteStart;
          sample += _acousticPianoNote(notes[n], age, 4.0 - noteStart) * 0.30;
        }
      }

      final double total = sample.clamp(-0.88, 0.88);
      final int pcm = (total * 32767).round();
      bd.setInt16(44 + i * 2, pcm, Endian.little);
    }

    await wavFile.writeAsBytes(bd.buffer.asUint8List());
    return wavFile.path;
  }
}
