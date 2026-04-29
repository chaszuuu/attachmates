import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class ChatHelpers {
  /// Safe local conversion for Firestore Timestamp
  static DateTime? asLocal(Timestamp? t) => t?.toDate().toLocal();

  /// Same calendar day
  static bool isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// Cluster join check (IG-style connected corners)
  static bool connectsToPrev(
    int i,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs, {
    required Duration clusterGap,
  }) {
    if (i <= 0) return false;
    final curr = docs[i].data();
    final prev = docs[i - 1].data();

    final String s1 = (curr['sender_uid'] ?? '') as String? ?? '';
    final String s2 = (prev['sender_uid'] ?? '') as String? ?? '';
    if (s1 != s2) return false;

    final DateTime? t1 = asLocal(curr['created_at'] as Timestamp?);
    final DateTime? t2 = asLocal(prev['created_at'] as Timestamp?);
    if (t1 == null || t2 == null) return false;

    return isSameDay(t1, t2) && (t2.difference(t1).abs() <= clusterGap);
  }

  static bool connectsToNext(
    int i,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs, {
    required Duration clusterGap,
  }) {
    if (i >= docs.length - 1) return false;
    final curr = docs[i].data();
    final next = docs[i + 1].data();

    final String s1 = (curr['sender_uid'] ?? '') as String? ?? '';
    final String s2 = (next['sender_uid'] ?? '') as String? ?? '';
    if (s1 != s2) return false;

    final DateTime? t1 = asLocal(curr['created_at'] as Timestamp?);
    final DateTime? t2 = asLocal(next['created_at'] as Timestamp?);
    if (t1 == null || t2 == null) return false;

    return isSameDay(t1, t2) && (t2.difference(t1).abs() <= clusterGap);
  }

  /// IG-style “big gap within same day”
  static bool hasSignificantGap(DateTime newer, DateTime? older,
      {Duration gap = const Duration(hours: 8)}) {
    if (older == null) return true;
    if (!isSameDay(newer, older)) return false;
    return newer.difference(older).abs() >= gap;
  }

  /// Rounded bubble radius with flattened inner corners
  static BorderRadius bubbleRadius({
    required bool isMe,
    required bool connectPrev,
    required bool connectNext,
    double outer = 18,
    double inner = 6,
  }) {
    final double topLeft = isMe ? outer : (connectNext ? inner : outer);
    final double bottomLeft = isMe ? outer : (connectPrev ? inner : outer);
    final double topRight = isMe ? (connectNext ? inner : outer) : outer;
    final double bottomRight = isMe ? (connectPrev ? inner : outer) : outer;

    return BorderRadius.only(
      topLeft: Radius.circular(topLeft),
      bottomLeft: Radius.circular(bottomLeft),
      topRight: Radius.circular(topRight),
      bottomRight: Radius.circular(bottomRight),
    );
  }
}
