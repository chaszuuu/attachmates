// lib/repositories/admin_repository.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import '../utils/api_client.dart';

class AdminRepository {
  // ---- Verification queue (REST, still used by approve/reject) ----
  static Future<Map<String, dynamic>> fetchPending({
    int limit = 20,
    String? cursor,
  }) =>
      ApiClient.adminFetchPending(limit: limit, cursor: cursor);

  static Future<int> fetchPendingCount() => ApiClient.adminFetchPendingCount();

  static Future<void> approve(String uid) => ApiClient.adminApprove(uid);

  static Future<void> reject(String uid, String reason) =>
      ApiClient.adminReject(uid, reason);

  // ---- Roles ----
  static Future<List<dynamic>> listAdmins() => ApiClient.adminListAdmins();

  static Future<Map<String, dynamic>> grantRole(String uid, String role) =>
      ApiClient.adminGrantRole(uid, role);

  static Future<Map<String, dynamic>> revokeRole(String uid, String role) =>
      ApiClient.adminRevokeRole(uid, role);

  // ---- Realtime Firestore Stream (handles status casing) ----
  static Stream<List<Map<String, dynamic>>> pendingStream({int limit = 100}) {
    final q = FirebaseFirestore.instance.collection('users').where(
        'identity_verification.status',
        whereIn: ['pending', 'Pending']).limit(limit);

    final base = q.snapshots().map((snap) {
      final list = snap.docs.map((doc) {
        final data = doc.data() as Map<String, dynamic>;
        final iv =
            (data['identity_verification'] ?? {}) as Map<String, dynamic>;

        return {
          'uid': doc.id,
          ...data,
          // Normalize for UI (no URLs stored in iv now; keep name fallbacks)
          'displayName': data['displayName'] ?? data['display_name'] ?? '',
          // Keep profile_image_url if you use it elsewhere (not the signed one)
          'profile_image_url': data['profile_image_url'] ?? '',
          // Submitted timestamp (Firestore Timestamp or null)
          'verificationSubmittedAt': iv['submitted_at'],
        };
      }).toList();

      // Debug visibility (first few IDs)
      // ignore: avoid_print
      print('[pendingStream] found ${list.length} pending '
          '(ids: ${list.map((e) => e["uid"]).take(5).toList()})');

      return list;
    });

    return base.asBroadcastStream();
  }

  static Stream<int> pendingCountStream({int limit = 100}) =>
      pendingStream(limit: limit).map((l) => l.length);

  // ---- Signed media (Supabase) ----
  // Fetch short-lived signed URLs for selfie / front ID / back ID
  static Future<Map<String, String>> fetchVerificationMedia(
    String uid, {
    int expires = 3600,
  }) async {
    final m = await ApiClient.adminGetVerificationMedia(uid, expires: expires);
    return {
      'selfie_url': (m['selfie_url'] ?? '').toString(),
      'front_id_url': (m['front_id_url'] ?? '').toString(),
      'back_id_url': (m['back_id_url'] ?? '').toString(),
    };
  }
}
