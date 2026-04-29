import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_facebook_auth/flutter_facebook_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../utils/animations.dart';
import '../../widgets/terms_modal.dart';
import '../profile_setup/profile_setup_screen.dart';
import 'phone_input_screen.dart';
import '../../services/google_auth_service.dart'; // also brings GoogleLinkRequired into scope
import '../../services/facebook_auth_service.dart';
import '../discover/discover_screen.dart';
import '../results/profile_verification_screen.dart';
import '../quiz/quiz_screen.dart' show QuizSetupScreen;
import '../../utils/constants.dart';
// ⬇️ NEW: ensure first-time users see Terms + Privacy (scroll-to-bottom gating)
import '../../utils/policies_gate.dart';
import '../../services/auth_router.dart';

/// ─────────────────────────────────────────────────────────────────────────
/// AuthScreen
/// - Uses a shared AuthRouter (server-truth) to decide next screen
/// - Requires profile setup completion before skipping to verification
/// - If only cache is available and user is not approved, waits on a local
///   `_AuthCheckingScreen` for a server snapshot
/// ─────────────────────────────────────────────────────────────────────────
class AuthScreen extends StatefulWidget {
  final bool isLogin;
  final VoidCallback? onBack;

  const AuthScreen({
    super.key,
    required this.isLogin,
    this.onBack,
  });

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

enum _Busy { none, google, facebook, phone }

class _AuthScreenState extends State<AuthScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  _Busy _busy = _Busy.none;

  final GoogleAuthService _authService = GoogleAuthService();
  final FacebookAuthService _fbService = FacebookAuthService();

