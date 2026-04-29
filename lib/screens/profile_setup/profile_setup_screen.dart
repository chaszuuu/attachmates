import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'personal_information_page.dart';
import 'interests_page.dart';
import 'liveness_test_page.dart';
import 'id_verification_page.dart';
import 'profile_modal.dart';

class ProfileSetupScreen extends StatefulWidget {
  const ProfileSetupScreen({super.key});

  @override
  State<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends State<ProfileSetupScreen> {
  int _currentPage = 0;
  final PageController _pageController = PageController();
  final GlobalKey<FormState> _personalInfoFormKey = GlobalKey<FormState>();

  Map<String, dynamic> _personalInfo = {};
  List<String> _interests = [];
  File? _livenessImage;
  File? _idFrontImage;
  File? _idBackImage;
  String? _selectedIdType;

  String? _selfieUrl;
  String? _idFrontUrl;
  String? _idBackUrl;

  bool _livenessSubmitted = false;
  bool _idSubmitted = false;

  static const Color _brandColor = Color(0xFFB5276A);

  bool get _isPersonalInfoComplete {
    final m = _personalInfo;
    bool notEmpty(v) => (v is String) ? v.trim().isNotEmpty : (v != null);
    return notEmpty(m['first_name']) &&
        notEmpty(m['last_name']) &&
        notEmpty(m['dob']) &&
        notEmpty(m['gender']);
  }

  bool get _canGoNext {
    switch (_currentPage) {
      case 0:
        return _isPersonalInfoComplete;
      case 1:
        return _interests.length >= 3 && _interests.length <= 10;
      case 2:
        return _livenessSubmitted;
      case 3:
        return _idSubmitted;
      default:
        return true;
    }
  }

  @override
  void initState() {
    super.initState();
    _prewarmIdToken();
  }

  Future<void> _prewarmIdToken() async {
    try {
      final u = FirebaseAuth.instance.currentUser;
      if (u != null) await u.getIdToken(true);
    } catch (_) {}
  }

  Future<void> _nextPage() async {
    FocusScope.of(context).unfocus();

    if (_currentPage == 0 &&
        _personalInfoFormKey.currentState?.validate() != true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please complete all required fields.')),
      );
      return;
    }

    if (_currentPage == 1) {
      if (_interests.length < 3) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pick at least 3 interests.')),
        );
        return;
      }
      if (_interests.length > 10) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pick up to 10 interests.')),
        );
        return;
      }
    }

    if (_currentPage == 2) {
      if (!_livenessSubmitted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please submit your selfie first.')),
        );
        return;
      }
      if (_selfieUrl == null || _selfieUrl!.isEmpty) {
        final prefs = await SharedPreferences.getInstance();
        _selfieUrl = prefs.getString('liveness_selfie_url');
      }
      final hasSelfie = _livenessImage != null ||
          (_selfieUrl != null && _selfieUrl!.isNotEmpty);
      if (!hasSelfie) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please take a selfie to continue.')),
        );
        return;
      }
    }

    if (_currentPage == 3) {
      if (!_idSubmitted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please save your ID first.')),
        );
        return;
      }
      final hasFront = _idFrontImage != null ||
          (_idFrontUrl != null && _idFrontUrl!.isNotEmpty);
      final hasBack = _idBackImage != null ||
          (_idBackUrl != null && _idBackUrl!.isNotEmpty);
      if (!hasFront || !hasBack || _selectedIdType == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please complete the ID verification.')),
        );
        return;
      }
    }

    if (_currentPage < 3) {
      setState(() => _currentPage++);
      _pageController.animateToPage(
        _currentPage,
        duration: const Duration(milliseconds: 300),
        curve: Curves.ease,
      );
    } else {
      _personalInfo = {..._personalInfo, "interests": _interests};
      if (_selfieUrl == null || _selfieUrl!.isEmpty) {
        final prefs = await SharedPreferences.getInstance();
        _selfieUrl = prefs.getString('liveness_selfie_url');
      }

      try {
        await FirebaseAuth.instance.currentUser?.getIdToken(true);
      } catch (_) {}

      showVerificationConfirmationModal(
        context: context,
        personalInfo: _personalInfo,
        livenessImage: _livenessImage,
        idFrontImage: _idFrontImage,
        idBackImage: _idBackImage,
        selectedIdType: _selectedIdType,
        onSubmitComplete: () {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Submitted for review.')),
          );
        },
        selfieUrl: _selfieUrl,
        idFrontUrl: _idFrontUrl,
        idBackUrl: _idBackUrl,
      );
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

  AppBar _buildAppBar() {
    const sections = [
      'Personal Info',
      'Interests',
      'Liveness Test',
      'ID Verification'
    ];
    final total = sections.length;
    final step = _currentPage.clamp(0, total - 1) + 1;
    final section = sections[_currentPage.clamp(0, total - 1)];

    return AppBar(
      automaticallyImplyLeading: false,
      backgroundColor: _brandColor, // 🔹 brand magenta background
      foregroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 8, // 🔹 Stronger elevation
      shadowColor: Colors.black.withOpacity(0.3), // 🔹 More visible contrast
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

  @override
  Widget build(BuildContext context) {
    // progress for bottom bar
    const total = 4;
    final step = _currentPage.clamp(0, total - 1) + 1;
    final progress = step / total;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: _buildAppBar(),
      body: SafeArea(
        child: Container(
          color: Colors.white,
          child: Column(
            children: [
              Expanded(
                child: PageView(
                  controller: _pageController,
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    PersonalInformationPage(
                      formKey: _personalInfoFormKey,
                      onInfoChanged: (info) =>
                          setState(() => _personalInfo = info),
                      initialData: _personalInfo,
                    ),
                    InterestsPage(
                      onInterestsSelected: (list) =>
                          setState(() => _interests = list),
                      minSelect: 3,
                      maxSelect: 10,
                    ),
                    LivenessTestPage(
                      onImageCaptured: (image) => setState(() {
                        _livenessImage = image;
                        _livenessSubmitted = false;
                      }),
                      onSubmittedChanged: (ok) =>
                          setState(() => _livenessSubmitted = ok),
                    ),
                    IdVerificationPage(
                      onFrontImagePicked: (file) => setState(() {
                        _idFrontImage = file;
                        _idSubmitted = false;
                      }),
                      onBackImagePicked: (file) => setState(() {
                        _idBackImage = file;
                        _idSubmitted = false;
                      }),
                      onIdTypeSelected: (type) => setState(() {
                        _selectedIdType = type;
                        _idSubmitted = false;
                      }),
                      onFrontUrlUploaded: (url) =>
                          setState(() => _idFrontUrl = url),
                      onBackUrlUploaded: (url) =>
                          setState(() => _idBackUrl = url),
                      onSubmittedChanged: (ok) =>
                          setState(() => _idSubmitted = ok),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),

      // Bottom nav — keeps 72 height, adds progress at TOP inside bar
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          height: 72, // unchanged
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.08),
                blurRadius: 10,
                offset: const Offset(0, -2), // shadow above
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Progress bar at the very top of the nav bar
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Container(
                  height: 6,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(100),
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return Align(
                        alignment: Alignment.centerLeft,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeOut,
                          height: 6,
                          width: constraints.maxWidth * progress,
                          decoration: BoxDecoration(
                            color: _brandColor,
                            borderRadius: BorderRadius.circular(100),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),

              // Chevron row fills remaining height
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // Left chevron (disabled at first page)
                      IconButton(
                        icon: const Icon(Icons.chevron_left, size: 36),
                        onPressed: _currentPage > 0 ? _prevPage : null,
                      ),
                      // Right chevron
                      IconButton(
                        icon: const Icon(Icons.chevron_right, size: 36),
                        onPressed: _nextPage, // always enabled
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
