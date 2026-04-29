// lib/screens/auth/otp_screen.dart
import 'dart:async';
import 'package:attachmates/utils/constants.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart'; // ✅ for token refresh
import '../../utils/animations.dart';

// ✅ route with central server-truth router (no Auth hop)
import '../../services/auth_router.dart';

// ⬇️ real phone auth flow
import '../../services/phone_auth_service.dart';
// ✅ FB-style link modal (reused)
import '../../widgets/link_account_modal.dart';

class OTPScreen extends StatefulWidget {
  final String? phoneNumber;
  // carry verification state from PhoneInputScreen
  final String verificationId;
  final int? resendToken;

  const OTPScreen({
    super.key,
    this.phoneNumber,
    required this.verificationId,
    this.resendToken,
  });

  @override
  State<OTPScreen> createState() => _OTPScreenState();
}

class _OTPScreenState extends State<OTPScreen>
    with SingleTickerProviderStateMixin {
  final List<TextEditingController> _controllers =
      List.generate(6, (index) => TextEditingController());
  final List<FocusNode> _focusNodes = List.generate(6, (index) => FocusNode());
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late String _phoneNumber;

  // keep latest token + verificationId for resend/verify
  int? _resendToken;
  late String _verificationId;

  // ── NEW: in-flight guards ────────────────────────────────────────────────
  bool _verifying = false;
  bool _resending = false;

  // ── NEW: resend cooldown UI (e.g. 30s) ───────────────────────────────────
  static const int _cooldownSecs = 30;
  int _cooldownLeft = 0;
  Timer? _cooldownTimer;

  @override
  void initState() {
    super.initState();
    _phoneNumber = widget.phoneNumber ?? '+1 (555) 123-4567';
    _verificationId = widget.verificationId;
    _resendToken = widget.resendToken;

    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _fadeAnimation =
        CurvedAnimation(parent: _animationController, curve: Curves.easeIn);

    _animationController.forward();

    // Optional: start a short cooldown upon entering the screen
    _startCooldown();
  }

  @override
  void dispose() {
    for (var controller in _controllers) {
      controller.dispose();
    }
    for (var node in _focusNodes) {
      node.dispose();
    }
    _cooldownTimer?.cancel();
    _animationController.dispose();
    super.dispose();
  }

  void _startCooldown() {
    _cooldownTimer?.cancel();
    setState(() => _cooldownLeft = _cooldownSecs);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      if (_cooldownLeft <= 1) {
        t.cancel();
        setState(() => _cooldownLeft = 0);
      } else {
        setState(() => _cooldownLeft--);
      }
    });
  }

  void _onOTPChanged(String value, int index) {
    if (value.isNotEmpty && index < 5) {
      _focusNodes[index + 1].requestFocus();
    } else if (value.isEmpty && index > 0) {
      _focusNodes[index - 1].requestFocus();
    }

    // Auto-verify when all 6 digits present — but only if not already verifying
    if (!_verifying && _controllers.every((c) => c.text.isNotEmpty)) {
      _verifyOTP();
    }
  }

  Future<void> _verifyOTP() async {
    final otp = _controllers.map((c) => c.text).join();
    if (otp.length != 6) return;
    if (_verifying) return; // ⬅️ guard
    setState(() => _verifying = true);

    try {
      await PhoneAuthService.signInWithOTP(
        verificationId: _verificationId,
        smsCode: otp,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('OTP verified successfully!'),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 1),
      ));

      // ✅ Directly call central router (handles pending/rejected/quiz/discover)
      await Future.delayed(const Duration(milliseconds: 400));
      if (!mounted) return;
      try { await FirebaseAuth.instance.currentUser?.getIdToken(true); } catch (_) {}
      await AuthRouter.routeAfterAuth(context);
    } catch (e) {
      if (!mounted) return;
      final es = e.toString();
      if (es.contains('credential-already-in-use')) {
        // 🔔 FB-style confirm modal
        final ok = await showLinkAccountModal(context: context);
        if (ok == true && mounted) {
          try { await FirebaseAuth.instance.currentUser?.getIdToken(true); } catch (_) {}
          await AuthRouter.routeAfterAuth(context);
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Invalid code: $e'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 3),
        ));
      }
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  Future<void> _resendOTP() async {
    if (_resending || _cooldownLeft > 0) return; // ⬅️ guard
    setState(() => _resending = true);

    // Clear fields + focus first box
    for (var c in _controllers) c.clear();
    _focusNodes[0].requestFocus();

    try {
      await PhoneAuthService.verifyPhoneNumber(
        phoneNumber: _phoneNumber, // already E.164 from PhoneInputScreen
        forceResendingToken: _resendToken,
        onCodeSent: (verificationId, resendToken) {
          _verificationId = verificationId;
          _resendToken = resendToken;

          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('OTP resent to your phone!'),
            backgroundColor: Color(0xFFB5276A),
            duration: Duration(seconds: 2),
          ));

          // restart cooldown after a successful resend
          _startCooldown();
        },
        onAutoVerified: () {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Phone verified automatically'),
            backgroundColor: Colors.green,
          ));
          // We do NOT auto-route here to avoid surprising jumps during resend.
          // The main verify path already routes after a successful sign-in.
        },
        onError: (err) async {
          if (!mounted) return;
          if (err.contains('credential-already-in-use')) {
            final ok = await showLinkAccountModal(context: context);
            if (ok == true && mounted) {
              try { await FirebaseAuth.instance.currentUser?.getIdToken(true); } catch (_) {}
              await AuthRouter.routeAfterAuth(context);
            }
          } else {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(err),
              backgroundColor: Colors.red,
            ));
          }
        },
      );
    } finally {
      if (mounted) setState(() => _resending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canResend = !_resending && _cooldownLeft == 0;

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
                      child: const Icon(
                        Icons.phone_outlined,
                        size: 60,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 40),
                    // Title
                    const Text(
                      'Enter Verification Code',
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
                      'We\'ve sent a 6-digit code to\n$_phoneNumber',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.9),
                        fontSize: 16,
                        height: 1.5,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 40),
                    // OTP Input Fields
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: List.generate(6, (index) {
                        return Container(
                          width: 45,
                          height: 55,
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
                          child: TextField(
                            controller: _controllers[index],
                            focusNode: _focusNodes[index],
                            textAlign: TextAlign.center,
                            keyboardType: TextInputType.number,
                            maxLength: 1,
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color: Colors.black87,
                            ),
                            decoration: const InputDecoration(
                              border: InputBorder.none,
                              counterText: '',
                            ),
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                            onChanged: (value) => _onOTPChanged(value, index),
                          ),
                        );
                      }),
                    ),
                    const SizedBox(height: 40),

                    // Verify Button (disabled while verifying)
                    AnimatedPressable(
                      onPressed: _verifying ? () {} : _verifyOTP,
                      child: Opacity(
                        opacity: _verifying ? 0.7 : 1,
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
                              if (_verifying) ...[
                                const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      Colors.white,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                              ],
                              Text(
                                _verifying ? 'Verifying…' : 'Verify Code',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 30),

                    // Resend Code (disabled during cooldown / sending)
                    AnimatedTextLink(
                      text: canResend
                          ? 'Didn\'t receive the code? Resend'
                          : _resending
                              ? 'Resending…'
                              : 'Resend available in $_cooldownLeft s',
                      onTap: canResend ? _resendOTP : () {},
                      style: TextStyle(
                        color: Colors.white.withOpacity(canResend ? 1 : 0.6),
                        fontSize: 14,
                        decoration:
                            canResend ? TextDecoration.underline : null,
                      ),
                      hoverStyle: TextStyle(
                        color: Colors.white.withOpacity(canResend ? 1 : 0.6),
                        fontSize: 14,
                        decoration:
                            canResend ? TextDecoration.underline : null,
                        fontWeight: canResend ? FontWeight.bold : FontWeight.w500,
                      ),
                    ),

                    const SizedBox(height: 20),

                    // Change Phone Number
                    AnimatedTextLink(
                      text: 'Change phone number',
                      onTap: () => Navigator.of(context).pop(),
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.8),
                        fontSize: 14,
                      ),
                      hoverStyle: TextStyle(
                        color: Colors.white.withOpacity(0.8),
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Back
          Positioned(
            top: MediaQuery.of(context).padding.top + 16,
            left: 20,
            child: AnimatedPressable(
              onPressed: () => Navigator.of(context).pop(),
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1),
                ),
                child: const Icon(
                  Icons.chevron_left,
                  color: Colors.white,
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
