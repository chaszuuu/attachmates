// lib/services/auth_router.dart
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../screens/profile_setup/profile_setup_screen.dart';
import '../screens/results/profile_verification_screen.dart';
import '../screens/discover/discover_screen.dart';
import '../screens/quiz/quiz_screen.dart' show QuizSetupScreen;

class AuthRouter {
  static Route _slideTo(Widget page) {
    return PageRouteBuilder(
      pageBuilder: (context, a, b) => page,
      transitionsBuilder: (context, a, b, child) {
        const begin = Offset(1.0, 0.0);
        const end = Offset.zero;
        final tween =
            Tween(begin: begin, end: end).chain(CurveTween(curve: Curves.easeInOut));
        return SlideTransition(position: a.drive(tween), child: child);
      },
      transitionDuration: const Duration(milliseconds: 500),
    );
  }

  static String _normalizeStatus(String? s) {
    final v = (s ?? '').toLowerCase().trim();
    if (v.isEmpty || v == 'not_started' || v == 'unknown') return 'pending';
    return v;
  }

  /// Central server-truth router: same logic used by AuthScreen._routeAfterAuthUsingServer()
  static Future<void> routeAfterAuth(BuildContext context) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      final users = FirebaseFirestore.instance.collection('users').doc(user.uid);

      DocumentSnapshot<Map<String, dynamic>> snap;
      try {
        snap = await users
            .get(const GetOptions(source: Source.server))
            .timeout(const Duration(seconds: 6));
      } on Exception {
        snap = await users.get(const GetOptions(source: Source.cache));
      }

      if (!context.mounted) return;

      // No doc → Profile Setup
      if (!snap.exists) {
        Navigator.of(context).pushReplacement(_slideTo(const ProfileSetupScreen()));
        return;
      }

      final data = snap.data() ?? <String, dynamic>{};
      final fromServer = !snap.metadata.isFromCache;

      // Require setup complete before skipping to verification
      final setupDone = (data['profile_setup_complete'] == true) ||
          (data['profileSetupComplete'] == true);
      if (!setupDone) {
        Navigator.of(context).pushReplacement(_slideTo(const ProfileSetupScreen()));
        return;
      }

      // Identity status
      String status = 'pending';
      final ivCamel = data['identityVerification'];
      final ivSnake = data['identity_verification'];
      if (ivCamel is Map && ivCamel['status'] is String) {
        status = ivCamel['status'].toString();
      } else if (data['identityVerificationStatus'] is String) {
        status = data['identityVerificationStatus'].toString();
      } else if (ivSnake is Map && ivSnake['status'] is String) {
        status = ivSnake['status'].toString();
      } else if (data['identity_verification_status'] is String) {
        status = data['identity_verification_status'].toString();
      }
      status = _normalizeStatus(status);

      // Quiz completion
      bool quizCompleted = false;
      final quiz = data['quiz'];
      if (quiz is Map && quiz['completed'] is bool) {
        quizCompleted = quiz['completed'] as bool;
      }

      if (status == 'rejected') {
        Navigator.of(context).pushReplacement(
          PageRouteBuilder(
            pageBuilder: (_, __, ___) =>
                const ProfileVerificationScreen(status: 'rejected'),
            transitionsBuilder: (_, a, __, child) =>
                FadeTransition(opacity: a, child: child),
            transitionDuration: const Duration(milliseconds: 200),
          ),
        );
        return;
      }

      if (status != 'approved') {
        Navigator.of(context).pushReplacement(
          PageRouteBuilder(
            pageBuilder: (_, __, ___) =>
                const ProfileVerificationScreen(status: 'pending'),
            transitionsBuilder: (_, a, __, child) =>
                FadeTransition(opacity: a, child: child),
            transitionDuration: const Duration(milliseconds: 200),
          ),
        );
        return;
      }

      if (!quizCompleted) {
        Navigator.of(context).pushReplacement(_slideTo(const QuizSetupScreen()));
        return;
      }

      Navigator.of(context).pushReplacement(_slideTo(const DiscoverScreen()));
    } catch (_) {
      // Optional: handle fallback or show a small error dialog/snackbar
    }
  }
}
