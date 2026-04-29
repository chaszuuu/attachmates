// front_end/lib/screens/quiz/attachment_style/attachment_style_page3.dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ✅ Shared helpers (global widgets/)
import '../../../widgets/quiz/required_badge.dart';
import '../../../widgets/quiz/validation_scroller.dart';
import '../../../widgets/quiz/validation_target.dart';

class AttachmentStylePage3 extends StatefulWidget {
  final List<int?> responses; // global 0..59
  final void Function(int index, int value) onResponseChanged;

  // NEW: validation inputs from parent
  final Set<int>
      invalidIndices; // global indices flagged by parent (40..59 here)
  final bool pulse; // brief attention pulse when validation fails

  const AttachmentStylePage3({
    super.key,
    required this.responses,
    required this.onResponseChanged,
    this.invalidIndices = const {},
    this.pulse = false,
  });

  @override
  State<AttachmentStylePage3> createState() => _AttachmentStylePage3State();
}

class _AttachmentStylePage3State extends State<AttachmentStylePage3>
    with ValidationScroller
    implements ValidationTarget {
  final ScrollController _scrollController = ScrollController();

  // Persist only this page's 20 answers (global indices 40..59)
  static const String _prefsKey = 'attachment_answers_p3_v1';

  final List<String> _questions = const [
    "I express openness to others' beliefs.",
    "I make an effort to understand the perspective of my online matches.",
    "I always look my best so my online partner finds me attractive.",
    "I can become easily attached to people I meet online and find it difficult to separate myself from them.",
    "I feel uneasy when expressing emotions with my online partner.",
    "I feel uncomfortable when my online partner becomes too emotionally dependent on me.",
    "I often start conflicts with my online partner due to my mood swings.",
    "I demonstrate a fluctuation between being enthusiastic and being nonchalant in conversations with my online partner.",
    "I make them comfortable when we communicate online.",
    "I make sure my online partner has a sense of comfort in our conversation.",
    "I demonstrate a sense of commitment and meaningful conversation with my online partner.",
    "I can tolerate my online partner's negative traits so I can have more dates with them.",
    "I would be hesitant but willing to do risky sexual acts if that is what my online partner wants.",
    "I become anxious when a potential partner I met online does not respond to me.",
    "It's hard for me to commit to romantic online relationships due to my fear of losing my independence.",
    "I avoid sharing too much information about my personal life.",
    "It doesn't bother me when someone ghosts me.",
    "I tend to predict how long an online relationship will last.",
    "I often leave my partner before they leave me.",
    "I believe I would only hurt my partner in a long-term relationship.",
  ];

  static const List<String> _likertWords = [
    "Strongly\nDisagree",
    "Disagree",
    "Slightly\nDisagree",
    "Slightly\nAgree",
    "Agree",
    "Strongly\nAgree",
  ];

  // 🔑 Per-row keys sized from questions length (local indices 0..19)
  late final List<GlobalKey> _rowKeys =
      List<GlobalKey>.generate(_questions.length, (_) => GlobalKey());

  @override
  void initState() {
    super.initState();
    _loadAnswersFromPrefs();
  }

  // 🔔 Auto-jump when parent updates invalidIndices for this page
  @override
  void didUpdateWidget(covariant AttachmentStylePage3 oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.invalidIndices.isNotEmpty &&
        widget.invalidIndices != oldWidget.invalidIndices) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        scrollToFirstMissing(widget.invalidIndices);
      });
    }
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
            final globalIndex = 40 + i; // page 3 offset
            widget.onResponseChanged(globalIndex, v);
          }
        }
      }
      if (mounted) setState(() {});
    }
  }

  Future<void> _saveAnswersToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    // slice global 40..59
    final slice = List<String>.generate(
      20,
      (i) => widget.responses[40 + i]?.toString() ?? 'null',
    );
    await prefs.setStringList(_prefsKey, slice);
  }

  void _handleChange(int globalIndex, int value) {
    widget.onResponseChanged(globalIndex, value);
    _saveAnswersToPrefs();
  }

  // === ValidationTarget ===
  // Parent passes global invalid indices; for page 3 they’re 40..59.
  @override
  Future<bool> scrollToFirstMissing(Set<int> invalidIndices) async {
    // Convert global indices (40..59) → local indices (0..19) to match _rowKeys
    final localInvalid = <int>{};
    for (final gi in invalidIndices) {
      final li = gi - 40;
      if (li >= 0 && li < _rowKeys.length) localInvalid.add(li);
    }

    return scrollToFirstInvalid(
      itemKeys: _rowKeys,
      invalidIndices: localInvalid,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      alignment: 0.08,
    );
  }

  @override
  Widget build(BuildContext context) {
    return _buildPage(_questions, 40);
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
          // --- Header like pages 1 & 2 ---
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
            "Answer a few questions to help us match you better (7 / 9)",
            style: TextStyle(fontSize: 14, color: brand),
          ),
          const SizedBox(height: 20),
          const Text(
            "Discover Your Attachment Style - Pt 3",
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
              "This is the final set of statements for your attachment style assessment. "
              "Choose the response that best matches your level of agreement.",
              style: TextStyle(
                fontSize: 13,
                color: brand,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(height: 24),

          // --- Questions ---
          ...List.generate(questions.length, (i) {
            final globalIndex = i + offset; // 40..59
            final isInvalid = widget.invalidIndices.contains(globalIndex);

            return AnimatedContainer(
              key: _rowKeys[i], // per-row key (local index 0..19)
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
                  // Question + badge
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
                                    (states) => states.contains(
                                      MaterialState.selected,
                                    )
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
