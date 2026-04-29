// lib/screens/auth/phone_input_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart'; // ✅ for token refresh
import '../../utils/animations.dart';
import 'otp_screen.dart';
import '../../utils/constants.dart';

// ✅ use central router directly (no Auth hop)
import '../../services/auth_router.dart';

// ⬇️ NEW: use the real phone auth flow
import '../../services/phone_auth_service.dart';
// ✅ FB-style modal reuse
import '../../widgets/link_account_modal.dart';

class PhoneInputScreen extends StatefulWidget {
  const PhoneInputScreen({super.key});

  @override
  State<PhoneInputScreen> createState() => _PhoneInputScreenState();
}

class _PhoneInputScreenState extends State<PhoneInputScreen>
    with SingleTickerProviderStateMixin {
  final _phoneController = TextEditingController();
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  String _selectedCountryCode = '+63';
  String _selectedCountry = '🇵🇭';

  // Keep latest resend token between attempts (provided by Firebase)
  int? _resendToken;

  // Guard against multiple taps while verifyPhoneNumber is in flight
  bool _sending = false;

  // ⬇️ NSN (national significant number) rules per country (after removing one leading '0')
  // Values are [minLen, maxLen]
  static const Map<String, List<int>> _nsnRules = {
    '+63': [10, 10], // Philippines – mobile: 10 (e.g., 9xx…)
    '+62': [9, 12],  // Indonesia – 9–12
    '+66': [9, 9],   // Thailand – 9
    '+84': [9, 9],   // Vietnam – 9 (mobile; 0 + 9 domestically)
    '+60': [9, 10],  // Malaysia – 9–10
    '+65': [8, 8],   // Singapore – 8
    '+95': [8, 10],  // Myanmar – 8–10
    '+855': [8, 9],  // Cambodia – 8–9
    '+856': [8, 9],  // Laos – 8–9
    '+673': [7, 7],  // Brunei – 7
    '+670': [7, 8],  // Timor-Leste – 7–8
  };

  // Cap local input length (allow one leading 0, so +1 over max to be safe)
  int _maxLocalLen = 12; // default; set based on selected country

  final List<Map<String, String>> _countries = const [
    {'code': '+63', 'country': '🇵🇭', 'name': 'Philippines'},
    {'code': '+62', 'country': '🇮🇩', 'name': 'Indonesia'},
    {'code': '+66', 'country': '🇹🇭', 'name': 'Thailand'},
    {'code': '+84', 'country': '🇻🇳', 'name': 'Vietnam'},
    {'code': '+60', 'country': '🇲🇾', 'name': 'Malaysia'},
    {'code': '+65', 'country': '🇸🇬', 'name': 'Singapore'},
    {'code': '+95', 'country': '🇲🇲', 'name': 'Myanmar'},
    {'code': '+855', 'country': '🇰🇭', 'name': 'Cambodia'},
    {'code': '+856', 'country': '🇱🇦', 'name': 'Laos'},
    {'code': '+673', 'country': '🇧🇳', 'name': 'Brunei'},
    {'code': '+670', 'country': '🇹🇱', 'name': 'Timor-Leste'},
  ];

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeIn),
    );

    _animationController.forward();

    // set initial max length
    _recomputeMaxLenForCountry(_selectedCountryCode);
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _animationController.dispose();
    super.dispose();
  }

  // limit calculator for local (user-entered) number
  void _recomputeMaxLenForCountry(String dialCode) {
    final rule = _nsnRules[dialCode];
    // allow one extra leading 0 in local input
    final localMax = (rule != null ? rule[1] : 12) + 1;
    setState(() => _maxLocalLen = localMax);
  }

  /// Normalize to E.164 (no spaces) – drop a single leading 0 if present
  String _toE164(String dialCode, String local) {
    var n = local.replaceAll(RegExp(r'\s+'), '');
    if (n.startsWith('0')) n = n.substring(1);
    return '$dialCode$n';
  }

  // validate *local* number given selected dial code
  String? _validateLocal(String dialCode, String localRaw) {
    final onlyDigits = localRaw.replaceAll(RegExp(r'\s+'), '');
    if (!RegExp(r'^\d+$').hasMatch(onlyDigits)) {
      return 'Digits only for the phone number';
    }

    // remove a single leading 0 for NSN length check
    final local = onlyDigits.startsWith('0') ? onlyDigits.substring(1) : onlyDigits;

    final rule = _nsnRules[dialCode];
    if (rule == null) {
      // fallback: require 6–12 digits
      if (local.length < 6 || local.length > 12) {
        return 'Enter a valid phone number';
      }
      return null;
    }

    final min = rule[0], max = rule[1];
    if (local.length < min || local.length > max) {
      return 'Enter a valid $min–$max digit mobile number';
    }

    // Country-specific extras
    if (dialCode == '+63') {
      // PH mobile commonly starts with 9 after dropping 0 (e.g., 9xx…)
      if (!local.startsWith('9') || local.length != 10) {
        return 'PH mobile should be 10 digits and start with 9';
      }
    }

    return null;
  }

  Future<void> _handleContinue() async {
    if (_sending) return; // guard against double-taps

    final raw = _phoneController.text.trim();

    if (raw.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Please enter your phone number'),
        backgroundColor: Colors.red,
        duration: Duration(seconds: 2),
      ));
      return;
    }

    final error = _validateLocal(_selectedCountryCode, raw);
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(error),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 2),
      ));
      return;
    }

    // Close keyboard before calling Firebase
    FocusScope.of(context).unfocus();

    final e164 = _toE164(_selectedCountryCode, raw);

    setState(() => _sending = true);
    try {
      await PhoneAuthService.verifyPhoneNumber(
        phoneNumber: e164,
        forceResendingToken: _resendToken,
        onCodeSent: (verificationId, resendToken) {
          _resendToken = resendToken;
          if (!mounted) return;
          Navigator.of(context).push(
            PageRouteBuilder(
              pageBuilder: (context, animation, secondaryAnimation) => OTPScreen(
                phoneNumber: e164,              // show normalized number
                verificationId: verificationId, // pass the verification session
                resendToken: resendToken,       // pass for future resends
              ),
              transitionsBuilder: (context, animation, secondaryAnimation, child) {
                const begin = Offset(1.0, 0.0);
                const end = Offset.zero;
                const curve = Curves.easeInOut;
                final tween = Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
                final offsetAnimation = animation.drive(tween);
                return SlideTransition(position: offsetAnimation, child: child);
              },
              transitionDuration: const Duration(milliseconds: 500),
            ),
          );
        },
        onAutoVerified: () async {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Phone verified automatically'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ));
          // ✅ Directly call central router (no AuthScreen hop)
          try { await FirebaseAuth.instance.currentUser?.getIdToken(true); } catch (_) {}
          await AuthRouter.routeAfterAuth(context);
        },
        onError: (err) async {
          if (!mounted) return;
          if (err.contains('credential-already-in-use')) {
            // 🔔 FB-style confirm modal
            final ok = await showLinkAccountModal(context: context);
            if (ok == true && mounted) {
              // Route with central router as well (no visual hop)
              try { await FirebaseAuth.instance.currentUser?.getIdToken(true); } catch (_) {}
              await AuthRouter.routeAfterAuth(context);
            }
          } else {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(err),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 3),
            ));
          }
        },
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _showCountryPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Container(
          height: 400,
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Select Country',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 20),
              Expanded(
                child: ListView.builder(
                  itemCount: _countries.length,
                  itemBuilder: (context, index) {
                    final country = _countries[index];
                    return ListTile(
                      leading: Text(country['country']!, style: const TextStyle(fontSize: 24)),
                      title: Text(
                        country['name']!,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                      ),
                      trailing: Text(
                        country['code']!,
                        style: const TextStyle(fontSize: 16, color: Colors.grey),
                      ),
                      onTap: () {
                        setState(() {
                          _selectedCountryCode = country['code']!;
                          _selectedCountry = country['country']!;
                          _recomputeMaxLenForCountry(_selectedCountryCode);
                          _phoneController.clear();
                        });
                        Navigator.pop(context);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Main Content with full gradient background
          Container(
            width: double.infinity,
            height: double.infinity,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.white,
                  AppColors.primaryColor,
                  
                ],
              ),
            ),
            child: FadeTransition(
              opacity: _fadeAnimation,
              child: SingleChildScrollView(
                padding: EdgeInsets.only(
                  top: MediaQuery.of(context).padding.top + 80,
                  left: 24,
                  right: 24,
                  bottom: 24,
                ),
                child: Column(
                  children: [
                    const SizedBox(height: 40),
                    // Phone Icon
                    Container(
                      width: 120,
                      height: 120,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.2),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.phone_outlined, size: 60, color: Colors.white),
                    ),
                    const SizedBox(height: 40),
                    // Title
                    const Text(
                      'Enter Phone Number',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    // Description
                    Text(
                      'We\'ll send you a verification code\nto confirm your phone number',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.9),
                        fontSize: 16,
                        height: 1.5,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 40),
                    // Phone Number Input
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.1),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          // Country Code Selector
                          GestureDetector(
                            onTap: _showCountryPicker,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
                              decoration: BoxDecoration(
                                border: Border(
                                  right: BorderSide(color: Colors.grey.shade300, width: 1),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(_selectedCountry, style: const TextStyle(fontSize: 20)),
                                  const SizedBox(width: 8),
                                  Text(
                                    _selectedCountryCode,
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w500,
                                      color: Colors.black87,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  const Icon(Icons.keyboard_arrow_down, color: Colors.grey, size: 20),
                                ],
                              ),
                            ),
                          ),
                          // Phone Number Input
                          Expanded(
                            child: TextField(
                              controller: _phoneController,
                              keyboardType: TextInputType.phone,
                              decoration: const InputDecoration(
                                hintText: 'Phone number',
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.symmetric(vertical: 18, horizontal: 16),
                                hintStyle: TextStyle(color: Colors.grey, fontSize: 16),
                              ),
                              style: const TextStyle(fontSize: 16, color: Colors.black87),
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                                // dynamic local length cap
                                LengthLimitingTextInputFormatter(_maxLocalLen),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 40),
                    // Continue Button (with loading guard)
                    AnimatedPressable(
                      onPressed: _sending ? () {} : _handleContinue,
                      child: Opacity(
                        opacity: _sending ? 0.7 : 1.0,
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          decoration: BoxDecoration(
                            color: const Color(0xFFB5276A),
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.1),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (_sending) ...[
                                const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                  ),
                                ),
                                const SizedBox(width: 12),
                              ],
                              const Text(
                                'Continue',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 30),
                    // Terms Text
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Text(
                        'By continuing, you agree that we may send you SMS messages for verification purposes.',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.8),
                          fontSize: 12,
                          height: 1.4,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Back button positioned at top left
          Positioned(
            top: MediaQuery.of(context).padding.top + 16,
            left: 20,
            child: AnimatedPressable(
              onPressed: _sending ? () {} : () => Navigator.of(context).pop(),
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: _sending ? Colors.white.withOpacity(0.6) : Colors.white,
                    width: 1,
                  ),
                ),
                child: Icon(
                  Icons.chevron_left,
                  color: _sending ? Colors.white.withOpacity(0.8) : Colors.white,
                  size: 28,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
