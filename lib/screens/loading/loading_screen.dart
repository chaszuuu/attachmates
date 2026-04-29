import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';

class DynamicLoadingScreenDots extends StatefulWidget {
  final List<String> messages;
  final Duration totalDuration;
  final Duration messageInterval;
  final int dotCount;
  final double dotSize;
  final double dotSpacing;
  final Color color;
  final double minOpacity;
  final VoidCallback? onFinish;

  const DynamicLoadingScreenDots({
    super.key,
    required this.messages,
    this.totalDuration = const Duration(seconds: 5),
    this.messageInterval = const Duration(seconds: 1),
    this.dotCount = 5,
    this.dotSize = 24,
    this.dotSpacing = 10,
    this.color = const Color(0xFFB5276A), // your magenta
    this.minOpacity = 0.25,
    this.onFinish,
  });

  @override
  State<DynamicLoadingScreenDots> createState() =>
      _DynamicLoadingScreenDotsState();
}

class _DynamicLoadingScreenDotsState extends State<DynamicLoadingScreenDots>
    with TickerProviderStateMixin {
  late final AnimationController _ctrl;
  late Timer _msgTimer;
  Timer? _finishTimer;
  int _msgIndex = 0;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1800))
      ..repeat();

    _msgTimer = Timer.periodic(widget.messageInterval, (_) {
      setState(() => _msgIndex = (_msgIndex + 1) % widget.messages.length);
    });

    _finishTimer = Timer(widget.totalDuration, () {
      widget.onFinish?.call();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _msgTimer.cancel();
    _finishTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Sliding dots (same vibe as your ProfileVerificationScreen)
                _SlidingDotsInline(
                  controller: _ctrl,
                  count: widget.dotCount,
                  size: widget.dotSize,
                  dotSpacing: widget.dotSpacing,
                  color: widget.color,
                  minOpacity: widget.minOpacity,
                ),
                const SizedBox(height: 20),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: Text(
                    widget.messages[_msgIndex],
                    key: ValueKey(_msgIndex),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 16,
                      color: Colors.black54,
                      height: 1.35,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Inline version of your SlidingDots so this file is standalone.
/// If you already export `SlidingDots` elsewhere, delete this class and import that.
class _SlidingDotsInline extends StatelessWidget {
  final AnimationController controller;
  final int count;
  final double size;
  final double dotSpacing;
  final Color color;
  final double minOpacity;

  const _SlidingDotsInline({
    required this.controller,
    required this.count,
    required this.size,
    required this.dotSpacing,
    required this.color,
    required this.minOpacity,
  });

  @override
  Widget build(BuildContext context) {
    const sigma = 0.45;
    double gaussian(double x) => math.exp(-(x * x) / (2 * sigma * sigma));

    return AnimatedBuilder(
      animation: controller,
      builder: (_, __) {
        final head = controller.value * count;

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(count, (i) {
            double dist = i - head;
            if (dist > count / 2) dist -= count;
            if (dist < -count / 2) dist += count;

            final w = gaussian(dist);
            final opacity = minOpacity + (1 - minOpacity) * w;

            return Padding(
              padding: EdgeInsets.symmetric(horizontal: dotSpacing / 2),
              child: Opacity(
                opacity: opacity,
                child: Container(
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}
