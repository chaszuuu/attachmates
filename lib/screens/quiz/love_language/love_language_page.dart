// front_end/lib/screens/quiz/love_language/love_language_page.dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ✅ Shared helpers (global widgets/)
import '../../../widgets/quiz/required_badge.dart';
import '../../../widgets/quiz/validation_scroller.dart';
import '../../../widgets/quiz/validation_target.dart';

class LoveLanguagePage extends StatefulWidget {
  /// Stores selected option letter per question index (0–29): 'A'..'E'
  final Map<int, String?> responses;
  final Function(int, String) onResponseChanged;

  // NEW: validation inputs from parent
  final Set<int> invalidIndices; // 0..29 unanswered indices
  final bool pulse; // brief attention pulse when validation fails

  const LoveLanguagePage({
    super.key,
    required this.responses,
    required this.onResponseChanged,
    this.invalidIndices = const {},
    this.pulse = false,
  });

  @override
  State<LoveLanguagePage> createState() => _LoveLanguagePageState();
}

class _LoveLanguagePageState extends State<LoveLanguagePage>
    with ValidationScroller
    implements ValidationTarget {
  final ScrollController _scrollController = ScrollController();
  double _scrollProgress = 0.0;

  // Per-question keys (30 questions → 30 keys)
  final List<GlobalKey> _rowKeys =
      List<GlobalKey>.generate(30, (_) => GlobalKey());

  /// SharedPreferences key (bump suffix to _v2 if you change item count/format)
  static const String _prefsKey = 'love_language_responses_v1';

  // Two-option items (letter → statement). Letters must stay exact.
  static const List<Map<String, String>> _questions = [
    {
      "number": "1",
      "A": "I like to receive notes of affirmation from you.",
      "E": "I like it when you hug me."
    },
    {
      "number": "2",
      "B": "I like to spend one-on-one time with you.",
      "D": "I feel loved when you give me practical help."
    },
    {
      "number": "3",
      "C": "I like it when you give me gifts.",
      "B": "I like taking long walks with you."
    },
    {
      "number": "4",
      "D": "I feel loved when you do things to help me.",
      "E": "I feel loved when you hug or touch me."
    },
    {
      "number": "5",
      "E": "I feel loved when you hold me in your arms.",
      "C": "I feel loved when I receive a gift from you."
    },
    {
      "number": "6",
      "B": "I like to go places with you.",
      "E": "I like to hold hands with you."
    },
    {
      "number": "7",
      "A": "I feel loved when you acknowledge me.",
      "C": "Visible symbols of love (gifts) are very important to me."
    },
    {
      "number": "8",
      "E": "I like to sit close to you.",
      "A": "I like it when you tell me that I am attractive."
    },
    {
      "number": "9",
      "B": "I like to spend time with you.",
      "C": "I like to receive little gifts from you."
    },
    {
      "number": "10",
      "D": "I know you love me when you help me.",
      "A": "Your words of acceptance are important to me."
    },
    {
      "number": "11",
      "B": "I like to be together when we do things.",
      "A": "I like the kind words you say to me."
    },
    {
      "number": "12",
      "E": "I feel whole when we hug.",
      "D": "What you do affects me more than what you say."
    },
    {
      "number": "13",
      "A": "I value your praise and try to avoid your criticism.",
      "C":
          "Several inexpensive gifts mean more to me than one large expensive gift."
    },
    {
      "number": "14",
      "E": "I feel closer to you when you touch me.",
      "B": "I feel close when we are talking or doing something together."
    },
    {
      "number": "15",
      "A": "I like you to compliment my achievements.",
      "D":
          "I know you love me when you do things for me that you don't enjoy doing."
    },
    {
      "number": "16",
      "E": "I like for you to touch me when you walk by.",
      "B": "I like when you listen to me sympathetically."
    },
    {
      "number": "17",
      "C": "I really enjoy receiving gifts from you.",
      "D": "I feel loved when you help me with my home projects."
    },
    {
      "number": "18",
      "A": "I like when you compliment my appearance.",
      "B": "I feel loved when you take the time to understand my feelings"
    },
    {
      "number": "19",
      "E": "I feel secure when you are touching me",
      "D": "Your acts of service make me feel loved."
    },
    {
      "number": "20",
      "D": "I appreciate the many things you do for me.",
      "C": "I like receiving gifts that you make."
    },
    {
      "number": "21",
      "B":
          "I really enjoy the feeling I get when you give me your undivided attention.",
      "D":
          "I really enjoy the feeling I get when you do some act of service for me."
    },
    {
      "number": "22",
      "C": "I feel loved when you celebrate my birthday with a gift.",
      "A":
          "I feel loved when you celebrate my birthday with meaningful words (written or spoken.)"
    },
    {
      "number": "23",
      "D": "I feel loved when you help me out with my chores.",
      "C": "I know you are thinking of me when you give me a gift."
    },
    {
      "number": "24",
      "C": "I appreciate it when you remember special days with a gift.",
      "B": "I appreciate it when you listen patiently and don't interrupt me."
    },
    {
      "number": "25",
      "B": "I enjoy extended trips with you",
      "D":
          "I like to know that you are concerned enough to help me with my daily task."
    },
    {
      "number": "26",
      "E": "Kissing me unexpectedly makes me feel loved.",
      "C": "Giving me a gift for no occasion makes me feel loved."
    },
    {
      "number": "27",
      "A": "I like to be told that you appreciate me.",
      "B": "I like for you to look at me when we are talking."
    },
    {
      "number": "28",
      "C": "Your gifts are always special to me.",
      "E": "I feel loved when you kiss me."
    },
    {
      "number": "29",
      "A": "I feel loved when you tell me how much you appreciate me.",
      "D": "I feel loved when you enthusiastically do a task I have requested."
    },
    {
      "number": "30",
      "E": "I need to be hugged by you every day.",
      "A": "I need your words of affirmation daily."
    },
  ];

  static const Map<String, String> _loveLanguages = {
    "A": "A. Words of Affirmation",
    "B": "B. Quality Time",
    "C": "C. Receiving Gifts",
    "D": "D. Acts of Service",
    "E": "E. Physical Touch",
  };

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_updateScrollProgress);
    _loadResponsesFromPrefs(); // ← load saved selections
  }

  // 🔔 Auto-jump when parent updates invalidIndices for this page
  @override
  void didUpdateWidget(covariant LoveLanguagePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.invalidIndices.isNotEmpty &&
        widget.invalidIndices != oldWidget.invalidIndices) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        scrollToFirstMissing(widget.invalidIndices);
      });
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_updateScrollProgress);
    _scrollController.dispose();
    super.dispose();
  }

  // === ValidationTarget ===
  @override
  Future<bool> scrollToFirstMissing(Set<int> invalidIndices) async {
    // here indices are already local (0..29), 1:1 with _rowKeys
    return scrollToFirstInvalid(
      itemKeys: _rowKeys,
      invalidIndices: invalidIndices,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      alignment: 0.08,
    );
  }

  // ────────────────────────────────────────────────────────────────────────────
  // Persistence
  Future<void> _loadResponsesFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_prefsKey);

    if (stored != null && stored.length == _questions.length) {
      for (int i = 0; i < stored.length; i++) {
        final s = stored[i];
        if (s != 'null') {
          final upper = s.toUpperCase();
          if (_loveLanguages.keys.contains(upper)) {
            widget.onResponseChanged(i, upper);
          }
        }
      }
      if (mounted) setState(() {});
    }
  }

  Future<void> _saveResponsesToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final list = List<String>.generate(
      _questions.length,
      (i) => widget.responses[i]?.toString() ?? 'null',
    );
    await prefs.setStringList(_prefsKey, list);
  }

  void _handleChange(int index, String letter) {
    final upper = letter.toUpperCase();
    widget.onResponseChanged(index, upper);
    _saveResponsesToPrefs();
    setState(() {}); // update radio selection immediately
  }
  // ────────────────────────────────────────────────────────────────────────────

  void _updateScrollProgress() {
    if (_scrollController.position.hasPixels &&
        _scrollController.position.maxScrollExtent > 0) {
      setState(() {
        _scrollProgress = _scrollController.offset /
            _scrollController.position.maxScrollExtent;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    const brand = Color(0xFFB5276A);
    final redSoft = const Color(0xFFFFCDD2);
    final redStrong = const Color(0xFFD32F2F);

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            controller: _scrollController,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Let's Get to Know You",
                    style: const TextStyle(
                      color: brand,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "Answer a few questions to help us match you better (8 / 9)",
                    style: const TextStyle(
                      color: brand,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    "The 5 Love Languages Test",
                    style: const TextStyle(
                      color: brand,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: brand.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "Find out how you prefer to give and receive love.",
                          style: const TextStyle(
                            color: brand,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _loveLanguages.values
                              .map(_buildLoveLanguageLabel)
                              .toList(),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 30),

                  // Questions with radios (with validation highlights)
                  for (int i = 0; i < _questions.length; i++)
                    _buildQuestion(
                      index: i,
                      questionData: _questions[i],
                      isInvalid: widget.invalidIndices.contains(i),
                      rowKey: _rowKeys[i],
                      redSoft: redSoft,
                      redStrong: redStrong,
                      brand: brand,
                    ),

                  const SizedBox(height: 30),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLoveLanguageLabel(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFB5276A).withOpacity(0.2),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFFB5276A),
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildQuestion({
    required int index,
    required Map<String, String> questionData,
    required bool isInvalid,
    required GlobalKey rowKey,
    required Color redSoft,
    required Color redStrong,
    required Color brand,
  }) {
    final String questionNumber = questionData["number"] ?? "${index + 1}";
    final optionKeys = questionData.keys.where((k) => k != "number").toList()
      ..sort(); // two options, stable order

    return AnimatedContainer(
      key: rowKey,
      duration: const Duration(milliseconds: 180),
      margin: const EdgeInsets.only(bottom: 16),
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
      child: Stack(
        children: [
          // Content
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header row: Q number only (badge moved to top-right)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Q$questionNumber.",
                    style: TextStyle(
                      color: brand,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // Two options with radios
              for (final key in optionKeys)
                _buildOptionWithRadio(
                  index: index,
                  optionKey: key,
                  optionText: questionData[key] ?? "",
                  brand: brand,
                ),
            ],
          ),

          // Top-right badge when invalid
          if (isInvalid)
            Positioned(
              top: 6,
              right: 6,
              child: RequiredBadge(compact: true, showIcon: true),
            ),
        ],
      ),
    );
  }

  Widget _buildOptionWithRadio({
    required int index,
    required String optionKey,
    required String optionText,
    required Color brand,
  }) {
    final groupValue = widget.responses[index];

    return Padding(
      padding: const EdgeInsets.only(left: 4.0, bottom: 8.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Radio<String>(
            value: optionKey,
            groupValue: groupValue,
            onChanged: (value) {
              if (value != null) _handleChange(index, value);
            },
            fillColor: MaterialStateProperty.resolveWith<Color>(
              (states) =>
                  states.contains(MaterialState.selected) ? brand : Colors.grey,
            ),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 12.0),
              child: Text(
                "$optionKey. $optionText",
                style: TextStyle(color: brand, fontSize: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