  bool get _isAnyBusy => _busy != _Busy.none;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );

    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeIn,
    ));

    _animationController.forward();

    // ⬇️ First-time policies gate (shows Terms then Privacy; buttons enable at bottom)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ensurePoliciesAccepted(context);
    });
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _handlePhoneLogin() {
    if (_isAnyBusy) return;

    setState(() => _busy = _Busy.phone);

    Navigator.of(context)
        .push(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            const PhoneInputScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(1.0, 0.0);
          const end = Offset.zero;
          const curve = Curves.easeInOut;

          var tween =
              Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
          var offsetAnimation = animation.drive(tween);

          return SlideTransition(
            position: offsetAnimation,
            child: child,
          );
        },
        transitionDuration: const Duration(milliseconds: 500),
      ),
    )
        .then((_) {
      if (mounted) setState(() => _busy = _Busy.none);
    });
  }

  Future<void> _handleGoogleLogin() async {
    if (_isAnyBusy) return;

    setState(() => _busy = _Busy.google);

    try {
      final result = await _authService.signInWithGoogleAndCheckProfile();

      if (!mounted) return;

      if (result != null) {
        // 🔑 Ensure a fresh token before any routed screen makes API calls
        try {
          await FirebaseAuth.instance.currentUser?.getIdToken(true);
        } catch (_) {}
        _routeAfterAuth(true);
      } else {
        _showErrorSnackBar('Sign-in was cancelled');
      }
    } on GoogleLinkRequired catch (link) {
      // New: conflict flow mirrors Facebook
      final proceed = await _showLinkDialog(
        context: context,
        identifier: link.email,
        methods: link.existingMethods,
        providerLabel: 'Google',
      );
      if (proceed == true) {
        await _autoLinkGoogleToExistingAccount(
          email: link.email,
          existingMethods: link.existingMethods,
          pendingGoogleCredential: link.pendingGoogleCredential,
        );
        if (!mounted) return;
        // 🔑 Fresh token after linking, before routing
        try {
          await FirebaseAuth.instance.currentUser?.getIdToken(true);
        } catch (_) {}
        _routeAfterAuth(true);
      }
    } catch (e) {
      String errorMessage = 'An error occurred during sign-in';

      if (e.toString().contains('AuthException:')) {
        errorMessage =
            e.toString().split('AuthException: ')[1].split(' (Code:')[0];
      }

      _showErrorSnackBar(errorMessage);
    } finally {
      if (mounted) setState(() => _busy = _Busy.none);
    }
  }

  /// Mixed flow with the OLD modal (single "Continue"):
  /// - Pre-check (if FB returns email) → show modal → auto-link on Continue
  /// - Otherwise sign-in via service; on conflict → show modal → auto-link
  Future<void> _handleFacebookLogin() async {
    if (_isAnyBusy) return;

    setState(() => _busy = _Busy.facebook);

    try {
      // 1) Begin FB login to obtain token (and hopefully email via userData)
      final res = await FacebookAuth.instance.login(
        permissions: const ['public_profile', 'email'],
      );
      if (res.status != LoginStatus.success || res.accessToken == null) {
        _showErrorSnackBar('Sign-in was cancelled');
        return;
      }

      final token = res.accessToken!.token;
      final fbCred = FacebookAuthProvider.credential(token);

      // 2) Try to fetch email for pre-check
      String? email;
      try {
        final userData =
            await FacebookAuth.instance.getUserData(fields: 'email');
        email = (userData['email'] as String?)?.trim();
      } catch (_) {
        // no email available due to FB privacy settings — continue
      }

      if (email != null && email.isNotEmpty) {
        final methods =
            await FirebaseAuth.instance.fetchSignInMethodsForEmail(email);

        if (methods.contains('google.com')) {
          // === Modal confirmation ===
          final proceed = await _showLinkDialog(
            context: context,
            identifier: email,
            methods: methods,
            providerLabel: 'Facebook',
          );
          if (proceed == true) {
            await _autoLinkFacebookToExistingAccount(
              email: email,
              existingMethods: methods,
              pendingFacebookCredential: fbCred,
            );
            if (!mounted) return;
            // 🔑 Fresh token after linking, before routing
            try {
              await FirebaseAuth.instance.currentUser?.getIdToken(true);
            } catch (_) {}
            _routeAfterAuth(true);
          }
          return;
        } else if (methods.contains('password')) {
          // You removed password flows; short, clear notice.
          throw Exception(
            'This email uses Email/Password. Sign in with Email first from Settings, then link Facebook.',
          );
        }
        // else: either no methods yet or already facebook.com → proceed normally below
      }

      // 3) Normal path via service
      final result =
          await _fbService.signInAndResolveProfile(usingCredential: fbCred);
      if (!mounted) return;

      if (result == null) {
        _showErrorSnackBar('Sign-in was cancelled');
        return;
      }

      // 🔑 Fresh token after FB sign-in, before routing
      try {
        await FirebaseAuth.instance.currentUser?.getIdToken(true);
      } catch (_) {}
      _routeAfterAuth(true);
    } on FacebookLinkRequired catch (link) {
      // 4) Conflict after sign-in attempt → modal → auto-link on Continue
      final proceed = await _showLinkDialog(
        context: context,
        identifier: link.email,
        methods: link.existingMethods,
        providerLabel: 'Facebook',
      );
      if (proceed == true) {
        await _autoLinkFacebookToExistingAccount(
          email: link.email,
          existingMethods: link.existingMethods,
          pendingFacebookCredential: link.pendingFacebookCredential,
        );
        if (!mounted) return;
        // 🔑 Fresh token after linking, before routing
        try {
          await FirebaseAuth.instance.currentUser?.getIdToken(true);
        } catch (_) {}
        _routeAfterAuth(true);
      }
    } catch (e) {
      _showErrorSnackBar(e.toString());
    } finally {
      if (mounted) setState(() => _busy = _Busy.none);
    }
  }

  /// Attempts to sign in with existing provider and link FB cred to that UID.
  /// Robust: re-fetch methods if empty; try Google fallback if unknown.
  Future<Map<String, dynamic>> _autoLinkFacebookToExistingAccount({
    required String email,
    required List<String> existingMethods,
    required AuthCredential pendingFacebookCredential,
  }) async {
    // Normalize & re-fetch if SDK returned an empty list
    final methods = {...existingMethods}.toSet();
    if (methods.isEmpty) {
      try {
        final refetched =
            await FirebaseAuth.instance.fetchSignInMethodsForEmail(email);
        methods.addAll(refetched);
      } catch (_) {
        // ignore; we'll fall back below
      }
    }

    // If it already lists facebook.com, we may already be linked
    if (methods.contains('facebook.com')) {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        return {'user': user, 'isProfileComplete': true};
      }
      // fall through if not signed in
    }

    // Known path: Google
    if (methods.contains('google.com')) {
      final google = GoogleSignIn(scopes: ['email', 'profile']);
      GoogleSignInAccount? gAcc = await google.signInSilently();
      gAcc ??= await google.signIn(); // may show account chooser
      if (gAcc == null) throw Exception('Google sign-in was cancelled.');

      final gAuth = await gAcc.authentication;
      final gCred = GoogleAuthProvider.credential(
        accessToken: gAuth.accessToken,
        idToken: gAuth.idToken,
      );

      await FirebaseAuth.instance.signInWithCredential(gCred);

      final linked = await _fbService
          .linkPendingFacebookToCurrentUser(pendingFacebookCredential);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Facebook linked to your account.')),
        );
      }
      return linked;
    }

    // Password path (unsupported in your UI)
    if (methods.contains('password')) {
      throw Exception(
        'This email uses Email/Password. Sign in with Email first from Settings, then link Facebook.',
      );
    }

    // Pragmatic fallback: try Google anyway (most common case) if methods unknown
    try {
      final google = GoogleSignIn(scopes: ['email', 'profile']);
      GoogleSignInAccount? gAcc = await google.signInSilently();
      gAcc ??= await google.signIn();
      if (gAcc != null) {
        final gAuth = await gAcc.authentication;
        final gCred = GoogleAuthProvider.credential(
          accessToken: gAuth.accessToken,
          idToken: gAuth.idToken,
        );
        await FirebaseAuth.instance.signInWithCredential(gCred);
        final linked = await _fbService
            .linkPendingFacebookToCurrentUser(pendingFacebookCredential);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Facebook linked to your account.')),
          );
        }
        return linked;
      }
    } catch (_) {
      // ignore and fall through to friendly error
    }

    // Final friendly error
    throw Exception(
      'We couldn’t detect the existing sign-in method for $email. '
      'Please sign in with the existing method (e.g., Google), then try linking again.',
    );
  }

  /// Attempts to sign in with existing provider and link Google cred to that UID.
  /// Mirrors the FB helper above.
  Future<Map<String, dynamic>> _autoLinkGoogleToExistingAccount({
    required String email,
    required List<String> existingMethods,
    required AuthCredential pendingGoogleCredential,
  }) async {
    // Normalize & re-fetch if SDK returned an empty list
    final methods = {...existingMethods}.toSet();
    if (methods.isEmpty) {
      try {
        final refetched =
            await FirebaseAuth.instance.fetchSignInMethodsForEmail(email);
        methods.addAll(refetched);
      } catch (_) {
        // ignore; we’ll try pragmatic fallbacks
      }
    }

    // If Google already linked and we have a session, just continue
    if (methods.contains('google.com')) {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        return {'user': user, 'isProfileComplete': true};
      }
      // fall through to sign in with the known existing method (likely Facebook)
    }

    // Known path: Facebook
    if (methods.contains('facebook.com')) {
      final res = await FacebookAuth.instance.login(
        permissions: const ['public_profile', 'email'],
      );
      if (res.status != LoginStatus.success || res.accessToken == null) {
        throw Exception('Facebook sign-in was cancelled.');
      }
      final fbCred = FacebookAuthProvider.credential(res.accessToken!.token);
      await FirebaseAuth.instance.signInWithCredential(fbCred);

      // Link Google to the now-signed-in user
      final linked =
          await FirebaseAuth.instance.currentUser!.linkWithCredential(
        pendingGoogleCredential,
      );

      // Fresh claims
      try {
        await linked.user?.reload();
        await linked.user?.getIdToken(true);
      } catch (_) {}

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Google linked to your account.')),
        );
      }
      return {'user': linked.user!, 'isProfileComplete': true};
    }

    // Password path (unsupported in your UI)
    if (methods.contains('password')) {
      throw Exception(
        'This email uses Email/Password. Sign in with Email first from Settings, then link Google.',
      );
    }

    // Pragmatic fallback: try Facebook anyway (most common other case)
    try {
      final res = await FacebookAuth.instance.login(
        permissions: const ['public_profile', 'email'],
      );
      if (res.status == LoginStatus.success && res.accessToken != null) {
        final fbCred = FacebookAuthProvider.credential(res.accessToken!.token);
        await FirebaseAuth.instance.signInWithCredential(fbCred);
        final linked =
            await FirebaseAuth.instance.currentUser!.linkWithCredential(
          pendingGoogleCredential,
        );
        try {
          await linked.user?.reload();
          await linked.user?.getIdToken(true);
        } catch (_) {}
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Google linked to your account.')),
          );
        }
        return {'user': linked.user!, 'isProfileComplete': true};
      }
    } catch (_) {
      // ignore and fall through
    }

    // Final friendly error
    throw Exception(
      'We couldn’t detect the existing sign-in method for $email. '
      'Please sign in with the existing method (e.g., Facebook), then try linking again.',
    );
  }

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: 'Dismiss',
          textColor: Colors.white,
          onPressed: () {
            ScaffoldMessenger.of(context).hideCurrentSnackBar();
          },
        ),
      ),
    );
  }

  /// Generic link modal (works for Google/Facebook; shows identifier as email/phone)
  Future<bool?> _showLinkDialog({
    required BuildContext context,
    required String identifier, // email or phone (for phone flows elsewhere)
    required List<String> methods,
    String providerLabel = 'Your account', // 'Google' | 'Facebook' | etc.
  }) {
    final primary = const Color(0xFFB5276A);

    // Build an ending sentence based on provider label
    final lower = providerLabel.toLowerCase();
    final linkCopy =
        'Continue to link $lower with that account and keep everything in one place.';

    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) {
        return AnimatedPadding(
          duration: const Duration(milliseconds: 200),
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(24)),
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
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // drag handle
                    Container(
                      width: 44,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),

                    // header row
                    Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: primary.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          alignment: Alignment.center,
                          child: Icon(Icons.link, color: primary),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            'Link your account',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: Colors.black87,
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 12),

                    // Copy (personal & justified)
                    RichText(
                      textAlign: TextAlign.justify,
                      text: TextSpan(
                        style: const TextStyle(
                          fontSize: 14,
                          color: Colors.black87,
                          height: 1.35,
                        ),
                        children: [
                          TextSpan(
                            text:
                                'Looks like the email from your $providerLabel account (',
                          ),
                        ],
                      ),
                    ),

                    // Identifier line styled separately for clarity:
                    Padding(
                      padding: const EdgeInsets.only(top: 2, bottom: 2),
                      child: Text(
                        identifier,
                        style: const TextStyle(
                          fontSize: 14,
                          color: Colors.black87,
                          fontWeight: FontWeight.w700,
                        ),
                        textAlign: TextAlign.left,
                      ),
                    ),
                    Text(
                      ') is already connected to an existing account. $linkCopy',
                      style: const TextStyle(
                        fontSize: 14,
                        color: Colors.black87,
                        height: 1.35,
                      ),
                      textAlign: TextAlign.justify,
                    ),

                    const SizedBox(height: 18),

                    // single primary action
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () => Navigator.pop(context, true),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: primary,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text('Continue'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // ───────────────────────────────────────────────────────────
  // ROUTING DELEGATE
  // ───────────────────────────────────────────────────────────

  // NOTE: keep signature for existing callsites
  void _routeAfterAuth(bool _ignoredIsProfileComplete) {
    AuthRouter.routeAfterAuth(context);
  }

  @override
  Widget build(BuildContext context) {
    final isGoogleLoading = _busy == _Busy.google;
    final isFacebookLoading = _busy == _Busy.facebook;
    final isPhoneLoading = _busy == _Busy.phone;

    return Scaffold(
      body: Stack(
        children: [
          // Main Content
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
                  top: MediaQuery.of(context).padding.top + 100,
                  left: 24,
                  right: 24,
                  bottom: 24,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Welcome!',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Please choose your sign in method \nbelow',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.8),
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 100),

                    // Social Login Buttons (button-only loading)
                    ModernButton(
                      text: isGoogleLoading
                          ? 'signing in…'
                          : 'continue with Google',
                      onPressed: _isAnyBusy ? () {} : _handleGoogleLogin,
                      isPrimary: false,
                      isLoading: isGoogleLoading,
                      loadingText: 'signing in…',
                      customIcon: isGoogleLoading ? null : const GoogleIcon(),
                    ),
                    const SizedBox(height: 16),
                    ModernButton(
                      text: isFacebookLoading
                          ? 'signing in…'
                          : 'continue with Facebook',
                      onPressed: _isAnyBusy ? () {} : _handleFacebookLogin,
                      isPrimary: false,
                      isLoading: isFacebookLoading,
                      loadingText: 'signing in…',
                      customIcon:
                          isFacebookLoading ? null : const FacebookIcon(),
                    ),
                    const SizedBox(height: 16),
                    ModernButton(
                      text: isPhoneLoading
                          ? 'loading…'
                          : 'continue with Phone Number',
                      onPressed: _isAnyBusy ? () {} : _handlePhoneLogin,
                      isPrimary: false,
                      isLoading: isPhoneLoading,
                      loadingText: 'loading…',
                      icon: isPhoneLoading ? null : Icons.phone_outlined,
                    ),
                    const SizedBox(height: 40),

                    // Terms and Privacy (no underline)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: RichText(
                          textAlign: TextAlign.center,
                          text: TextSpan(
                            children: [
                              const TextSpan(
                                text: 'By continuing, you agree to our\n',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                ),
                              ),
                              WidgetSpan(
                                child: GestureDetector(
                                  onTap: () => showTermsModal(context),
                                  child: const Text(
                                    'Terms of Use',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      decoration: TextDecoration.none, // ⬅️
                                    ),
                                  ),
                                ),
                              ),
                              const TextSpan(
                                text: ' and ',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                ),
                              ),
                              WidgetSpan(
                                child: GestureDetector(
                                  onTap: () => showPrivacyModal(context),
                                  child: const Text(
                                    'Privacy Policy',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      decoration: TextDecoration.none, // ⬅️
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ),
          ),

          // Back button positioned at top left
          if (widget.onBack != null)
            Positioned(
              top: MediaQuery.of(context).padding.top + 16,
              left: 16, // match the 24px gutter used by the page content
              child: AnimatedPressable(
                onPressed: _isAnyBusy ? () {} : widget.onBack!,
                child: Container(
                  width: 40,
                  height: 40,
                  alignment:
                      Alignment.centerLeft, // align icon to the left edge
                  // no decoration = no circle outline
                  child: Icon(
                    Icons.chevron_left,
                    color: _isAnyBusy
                        ? Colors.white.withOpacity(0.5)
                        : Colors.white,
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

// ───────────────────────────────────────────────────────────
// Local-asset icons (no network). Falls back to Material icons if missing.
// ───────────────────────────────────────────────────────────

class GoogleIcon extends StatelessWidget {
  const GoogleIcon({super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 20,
      height: 20,
      child: Image.asset(
        'assets/icons/google.png',
        width: 20,
        height: 20,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stack) => const Icon(
          Icons.g_mobiledata,
          size: 20,
          color: Color(0xFFB5276A),
        ),
      ),
    );
  }
}

class FacebookIcon extends StatelessWidget {
  const FacebookIcon({super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 20,
      height: 20,
      child: Image.asset(
        'assets/icons/facebook.png',
        width: 20,
        height: 20,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stack) => const Icon(
          Icons.facebook,
          size: 20,
          color: Color(0xFF1877F2),
        ),
      ),
    );
  }
}

// Modern Input Field Widget
class ModernInputField extends StatelessWidget {
  final TextEditingController controller;
  final String hintText;
  final IconData icon;
  final TextInputType keyboardType;

  const ModernInputField({
    super.key,
    required this.controller,
    required this.hintText,
    required this.icon,
    this.keyboardType = TextInputType.text,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
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
        controller: controller,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          hintText: hintText,
          prefixIcon: Icon(icon, color: Colors.grey.shade600),
          border: InputBorder.none,
          contentPadding:
              const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
          hintStyle: TextStyle(
            color: Colors.grey.shade500,
            fontSize: 16,
          ),
        ),
        style: const TextStyle(
          fontSize: 16,
          color: Colors.black87,
        ),
      ),
    );
  }
}

// Modern Button Widget (shows loading only inside the button)
class ModernButton extends StatelessWidget {
  final String text;
  final VoidCallback onPressed;
  final bool isPrimary;
  final IconData? icon;
  final Widget? customIcon;

  // loading props
  final bool isLoading;
  final String? loadingText;

  const ModernButton({
    super.key,
    required this.text,
    required this.onPressed,
    this.isPrimary = true,
    this.icon,
    this.customIcon,
    this.isLoading = false,
    this.loadingText,
  });

  @override
  Widget build(BuildContext context) {
    final background = isPrimary ? const Color(0xFFB5276A) : Colors.white;
    final fg = isPrimary ? Colors.white : Colors.black87;

    return AnimatedPressable(
      onPressed: isLoading ? () {} : onPressed,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: isLoading ? 0.7 : 1.0,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: background,
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
              if (!isLoading && customIcon != null) ...[
                customIcon!,
                const SizedBox(width: 12),
              ] else if (!isLoading && icon != null) ...[
                Icon(icon, color: fg, size: 20),
                const SizedBox(width: 12),
              ] else if (isLoading) ...[
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(
                        isPrimary ? Colors.white : Color(0xFFB5276A)),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Text(
                isLoading ? (loadingText ?? 'loading…') : text,
                style: TextStyle(
                  color: fg,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// ─────────────────────────────────────────────────────────────────────────
/// Local checking screen to wait for a SERVER snapshot after sign-in
/// (only used when our first read came from CACHE and status != approved)
/// ─────────────────────────────────────────────────────────────────────────
class _AuthCheckingScreen extends StatefulWidget {
  const _AuthCheckingScreen();

  @override
  State<_AuthCheckingScreen> createState() => _AuthCheckingScreenState();
}

class _AuthCheckingScreenState extends State<_AuthCheckingScreen> {
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sub;

  @override
  void initState() {
    super.initState();
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      _go(const AuthScreen(isLogin: true));
      return;
    }

    _sub = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .snapshots(includeMetadataChanges: true)
        .listen((snap) {
      // Only react to SERVER updates to avoid stale cache flicker
      if (snap.metadata.isFromCache) return;

      final d = snap.data() ?? <String, dynamic>{};

      // If the doc doesn’t exist or setup incomplete, go to setup
      final setupDone = (d['profile_setup_complete'] == true) ||
          (d['profileSetupComplete'] == true);
      if (!snap.exists || !setupDone) {
        _go(const ProfileSetupScreen());
        return;
      }

      // Normalize identity status
      String status = 'pending';
      final ivCamel = d['identityVerification'];
      final ivSnake = d['identity_verification'];
      if (ivCamel is Map && ivCamel['status'] is String) {
        status = ivCamel['status'] as String;
      } else if (d['identityVerificationStatus'] is String) {
        status = d['identityVerificationStatus'] as String;
      } else if (ivSnake is Map && ivSnake['status'] is String) {
        status = ivSnake['status'] as String;
      } else if (d['identity_verification_status'] is String) {
        status = d['identity_verification_status'] as String;
      }
      status = status.toLowerCase().trim();
      if (status.isEmpty || status == 'not_started' || status == 'unknown') {
        status = 'pending';
      }

      final quizDone = (d['quiz'] is Map) && (d['quiz']['completed'] == true);

      if (status == 'rejected') {
        _go(const ProfileVerificationScreen(status: 'rejected'));
      } else if (status != 'approved') {
        _go(const ProfileVerificationScreen(status: 'pending'));
      } else if (!quizDone) {
        _go(const QuizSetupScreen());
      } else {
        _go(const DiscoverScreen());
      }
    });
  }

  void _go(Widget page) {
    if (!mounted) return;
    _sub?.cancel();
    _sub = null;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => page,
        transitionsBuilder: (_, a, __, child) =>
            FadeTransition(opacity: a, child: child),
        transitionDuration: const Duration(milliseconds: 200),
      ),
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
