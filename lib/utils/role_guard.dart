import 'package:firebase_auth/firebase_auth.dart';

class RoleGuard {
  const RoleGuard._();

  // Public helper if you want to inspect roles elsewhere.
  static Future<List<String>> roles() async => _roles();

  static Future<List<String>> _roles() async {
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) return [];

    // Force refresh to make sure latest custom claims are fetched
    final res = await u.getIdTokenResult(true);
    final claims = res.claims ?? const {};
    final raw = claims['roles'];

    // Accept list or single string; normalize to lower-case strings
    if (raw is List) {
      return raw
          .map((e) => e.toString())
          .where((s) => s.trim().isNotEmpty)
          .map((s) => s.toLowerCase())
          .toList();
    } else if (raw is String && raw.trim().isNotEmpty) {
      return [raw.toLowerCase()];
    }
    return [];
  }

  static Future<bool> hasAny(List<String> wanted) async {
    final r = await _roles();
    final want = wanted.map((s) => s.toLowerCase()).toSet();
    return r.any((x) => want.contains(x));
  }

  static Future<bool> isReviewerOrAbove() =>
      hasAny(const ['reviewer', 'admin', 'superadmin']);

  static Future<bool> isAdminOrAbove() => hasAny(const ['admin', 'superadmin']);

  static Future<bool> isSuperadmin() => hasAny(const ['superadmin']);
}
