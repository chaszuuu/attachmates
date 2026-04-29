// lib/services/facebook_auth_service.dart
import 'dart:developer';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_facebook_auth/flutter_facebook_auth.dart';

// NEW: centralize provider syncing
import 'auth_link_helper.dart';

/// Thrown when the email already exists with a different provider
/// (e.g., Google). It carries the pending Facebook credential so
/// you can link it after signing in with the existing provider.
class FacebookLinkRequired implements Exception {
  final AuthCredential pendingFacebookCredential;
  final String email;
  final List<String> existingMethods;

  FacebookLinkRequired({
    required this.pendingFacebookCredential,
    required this.email,
    required this.existingMethods,
  });

  @override
  String toString() =>
      'FacebookLinkRequired(email=$email, methods=$existingMethods)';
}

class FacebookAuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Sign in with a PRE-OBTAINED Facebook OAuth credential (preferred),
  /// or (fallback) run the full FB login once here. Ensures Firestore user doc.
  /// On cross-provider conflict, throws [FacebookLinkRequired].
  Future<Map<String, dynamic>?> signInAndResolveProfile({
    OAuthCredential? usingCredential,
  }) async {
    try {
      OAuthCredential fbCred;

      if (usingCredential != null) {
        fbCred = usingCredential;
      } else {
        // Fallback path: do a single FB login here (screen should normally pass the cred).
        final LoginResult res = await FacebookAuth.instance.login(
          permissions: const ['public_profile', 'email'],
        );
        if (res.status != LoginStatus.success || res.accessToken == null) {
          log('Facebook login canceled/failed – ${res.status} ${res.message}');
          return null; // user cancelled
        }
        fbCred = FacebookAuthProvider.credential(res.accessToken!.token);
      }

      final UserCredential userCred = await _auth.signInWithCredential(fbCred);
      final user = userCred.user;
      if (user == null) {
        throw FirebaseAuthException(
          code: 'facebook-signin-failed',
          message: 'Failed to sign in with Facebook.',
        );
      }

      // Ensure fresh token/claims immediately for downstream API calls.
      await user.reload();
      await user.getIdToken(true);

      // ⬇️ NEW: backfill email from Graph if Firebase user has no email
      String? fbEmail = user.email;
      if (fbEmail == null || fbEmail.isEmpty) {
        try {
          final data = await FacebookAuth.instance.getUserData(fields: 'email');
          final fetched = (data['email'] as String?)?.trim();
          if (fetched != null && fetched.isNotEmpty) {
            fbEmail = fetched;
          }
        } catch (_) {
          // Email might be hidden by FB privacy settings; ignore if not available
        }
      }

      final isComplete = await _ensureUserDocAndGetStatus(
        user.uid,
        email: fbEmail, // pass possibly backfilled email
        name: user.displayName,
        photoUrl: user.photoURL,
      );

      // Keep Firestore in sync with whatever providers are now linked.
      await AuthLinkHelper.syncLinkedProviders(user: user);

      return {'user': user, 'isProfileComplete': isComplete};
    } on FirebaseAuthException catch (e) {
      // Cross-provider conflict (common when same email used by Google).
      if (e.code == 'account-exists-with-different-credential' ||
          e.code == 'email-already-in-use') {
        final email = e.email;
        final pending =
            usingCredential ?? e.credential; // FB cred to be linked later
        if (email != null && pending != null) {
          // Try to fetch existing methods; proceed even if it fails
          var methods = <String>[];
          try {
            methods = await _auth.fetchSignInMethodsForEmail(email);
          } catch (_) {
            // ignore — UI can still show guidance even if methods are unknown
          }

          // If Firebase already shows facebook.com linked, short-circuit
          if (methods.contains('facebook.com')) {
            final user = _auth.currentUser;
            if (user != null) {
              return {'user': user, 'isProfileComplete': true};
            }
            // otherwise fall through to throw, caller will handle linking flow
          }

          // Re-throw structured exception for the Auth screen to show the link modal.
          throw FacebookLinkRequired(
            pendingFacebookCredential: pending,
            email: email,
            existingMethods: methods,
          );
        }
      }
      rethrow;
    } catch (e, st) {
      log('FB Sign-In error: $e', stackTrace: st);
      rethrow;
    }
  }

  /// Call this AFTER signing in with the existing provider (e.g., Google)
  /// to link the pending Facebook credential to that same Firebase user.
  Future<Map<String, dynamic>> linkPendingFacebookToCurrentUser(
    AuthCredential pendingFacebookCredential,
  ) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw FirebaseAuthException(
        code: 'no-current-user',
        message: 'No user is signed in to link with.',
      );
    }

    final linked = await user.linkWithCredential(pendingFacebookCredential);
    final linkedUser = linked.user!;
    // Make sure token/claims are refreshed after linking
    await linkedUser.reload();
    await linkedUser.getIdToken(true);

    final isComplete = await _ensureUserDocAndGetStatus(
      linkedUser.uid,
      email: linkedUser.email,
      name: linkedUser.displayName,
      photoUrl: linkedUser.photoURL,
    );

    await AuthLinkHelper.syncLinkedProviders(user: linkedUser);

    return {'user': linkedUser, 'isProfileComplete': isComplete};
  }

  /// Optional helpers for a settings screen.
  Future<UserCredential> linkToCurrentUser() async {
    final res = await FacebookAuth.instance
        .login(permissions: const ['public_profile', 'email']);
    if (res.status != LoginStatus.success || res.accessToken == null) {
      throw FirebaseAuthException(
        code: 'facebook-login-failed',
        message: res.message,
      );
    }
    final cred = FacebookAuthProvider.credential(res.accessToken!.token);
    final result = await _auth.currentUser!.linkWithCredential(cred);

    // Refresh token/claims and sync providers
    final u = result.user!;
    await u.reload();
    await u.getIdToken(true);
    await AuthLinkHelper.syncLinkedProviders(user: u);

    return result;
  }

  Future<void> unlinkFromCurrentUser() async {
    await _auth.currentUser?.unlink('facebook.com');
    final user = _auth.currentUser;
    if (user != null) {
      await user.reload();
      await user.getIdToken(true);
      await AuthLinkHelper.syncLinkedProviders(user: user);
    }
  }

  /// Ensure a user doc exists; return profile completion flag.
  Future<bool> _ensureUserDocAndGetStatus(
    String uid, {
    String? email,
    String? name,
    String? photoUrl,
  }) async {
    final ref = _firestore.collection('users').doc(uid);
    final snap = await ref.get();

    if (!snap.exists) {
      await ref.set({
        'uid': uid,
        'email': (email ?? '').trim(),
        'display_name': name ?? '',
        'photo_url': photoUrl ?? '',
        'created_at': FieldValue.serverTimestamp(),
        'last_login_at': FieldValue.serverTimestamp(),
        'updated_at': FieldValue.serverTimestamp(),
        'profile_setup_complete': false,
        'linked_providers': <String>[], // now filled by AuthLinkHelper
      });
      return false;
    } else {
      await ref.update({
        'last_login_at': FieldValue.serverTimestamp(),
        'updated_at': FieldValue.serverTimestamp(),
      });

      final data = snap.data() as Map<String, dynamic>;
      final complete = (data['profile_setup_complete'] as bool?) ??
          (data['profileSetupComplete'] as bool?) ?? // legacy camelCase
          false;

      // One-time backfill for legacy key
      if (!data.containsKey('profile_setup_complete') &&
          data.containsKey('profileSetupComplete')) {
        await ref.update({'profile_setup_complete': complete});
      }

      // ⬇️ NEW: backfill email if stored is empty and we now have one
      final storedEmail = (data['email'] as String?)?.trim() ?? '';
      final incomingEmail = (email ?? '').trim();
      if (storedEmail.isEmpty && incomingEmail.isNotEmpty) {
        await ref.update({'email': incomingEmail});
      }

      return complete;
    }
  }
}
