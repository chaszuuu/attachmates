// front_end/lib/screens/quiz/quiz_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

// Pages (UI only)
import 'attachment_style/attachment_style_page1.dart';
import 'attachment_style/attachment_style_page2.dart';
import 'attachment_style/attachment_style_page3.dart';
import 'love_language/love_language_page.dart';
import 'preferred_match_page.dart';

import 'quiz_modal.dart';
import '../results/results_screen.dart';
import '../../utils/api_client.dart';

// ✅ Use the shared ValidationTarget interface (do NOT redeclare it here)
import '../../widgets/quiz/validation_target.dart';

class QuizSetupScreen extends StatefulWidget {
  const QuizSetupScreen({super.key});

  @override
  State<QuizSetupScreen> createState() => _QuizSetupScreenState();
}

class _QuizSetupScreenState extends State<QuizSetupScreen> {
  static const Color _brandColor = Color(0xFFB5276A);

  int _currentPage = 0;
  final PageController _pageController = PageController();

  // --- Attachment Style Responses (60 items; 1..6 Likert) ---
  final List<int?> _attachmentResponses = List.filled(60, null);

  // --- Love Language Responses (30 items; 'A'..'E') ---
  final Map<int, String?> _loveLanguageResponses = {};

  // --- Preferred Gender (UI label; normalized on submit) ---
  String? _preferredGender;

  // --- Flow flags (from route args) ---
  bool _retake = false; // Mixed → attachment-only retake
  bool _reassess = false; // Profile → full reassess (cooldown-aware)
  int _retakeCount = 0;
  bool _argsInited = false;

  // --- Validation/highlight state ---
  Set<int> _invalidAttachmentIndices = {};
  Set<int> _invalidLoveIndices = {};
  bool _showValidationPulse = false;

