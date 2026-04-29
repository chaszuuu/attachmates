// lib/utils/audio_recorder.dart (or wherever you keep it)

import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_sound/flutter_sound.dart';

/// Simple file-recorder wrapper for voice notes.
/// - Records AAC in an .m4a file (good compatibility on Android & iOS)
/// - Tracks elapsed time with a Stopwatch
/// - Safety auto-stop after [maxSeconds]
class AudioRecorderService {
  final FlutterSoundRecorder _rec = FlutterSoundRecorder();
  final Stopwatch _timer = Stopwatch();

  bool _isOpened = false;
  String? _currentPath;
  Timer? _capTimer;

  // ---- Lifecycle ----
  Future<void> _ensureOpened() async {
    if (_isOpened) return;
    await _rec.openRecorder();
    _isOpened = true;
  }

  Future<void> dispose() async {
    _capTimer?.cancel();
    if (_rec.isRecording) {
      await _rec.stopRecorder();
    }
    if (_isOpened) {
      await _rec.closeRecorder();
      _isOpened = false;
    }
  }

  // ---- Paths ----
  Future<String> _newFilePath() async {
    final dir = await getTemporaryDirectory();
    final ts = DateTime.now().millisecondsSinceEpoch;
    return '${dir.path}/voice_$ts.m4a';
  }

  /// Start recording to a temp .m4a and return that path immediately.
  /// Caller should have already requested microphone permission.
  Future<String> start({int maxSeconds = 30}) async {
    await _ensureOpened();

    // If already recording/paused, stop the previous session cleanly.
    if (_rec.isRecording || _rec.isPaused) {
      try {
        await _rec.stopRecorder();
      } catch (_) {}
      _timer
        ..stop()
        ..reset();
      _capTimer?.cancel();
    }

    final path = await _newFilePath();

    await _rec.startRecorder(
      toFile: path,
      codec: Codec.aacMP4, // .m4a (AAC in MP4 container)
      bitRate: 48000,
      sampleRate: 16000,
      numChannels: 1,
    );

    _currentPath = path;
    _timer
      ..reset()
      ..start();

    // Safety cap (auto-stop)
    _capTimer?.cancel();
    _capTimer = Timer(Duration(seconds: maxSeconds), () async {
      if (_rec.isRecording || _rec.isPaused) {
        try {
          await _rec.stopRecorder();
        } catch (_) {}
        _timer.stop();
      }
    });

    return path;
  }

  Future<void> pause() async {
    if (_rec.isRecording) {
      await _rec.pauseRecorder();
      _timer.stop();
    }
  }

  Future<void> resume() async {
    if (_rec.isPaused) {
      await _rec.resumeRecorder();
      _timer.start();
    }
  }

  /// Stops and returns the final file path (falls back to current path if needed).
  Future<String?> stop() async {
    String? path;
    try {
      path = await _rec.stopRecorder(); // may be null on some devices/OSes
    } catch (_) {
      // ignore
    }
    _capTimer?.cancel();
    _timer.stop();
    return path ?? _currentPath;
  }

  /// Cancels the current recording and deletes the file.
  Future<void> cancel([String? path]) async {
    final toDelete = path ?? _currentPath;

    try {
      if (_rec.isRecording || _rec.isPaused) {
        await _rec.stopRecorder();
      }
    } catch (_) {}

    _capTimer?.cancel();
    _timer
      ..stop()
      ..reset();
    _currentPath = null;

    if (toDelete != null) {
      final f = File(toDelete);
      if (await f.exists()) {
        await f.delete();
      }
    }
  }

  // ---- Status/metrics ----
  Future<bool> get isRecording async => _rec.isRecording;
  double get durationSec => _timer.elapsedMilliseconds / 1000.0;
}
