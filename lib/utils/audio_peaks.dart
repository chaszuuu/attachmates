// lib/utils/audio_peaks.dart
import 'dart:math' as math;

/// Downsample live amplitude samples (0..1) into a compact list of bars (0..100).
/// - Uses windowed max pooling + light smoothing so the shape looks natural.
/// - Input can be any length; output length is `bars` (e.g., 64 or 96).
List<int> computePeaksFromSamples(
  List<double> samples, {
  int bars = 64,
  bool smooth = true,
}) {
  if (samples.isEmpty || bars <= 0) return const <int>[];

  // Clamp & sanitize inputs
  final clamped = samples.map((v) {
    if (v.isNaN) return 0.0;
    if (v < 0) return 0.0;
    if (v > 1) return 1.0;
    return v;
  }).toList(growable: false);

  // Windowed max pooling to emphasize transients
  final step = clamped.length / bars;
  final out = List<double>.filled(bars, 0.0, growable: false);

  for (int i = 0; i < bars; i++) {
    final start = (i * step).floor();
    final end = math.min(((i + 1) * step).ceil(), clamped.length);
    double peak = 0.0;
    for (int j = start; j < end; j++) {
      final v = clamped[j];
      if (v > peak) peak = v;
    }
    out[i] = peak;
  }

  // Optional light smoothing (1D gaussian-ish pass)
  if (smooth && out.length >= 3) {
    final sm = List<double>.from(out);
    for (int i = 1; i < out.length - 1; i++) {
      sm[i] = (out[i - 1] * 0.25) + (out[i] * 0.5) + (out[i + 1] * 0.25);
    }
    for (int i = 0; i < out.length; i++) out[i] = sm[i];
  }

  // Normalize with slight gain so quiet notes still show shape
  double maxVal = 0.0001;
  for (final v in out) {
    if (v > maxVal) maxVal = v;
  }
  final gain = maxVal < 0.35 ? (0.35 / maxVal) : 1.0; // gentle auto-gain

  // Convert to 0..100 integers
  return out
      .map((v) => (math.min(1.0, v * gain) * 100).round())
      .toList(growable: false);
}
