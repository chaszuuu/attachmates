// lib/models/app_notification.dart
import 'package:cloud_firestore/cloud_firestore.dart';

enum AppNotifType { message, match, like, likeback, verification, unknown }

AppNotifType parseNotifType(String? s) {
  switch ((s ?? '').toLowerCase()) {
    case 'message':
      return AppNotifType.message;
    case 'match':
      return AppNotifType.match;
    case 'like':
      return AppNotifType.like;
    case 'likeback':
      return AppNotifType.likeback;
    case 'verification':
      return AppNotifType.verification;
    default:
      return AppNotifType.unknown;
  }
}

class AppNotification {
  final String id;
  final AppNotifType type;
  final String? title;
  final String? body;
  final Map<String, dynamic> data; // deep-link payload
  final bool read;
  final DateTime? createdAt;

  AppNotification({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.data,
    required this.read,
    required this.createdAt,
  });

  /// Matches repo usage: s.docs.map(AppNotification.fromDoc)
  factory AppNotification.fromDoc(
      QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data();
    final ts = d['createdAt'];
    final created =
        ts is Timestamp ? ts.toDate() : (ts is DateTime ? ts : null);

    return AppNotification(
      id: doc.id,
      type: parseNotifType(d['type'] as String?),
      title: d['title'] as String?,
      body: d['body'] as String?,
      data: Map<String, dynamic>.from(d['data'] as Map? ?? const {}),
      read: d['read'] == true,
      createdAt: created,
    );
  }
}

extension AppNotificationTime on DateTime {
  String toCompactAgo() {
    final now = DateTime.now();
    final diff = now.difference(this);
    if (diff.inSeconds < 45) return 'now';
    if (diff.inMinutes < 1) return '${diff.inSeconds}s';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    final d = diff.inDays;
    if (d < 7) return '${d}d';
    return '${month}/${day}';
  }
}
