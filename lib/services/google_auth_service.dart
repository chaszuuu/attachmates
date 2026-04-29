import 'dart:developer';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

// 👇 centralized helper (already in your project)
import 'auth_link_helper.dart';

/// Custom exception class for authentication errors
class AuthException implements Exception {
  final String message;
  final String code;

  AuthException(this.message, this.code);

  @override
  String toString() => 'AuthException: $message (Code: $code)';
}

/// 👇 NEW: thrown when Google finds that the email already exists
/// with a different sign-in method (e.g., facebook.com / password).
/// Carries the pending Google credential so the caller can link it
/// after signing in with the existing provider.
class GoogleLinkRequired implements Exception {
  final AuthCredential pendingGoogleCredential;
  final String email;
  final List<String> existingMethods;

  GoogleLinkRequired({
    required this.pendingGoogleCredential,
    required this.email,
    required this.existingMethods,
  });

  @override
  String toString() =>
      'GoogleLinkRequired(email=$email, methods=$existingMethods)';
}

/// Service class to handle Google Sign-In with Firebase Authentication
class GoogleAuthService {
  // Firebase Auth instance
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // Google Sign-In instance with proper configuration
  final GoogleSignIn _googleSignIn = GoogleSignIn(scopes: ['email', 'profile']);

  // Firestore instance
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Initialize Firebase
  /// This method initializes Firebase and handles any initialization errors
  Future<void> initializeFirebase() async {
    try {
      await Firebase.initializeApp();
      log('Firebase initialized successfully');
    } catch (e) {
      log('Error initializing Firebase: $e');
      throw AuthException(
        'Failed to initialize Firebase',
        'firebase-init-error',
      );
    }
  }

  /// Sign in with Google and check/create user profile
  /// - Ensures Firestore doc exists/updated
  /// - Keeps `linked_providers` in Firestore synced with Firebase Auth (via AuthLinkHelper)
  /// Returns a map containing the user and profile completion status
  /// Returns null if sign-in fails or is cancelled
  Future<Map<String, dynamic>?> signInWithGoogleAndCheckProfile() async {
    // Keep an attempted email around so we can still raise a nice
    // GoogleLinkRequired even if the FirebaseAuthException doesn't include one.
    String? attemptedEmail;

    try {
      // Clear any cached Google session to avoid stale account issues
      try {
        await _googleSignIn.signOut();
      } catch (_) {}

      // Trigger the Google Sign-In flow
      final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();

      // If user cancels the sign-in process
      if (googleUser == null) {
        log('Google Sign-In cancelled by user');
        return null;
      }

      attemptedEmail = googleUser.email;
      log('Google user obtained: ${googleUser.email}');

      // Obtain the auth details from the request
      final GoogleSignInAuthentication googleAuth =
          await googleUser.authentication;

      // Validate that we have the necessary tokens
      if (googleAuth.accessToken == null || googleAuth.idToken == null) {
        throw AuthException(
          'Failed to obtain Google authentication tokens',
          'google-auth-tokens-null',
        );
      }

      log('Google authentication tokens obtained successfully');

      // Create a new credential
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      log('Google credential created, signing in to Firebase');

      // Sign in to Firebase with the Google credential
      final UserCredential userCredential = await _auth.signInWithCredential(
        credential,
      );
      final User? user = userCredential.user;

      if (user == null) {
        throw AuthException(
          'Failed to sign in with Google',
          'google-signin-failed',
        );
      }

      // Immediately ensure fresh token/claims for downstream API calls
      await user.reload();
      await user.getIdToken(true);

      log('User signed in successfully: ${user.email}');

      // Check if user document exists in Firestore
      final userRef = _firestore.collection('users').doc(user.uid);
      final userDoc = await userRef.get();

      bool isProfileComplete = false;

      if (!userDoc.exists) {
        // Create new user document (snake_case fields) and seed linked_providers
        await _createUserDocument(user);
        log('New user document created for: ${user.email}');
        isProfileComplete = false;
      } else {
        // Update last login/updated timestamps for existing user (snake_case)
        await userRef.update({
          'last_login_at': FieldValue.serverTimestamp(),
          'updated_at': FieldValue.serverTimestamp(),
        });

        // Get existing user data
        final data = userDoc.data() as Map<String, dynamic>;

        // Read profile flag with backward-compat for legacy camelCase
        isProfileComplete = (data['profile_setup_complete'] as bool?) ??
            (data['profileSetupComplete'] as bool?) ?? // legacy support
            false;

        // Optional lazy backfill – if legacy key exists but new doesn't, write new
        if (!data.containsKey('profile_setup_complete') &&
            data.containsKey('profileSetupComplete')) {
          await userRef.update({'profile_setup_complete': isProfileComplete});
        }

        log('Existing user found. Profile complete: $isProfileComplete');
      }

      // Sync the exact providers from Auth → Firestore via centralized helper
      await AuthLinkHelper.syncLinkedProviders(user: user);

      return {'user': user, 'isProfileComplete': isProfileComplete};
    } on FirebaseAuthException catch (e) {
      // 👇 CHANGED: If the email already exists with a different provider,
      // surface a structured exception so the UI can show the link modal
      // (mirroring your Facebook flow).
      if (e.code == 'account-exists-with-different-credential' ||
          e.code == 'email-already-in-use') {
        // We expect Firebase to include credential & email; fall back to the
        // Google attempt email if needed.
        final AuthCredential? pending = e.credential;
        final String? email =
            e.email ?? attemptedEmail ?? _auth.currentUser?.email;

        if (pending != null && email != null) {
          List<String> methods = const [];
          try {
            methods = await _auth.fetchSignInMethodsForEmail(email);
          } catch (_) {
            // if fetch fails, leave methods empty – UI can still show guidance
          }

          throw GoogleLinkRequired(
            pendingGoogleCredential: pending,
            email: email,
            existingMethods: methods,
          );
        }
      }

      log('Firebase Auth Error: ${e.code} - ${e.message}');
      throw AuthException(_getFirebaseAuthErrorMessage(e.code), e.code);
    } catch (e) {
      log('Google Sign-In Error: $e');

      // Handle specific Google Sign-In errors
      final es = e.toString();
      if (es.contains('PigeonUserDetails')) {
        throw AuthException(
          'Google Sign-In configuration error. Please check your setup.',
          'google-config-error',
        );
      } else if (es.contains('network_error') ||
          es.contains('network-request-failed')) {
        throw AuthException(
          'Network error. Please check your internet connection.',
          'network-error',
        );
      } else if (es.contains('sign_in_canceled')) {
        return null; // User cancelled
      } else if (es.contains('sign_in_failed')) {
        throw AuthException(
          'Google Sign-In failed. Please try again.',
          'google-signin-failed',
        );
      }

      throw AuthException(
        'An unexpected error occurred during sign-in',
        'unknown-error',
      );
    }
  }

