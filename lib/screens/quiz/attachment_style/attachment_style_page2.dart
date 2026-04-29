// front_end/lib/screens/quiz/attachment_style/attachment_style_page2.dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ✅ Shared helpers (global widgets/)
import '../../../widgets/quiz/required_badge.dart';
import '../../../widgets/quiz/validation_scroller.dart';
import '../../../widgets/quiz/validation_target.dart';

class AttachmentStylePage2 extends StatefulWidget implements ValidationTarget {
  final List<int?> responses; // global 0..59
  final void Function(int index, int value) onResponseChanged;

  // NEW: validation inputs from parent
  final Set<int>
      invalidIndices; // global indices flagged by parent (20..39 here)
  final bool pulse; // brief attention pulse when validation fails

  const AttachmentStylePage2({
    super.key,
    required this.responses,
    required this.onResponseChanged,
    this.invalidIndices = const {},
    this.pulse = false,
  });

  // Parent may call this via the State (the real work is in State).
  @override
  Future<bool> scrollToFirstMissing(Set<int> invalidIndices) async {
    // Placeholder; State implements the real logic.
    return false;
  }

  @override
  State<AttachmentStylePage2> createState() => _AttachmentStylePage2State();
}

class _AttachmentStylePage2State extends State<AttachmentStylePage2>
    with ValidationScroller
    implements ValidationTarget {
  final ScrollController _scrollController = ScrollController();

  // Persist only this page's 20 answers (global indices 20..39)
  static const String _prefsKey = 'attachment_answers_p2_v1';

  final List<String> _questions = const [
    "I use dating applications to search for a potential sexual partner only.",
    "I use dating applications primarily to satisfy my sexual needs.",
    "I am confused about my online partner's intentions when they converse with me.",
    "I leave my partner ignored for a long period of time and only reply when it is convenient.",
    "I use clear and concise language to avoid confusion whenever I communicate with my online partner.",
    "I respect the personal boundaries and personal space of my online partner.",
    "I blame myself when online relationships don't work out.",
    "I prefer to be led by my online partner.",
    "I don't have any problem engaging in a one-night stand with people I met online.",
    "I prefer to distance myself from my online partner.",
    "Once I realize I am into my partner, I feel the need to distance myself.",
    "I think it is better for me to be alone.",
    "I maintain respectful communication with my online partner.",
    "I respect opinions and consider others' perspectives.",
    "I feel obliged to make out with people on dating applications if they insist.",
    "Finding an online partner takes priority over everything else in my life.",
    "I handle my problems on my own without seeking support from my online partner.",
    "I find it uncomfortable when my online partner tries to get emotionally close to me.",
    "I fear being in a romantic relationship because of pity.",
    "I think my partner only stays with me out of pity.",
  ];

  static const List<String> _likertWords = [
    "Strongly\nDisagree",
    "Disagree",
    "Slightly\nDisagree",
    "Slightly\nAgree",
    "Agree",
    "Strongly\nAgree",
  ];

  // 🔑 Per-row keys (match questions length; local indices 0..19)
  late final List<GlobalKey> _rowKeys =
      List<GlobalKey>.generate(_questions.length, (_) => GlobalKey());

  @override
  void initState() {
    super.initState();
    _loadAnswersFromPrefs();
  }

  // 🔔 Auto-jump when parent updates invalidIndices for this page
  @override
  void didUpdateWidget(covariant AttachmentStylePage2 oldWidget) {
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
            final globalIndex = 20 + i; // page 2 offset
            widget.onResponseChanged(globalIndex, v);
          }
        }
      }
      if (mounted) setState(() {});
    }
  }

  Future<void> _saveAnswersToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    // slice global 20..39
    final slice = List<String>.generate(
      20,
      (i) => widget.responses[20 + i]?.toString() ?? 'null',
    );
    await prefs.setStringList(_prefsKey, slice);
  }

  void _handleChange(int globalIndex, int value) {
    widget.onResponseChanged(globalIndex, value);
    _saveAnswersToPrefs();
  }

  // === ValidationTarget ===
  // Parent passes global invalid indices; for page 2 they’re 20..39.
  @override
  Future<bool> scrollToFirstMissing(Set<int> invalidIndices) async {
    // Convert global indices (20..39) → local indices (0..19) to match _rowKeys
    final localInvalid = <int>{};
    for (final gi in invalidIndices) {
      final li = gi - 20;
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
    // Page 2 handles global indices 20..39
    return _buildPage(_questions, 20);
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
          // --- Header ---
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
            "Answer a few questions to help us match you better (6 / 9)",
            style: TextStyle(fontSize: 14, color: brand),
          ),
          const SizedBox(height: 20),
          const Text(
            "Discover Your Attachment Style - Pt 2",
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
              "Continue exploring your attachment style with the same 6-point Likert scale. "
              "Choose the option that best reflects your agreement for each statement.",
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
            final globalIndex = i + offset; // 20..39
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
                      final value = choiceIdx + 1; // 1..6
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
