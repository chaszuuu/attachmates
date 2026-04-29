// lib/services/auth_signout.dart
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_facebook_auth/flutter_facebook_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../services/fcm_token_service.dart';
import '../utils/presence_service.dart';
import '../services/push_service.dart';

// If you want to clear app prefs on sign-out:
import '../utils/shared_pref.dart'; // for clearAllPrefs()

class AuthSignOut {
  /// Full sign-out: push disable, FCM unbind, presence stop, Firebase signOut, provider SDK logouts.
  /// Set [clearPrefs] to true if you also want to wipe local app state.
  static Future<void> signOutAll({bool clearPrefs = false}) async {
    // 0) Best-effort: disable push for this device (server flag)
    await _safeAsync(() => PushService.disable());

    // 1) Unbind FCM mapping while we still know the current user
    await _safeAsync(
        () => FcmTokenService.unbindCurrentUser(deleteMessagingToken: true));

    // 2) Stop presence tracking (may depend on current user/session)
    await _safeAsync(() => PresenceService().stop());

    // 3) Authoritative: end Firebase session (clears ID + refresh tokens)
    await FirebaseAuth.instance.signOut();

    // 4) Clear your app’s local prefs if requested
    if (clearPrefs) {
      await _safeAsync(() => clearAllPrefs());
      // or: final prefs = await SharedPreferences.getInstance(); await prefs.clear();
    }

    // 5) Best-effort provider SDK logouts (don’t fail the whole flow if these error)
    await _safeAsync(() => FacebookAuth.instance.logOut());

    await _safeAsync(() async {
      final google = GoogleSignIn();
      // Sign out of Google session in case user switches accounts next time
      await google.signOut();
      // Revoke access where supported (no-op if not connected)
      try {
        await google.disconnect();
      } catch (_) {}
    });

    // 6) Apple Sign-In doesn’t keep a persistent SDK session on mobile,
    // but you can wrap any clean-up you use; this is optional/no-op:
    await _safeAsync(() async {
      // SignInWithApple has no explicit logout; left intentionally blank.
      // If you store any Apple-specific state, clear it here.
    });
  }

  static Future<void> signOutGoogleOnly() async {
    await _safeAsync(() async {
      final google = GoogleSignIn();
      await google.signOut();
      try {
        await google.disconnect();
      } catch (_) {}
    });
  }

  static Future<void> signOutFacebookOnly() async {
    await _safeAsync(() => FacebookAuth.instance.logOut());
  }

  // ---- helpers ----
  static Future<void> _safeAsync(Future<void> Function() op) async {
    try {
      await op();
    } catch (_) {}
  }
}
