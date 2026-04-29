// lib/widgets/terms_modal.dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/animations.dart';
import '../utils/constants.dart'; // AppColors.primaryColor

const _kPoliciesAcceptedKey = 'policiesAccepted_v2';

// ==============================
// Public API
// ==============================
Future<void> showTermsModal(BuildContext context) async {
  final prefs = await SharedPreferences.getInstance();
  final firstTime = !(prefs.getBool(_kPoliciesAcceptedKey) ?? false);

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withOpacity(0.5),
    isDismissible: !firstTime,
    enableDrag: !firstTime,
    builder: (_) => _PolicySheet(
      title: 'Terms & Privacy',
      primaryColor: AppColors.primaryColor,
      requireScrollToEnd: true,
      acceptText: 'I Agree',
      firstTime: firstTime,
      sections: const [
        _PolicyBlock(
          heading: 'Effective Date – May 13, 2025',
          body:
              'Welcome to AttachMates. By using our app, you agree to these Terms and Conditions. If you do not agree, please discontinue use of the service.',
        ),
        _PolicyBlock(
          heading: 'Eligibility',
          body:
              'You must be at least 18 years old to use AttachMates. By creating an account, you confirm that you are of legal age and capable of forming a binding agreement. Accounts found to belong to minors will be removed.',
        ),
        _PolicyBlock(
          heading: 'User Conduct',
          body:
              'Users must act respectfully toward others. Harassment, impersonation, hate speech, or posting inappropriate content is strictly prohibited. You agree not to use AttachMates for illegal or harmful purposes.',
        ),
        _PolicyBlock(
          heading: 'User Accounts',
          body:
              'You are responsible for maintaining your account security and for all activity under it. Notify AttachMates immediately of unauthorized use.',
        ),
        _PolicyBlock(
          heading: 'Accurate Information',
          body:
              'By creating an account, you agree that all information you provide is true and complete, including your name, gender, orientation, and other profile details.',
        ),
        _PolicyBlock(
          heading: 'Privacy Policy',
          body:
              'Our Privacy Policy explains how we collect, use, and protect your personal information. By using the app, you consent to these practices.',
        ),
        _PolicyBlock(
          heading: 'Data Usage',
          body:
              'We use your data to operate and improve AttachMates, enable matching, enhance safety, and communicate with you. We apply technical and organizational measures to protect your data.',
        ),
        _PolicyBlock(
          heading: 'Information Sharing',
          body:
              'We may share your data with trusted service providers who support our app, with other users where necessary for matching, or when required by law.',
        ),
        _PolicyBlock(
          heading: 'Matching and Content',
          body:
              'AttachMates uses assessments on attachment styles and love languages to suggest compatible matches. Orientation and gender-preference filters help control who appears to you. While these tools enhance compatibility, AttachMates does not guarantee relationship outcomes.',
        ),
        _PolicyBlock(
          heading: 'Periodic Reassessment',
          body:
              'To maintain accurate compatibility results, we may occasionally prompt users to retake assessments or update information to reflect current preferences.',
        ),
        _PolicyBlock(
          heading: 'Content Guidelines',
          body:
              'You are solely responsible for what you post. Content that is unlawful, misleading, discriminatory, harassing, or harmful may be removed. Repeat or severe violations can result in suspension or account termination.',
        ),
        _PolicyBlock(
          heading: 'Safe Match Verification',
          body:
              'AttachMates provides optional verification tools to enhance user safety. Even with these measures, exercise caution when interacting with others or meeting in person.',
        ),
        _PolicyBlock(
          heading: 'Account Suspension or Termination',
          body:
              'We may suspend or terminate your account at our discretion for violations of these terms or any unsafe or inappropriate behavior.',
        ),
        _PolicyBlock(
          heading: 'Limitation of Liability',
          body:
              'AttachMates is provided "as is" without warranties of any kind. We are not responsible for any damages arising from your use of the app or the actions of other users.',
        ),
        _PolicyBlock(
          heading: 'Changes to Terms',
          body:
              'We may update these Terms and Conditions periodically. Continued use after changes take effect means you accept the revised terms.',
        ),
        _PolicyBlock(
          heading: 'Contact Us',
          body:
              'If you have questions about these Terms or our Privacy Policy, contact us at: support@attachmates.app',
        ),
      ],
    ),
  );
}

