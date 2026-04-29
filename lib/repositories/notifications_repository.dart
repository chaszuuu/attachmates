// lib/repositories/notifications_repository.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/app_notification.dart';

class NotificationsRepository {
  final FirebaseAuth _auth;
  final FirebaseFirestore _fs;

  NotificationsRepository({
    FirebaseAuth? auth,
    FirebaseFirestore? firestore,
  })  : _auth = auth ?? FirebaseAuth.instance,
        _fs = firestore ?? FirebaseFirestore.instance;

  /// Resolve UID from explicit [uid] or current user.
  String? _resolveUid(String? uid) => uid ?? _auth.currentUser?.uid;

  /// Stream ALL notifications (newest first).
  /// - Backwards-compatible: can be called with no args.
  /// - Use [uid] to pin to a specific user (e.g., inside authStateChanges()).
  /// - [limit] is a safety cap to avoid unbounded streams.
  Stream<List<AppNotification>> streamAll({String? uid, int limit = 200}) {
    final u = _resolveUid(uid);
    if (u == null || u.isEmpty) return const Stream.empty();

    return _fs
        .collection('users')
        .doc(u)
        .collection('notifications')
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((s) => s.docs.map(AppNotification.fromDoc).toList());
  }

  /// Unread count as a realtime stream (used for the bell badge).
  /// NOTE: This returns the *size of the live query*, not an aggregate count.
  Stream<int> unreadCountStream({String? uid, int safetyLimit = 500}) {
    final u = _resolveUid(uid);
    if (u == null || u.isEmpty) return Stream<int>.value(0);

    return _fs
        .collection('users')
        .doc(u)
        .collection('notifications')
        .where('read', isEqualTo: false)
        .limit(safetyLimit) // safety cap; UI can show "99+" etc.
        .snapshots()
        .map((s) => s.size);
  }

  /// One-shot unread count (not a stream).
  Future<int> getUnreadCountOnce({String? uid, int safetyLimit = 1000}) async {
    final u = _resolveUid(uid);
    if (u == null || u.isEmpty) return 0;

    final q = await _fs
        .collection('users')
        .doc(u)
        .collection('notifications')
        .where('read', isEqualTo: false)
        .limit(safetyLimit)
        .get();

    return q.size;
  }

  /// Mark a single notification as read.
  Future<void> markRead(String id, {String? uid}) async {
    final u = _resolveUid(uid);
    if (u == null || u.isEmpty) return;

    await _fs
        .collection('users')
        .doc(u)
        .collection('notifications')
        .doc(id)
        .set({'read': true}, SetOptions(merge: true));
  }

  /// Mark all unread notifications as read (paged batch).
  Future<void> markAllRead({String? uid, int pageSize = 500}) async {
    final u = _resolveUid(uid);
    if (u == null || u.isEmpty) return;

    final q = await _fs
        .collection('users')
        .doc(u)
        .collection('notifications')
        .where('read', isEqualTo: false)
        .limit(pageSize)
        .get();

    if (q.docs.isEmpty) return;

    final batch = _fs.batch();
    for (final d in q.docs) {
      batch.set(d.reference, {'read': true}, SetOptions(merge: true));
    }
    await batch.commit();
  }

  // -------------------------
  // 🔻 NEW: Delete operations
  // -------------------------

  /// Delete a single notification document.
  Future<void> delete(String id, {String? uid}) async {
    final u = _resolveUid(uid);
    if (u == null || u.isEmpty) return;

    await _fs
        .collection('users')
        .doc(u)
        .collection('notifications')
        .doc(id)
        .delete();
  }

  /// Delete ALL notifications for the user.
  /// Uses paged batch deletes to avoid exceeding write limits.
  Future<void> clearAll({String? uid, int batchSize = 400}) async {
    final u = _resolveUid(uid);
    if (u == null || u.isEmpty) return;

    final col = _fs.collection('users').doc(u).collection('notifications');

    while (true) {
      final snap = await col.limit(batchSize).get();
      if (snap.docs.isEmpty) break;

      final batch = _fs.batch();
      for (final d in snap.docs) {
        batch.delete(d.reference);
      }
      await batch.commit();

      if (snap.docs.length < batchSize) break;
    }
  }
}
