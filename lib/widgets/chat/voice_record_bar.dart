// lib/widgets/chat/voice_record_bar.dart
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import '../../utils/audio_recorder.dart';
import '../../utils/constants.dart';

typedef VoiceSendCallback = Future<void> Function(File file, double durationSec);

class VoiceRecordBar extends StatefulWidget {
  final VoiceSendCallback onSend;

  /// Kept for API compatibility (no-op in this design)
  final double cancelThreshold; // unused now
  final double lockThreshold;   // unused now

  /// Max recording length in seconds (auto-stops & enables send when reached)
  final int maxSeconds;

  const VoiceRecordBar({
    super.key,
    required this.onSend,
    this.cancelThreshold = 120,
    this.lockThreshold = 80,
    this.maxSeconds = 30,
  });

  @override
  State<VoiceRecordBar> createState() => _VoiceRecordBarState();
}

class _VoiceRecordBarState extends State<VoiceRecordBar>
    with SingleTickerProviderStateMixin {
  final _rec = AudioRecorderService();

  Timer? _ticker;
  Duration _elapsed = Duration.zero;
  bool _starting = true;   // show small spinner while starting
  bool _stopping = false;  // prevent double taps
  String? _tmpPath;

  // lightweight waveform animation driver
  late final AnimationController _anim =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
        ..repeat();

  @override
  void initState() {
    super.initState();
    _startRecording();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _anim.dispose();
    _rec.dispose();
    super.dispose();
  }

  Future<void> _startRecording() async {
    setState(() {
      _starting = true;
      _elapsed = Duration.zero;
    });

    try {
      await _rec.start(maxSeconds: widget.maxSeconds);
    } catch (e) {
      if (!mounted) return;
      // If start fails, just close the sheet gracefully.
      Navigator.of(context).maybePop();
      return;
    }

    // tick every 100ms for smooth timer + waveform
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) async {
      if (!mounted) return;
      setState(() {
        _elapsed = Duration(
          milliseconds: (_rec.durationSec * 1000).toInt(),
        );
      });

      // Auto-stop at maxSeconds (recorder may also enforce this)
      if (_elapsed.inSeconds >= widget.maxSeconds && !_stopping) {
        _onTapSend();
      }
    });

    if (mounted) {
      setState(() => _starting = false);
    }
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _onTapDiscard() async {
    if (_stopping) return;
    _stopping = true;
    try {
      await _rec.cancel(_tmpPath);
    } finally {
      if (mounted) Navigator.of(context).maybePop();
    }
  }

  Future<void> _onTapSend() async {
    if (_stopping) return;
    _stopping = true;

    try {
      // ensure we have a path
      final path = await _rec.stop();
      if (path == null) {
        // nothing recorded — just close
        if (mounted) Navigator.of(context).maybePop();
        return;
      }
      _tmpPath = path;

      final file = File(path);
      // FIX: clamp returns num → convert to double
      final dur = _rec.durationSec
          .clamp(0.0, widget.maxSeconds.toDouble())
          .toDouble();
      await widget.onSend(file, dur);

      // clean up temp
      if (file.existsSync()) {
        try {
          file.deleteSync();
        } catch (_) {}
      }
    } finally {
      if (mounted) Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final bg = AppColors.primaryColor;

    return Material(
      color: Colors.white,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(
            left: 12,
            right: 12,
            bottom: MediaQuery.of(context).viewPadding.bottom + 4,
            top: 8,
          ),
          child: Container(
            height: 64,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(32),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.12),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              children: [
                // Trash (discard)
                _RoundIconButton(
                  diameter: 44,
                  bg: Colors.white,
                  icon: Icons.delete_outline,
                  iconColor: Colors.black54,
                  onTap: _onTapDiscard,
                ),
                const SizedBox(width: 10),

                // Waveform + timer
                Expanded(
                  child: Row(
                    children: [
                      // Leading "dots" like the mock → three small white dots
                      const _LeadDots(),
                      const SizedBox(width: 8),
                      // Animated waveform bars
                      Expanded(
                        child: _AnimatedWaveBars(progress: _anim),
                      ),
                      const SizedBox(width: 8),
                      // Timer
                      _starting
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                              ),
                            )
                          : Text(
                              _fmt(_elapsed),
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                              ),
                            ),
                    ],
                  ),
                ),

                const SizedBox(width: 10),

                // Send
                _RoundIconButton(
                  diameter: 44,
                  bg: Colors.white,
                  icon: Icons.arrow_upward_rounded,
                  iconColor: bg,
                  onTap: _onTapSend,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Small rounded white button used for Trash / Send
class _RoundIconButton extends StatelessWidget {
  final double diameter;
  final Color bg;
  final IconData icon;
  final Color iconColor;
  final VoidCallback onTap;

  const _RoundIconButton({
    required this.diameter,
    required this.bg,
    required this.icon,
    required this.iconColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: diameter,
      height: diameter,
      child: Material(
        color: bg,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          splashColor: iconColor.withOpacity(.15),
          highlightColor: Colors.transparent,
          child: Center(
            child: Icon(icon, color: iconColor, size: 22),
          ),
        ),
      ),
    );
  }
}

/// Three small leading dots to match the pill design.
class _LeadDots extends StatelessWidget {
  const _LeadDots();

  @override
  Widget build(BuildContext context) {
    const dot = BoxDecoration(color: Colors.white, shape: BoxShape.circle);
    return SizedBox(
      width: 22,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: const [
          SizedBox(width: 4, height: 4, child: DecoratedBox(decoration: dot)),
          SizedBox(width: 4, height: 4, child: DecoratedBox(decoration: dot)),
          SizedBox(width: 4, height: 4, child: DecoratedBox(decoration: dot)),
        ],
      ),
    );
  }
}

/// Simple animated bars (visual only). Uses an AnimationController that loops.
/// If your recorder exposes decibel/amplitude, you can feed it here instead.
class _AnimatedWaveBars extends StatelessWidget {
  final Animation<double> progress;
  const _AnimatedWaveBars({required this.progress});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: progress,
      builder: (context, _) {
        // Generate a pleasant repeating pattern with sin waves + slight randomness
        final t = progress.value * 2 * pi;
        final rnd = Random(7);
        final bars = List<double>.generate(24, (i) {
          final base = (sin(t + i * .45) + 1) / 2; // 0..1
          final jitter = (rnd.nextDouble() * 0.25);
          // FIX: clamp returns num → convert to double
          final v = ((base * 0.9) + jitter).clamp(0.15, 1.0).toDouble();
          return v;
        });

        return SizedBox(
          height: 28,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: bars
                .map((v) => Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1.2),
                      child: _Bar(heightFactor: v),
                    ))
                .toList(),
          ),
        );
      },
    );
  }
}

class _Bar extends StatelessWidget {
  final double heightFactor; // 0..1
  const _Bar({required this.heightFactor});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.center,
      child: Container(
        width: 3.2,
        height: 6 + 22 * heightFactor, // min 6px, max ~28px
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}