Future<void> showPrivacyModal(BuildContext context) async {
  final prefs = await SharedPreferences.getInstance();
  final firstTime = !(prefs.getBool(_kPoliciesAcceptedKey) ?? false);

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withOpacity(0.5),
    isDismissible: !firstTime,
    enableDrag: !firstTime,
    builder: (_) => _PolicySheet(
      title: 'Privacy Policy',
      primaryColor: AppColors.primaryColor,
      requireScrollToEnd: true,
      acceptText: 'I Understand',
      firstTime: firstTime,
      sections: const [
        _PolicyBlock(
          heading: 'Effective Date – May 13, 2025',
          body:
              'AttachMates is committed to protecting your privacy. This policy describes how we collect, use, and safeguard your information when you use our app.',
        ),
        _PolicyBlock(
          heading: 'Information We Collect',
          body:
              'We collect data you provide directly, such as your name, email, phone number, photos, and quiz responses, as well as automatically collected information like device type, location (with permission), and app usage.',
        ),
        _PolicyBlock(
          heading: 'How We Use Your Information',
          body:
              'Your information helps us provide and improve AttachMates—enabling matching, personalization, communication, safety, and new features.',
        ),
        _PolicyBlock(
          heading: 'Information Sharing',
          body:
              'We do not sell or rent personal information. We may share limited data with users for matching, or with service providers assisting in operating core functions, and when legally required.',
        ),
        _PolicyBlock(
          heading: 'Data Security',
          body:
              'We follow industry-standard security practices to prevent unauthorized access, alteration, or loss of your data. We continuously improve our safeguards.',
        ),
        _PolicyBlock(
          heading: 'Data Retention',
          body:
              'We keep personal data while your account remains active or as required to provide our services. If you delete your account, we will remove or anonymize your data within a reasonable period.',
        ),
        _PolicyBlock(
          heading: 'Your Rights',
          body:
              'You may access, update, or delete your data and adjust privacy settings—such as visibility or who can contact you—within the app.',
        ),
        _PolicyBlock(
          heading: 'Location Information',
          body:
              'Location data is used to suggest nearby matches. You can disable location access anytime through device settings.',
        ),
        _PolicyBlock(
          heading: 'Cookies and Tracking',
          body:
              'We use cookies and analytics tools to improve your experience and understand app usage. You may control cookie settings on your device.',
        ),
        _PolicyBlock(
          heading: 'Third-Party Services',
          body:
              'The app may link to third-party services or social platforms. Their policies apply to those services, not ours.',
        ),
        _PolicyBlock(
          heading: 'Children\'s Privacy',
          body:
              'AttachMates is for users 18 and older. We do not knowingly collect information from minors. If discovered, such data will be deleted.',
        ),
        _PolicyBlock(
          heading: 'Changes to This Policy',
          body:
              'We may update this Privacy Policy periodically and will notify you of significant changes through the app.',
        ),
        _PolicyBlock(
          heading: 'Contact Us',
          body:
              'For privacy-related inquiries, contact us at: privacy@attachmates.app',
        ),
      ],
    ),
  );
}

// ==============================
// Internal widgets
// ==============================
class _PolicySheet extends StatefulWidget {
  final String title;
  final List<_PolicyBlock> sections;
  final Color primaryColor;
  final bool requireScrollToEnd;
  final String acceptText;
  final bool firstTime; // hide ✕ on first show + lock back

  const _PolicySheet({
    required this.title,
    required this.sections,
    required this.primaryColor,
    this.requireScrollToEnd = false,
    this.acceptText = 'I Understand',
    this.firstTime = false,
  });

  @override
  State<_PolicySheet> createState() => _PolicySheetState();
}

class _PolicySheetState extends State<_PolicySheet> {
  late final ScrollController _sc;
  bool _atBottom = false;

  @override
  void initState() {
    super.initState();
    _sc = ScrollController()..addListener(_onScroll);
  }

  void _onScroll() {
    if (!_sc.hasClients) return;
    final canProceed = _sc.position.pixels >= (_sc.position.maxScrollExtent - 8);
    if (canProceed != _atBottom) setState(() => _atBottom = canProceed);
  }

  @override
  void dispose() {
    _sc.removeListener(_onScroll);
    _sc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    final sheetFactor = h < 700 ? 0.90 : 0.85;

    // OPTION A: Back is fully disabled on first-time, regardless of scroll.
    final canExit = !widget.firstTime;

    return WillPopScope(
      onWillPop: () async => canExit,
      child: FractionallySizedBox(
        heightFactor: sheetFactor,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.12),
                blurRadius: 24,
                offset: const Offset(0, -8),
              ),
            ],
          ),
          child: SafeArea(
            top: false,
            bottom: false,
            child: Column(
              children: [
                // Header
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
                  decoration: BoxDecoration(
                    color: widget.primaryColor,
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(24)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.15),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      const SizedBox(width: 0),
                      Expanded(
                        child: Text(
                          widget.title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      // ✕ Close — completely hidden on first-time
                      if (!widget.firstTime)
                        AnimatedPressable(
                          onPressed: () => Navigator.of(context).maybePop(),
                          child: const Icon(Icons.close, color: Colors.white),
                        ),
                    ],
                  ),
                ),

                // Content (scroll-tracked)
                Expanded(
                  child: Scrollbar(
                    thumbVisibility: true,
                    controller: _sc,
                    child: SingleChildScrollView(
                      controller: _sc,
                      padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final block in widget.sections) ...[
                            if (block.heading.trim().isNotEmpty)
                              _PolicySectionTitle(
                                title: block.heading,
                                color: widget.primaryColor,
                              ),
                            _PolicyParagraph(text: block.body),
                            const SizedBox(height: 6),
                          ],
                          if (widget.requireScrollToEnd) ...[
                            const SizedBox(height: 8),
                            Text(
                              _atBottom
                                  ? 'You’ve reached the end.'
                                  : 'Scroll to the bottom to enable the button.',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: Colors.black.withOpacity(0.55),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),

                // Footer
                Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.08),
                        blurRadius: 8,
                        offset: const Offset(0, -2),
                      ),
                    ],
                  ),
                  child: SafeArea(
                    top: false,
                    bottom: true,
                    minimum: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: widget.requireScrollToEnd && !_atBottom
                            ? null
                            : () => Navigator.of(context).pop(),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: widget.primaryColor,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Text(
                          widget.acceptText,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
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

class _PolicySectionTitle extends StatelessWidget {
  final String title;
  final Color color;
  const _PolicySectionTitle({required this.title, required this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 6),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    );
  }
}

class _PolicyParagraph extends StatelessWidget {
  final String text;
  const _PolicyParagraph({required this.text});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      textAlign: TextAlign.justify,
      style: const TextStyle(
        fontSize: 14,
        height: 1.5,
        color: Colors.black87,
      ),
    );
  }
}

class _PolicyBlock {
  final String heading;
  final String body;
  const _PolicyBlock({required this.heading, required this.body});
}
