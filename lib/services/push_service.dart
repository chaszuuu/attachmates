// lib/services/push_service.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// NEW: request Android 13+ notification permission from Dart
import 'package:permission_handler/permission_handler.dart';

import 'fcm_token_service.dart';

/// Match the backend's channel id (used in send_to_user(..., android_channel_id: ...))
const String _kChannelId = 'high_importance_channel';
const String _kChannelName = 'High Importance Notifications';
const String _kChannelDesc = 'General alerts like messages, likes, matches';

typedef NotificationTapHandler = void Function(Map<String, dynamic> data);

class PushService {
  static final FirebaseMessaging _fm = FirebaseMessaging.instance;
  static final FlutterLocalNotificationsPlugin _ln =
      FlutterLocalNotificationsPlugin();

  static NotificationTapHandler? onNotificationTap;

  static bool _initialized = false;
  static bool _channelReady = false;

  /// Call once after Firebase.initializeApp()
  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    // ---- Permissions (iOS); Android permission handled in enable() ----
    try {
      await _fm.requestPermission(alert: true, badge: true, sound: true);
    } catch (_) {}

    // Keep device token saved & refreshed for the signed-in user (idempotent)
    await FcmTokenService.saveForCurrentUser();
    FcmTokenService.bindAutoRefresh();

    // ---- Local notifications bootstrap ----
    await _initFlutterLocalNotifications();

    // iOS: show system alert while app is in foreground as well
    if (Platform.isIOS) {
      await _fm.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );
    }

    // ---- Foreground FCM → show a local clone (Android + iOS) ----
    FirebaseMessaging.onMessage.listen((RemoteMessage msg) async {
      final notif = msg.notification;
      final data = msg.data;

      // Ensure channel exists (Android)
      if (Platform.isAndroid && !_channelReady) {
        await _ensureAndroidChannel();
      }

      final title = notif?.title ?? data['title'];
      final body = notif?.body ?? data['body'];

      if (title != null || body != null) {
        final androidDetails = AndroidNotificationDetails(
          _kChannelId,
          _kChannelName,
          channelDescription: _kChannelDesc,
          importance: Importance.high,
          priority: Priority.high,
          playSound: true,
          enableVibration: true,
          icon:
              '@mipmap/ic_launcher', // change to '@mipmap/ic_notification' if you add one
        );
        const iosDetails = DarwinNotificationDetails(
          presentAlert: true,
          presentSound: true,
          presentBadge: false,
        );

        await _ln.show(
          _hashId(msg),
          title ?? '',
          body ?? '',
          NotificationDetails(android: androidDetails, iOS: iosDetails),
          payload: _encodePayload(data),
        );
      }
    });

    // ---- Taps from background (OS banner tap) ----
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage msg) {
      _handleTap(msg.data);
    });

    // ---- Launched from terminated state ----
    final initial = await _fm.getInitialMessage();
    if (initial != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _handleTap(initial.data);
      });
    }
  }

  /// ===== NEW: Toggle-friendly helpers =====
  /// Call when the Settings toggle is turned ON.
  static Future<bool> enable() async {
    await init();

    // Android 13+ runtime permission
    if (Platform.isAndroid) {
      final status = await Permission.notification.request();
      if (!status.isGranted) return false;
    }

    // iOS permission (idempotent)
    try {
      final p =
          await _fm.requestPermission(alert: true, badge: true, sound: true);
      final ok = p.authorizationStatus == AuthorizationStatus.authorized ||
          p.authorizationStatus == AuthorizationStatus.provisional;
      if (!ok && Platform.isIOS) return false;
    } catch (_) {
      // ignore
    }

    // Ensure channel exists (Android)
    if (Platform.isAndroid && !_channelReady) {
      await _ensureAndroidChannel();
    }

    // (Re)bind token for the current user
    await FcmTokenService.saveForCurrentUser();
    // Ensure token auto-refresh keeps mapping up to date
    FcmTokenService.bindAutoRefresh();

    return true;
  }

  /// Call when the Settings toggle is turned OFF.
  static Future<void> disable() async {
    try {
      // Mark this device disabled for the current user so backend won’t send to it.
      await FcmTokenService.disableForCurrentDevice();
    } catch (_) {
      // If your FcmTokenService doesn’t have this yet, implement it to flip enabled=false
      // under users/{uid}/devices/{deviceId}.
    }
  }

  /// ===== END NEW =====

  // ===== Local notifications setup =====
  static Future<void> _initFlutterLocalNotifications() async {
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );

    const init = InitializationSettings(android: androidInit, iOS: iosInit);

    await _ln.initialize(
      init,
      onDidReceiveNotificationResponse: (NotificationResponse r) {
        _handleTap(_decodePayload(r.payload));
      },
      onDidReceiveBackgroundNotificationResponse:
          _onDidReceiveBackgroundResponse,
    );

    if (Platform.isAndroid) {
      await _ensureAndroidChannel();
    }
  }

  static Future<void> _ensureAndroidChannel() async {
    if (_channelReady) return;
    final androidImpl = _ln.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidImpl != null) {
      await androidImpl.createNotificationChannel(
        const AndroidNotificationChannel(
          _kChannelId,
          _kChannelName,
          description: _kChannelDesc,
          importance: Importance.high,
        ),
      );
      _channelReady = true;
    }
  }

  // ===== Helpers =====
  static void _handleTap(Map<String, dynamic> data) {
    try {
      onNotificationTap?.call(data);
    } catch (e) {
      debugPrint('PushService tap handler error: $e');
    }
  }

  static String? _encodePayload(Map<String, dynamic>? data) {
    if (data == null || data.isEmpty) return null;
    try {
      return jsonEncode(data);
    } catch (_) {
      return data.entries.map((e) => '${e.key}=${e.value}').join('&');
    }
  }

  static Map<String, dynamic> _decodePayload(String? payload) {
    if (payload == null || payload.isEmpty) return const {};
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v));
      }
    } catch (_) {
      final parts = payload.split('&');
      final out = <String, dynamic>{};
      for (final p in parts) {
        final i = p.indexOf('=');
        if (i > 0) out[p.substring(0, i)] = p.substring(i + 1);
      }
      return out;
    }
    return const {};
  }

  static int _hashId(RemoteMessage m) {
    final key =
        '${m.messageId ?? ''}|${m.sentTime?.millisecondsSinceEpoch ?? 0}|${m.data['chatId'] ?? m.data['chat_id'] ?? ''}';
    return key.hashCode & 0x7fffffff;
  }
}

/// Top-level background handler (optional if you already registered one in main()).
/// If you use this, register it in main():
/// FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint('BG message: ${message.messageId} data=${message.data}');
}

/// Background tap handler for local notifications (Android 12L+ can invoke this)
@pragma('vm:entry-point')
void _onDidReceiveBackgroundResponse(NotificationResponse r) {
  // App will resume; foreground initialize() handler will process the tap.
}