  /// Create a new user document in Firestore (snake_case schema)
  /// Seeds `linked_providers` with ['google.com'] for first-time Google sign-in.
  Future<void> _createUserDocument(User user) async {
    try {
      final userData = {
        'uid': user.uid,
        'email': user.email ?? '',
        'display_name': user.displayName ?? '',
        'photo_url': user.photoURL ?? '',
        'created_at': FieldValue.serverTimestamp(),
        'last_login_at': FieldValue.serverTimestamp(),
        'updated_at': FieldValue.serverTimestamp(),
        'profile_setup_complete': false,
        'linked_providers': <String>['google.com'],
      };

      await _firestore.collection('users').doc(user.uid).set(userData);
      log('User document created successfully');
    } catch (e) {
      log('Error creating user document: $e');
      throw AuthException('Failed to create user profile', 'firestore-error');
    }
  }

  /// Sign out from both Firebase and Google Sign-In
  Future<void> signOut() async {
    try {
      // Sign out from Firebase first
      await _auth.signOut();

      // Then sign out from Google Sign-In
      await _googleSignIn.signOut();

      // Also disconnect to ensure clean state
      try {
        await _googleSignIn.disconnect();
      } catch (_) {}

      log('User signed out successfully');
    } catch (e) {
      log('Error during sign out: $e');
      // Don't throw error for sign out failures, just log them
    }
  }

  /// Check if user is currently signed in
  bool get isSignedIn => _auth.currentUser != null;

  /// Get current user
  User? get currentUser => _auth.currentUser;

  /// Stream of authentication state changes
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  /// Update user profile completion status (snake_case)
  Future<void> updateProfileSetupStatus(String uid, bool isComplete) async {
    try {
      await _firestore.collection('users').doc(uid).update({
        'profile_setup_complete': isComplete,
        'updated_at': FieldValue.serverTimestamp(),
      });
      log('Profile setup status updated: $isComplete');
    } catch (e) {
      log('Error updating profile setup status: $e');
      throw AuthException(
        'Failed to update profile status',
        'profile-update-error',
      );
    }
  }

  /// Get user data from Firestore
  Future<Map<String, dynamic>?> getUserData(String uid) async {
    try {
      final doc = await _firestore.collection('users').doc(uid).get();
      if (doc.exists) {
        return doc.data() as Map<String, dynamic>?;
      }
      return null;
    } catch (e) {
      log('Error getting user data: $e');
      throw AuthException('Failed to get user data', 'get-user-data-error');
    }
  }

  /// Convert Firebase Auth error codes to user-friendly messages
  String _getFirebaseAuthErrorMessage(String errorCode) {
    switch (errorCode) {
      case 'account-exists-with-different-credential':
        return 'An account already exists with a different sign-in method.';
      case 'invalid-credential':
        return 'The credential is invalid or has expired.';
      case 'operation-not-allowed':
        return 'Google Sign-In is not enabled for this project.';
      case 'user-disabled':
        return 'This user account has been disabled.';
      case 'user-not-found':
        return 'No user found with this credential.';
      case 'wrong-password':
        return 'Incorrect password provided.';
      case 'invalid-verification-code':
        return 'The verification code is invalid.';
      case 'invalid-verification-id':
        return 'The verification ID is invalid.';
      case 'network-request-failed':
        return 'Network error. Please check your internet connection.';
      case 'too-many-requests':
        return 'Too many requests. Please try again later.';
      case 'user-token-expired':
        return 'Your session has expired. Please sign in again.';
      case 'invalid-api-key':
        return 'Invalid API key. Please check your Firebase configuration.';
      case 'app-not-authorized':
        return 'This app is not authorized to use Firebase Authentication.';
      default:
        return 'An authentication error occurred. Please try again.';
    }
  }
}
