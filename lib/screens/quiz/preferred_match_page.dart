// front_end/lib/screens/quiz/preferred_match_page.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ✅ Shared helpers (global widgets/)
import '../../../widgets/quiz/required_badge.dart';
import '../../../widgets/quiz/validation_scroller.dart';
import '../../../widgets/quiz/validation_target.dart';

class PreferredMatchPage extends StatefulWidget {
  final String?
      selectedPreference; // "Male" | "Female" | "Non-binary" | "Other" | "No Preference"
  final Function(String) onPreferenceChanged;

  // NEW: validation inputs from parent
  final bool
      showRequiredHint; // true when user tried to continue with none selected
  final bool pulse; // brief attention pulse when validation fails

  const PreferredMatchPage({
    super.key,
    required this.selectedPreference,
    required this.onPreferenceChanged,
    this.showRequiredHint = false,
    this.pulse = false,
  });

  @override
  State<PreferredMatchPage> createState() => PreferredMatchPageState();
}

class PreferredMatchPageState extends State<PreferredMatchPage>
    with TickerProviderStateMixin, ValidationScroller
    implements ValidationTarget {
  late AnimationController _maleAnimController;
  late AnimationController _femaleAnimController;
  late AnimationController _nonBinaryAnimController;
  late AnimationController _otherAnimController;
  late AnimationController _noPrefAnimController;

  final GlobalKey _topKey = GlobalKey();
  final ScrollController _scrollController = ScrollController();

  static const _prefsKeyUiLabel = 'preferred_match_v1';
  static const _prefsKeyArray = 'preferred_gender_json';

  static const Color _brand = Color(0xFFB5276A);
  static const Color _redSoft = Color(0xFFFFCDD2);
  static const Color _redStrong = Color(0xFFD32F2F);

  @override
  void initState() {
    super.initState();
    _maleAnimController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 300));
    _femaleAnimController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 300));
    _nonBinaryAnimController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 300));
    _otherAnimController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 300));
    _noPrefAnimController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 300));
    _loadPreferenceFromPrefs();
  }

  @override
  void didUpdateWidget(covariant PreferredMatchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.showRequiredHint && !oldWidget.showRequiredHint) {
      ensureVisibleKey(
        _topKey,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        alignment: 0.02,
      );
    }
  }

  @override
  void dispose() {
    _maleAnimController.dispose();
    _femaleAnimController.dispose();
    _nonBinaryAnimController.dispose();
    _otherAnimController.dispose();
    _noPrefAnimController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Future<bool> scrollToFirstMissing(Set<int> _) async {
    await ensureVisibleKey(
      _topKey,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      alignment: 0.02,
    );
    return true;
  }

  // ✅ UPDATED: "No Preference" now submits as literal "no preference"
  List<String> _preferredListFromUi(String value) {
    switch (value) {
      case 'Male':
        return ['male'];
      case 'Female':
        return ['female'];
      case 'Non-binary':
        return ['nonbinary'];
      case 'Other':
        return ['other'];
      case 'No Preference':
        return ['no preference'];
      default:
        return [];
    }
  }

  // ✅ UPDATED: convert legacy all-gender arrays to "no preference"
  List<String> _normalizePreferredArray(List<String> arr,
      {String? legacyUiLabel}) {
    final s = <String>{for (final v in arr) v.trim().toLowerCase()};

    // Legacy combined label upgrade
    if (legacyUiLabel == 'Non-binary / Other' &&
        s.contains('nonbinary') &&
        !s.contains('other')) {
      s.add('other');
    }

    // Convert legacy arrays containing all genders into "no preference"
    const allGenders = {'male', 'female', 'nonbinary', 'other'};
    if (s.containsAll(allGenders)) {
      return ['no preference'];
    }

    return s.toList();
  }

  Future<void> _loadPreferenceFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final savedUi = prefs.getString(_prefsKeyUiLabel);

    String? upgradedUi = savedUi;
    if (savedUi == 'Non-binary / Other') {
      upgradedUi = 'Non-binary';
      await prefs.setString(_prefsKeyUiLabel, upgradedUi);
    }

    if (upgradedUi != null &&
        upgradedUi.isNotEmpty &&
        upgradedUi != widget.selectedPreference) {
      widget.onPreferenceChanged(upgradedUi);
      if (mounted) setState(() {});
    }

    final arrJson = prefs.getString(_prefsKeyArray);
    if (arrJson == null || arrJson.isEmpty) {
      if (upgradedUi != null && upgradedUi.isNotEmpty) {
        var arr = _preferredListFromUi(upgradedUi);
        if (savedUi == 'Non-binary / Other') {
          arr = _normalizePreferredArray(arr, legacyUiLabel: savedUi);
        }
        await prefs.setString(_prefsKeyArray, jsonEncode(arr));
      }
    } else {
      try {
        final List<dynamic> raw = jsonDecode(arrJson);
        final normalized = _normalizePreferredArray(
          raw.map((e) => e.toString()).toList(),
          legacyUiLabel: savedUi,
        );
        if (jsonEncode(normalized) != arrJson) {
          await prefs.setString(_prefsKeyArray, jsonEncode(normalized));
        }
      } catch (_) {
        if (upgradedUi != null && upgradedUi.isNotEmpty) {
          final arr = _preferredListFromUi(upgradedUi);
          await prefs.setString(_prefsKeyArray, jsonEncode(arr));
        }
      }
    }
  }

  Future<void> _savePreferenceToPrefs(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKeyUiLabel, value);
    final arr = _preferredListFromUi(value);
    await prefs.setString(_prefsKeyArray, jsonEncode(arr));
  }

  void _handleTap(String value) {
    widget.onPreferenceChanged(value);
    _savePreferenceToPrefs(value);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final bool invalid = widget.showRequiredHint ||
        (widget.selectedPreference == null ||
            widget.selectedPreference!.isEmpty);

    return SingleChildScrollView(
      controller: _scrollController,
      child: Padding(
        key: _topKey,
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Let's Get to Know You",
              style: TextStyle(
                  color: _brand, fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              "Answer a few questions to help us match you better (9 / 9)",
              style: TextStyle(color: _brand, fontSize: 14),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    "Preferred Match",
                    style: TextStyle(
                        color: _brand,
                        fontSize: 18,
                        fontWeight: FontWeight.bold),
                  ),
                ),
                if (invalid) const RequiredBadge(compact: true, showIcon: true),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _brand.withOpacity(0.10),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                "Select the gender you're interested in connecting with. "
                "Choose 'No Preference' to be matched with everyone.",
                style: TextStyle(
                    color: _brand, fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 40),
            _buildGenderOption(
              label: "Male",
              icon: Icons.male_rounded,
              value: "Male",
              controller: _maleAnimController,
              delay: 100,
              invalid: invalid,
            ),
            const SizedBox(height: 16),
            _buildGenderOption(
              label: "Female",
              icon: Icons.female_rounded,
              value: "Female",
              controller: _femaleAnimController,
              delay: 200,
              invalid: invalid,
            ),
            const SizedBox(height: 16),
            _buildGenderOption(
              label: "Non-binary",
              icon: Icons.transgender_rounded,
              value: "Non-binary",
              controller: _nonBinaryAnimController,
              delay: 300,
              invalid: invalid,
            ),
            const SizedBox(height: 16),
            _buildGenderOption(
              label: "Other",
              icon: Icons.person_outline,
              value: "Other",
              controller: _otherAnimController,
              delay: 350,
              invalid: invalid,
            ),
            const SizedBox(height: 16),
            _buildGenderOption(
              label: "No Preference",
              icon: Icons.group_rounded,
              value: "No Preference",
              controller: _noPrefAnimController,
              delay: 400,
              invalid: invalid,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGenderOption({
    required String label,
    required IconData icon,
    required String value,
    required AnimationController controller,
    required int delay,
    required bool invalid,
  }) {
    final bool isSelected = widget.selectedPreference == value;

    if (isSelected) {
      controller.forward();
    } else {
      controller.reverse();
    }

    final bool shouldPulse = invalid && widget.pulse && !isSelected;

    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0.0, end: 1.0),
      duration: Duration(milliseconds: 500 + delay),
      curve: Curves.easeOutBack,
      builder: (context, scale, child) {
        return Transform.scale(
          scale: scale,
          child: GestureDetector(
            onTap: () => _handleTap(value),
            child: AnimatedBuilder(
              animation: controller,
              builder: (context, child) {
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  decoration: BoxDecoration(
                    color: isSelected ? _brand : Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isSelected
                          ? _brand
                          : (shouldPulse ? _redStrong : Colors.grey.shade300),
                      width: isSelected ? 2 : (shouldPulse ? 1.2 : 1),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: isSelected
                            ? _brand.withOpacity(0.3)
                            : (shouldPulse
                                ? _redStrong.withOpacity(0.12)
                                : Colors.grey.withOpacity(0.1)),
                        spreadRadius: isSelected ? 1 : (shouldPulse ? 1 : 0),
                        blurRadius: isSelected ? 8 : (shouldPulse ? 10 : 4),
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      const SizedBox(width: 20),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? Colors.white.withOpacity(0.2)
                              : _brand.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          icon,
                          size: 28,
                          color: isSelected ? Colors.white : _brand,
                        ),
                      ),
                      const SizedBox(width: 20),
                      Expanded(
                        child: Text(
                          label,
                          style: TextStyle(
                            color: isSelected ? Colors.white : _brand,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}
