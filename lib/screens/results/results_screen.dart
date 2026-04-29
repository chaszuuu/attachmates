import 'package:flutter/material.dart';
import 'dart:async';
import '../discover/discover_screen.dart';
import '../../utils/animations.dart';

// ✅ Import only QuizSetupScreen (your class name)
import '../quiz/quiz_retake_modal.dart' show showQuizRetakeModal;
import '../quiz/quiz_screen.dart' show QuizSetupScreen;

class ResultsScreen extends StatefulWidget {
  final Map<String, double> attachmentPercents; // backend 0..1 by category max
  final Map<String, double>
      loveLanguagePercents; // backend 0..1 by category max
  final String finalAttachmentStyle;
  final String finalLoveLanguage;
  final bool showLoading;

  const ResultsScreen({
    super.key,
    required this.attachmentPercents,
    required this.loveLanguagePercents,
    required this.finalAttachmentStyle,
    required this.finalLoveLanguage,
    this.showLoading = true,
  });

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> {
  int _currentPage = 0;
  final PageController _pageController = PageController();
  bool _isLoading = true;

  // Mutable so we can update after a retake
  late String _finalAttachmentStyle;
  late String _finalLoveLanguage;

  // Dominant labels (derived)
  late String _dominantAttachmentStyle;
  late String _dominantLoveLanguage;

  // Normalized (sum to 1.0) for bars (mutable)
  late Map<String, double> _attachmentNorm;
  late Map<String, double> _loveLangNorm;

  // Integer percent labels that sum to 100 exactly (mutable)
  late Map<String, int> _attachmentPct100;
  late Map<String, int> _loveLangPct100;

  @override
  void initState() {
    super.initState();

    _finalAttachmentStyle = widget.finalAttachmentStyle;
    _finalLoveLanguage = widget.finalLoveLanguage;

    _applyResults(
      attachmentPercents: widget.attachmentPercents,
      loveLanguagePercents: widget.loveLanguagePercents,
      finalAttachment: _finalAttachmentStyle,
      finalLoveLang: _finalLoveLanguage,
    );

    if (widget.showLoading) {
      Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _isLoading = false);
      });
    } else {
      _isLoading = false;
    }
  }

  // Mixed detector uses current state
  bool get _isMixed {
    final s = _finalAttachmentStyle.trim().toLowerCase();
    return s == 'mixed' || s == 'invalid';
  }

  // Apply results into local state (used on init and after retake)
  void _applyResults({
    required Map<String, double> attachmentPercents,
    required Map<String, double> loveLanguagePercents,
    required String finalAttachment,
    required String finalLoveLang,
  }) {
    _attachmentNorm = _normalizeToUnity(attachmentPercents);
    _loveLangNorm = _normalizeToUnity(loveLanguagePercents);

    _attachmentPct100 = _percentLabelsSum100(_attachmentNorm);
    _loveLangPct100 = _percentLabelsSum100(_loveLangNorm);

    _dominantAttachmentStyle =
        finalAttachment.isNotEmpty ? finalAttachment : _topKey(_attachmentNorm);

    _dominantLoveLanguage =
        finalLoveLang.isNotEmpty ? finalLoveLang : _topKey(_loveLangNorm);
  }

  // Mixed banner triggers retake modal -> attachment-only retake (via args)
  Widget _retakeBanner() {
    if (!_isMixed) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(top: 12, bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.amber.withOpacity(0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.amber),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "We detected a mixed attachment result.",
            style: TextStyle(fontWeight: FontWeight.w700, color: Colors.white),
          ),
          const SizedBox(height: 6),
          const Text(
            "Retaking the attachment section can help refine your style.",
            style: TextStyle(color: Colors.white),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: const Color(0xFFB5276A),
              ),
              onPressed: () async {
                // 1) Ask user via Mixed-only retake modal
                final ok = await showQuizRetakeModal(context: context);
                if (ok != true) return;

                // 2) Navigate to QUIZ in attachment-only retake mode via route args
                final ret = await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const QuizSetupScreen(),
                    settings: const RouteSettings(
                      arguments: {'retake': true, 'retakeCount': 1},
                    ),
                  ),
                );

                if (!mounted) return;

                // 3) If quiz finished and returned new results, update state
                if (ret is Map && ret['updated'] == true) {
                  final String newFinalAttachment =
                      (ret['finalAttachment'] as String?) ??
                          _finalAttachmentStyle;
                  final String newFinalLove =
                      (ret['finalLoveLang'] as String?) ?? _finalLoveLanguage;

                  final Map<String, double> newAttach =
                      Map<String, double>.from(
                          ret['attachmentPercents'] ?? _attachmentNorm);
                  final Map<String, double> newLove = Map<String, double>.from(
                      ret['lovePercents'] ?? _loveLangNorm);

                  setState(() {
                    _finalAttachmentStyle = newFinalAttachment;
                    _finalLoveLanguage = newFinalLove;
                    _applyResults(
                      attachmentPercents: newAttach,
                      loveLanguagePercents: newLove,
                      finalAttachment: _finalAttachmentStyle,
                      finalLoveLang: _finalLoveLanguage,
                    );
                  });

                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Attachment results updated")),
                  );
                }
              },
              child: const Text("Retake"),
            ),
          ),
        ],
      ),
    );
  }

  // ---- helpers ----

  Map<String, double> _normalizeToUnity(Map<String, double> m) {
    if (m.isEmpty) return {};
    final sum = m.values.fold<double>(0, (a, b) => a + (b.isNaN ? 0 : b));
    if (sum <= 0) {
      // keep key set; all zero
      return {for (final e in m.entries) e.key: 0.0};
    }
    return {for (final e in m.entries) e.key: (e.value / sum).clamp(0.0, 1.0)};
  }

  Map<String, int> _percentLabelsSum100(Map<String, double> normalized) {
    // largest remainder method
    final keys = normalized.keys.toList();
    final doubles = [for (final k in keys) (normalized[k] ?? 0.0) * 100.0];
    final floors = doubles.map((d) => d.floor()).toList();
    int remainder = 100 - floors.fold<int>(0, (a, b) => a + b);

    // indices sorted by fractional part desc
    final idx = List.generate(doubles.length, (i) => i)
      ..sort((i, j) => (doubles[j] - doubles[j].floor())
          .compareTo(doubles[i] - doubles[i].floor()));

    int p = 0;
    while (remainder > 0 && p < idx.length) {
      floors[idx[p]] += 1;
      remainder -= 1;
      p += 1;
    }

    return {for (int i = 0; i < keys.length; i++) keys[i]: floors[i]};
  }

  String _topKey(Map<String, double> m) {
    if (m.isEmpty) return '';
    return m.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  }

  void _nextPage() {
    if (_currentPage < 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOut,
      );
    } else {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const DiscoverScreen()),
      );
    }
  }

  // ---- UI ----

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PageView(
        controller: _pageController,
        physics: _isLoading ? const NeverScrollableScrollPhysics() : null,
        onPageChanged: (page) => setState(() => _currentPage = page),
        children: [
          _isLoading ? _buildLoadingPage() : _buildAttachmentStyleResultPage(),
          _buildLoveLanguageResultPage(),
        ],
      ),
    );
  }

  Widget _buildLoadingPage() {
    return Container(
      color: const Color(0xFFB5276A),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 20.0),
              child: Text(
                'Calculating your\nResults',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            SizedBox(height: 40),
            SizedBox(
              width: 100,
              height: 100,
              child: PixelatedHeartAnimation(
                color: Colors.white,
                size: 100,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAttachmentStyleResultPage() {
    // show descending by normalized values
    final entries = _attachmentNorm.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Container(
      color: const Color(0xFFB5276A),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 40),
              const Text(
                'Your Attachment Style is:',
                style: TextStyle(color: Colors.white, fontSize: 20),
              ),
              const SizedBox(height: 8),
              Text(
                _dominantAttachmentStyle,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                ),
              ),

              // Retake banner if Mixed/Invalid
              _retakeBanner(),

              const SizedBox(height: 16),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: entries
                        .map((e) => _buildProgressRow(
                              label: _prettyAttachmentLabel(e.key),
                              percentageForBar: e.value, // normalized 0..1
                              percentLabelInt: _attachmentPct100[e.key] ??
                                  (e.value * 100).round(),
                              highlight: e.key == _dominantAttachmentStyle,
                            ))
                        .toList(),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.bottomRight,
                child: AnimatedPressable(
                  onPressed: _nextPage,
                  child: Container(
                    width: 50,
                    height: 50,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                    ),
                    child: const Icon(Icons.arrow_forward,
                        color: Color(0xFFB5276A)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _prettyAttachmentLabel(String key) {
    switch (key) {
      case 'Secure':
        return 'Secure Attachment Style';
      case 'Anxious':
        return 'Anxious Attachment Style';
      case 'Avoidant':
        return 'Avoidant Attachment Style';
      case 'Disorganized':
        return 'Disorganized Attachment Style';
      default:
        return key;
    }
  }

  Widget _buildLoveLanguageResultPage() {
    final entries = _loveLangNorm.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Container(
      color: const Color(0xFFB5276A),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 40),
              const Text(
                'Your Love Language is:',
                style: TextStyle(color: Colors.white, fontSize: 20),
              ),
              const SizedBox(height: 8),
              Text(
                _dominantLoveLanguage,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 32),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: entries
                        .map((e) => _buildProgressRow(
                              label: e.key,
                              percentageForBar: e.value, // normalized 0..1
                              percentLabelInt: _loveLangPct100[e.key] ??
                                  (e.value * 100).round(),
                              highlight: e.key == _dominantLoveLanguage,
                            ))
                        .toList(),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: AnimatedPressable(
                  onPressed: _nextPage,
                  child: Container(
                    width: 200,
                    height: 50,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(25),
                    ),
                    child: const Center(
                      child: Text(
                        'Find Matches',
                        style: TextStyle(
                          color: Color(0xFFB5276A),
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProgressRow({
    required String label,
    required double percentageForBar, // 0..1 normalized within section
    required int percentLabelInt, // 0..100 ints that sum to 100
    required bool highlight,
  }) {
    final pctText = '$percentLabelInt%';
    return Padding(
      padding: const EdgeInsets.only(bottom: 24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Label + percentage text on the same line
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: highlight ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                pctText,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.9),
                  fontWeight: highlight ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Bar
          Stack(
            children: [
              Container(
                height: 6,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              AnimatedProgressBar(
                percentage: percentageForBar.clamp(0.0, 1.0),
                color: Colors.white,
                height: 6,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Heart animation (unchanged)
class PixelatedHeartAnimation extends StatefulWidget {
  final Color color;
  final double size;

  const PixelatedHeartAnimation({
    super.key,
    required this.color,
    required this.size,
  });

  @override
  State<PixelatedHeartAnimation> createState() =>
      _PixelatedHeartAnimationState();
}

class _PixelatedHeartAnimationState extends State<PixelatedHeartAnimation>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fillAnimation;

  @override
  void initState() {
    super.initState();
    _controller =
        AnimationController(vsync: this, duration: const Duration(seconds: 2));

    _fillAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );

    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) _controller.reverse();
      if (status == AnimationStatus.dismissed) _controller.forward();
    });

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _fillAnimation,
      builder: (context, child) {
        return CustomPaint(
          size: Size(widget.size, widget.size),
          painter: PixelatedHeartPainter(
            color: widget.color,
            fillPercentage: _fillAnimation.value,
          ),
        );
      },
    );
  }
}

class PixelatedHeartPainter extends CustomPainter {
  final Color color;
  final double fillPercentage;

  PixelatedHeartPainter({
    required this.color,
    required this.fillPercentage,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final outline = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final double pixelSize = size.width / 10;

    final List<List<int>> heartGrid = [
      [0, 0, 1, 1, 0, 0, 1, 1, 0, 0],
      [0, 1, 1, 1, 1, 1, 1, 1, 1, 0],
      [1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
      [1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
      [1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
      [0, 1, 1, 1, 1, 1, 1, 1, 1, 0],
      [0, 0, 1, 1, 1, 1, 1, 1, 0, 0],
      [0, 0, 0, 1, 1, 1, 1, 0, 0, 0],
      [0, 0, 0, 0, 1, 1, 0, 0, 0, 0],
      [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    ];

    int filledRows = (heartGrid.length * fillPercentage).round();

    for (int y = 0; y < heartGrid.length; y++) {
      for (int x = 0; x < heartGrid[y].length; x++) {
        if (heartGrid[y][x] == 1) {
          final Rect pixel =
              Rect.fromLTWH(x * pixelSize, y * pixelSize, pixelSize, pixelSize);
          canvas.drawRect(pixel, outline);

          if (y >= heartGrid.length - filledRows) {
            canvas.drawRect(pixel, fill);
          }
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant PixelatedHeartPainter oldDelegate) {
    return oldDelegate.fillPercentage != fillPercentage;
  }
}

class AnimatedProgressBar extends StatefulWidget {
  final double percentage; // 0..1
  final Color color;
  final double height;

  const AnimatedProgressBar({
    super.key,
    required this.percentage,
    required this.color,
    required this.height,
  });

  @override
  State<AnimatedProgressBar> createState() => _AnimatedProgressBarState();
}

class _AnimatedProgressBarState extends State<AnimatedProgressBar>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900));
    _animation = Tween<double>(begin: 0.0, end: widget.percentage).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );
    _controller.forward();
  }

  @override
  void didUpdateWidget(AnimatedProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.percentage != widget.percentage) {
      _animation =
          Tween<double>(begin: oldWidget.percentage, end: widget.percentage)
              .animate(
        CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
      );
      _controller
        ..reset()
        ..forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return AnimatedBuilder(
          animation: _animation,
          builder: (context, _) {
            return Container(
              height: widget.height,
              width: constraints.maxWidth * _animation.value.clamp(0.0, 1.0),
              decoration: BoxDecoration(
                color: widget.color,
                borderRadius: BorderRadius.circular(widget.height / 2),
              ),
            );
          },
        );
      },
    );
  }
}
