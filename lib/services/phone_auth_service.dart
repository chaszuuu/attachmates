// lib/services/phone_auth_service.dart
import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'auth_link_helper.dart';
import 'package:flutter/material.dart';

/// Thrown when a phone number is already linked to a DIFFERENT Firebase user
/// or Firebase reports a cross-provider conflict during OTP sign-in.
/// UI should instruct the user to sign in with the original method first,
/// then link this phone under Settings.
class PhoneLinkRequired implements Exception {
  final String phoneNumber;
  final String
      code; // e.g., credential-already-in-use, account-exists-with-different-credential
  final String message; // friendly / raw message

  PhoneLinkRequired({
    required this.phoneNumber,
    required this.code,
    required this.message,
  });

  @override
  String toString() => 'PhoneLinkRequired(number=$phoneNumber, code=$code)';
}

class PhoneAuthService {
  static final _auth = FirebaseAuth.instance;
  static final _db = FirebaseFirestore.instance;

  /// Start verification. On Android this may auto-verify (instant/auto-retrieval).
  static Future<void> verifyPhoneNumber({
    required String phoneNumber, // use E.164: +63xxxxxxxxxx
    required void Function(String verificationId, int? resendToken) onCodeSent,
    required VoidCallback onAutoVerified,
    required void Function(String error) onError,
    int? forceResendingToken,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    await _auth.verifyPhoneNumber(
      phoneNumber: phoneNumber,
      timeout: timeout,
      forceResendingToken: forceResendingToken,
      verificationCompleted: (PhoneAuthCredential cred) async {
        // Instant/auto verification path — link if already signed-in, else sign in.
        try {
          final user = await _linkOrSignInWithCredential(cred);
          // ensure fresh claims and provider sync
          await user.reload();
          await user.getIdToken(true);
          await _ensureUserDocAndTimestamps(user);
          await AuthLinkHelper.syncLinkedProviders(user: user);
          onAutoVerified();
        } on FirebaseAuthException catch (e) {
          // Keep legacy behavior for auto flow: surface a friendly error string to the callback.
          onError(_friendlyError(e));
        } catch (e) {
          onError(e.toString());
        }
      },
      verificationFailed: (FirebaseAuthException e) {
        // Note: this callback shape only returns a string; UI can't catch a typed exception here.
        // We still provide a clear message.
        onError(_friendlyError(e));
      },
      codeSent: (String verificationId, int? resendToken) {
        onCodeSent(verificationId, resendToken);
      },
      codeAutoRetrievalTimeout: (_) {},
    );
  }

  /// Sign in OR link using the 6-digit code — if a user is already signed in
  /// (e.g., via Google/Facebook), we LINK the phone to that same uid.
  ///
  /// On conflict with another account, throws [PhoneLinkRequired] so the caller
  /// can show a link guidance modal (same UX as your Facebook/Google flows).
  static Future<User> signInWithOTP({
    required String verificationId,
    required String smsCode,
    String? phoneNumberForUX, // optional for nicer error messages
  }) async {
    final cred = PhoneAuthProvider.credential(
      verificationId: verificationId,
      smsCode: smsCode,
    );

    try {
      final user = await _linkOrSignInWithCredential(cred);

      // Refresh token/claims and keep Firestore in sync
      await user.reload();
      await user.getIdToken(true);
      await _ensureUserDocAndTimestamps(user);
      await AuthLinkHelper.syncLinkedProviders(user: user);

      return user;
    } on FirebaseAuthException catch (e) {
      // Bubble a structured exception the UI can catch to show your link modal.
      if (e.code == 'credential-already-in-use' ||
          e.code == 'provider-already-linked' ||
          e.code == 'account-exists-with-different-credential') {
        final number = phoneNumberForUX ?? 'this phone number';
        throw PhoneLinkRequired(
          phoneNumber: number,
          code: e.code,
          message: _friendlyError(e),
        );
      }
      // For other auth errors, rethrow so caller can show a snackbar using _friendlyError.
      rethrow;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Internals
  // ─────────────────────────────────────────────────────────────────────────

  /// If there's a current user, try linking the phone credential to that uid.
  /// Otherwise, sign in with the phone credential.
  static Future<User> _linkOrSignInWithCredential(AuthCredential cred) async {
    final current = _auth.currentUser;

    try {
      if (current != null) {
        // Already signed in with another provider — link phone to the same account.
        final linked = await current.linkWithCredential(cred);
        return linked.user!;
      } else {
        // No active session — sign in (this may create or reuse a phone-based account).
        final res = await _auth.signInWithCredential(cred);
        return res.user!;
      }
    } on FirebaseAuthException catch (e) {
      // Bubble up — caller will convert conflicts to PhoneLinkRequired (OTP path)
      // and show friendly copy for verifyPhoneNumber via callback.
      throw e;
    }
  }

  /// Ensure a users/{uid} doc exists and keep timestamps fresh.
  /// Mirrors the behavior in your Google/Facebook services.
  static Future<void> _ensureUserDocAndTimestamps(User user) async {
    final ref = _db.collection('users').doc(user.uid);
    final snap = await ref.get();

    if (!snap.exists) {
      await ref.set({
        'uid': user.uid,
        'email': user.email ?? '',
        'display_name': user.displayName ?? '',
        'photo_url': user.photoURL ?? '',
        'created_at': FieldValue.serverTimestamp(),
        'last_login_at': FieldValue.serverTimestamp(),
        'updated_at': FieldValue.serverTimestamp(),
        'profile_setup_complete': false,
        // linked_providers is kept in sync by AuthLinkHelper after we link/sign in
        'linked_providers': <String>[],
      });
    } else {
      await ref.update({
        'last_login_at': FieldValue.serverTimestamp(),
        'updated_at': FieldValue.serverTimestamp(),
      });

      // Optional one-time backfill for legacy camelCase → snake_case
      final data = snap.data() as Map<String, dynamic>;
      final complete = (data['profile_setup_complete'] as bool?) ??
          (data['profileSetupComplete'] as bool?) ??
          false;

      if (!data.containsKey('profile_setup_complete') &&
          data.containsKey('profileSetupComplete')) {
        await ref.update({'profile_setup_complete': complete});
      }
    }
  }

  static String _friendlyError(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-verification-code':
        return 'The verification code is invalid.';
      case 'invalid-verification-id':
        return 'The verification session has expired. Please request a new code.';
      case 'session-expired':
        return 'The SMS code has expired. Please request a new one.';
      case 'too-many-requests':
        return 'Too many attempts. Please try again later.';
      case 'network-request-failed':
        return 'Network error. Please check your connection.';
      case 'credential-already-in-use':
        return 'This phone number is already linked to another account.';
      case 'provider-already-linked':
        return 'This phone number is already linked to this account.';
      case 'account-exists-with-different-credential':
        return 'This phone number is linked to a different sign-in method.';
      default:
        return e.message ?? 'Phone verification failed.';
    }
  }
}
