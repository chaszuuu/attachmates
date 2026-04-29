import 'package:shared_preferences/shared_preferences.dart';

/// =====================
/// Low-level clear helpers (yours)
/// =====================

/// Clears profile setup, liveness, ID verification, and interests data only.
Future<void> clearProfilePrefs() async {
  final prefs = await SharedPreferences.getInstance();

  // Profile setup info
  await prefs.remove('profile_image_path');
  await prefs.remove('first_name');
  await prefs.remove('last_name');
  await prefs.remove('gender');
  await prefs.remove('dob_display');
  await prefs.remove('dob_iso');
  await prefs.remove('bio');
  await prefs.remove('age');

  // Interests
  await prefs.remove('interests_labels_v1');
  await prefs.remove('interests_slugs_v1');

  // Liveness/selfie
  await prefs.remove('liveness_selfie_path');

  // ID verification
  await prefs.remove('id_front_image_path');
  await prefs.remove('id_back_image_path');
  await prefs.remove('id_type');
}

/// Clears all quiz-related preferences only.
/// Handles both current list-style keys and any legacy per-question keys.
Future<void> clearQuizPrefs() async {
  final prefs = await SharedPreferences.getInstance();

  // --- Current storage (from your files) ---
  // Attachment Style (list per page)
  await prefs.remove('attachment_answers_p1_v1');
  await prefs.remove('attachment_answers_p2_v1');
  await prefs.remove('attachment_answers_p3_v1');

  // Love Language (list of 30 letters)
  await prefs.remove('love_language_responses_v1');

  // Preferred Match (if used elsewhere)
  await prefs.remove('preferred_match_v1');

  // --- Legacy/per-question fallbacks (safe to keep for backwards compat) ---
  for (var i = 0; i < 20; i++) {
    await prefs.remove('attachment_page1_v1_q$i');
    await prefs.remove('attachment_page2_v1_q$i');
    await prefs.remove('attachment_page3_v1_q$i');
  }
  for (var i = 0; i < 30; i++) {
    await prefs.remove('love_language_v1_q$i');
  }

  // Defensive sweep for any keys with known prefixes (future-proofing)
  final keys = prefs.getKeys();
  const prefixes = <String>{
    'attachment_answers_p', // catches any future page versions
    'love_language_responses',
    'attachment_page1_v1_q', // legacy
    'attachment_page2_v1_q',
    'attachment_page3_v1_q',
    'love_language_v1_q',
    'quiz_', // if you add generic quiz keys later
  };
  for (final k in keys) {
    if (prefixes.any((p) => k.startsWith(p))) {
      await prefs.remove(k);
    }
  }
}

/// Clears everything (profile + quiz) — use for full reset (e.g., on sign-out).
Future<void> clearAllPrefs() async {
  await clearProfilePrefs();
  await clearQuizPrefs();
  // NOTE: We intentionally DO NOT clear policies acceptance
  // so users don’t get the Terms/Privacy every sign-in.
}

/// =====================
/// New: tiny convenience wrapper
/// =====================

/// Common keys
class PrefKeys {
  static const notifEnabled = 'notif_enabled';

  // ⬇️ NEW: Policies gate key (keep in one place)
  static const policiesAccepted = 'policiesAccepted_v2';
}

/// Simple static helpers used across the app (matches your current call sites).
class SharedPref {
  static Future<bool?> getBool(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(key);
  }

  static Future<void> setBool(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  static Future<String?> getString(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(key);
  }

  static Future<void> setString(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);
  }

  static Future<int?> getInt(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(key);
  }

  static Future<void> setInt(String key, int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(key, value);
  }

  static Future<void> remove(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
  }
}

/// Optional: higher-level convenience for notifications
Future<bool> getNotifEnabled({bool defaultValue = true}) async {
  final v = await SharedPref.getBool(PrefKeys.notifEnabled);
  return v ?? defaultValue;
}

Future<void> setNotifEnabled(bool enabled) async {
  await SharedPref.setBool(PrefKeys.notifEnabled, enabled);
}

/// =====================
/// NEW: Policies helpers (optional, nice for QA/dev tools)
/// =====================

Future<bool> getPoliciesAccepted() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(PrefKeys.policiesAccepted) ?? false;
}

Future<void> setPoliciesAccepted(bool accepted) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(PrefKeys.policiesAccepted, accepted);
}

/// Reset just the policies gate (handy for testing the modals again)
Future<void> resetPoliciesAccepted() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(PrefKeys.policiesAccepted);
  // Optional: clean up any older key if it ever existed
  await prefs.remove('policiesAccepted_v1');
}
