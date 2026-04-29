import 'dart:developer';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// Shared helper to sync FirebaseAuth provider data to Firestore
/// Field: users/{uid}.linked_providers
class AuthLinkHelper {
  static final _auth = FirebaseAuth.instance;
  static final _firestore = FirebaseFirestore.instance;

  /// Mirror all linked providers from FirebaseAuth into Firestore
  static Future<void> syncLinkedProviders({User? user}) async {
    try {
      final u = user ?? _auth.currentUser;
      if (u == null) return;

      await u.reload();
      final providers = u.providerData
          .map((p) => p.providerId)
          .where((id) => id != 'firebase')
          .toSet()
          .toList()
        ..sort(); // stable order for diffs

      await _firestore.collection('users').doc(u.uid).set(
        {'linked_providers': providers},
        SetOptions(merge: true),
      );
    } catch (e, st) {
      log('AuthLinkHelper.syncLinkedProviders error: $e', stackTrace: st);
    }
  }

  /// Add or remove a single provider manually (rarely used).
  static Future<void> addProvider(String providerId) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    await _firestore.collection('users').doc(uid).set({
      'linked_providers': FieldValue.arrayUnion([providerId]),
    }, SetOptions(merge: true));
  }

  static Future<void> removeProvider(String providerId) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    await _firestore.collection('users').doc(uid).set({
      'linked_providers': FieldValue.arrayRemove([providerId]),
    }, SetOptions(merge: true));
  }
}
