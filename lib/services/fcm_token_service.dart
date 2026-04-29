// lib/services/fcm_token_service.dart
import 'dart:io' show Platform;
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FcmTokenService {
  static final _auth = FirebaseAuth.instance;
  static final _fs = FirebaseFirestore.instance;
  static final _fm = FirebaseMessaging.instance;

  // Prevent multiple onTokenRefresh listeners
  static bool _refreshBound = false;

  /// Persisted, stable per-device identifier (doc id under /users/{uid}/devices).
  /// We prefer a locally stored ID over volatile hardware strings.
  static Future<String> _deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    const key = 'device_id_v1';
    var id = prefs.getString(key);
    if (id == null || id.isEmpty) {
      // Build a simple, unique-ish id once and cache it
      final rand = Random();
      final salt = List.generate(6, (_) => rand.nextInt(36))
          .map((n) => '0123456789abcdefghijklmnopqrstuvwxyz'[n])
          .join();
      final os = Platform.operatingSystem;
      final ms = DateTime.now().millisecondsSinceEpoch;
      id = '$os-$ms-$salt';
      await prefs.setString(key, id);
    }
    return id;
  }

  static String _platform() => Platform.isIOS
      ? 'ios'
      : Platform.isAndroid
          ? 'android'
          : Platform.operatingSystem;

  /// Best-effort request for notification permission (mainly iOS / Android 13+).
  static Future<void> _ensurePermission() async {
    try {
      await _fm.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );
    } catch (_) {}
  }

  /// Save (or update) the current device's FCM token under users/{uid}/devices/{deviceId}.
  /// Also flips `enabled: true` so the backend will target this device.
  static Future<void> saveForCurrentUser() async {
    final user = _auth.currentUser;
    if (user == null) return;

    await _ensurePermission();

    final token = await _fm.getToken();
    if (token == null || token.isEmpty) return;

    final devId = await _deviceId();
    final ref =
        _fs.collection('users').doc(user.uid).collection('devices').doc(devId);

    // Write both `token` and `fcmToken` (backward compatibility with older backend)
    await ref.set({
      'token': token,
      'fcmToken': token,
      'platform': _platform(),
      'enabled': true, // 👈 mark this device as active
      'lastSeen': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Keep token up-to-date when FCM rotates it.
  static void bindAutoRefresh() {
    if (_refreshBound) return; // guard against multiple subscriptions
    _refreshBound = true;

    _fm.onTokenRefresh.listen((newToken) async {
      if (newToken.isEmpty) return;
      final user = _auth.currentUser;
      if (user == null) return;

      final devId = await _deviceId();
      final ref = _fs
          .collection('users')
          .doc(user.uid)
          .collection('devices')
          .doc(devId);

      await ref.set({
        'token': newToken,
        'fcmToken': newToken, // keep both fields in sync
        'platform': _platform(),
        'enabled': true, // keep enabled on refresh
        'lastSeen': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    });
  }

  /// Disable **this device** for the current user without deleting the doc or token.
  /// Backend should skip devices where `enabled == false`.
  static Future<void> disableForCurrentDevice() async {
    final user = _auth.currentUser;
    if (user == null) return;

    try {
      final devId = await _deviceId();
      final ref = _fs
          .collection('users')
          .doc(user.uid)
          .collection('devices')
          .doc(devId);

      await ref.set({
        'enabled': false,
        'disabledAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  /// (Optional helper) Re-enable this device without forcing a token refresh.
  static Future<void> enableForCurrentDevice() async {
    final user = _auth.currentUser;
    if (user == null) return;

    try {
      final devId = await _deviceId();
      final ref = _fs
          .collection('users')
          .doc(user.uid)
          .collection('devices')
          .doc(devId);

      await ref.set({
        'enabled': true,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  /// Remove this device mapping on sign-out and (optionally) delete the local FCM token
  /// so the next user on the same device gets a clean token.
  static Future<void> unbindCurrentUser(
      {bool deleteMessagingToken = true}) async {
    final user = _auth.currentUser;
    if (user != null) {
      try {
        final devId = await _deviceId();
        await _fs
            .collection('users')
            .doc(user.uid)
            .collection('devices')
            .doc(devId)
            .delete();
      } catch (_) {}
    }

    if (deleteMessagingToken) {
      try {
        await _fm.deleteToken();
      } catch (_) {}
    }
  }

  /// (Legacy helper) Remove the device doc but keep the local token.
  static Future<void> removeForCurrentUser() async {
    final user = _auth.currentUser;
    if (user == null) return;
    try {
      final devId = await _deviceId();
      await _fs
          .collection('users')
          .doc(user.uid)
          .collection('devices')
          .doc(devId)
          .delete();
    } catch (_) {}
  }
}
