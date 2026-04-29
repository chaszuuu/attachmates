import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 🔽 Shared helpers
import '../../../widgets/quiz/required_badge.dart';
import '../../../widgets/quiz/validation_scroller.dart';
import '../../../widgets/quiz/validation_target.dart';

class AttachmentStylePage1 extends StatefulWidget {
  final List<int?> responses; // global 0..59
  final void Function(int index, int value) onResponseChanged;

  // NEW: validation inputs
  final Set<int>
      invalidIndices; // global indices flagged by parent (0..19 here)
  final bool pulse; // brief attention pulse when validation fails

  const AttachmentStylePage1({
    super.key,
    required this.responses,
    required this.onResponseChanged,
    this.invalidIndices = const {},
    this.pulse = false,
  });

  @override
  State<AttachmentStylePage1> createState() => _AttachmentStylePage1State();
}

class _AttachmentStylePage1State extends State<AttachmentStylePage1>
    with ValidationScroller
    implements ValidationTarget {
  final ScrollController _scrollController = ScrollController();

  // Per-row GlobalKeys so we can jump to the first missing.
  // Page 1 covers global indices 0..19, so we prepare 20 keys in order.
  final List<GlobalKey> _rowKeys =
      List<GlobalKey>.generate(20, (_) => GlobalKey());

  // Persist only this page's 20 answers (global indices 0..19)
  static const String _prefsKey = 'attachment_answers_p1_v1';

  final List<String> _questions = const [
    "I value closeness with my online partner.",
    "I prefer to have meaningful conversations with my online partner.",
    "I meet with my online matches even on a tight schedule if they insist.",
    "I share my personal social media password with my online partner.",
    "Whenever there's a misunderstanding with my online partner, I do not feel the need to sort it out.",
    "I believe that passionate online relationships are volatile and end quickly.",
    "I find myself browsing dating applications for a long period of time, looking at other people's profiles but never swiping right on them.",
    "I use dating apps, but I seldom go on dates.",
    "I believe healthy communication is the key to a happy online relationship.",
    "I compliment my online partner to express positive communication.",
    "I often ask my online partner why they liked me.",
    "I often worry about what my online partner thinks of me.",
    "I do not need to fully commit to an online relationship because it is not a necessity in life.",
    "I tend to look for potential hook-ups rather than intimate relationships using dating applications.",
    "I tend to withdraw myself whenever I feel like my relationship with my partner becomes more serious.",
    "I believe that romantic partners often try to take advantage of each other.",
    "I update my online partner on my whereabouts.",
    "I am considerate of my online partner's time schedule when arranging meetups.",
    "I often make changes about myself to fit my online partner's liking.",
    "I am scared when my online partner does not respond immediately.",
  ];

  static const List<String> _likertWords = [
    "Strongly\nDisagree",
    "Disagree",
    "Slightly\nDisagree",
    "Slightly\nAgree",
    "Agree",
    "Strongly\nAgree",
  ];

  @override
  void initState() {
    super.initState();
    _loadAnswersFromPrefs();
  }

  Future<void> _loadAnswersFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_prefsKey);

    if (stored != null && stored.length == 20) {
      for (int i = 0; i < 20; i++) {
        final s = stored[i];
        if (s != 'null') {
          final v = int.tryParse(s);
          if (v != null && v >= 1 && v <= 6) {
            widget.onResponseChanged(i, v);
          }
        }
      }
      if (mounted) setState(() {});
    }
  }

  Future<void> _saveAnswersToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final slice = List<String>.generate(
      20,
      (i) => widget.responses[i]?.toString() ?? 'null',
    );
    await prefs.setStringList(_prefsKey, slice);
  }

  void _handleChange(int globalIndex, int value) {
    widget.onResponseChanged(globalIndex, value);
    _saveAnswersToPrefs();
  }

  // === ValidationTarget implementation ===
  // Parent passes global invalid indices; for page 1 they’re 0..19.
  @override
  Future<bool> scrollToFirstMissing(Set<int> invalidIndices) async {
    return scrollToFirstInvalid(
      itemKeys: _rowKeys,
      invalidIndices: invalidIndices,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      alignment: 0.08,
    );
  }

  @override
  Widget build(BuildContext context) {
    return _buildPage(_questions, 0); // offset = 0 for page 1
  }

  Widget _buildPage(List<String> questions, int offset) {
    const brand = Color(0xFFB5276A);
    final redSoft = const Color(0xFFFFCDD2);
    final redStrong = const Color(0xFFD32F2F);

    return SingleChildScrollView(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Let's Get to Know You",
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: brand,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            "Answer a few questions to help us match you better (5 / 9)",
            style: TextStyle(fontSize: 14, color: brand),
          ),
          const SizedBox(height: 20),
          const Text(
            "Discover Your Attachment Style - Pt 1",
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: brand,
            ),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: brand.withOpacity(0.08),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              "Each of us has a unique attachment style that can be discovered using the 6-point Likert scale provided. "
              "Choose the response that best reflects your level of agreement.",
              style: TextStyle(
                fontSize: 13,
                color: brand,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Questions
          ...List.generate(questions.length, (i) {
            final globalIndex = i + offset; // 0..19
            final isInvalid = widget.invalidIndices.contains(globalIndex);

            return AnimatedContainer(
              key: _rowKeys[i], // <- per-row key
              duration: const Duration(milliseconds: 180),
              margin: const EdgeInsets.only(bottom: 14),
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  width: isInvalid ? 1.5 : 1.0,
                  color: isInvalid
                      ? (widget.pulse ? redStrong : redSoft)
                      : Colors.grey.shade300,
                ),
                boxShadow: [
                  if (isInvalid && widget.pulse)
                    BoxShadow(
                      color: redStrong.withOpacity(0.12),
                      blurRadius: 10,
                      spreadRadius: 1,
                      offset: const Offset(0, 2),
                    ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header row: number + question + (Required badge if invalid)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          "${globalIndex + 1}. ${questions[i]}",
                          style: const TextStyle(
                            color: brand,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                            height: 1.25,
                          ),
                        ),
                      ),
                      if (isInvalid) const SizedBox(width: 8),
                      if (isInvalid)
                        const RequiredBadge(compact: true, showIcon: true),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // Likert choices
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: List.generate(6, (choiceIdx) {
                      final value = choiceIdx + 1;
                      final selected = widget.responses[globalIndex] == value;

                      return Expanded(
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () => _handleChange(globalIndex, value),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  height: 34,
                                  child: Center(
                                    child: Text(
                                      _likertWords[choiceIdx],
                                      textAlign: TextAlign.center,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 10.5,
                                        height: 1.15,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Radio<int>(
                                  value: value,
                                  groupValue: widget.responses[globalIndex],
                                  onChanged: (v) {
                                    if (v != null)
                                      _handleChange(globalIndex, v);
                                  },
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  visualDensity: const VisualDensity(
                                    horizontal: -2,
                                    vertical: -2,
                                  ),
                                  fillColor:
                                      MaterialStateProperty.resolveWith<Color?>(
                                    (states) =>
                                        states.contains(MaterialState.selected)
                                            ? brand
                                            : Colors.grey,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  "(${value.toString()})",
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 10,
                                    height: 1.0,
                                    color: selected ? brand : Colors.black87,
                                    fontWeight: selected
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }),
                  ),
                ],
              ),
            );
          }),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}
