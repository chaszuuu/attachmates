// lib/utils/role_manager.dart
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 👇 add this to fetch the pending verification count
import '../repositories/admin_repository.dart';

/// Lightweight provider that caches Firebase custom claims (roles)
/// so the UI (like SettingsScreen) can render instantly without flicker.
/// Also exposes a pending reviews badge count for reviewer+ roles.
class RoleManager extends ChangeNotifier {
  static const _prefsKey = 'cached_roles_v1';

  List<String> _roles = const [];
  bool _loaded = false;

  // ---- Pending count state (for reviewer+) ----
  int? _pendingCount;
  DateTime? _lastPendingFetch; // optional throttle

  List<String> get roles => _roles;
  bool get isLoaded => _loaded;

  // Expose pending count (null = unknown, 0 = none, >0 = show badge)
  int? get pendingCount => _pendingCount;

  bool get isReviewerOrAbove =>
      _hasAny(const ['reviewer', 'admin', 'superadmin']);
  bool get isAdminOrAbove => _hasAny(const ['admin', 'superadmin']);
  bool get isSuperadmin => _hasAny(const ['superadmin']);

  bool _hasAny(List<String> wanted) {
    final w = wanted.map((e) => e.toLowerCase()).toSet();
    return _roles.any((r) => w.contains(r.toLowerCase()));
  }

  /// Load from SharedPreferences instantly (no network).
  Future<void> hydrateFromCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null) {
        final list = (jsonDecode(raw) as List)
            .map((e) => e.toString().toLowerCase())
            .toList();
        _roles = list;
      }
    } catch (_) {}
    _loaded = true;
    notifyListeners();
  }

  /// Refresh from Firebase custom claims.
  /// Set [force]=true to re-fetch token and get updated roles from backend.
  Future<void> refresh({bool force = false}) async {
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) {
      _roles = const [];
      _loaded = true;
      _pendingCount = null; // clear badge on sign-out
      notifyListeners();
      return;
    }

    final res = await u.getIdTokenResult(force);
    final claims = res.claims ?? const {};
    final raw = claims['roles'];
    List<String> roles;

    if (raw is List) {
      roles = raw
          .map((e) => e.toString())
          .where((s) => s.trim().isNotEmpty)
          .map((s) => s.toLowerCase())
          .toList();
    } else if (raw is String && raw.trim().isNotEmpty) {
      roles = [raw.toLowerCase()];
    } else {
      roles = const [];
    }

    _roles = roles;
    _loaded = true;

    // Persist roles cache for instant next-boot rendering
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(_roles));
    } catch (_) {}

    notifyListeners();
  }

  /// Fetch the current pending review count (only if reviewer+).
  /// Uses a small throttle so rapid UI rebuilds don't spam the backend.
  Future<void> refreshPendingCount(
      {Duration throttle = const Duration(seconds: 10)}) async {
    if (!isReviewerOrAbove) {
      if (_pendingCount != null) {
        _pendingCount = null; // hide badge if user lost reviewer+ role
        notifyListeners();
      }
      return;
    }

    final now = DateTime.now();
    if (_lastPendingFetch != null &&
        now.difference(_lastPendingFetch!) < throttle) {
      return; // throttle repeated calls
    }
    _lastPendingFetch = now;

    try {
      final c = await AdminRepository.fetchPendingCount();
      if (_pendingCount != c) {
        _pendingCount = c;
        notifyListeners(); // 🎉 update UI immediately
      }
    } catch (_) {
      // Keep previous value on failure; no UI spam
    }
  }

  /// Clear all roles (on logout)
  Future<void> clear() async {
    _roles = const [];
    _loaded = true;
    _pendingCount = null;
    _lastPendingFetch = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsKey);
    } catch (_) {}
    notifyListeners();
  }
}