  // --- Child page keys (so we can call scrollToFirstMissing) ---
  final GlobalKey _page1Key = GlobalKey(); // Attachment 0..19
  final GlobalKey _page2Key = GlobalKey(); // Attachment 20..39
  final GlobalKey _page3Key = GlobalKey(); // Attachment 40..59
  final GlobalKey _loveKey = GlobalKey(); // Love Language 0..29
  final GlobalKey _prefKey = GlobalKey(); // Preferred Match page

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_argsInited) return;
    final args = (ModalRoute.of(context)?.settings.arguments as Map?) ?? {};
    _retake = args['retake'] == true;
    _reassess = args['reassess'] == true;
    _retakeCount = (args['retakeCount'] as int?) ?? 0;
    _argsInited = true;
  }

  // ---------- Helpers ----------
  String _normalizePreferredGenderForApi(String? ui) {
    switch ((ui ?? '').trim()) {
      case 'Male':
        return 'male';
      case 'Female':
        return 'female';
      case 'Non-binary / Other':
        return 'nonbinary';
      case 'No Preference':
        return 'any';
      default:
        return '';
    }
  }

  List<int> _attachmentPageRange(int pageIndex) {
    if (pageIndex == 0) return List.generate(20, (i) => i); // 0..19
    if (pageIndex == 1) return List.generate(20, (i) => 20 + i); // 20..39
    if (pageIndex == 2) return List.generate(20, (i) => 40 + i); // 40..59
    return const [];
  }

  Set<int> _findMissingAttachmentForPage(int pageIndex) {
    final range = _attachmentPageRange(pageIndex);
    final missing = <int>{};
    for (final i in range) {
      if (_attachmentResponses[i] == null) missing.add(i);
    }
    return missing;
  }

  Set<int> _findMissingLoveLanguage() {
    final missing = <int>{};
    for (int i = 0; i < 30; i++) {
      final v = _loveLanguageResponses[i];
      if (v == null || v.isEmpty) missing.add(i);
    }
    return missing;
  }

  bool _validateCurrentPageAndMark() {
    switch (_currentPage) {
      case 0:
      case 1:
      case 2:
        _invalidAttachmentIndices = _findMissingAttachmentForPage(_currentPage);
        _invalidLoveIndices = {};
        return _invalidAttachmentIndices.isEmpty;
      case 3:
        _invalidLoveIndices = _findMissingLoveLanguage();
        _invalidAttachmentIndices = {};
        return _invalidLoveIndices.isEmpty;
      case 4:
        _invalidAttachmentIndices = {};
        _invalidLoveIndices = {};
        return _preferredGender != null && _preferredGender!.isNotEmpty;
      default:
        return false;
    }
  }

  void _nudgeValidationPulse() {
    setState(() => _showValidationPulse = true);
    Future.delayed(const Duration(milliseconds: 350), () {
      if (mounted) setState(() => _showValidationPulse = false);
    });
  }

  Future<void> _scrollCurrentPageToFirstMissing() async {
    // Try to call scrollToFirstMissing on the visible page if it implements ValidationTarget.
    ValidationTarget? target;
    Set<int> invalid = const {};

    if (_currentPage == 0) {
      target = _page1Key.currentState is ValidationTarget
          ? _page1Key.currentState as ValidationTarget
          : null;
      invalid = _invalidAttachmentIndices;
    } else if (_currentPage == 1) {
      target = _page2Key.currentState is ValidationTarget
          ? _page2Key.currentState as ValidationTarget
          : null;
      invalid = _invalidAttachmentIndices;
    } else if (_currentPage == 2) {
      target = _page3Key.currentState is ValidationTarget
          ? _page3Key.currentState as ValidationTarget
          : null;
      invalid = _invalidAttachmentIndices;
    } else if (_currentPage == 3) {
      target = _loveKey.currentState is ValidationTarget
          ? _loveKey.currentState as ValidationTarget
          : null;
      invalid = _invalidLoveIndices;
    } else if (_currentPage == 4) {
      // PreferredMatchPage: call its state's helper directly (state exposes the method).
      final state = _prefKey.currentState;
      if (state != null) {
        // Use dynamic to avoid typing the private State class.
        await (state as dynamic).scrollToFirstMissing(<int>{});
      }
      return;
    }

    if (target != null && invalid.isNotEmpty) {
      await target.scrollToFirstMissing(invalid);
    }
  }

  // ---------- Submit: full flow ----------
  Future<void> _handleSubmitAndNavigate() async {
    final result = await showQuizSubmissionModal(
      context: context,
      attachmentResponses: _attachmentResponses,
      loveLanguageResponses: _loveLanguageResponses,
      preferredGender: _normalizePreferredGenderForApi(_preferredGender),
      onSubmitComplete: () {},
      intent: _reassess ? 'profile_reassess' : null,
      cooldownAware: _reassess,
    );

    if (!mounted || result == null) return;

    String finalAttachment = "Secure";
    String finalLoveLang = "Quality Time";
    Map<String, double> attPercents = const {
      'Secure': 0.0,
      'Anxious': 0.0,
      'Avoidant': 0.0,
      'Disorganized': 0.0
    };
    Map<String, double> lovePercents = const {
      'Words of Affirmation': 0.0,
      'Quality Time': 0.0,
      'Receiving Gifts': 0.0,
      'Acts of Service': 0.0,
      'Physical Touch': 0.0,
    };

    try {
      finalAttachment =
          (result['attachment_final'] as String?) ?? finalAttachment;
      if (finalAttachment.toLowerCase() == 'invalid') finalAttachment = 'Mixed';
      finalLoveLang =
          (result['love_language_final'] as String?) ?? finalLoveLang;

      final percents = Map<String, dynamic>.from(result['percents'] ?? {});
      final att = Map<String, dynamic>.from(percents['attachment'] ?? {});
      final llp = Map<String, dynamic>.from(percents['love_language'] ?? {});

      attPercents = {
        'Secure': (att['Secure'] as num?)?.toDouble() ?? 0.0,
        'Anxious': (att['Anxious'] as num?)?.toDouble() ?? 0.0,
        'Avoidant': (att['Avoidant'] as num?)?.toDouble() ?? 0.0,
        'Disorganized': (att['Disorganized'] as num?)?.toDouble() ?? 0.0,
      };
      lovePercents = {
        'Words of Affirmation':
            (llp['Words of Affirmation'] as num?)?.toDouble() ?? 0.0,
        'Quality Time': (llp['Quality Time'] as num?)?.toDouble() ?? 0.0,
        'Receiving Gifts': (llp['Receiving Gifts'] as num?)?.toDouble() ?? 0.0,
        'Acts of Service': (llp['Acts of Service'] as num?)?.toDouble() ?? 0.0,
        'Physical Touch': (llp['Physical Touch'] as num?)?.toDouble() ?? 0.0,
      };
    } catch (_) {}

    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => ResultsScreen(
          attachmentPercents: attPercents,
          loveLanguagePercents: lovePercents,
          finalAttachmentStyle: finalAttachment,
          finalLoveLanguage: finalLoveLang,
          showLoading: true,
        ),
      ),
    );
  }

  // ---------- Submit: attachment-only retake (Mixed) ----------
  List<String> _buildLlAnswersForRetake() {
    if (_loveLanguageResponses.length == 30 &&
        List.generate(30, (i) => _loveLanguageResponses[i])
            .every((r) => r != null && r!.isNotEmpty)) {
      return List.generate(30, (i) => _loveLanguageResponses[i]!.toUpperCase());
    }
    const letters = ['A', 'B', 'C', 'D', 'E'];
    final out = <String>[];
    for (final l in letters) {
      out.addAll(List.filled(6, l));
    }
    return out;
  }

  Map<int, String?> _llListToMap(List<String> ll) {
    final m = <int, String?>{};
    for (int i = 0; i < ll.length; i++) {
      m[i] = ll[i];
    }
    return m;
  }

  Future<void> _submitRetakeAndNavigate() async {
    final attachments = _attachmentResponses.map((e) => e ?? 0).toList();
    if (attachments.any((e) => e == 0)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please complete all attachment items.')),
      );
      return;
    }

    final llAnswers = _buildLlAnswersForRetake();
    final retakeResult = await showQuizSubmissionModal(
      context: context,
      attachmentResponses: _attachmentResponses,
      loveLanguageResponses: _llListToMap(llAnswers),
      preferredGender: _normalizePreferredGenderForApi(_preferredGender),
      onSubmitComplete: () {},
      intent: null,
      cooldownAware: false,
    );

    if (!mounted || retakeResult == null) return;

    String finalAttachment =
        (retakeResult['attachment_final'] as String?) ?? 'Mixed';
    if (finalAttachment.toLowerCase() == 'invalid') finalAttachment = 'Mixed';
    String finalLoveLang =
        (retakeResult['love_language_final'] as String?) ?? 'Quality Time';

    final percents = Map<String, dynamic>.from(retakeResult['percents'] ?? {});
    final att = Map<String, dynamic>.from(percents['attachment'] ?? {});
    final llp = Map<String, dynamic>.from(percents['love_language'] ?? {});
    final attPercents = <String, double>{
      'Secure': (att['Secure'] as num?)?.toDouble() ?? 0.0,
      'Anxious': (att['Anxious'] as num?)?.toDouble() ?? 0.0,
      'Avoidant': (att['Avoidant'] as num?)?.toDouble() ?? 0.0,
      'Disorganized': (att['Disorganized'] as num?)?.toDouble() ?? 0.0,
    };
    final lovePercents = <String, double>{
      'Words of Affirmation':
          (llp['Words of Affirmation'] as num?)?.toDouble() ?? 0.0,
      'Quality Time': (llp['Quality Time'] as num?)?.toDouble() ?? 0.0,
      'Receiving Gifts': (llp['Receiving Gifts'] as num?)?.toDouble() ?? 0.0,
      'Acts of Service': (llp['Acts of Service'] as num?)?.toDouble() ?? 0.0,
      'Physical Touch': (llp['Physical Touch'] as num?)?.toDouble() ?? 0.0,
    };

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => ResultsScreen(
          attachmentPercents: attPercents,
          loveLanguagePercents: lovePercents,
          finalAttachmentStyle: finalAttachment,
          finalLoveLanguage: finalLoveLang,
          showLoading: true,
        ),
      ),
    );
  }

  // ---------- Nav + validation ----------
  void _nextPage() async {
    FocusScope.of(context).unfocus();

    // Validate and mark missing on the current page
    final ok = _validateCurrentPageAndMark();
    if (!ok) {
      setState(() {}); // refresh to show red highlights
      _nudgeValidationPulse(); // brief pulse to draw attention
      await _scrollCurrentPageToFirstMissing(); // smooth jump
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Please answer all highlighted items to continue.')),
      );
      return;
    }

    if (_retake && _currentPage == 2) {
      await _submitRetakeAndNavigate();
      return;
    }

    final lastIndex = _retake ? 2 : 4;
    if (_currentPage < lastIndex) {
      setState(() => _currentPage++);
      _pageController.animateToPage(
        _currentPage,
        duration: const Duration(milliseconds: 300),
        curve: Curves.ease,
      );
    } else {
      await _handleSubmitAndNavigate();
    }
  }

  void _prevPage() {
    if (_currentPage > 0) {
      setState(() => _currentPage--);
      _pageController.animateToPage(
        _currentPage,
        duration: const Duration(milliseconds: 300),
        curve: Curves.ease,
      );
    }
  }

  // (Kept for completeness; we now use _validateCurrentPageAndMark above)
  bool _validateCurrentPageResponses() {
    switch (_currentPage) {
      case 0:
        return _attachmentResponses.sublist(0, 20).every((r) => r != null);
      case 1:
        return _attachmentResponses.sublist(20, 40).every((r) => r != null);
      case 2:
        return _attachmentResponses.sublist(40, 60).every((r) => r != null);
      case 3:
        return List.generate(30, (i) => _loveLanguageResponses[i])
            .every((r) => r != null && r!.isNotEmpty);
      case 4:
        return _preferredGender != null && _preferredGender!.isNotEmpty;
      default:
        return false;
    }
  }

  // ---------- LIVE CLEARING OF INVALID HIGHLIGHTS ----------
  void _onAttachmentResponseChanged(int index, int value) {
    setState(() {
      _attachmentResponses[index] = value;

      // If we're on an attachment page, clear this index from invalids as soon as it's answered.
      if (_currentPage <= 2) {
        final currentRange = _attachmentPageRange(_currentPage);
        if (currentRange.contains(index)) {
          _invalidAttachmentIndices.remove(index);
        }
      }
    });
  }

  void _onLoveLanguageResponseChanged(int index, String value) {
    setState(() {
      _loveLanguageResponses[index] = value.toUpperCase();

      // If we are on the LL page, clear that specific index immediately.
      if (_currentPage == 3) {
        _invalidLoveIndices.remove(index);
      }
    });
  }

  void _onPreferredGenderChanged(String value) {
    setState(() {
      _preferredGender = value;
      // No set needed (single control) — the page will stop showing the "required" hint automatically.
    });
  }

  // ---------- Section label ----------
  String _sectionLabelForPage(int index) {
    if (_retake) {
      // Only 3 pages in retake; all are Attachment Style
      return 'Attachment Style';
    }
    switch (index) {
      case 0:
      case 1:
      case 2:
        return 'Attachment Style';
      case 3:
        return 'Love Language';
      case 4:
        return 'Preferred Gender';
      default:
        return '';
    }
  }

  // ---------- AppBar (inverted, with section name) ----------
  AppBar _buildAppBar() {
    final int total = _retake ? 3 : 5;
    final int step = (_currentPage.clamp(0, total - 1)) + 1;
    final String section = _sectionLabelForPage(_currentPage);

    return AppBar(
      automaticallyImplyLeading: false,
      backgroundColor: _brandColor,
      foregroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 8,
      shadowColor: Colors.black.withOpacity(0.3),
      systemOverlayStyle: const SystemUiOverlayStyle(
        statusBarColor: _brandColor,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
      titleSpacing: 0,
      title: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Text(
                  'AttachMates',
                  style: GoogleFonts.indieFlower(
                    textStyle: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  section,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
            Text(
              'Step $step of $total',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- Bottom chevrons + progress (keyboard-aware, fixed height) ----------
  Widget _buildBottomBar() {
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    final hasKeyboard = viewInsets > 0;

    final int total = _retake ? 3 : 5;
    final double progress = ((_currentPage.clamp(0, total - 1) + 1) / total);

    // Keep the container height fixed (72 normal, 60 with keyboard)
    final double barHeight = hasKeyboard ? 60 : 72;

    return SafeArea(
      top: false,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        height: barHeight,
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.08),
              blurRadius: 10,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Progress bar — pinned to the top inside the bar
            Positioned(
              left: 16,
              right: 16,
              top: hasKeyboard ? 4 : 6,
              height: 6,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return Stack(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.grey.shade200,
                          borderRadius: BorderRadius.circular(100),
                        ),
                      ),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOut,
                        width: constraints.maxWidth * progress,
                        decoration: BoxDecoration(
                          color: _brandColor,
                          borderRadius: BorderRadius.circular(100),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),

            // Chevron row — vertically centered/bottom-aligned without overflow
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, hasKeyboard ? 6 : 10),
                child: SizedBox(
                  height: hasKeyboard ? 46 : 52, // fits inside barHeight
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _currentPage > 0
                          ? IconButton(
                              icon: const Icon(Icons.chevron_left, size: 32),
                              onPressed: _prevPage,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                width: 48,
                                height: 48,
                              ),
                            )
                          : const SizedBox(width: 48, height: 48),
                      IconButton(
                        icon: Icon(
                          (_retake ? (_currentPage < 2) : (_currentPage < 4))
                              ? Icons.chevron_right
                              : Icons.check,
                          size: 32,
                        ),
                        onPressed: _nextPage,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
                          width: 48,
                          height: 48,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- Build ----------
  @override
  Widget build(BuildContext context) {
    final int total = _retake ? 3 : 5;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: _buildAppBar(),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView(
                controller: _pageController,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  AttachmentStylePage1(
                    key: _page1Key,
                    responses: _attachmentResponses,
                    onResponseChanged: _onAttachmentResponseChanged,
                    // NEW: validation inputs
                    invalidIndices: _currentPage == 0
                        ? _invalidAttachmentIndices
                        : const {},
                    pulse: _showValidationPulse,
                  ),
                  AttachmentStylePage2(
                    key: _page2Key,
                    responses: _attachmentResponses,
                    onResponseChanged: _onAttachmentResponseChanged,
                    invalidIndices: _currentPage == 1
                        ? _invalidAttachmentIndices
                        : const {},
                    pulse: _showValidationPulse,
                  ),
                  AttachmentStylePage3(
                    key: _page3Key,
                    responses: _attachmentResponses,
                    onResponseChanged: _onAttachmentResponseChanged,
                    invalidIndices: _currentPage == 2
                        ? _invalidAttachmentIndices
                        : const {},
                    pulse: _showValidationPulse,
                  ),
                  // Full flow pages (ignored in retake but kept in tree)
                  LoveLanguagePage(
                    key: _loveKey,
                    responses: _loveLanguageResponses,
                    onResponseChanged: _onLoveLanguageResponseChanged,
                    invalidIndices:
                        _currentPage == 3 ? _invalidLoveIndices : const {},
                    pulse: _showValidationPulse,
                  ),
                  PreferredMatchPage(
                    key: _prefKey,
                    selectedPreference: _preferredGender,
                    onPreferenceChanged: _onPreferredGenderChanged,
                    showRequiredHint: _currentPage == 4 &&
                        (_preferredGender == null ||
                            _preferredGender!.isNotEmpty == false),
                    pulse: _showValidationPulse,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: _buildBottomBar(),
    );
  }
}
