// lib/utils/chat_queries.dart
import 'package:cloud_firestore/cloud_firestore.dart';

/// Centralized chat queries for the inbox
/// - Filters by membership
/// - When [hideEnded] is true: shows ACTIVE chats and ENDED-BY-BLOCK chats,
///   but hides ENDED-BY-UNMATCH chats.
/// - Deterministic order: last_message_at desc, then docId desc
/// - Pagination uses startAfterDocument to avoid composite cursor mistakes
class ChatQueries {
  // Collection and field names
  static const String kCollectionChats = 'chats';
  static const String kMembers = 'members';
  static const String kLastMessageAt = 'last_message_at';

  // End state fields on chats
  static const String kIsEnded = 'is_ended'; // bool
  static const String kEndedReason = 'ended_reason'; // 'blocked' | 'unmatched'

  /// Base query – newest first with stable tie-breaker on docId
  ///
  /// When [hideEnded] is true (default), the query will:
  ///   - include chats where is_ended == false (active), OR
  ///   - include chats where is_ended == true AND ended_reason == 'blocked'
  /// This keeps blocked conversations visible in the inbox,
  /// while hiding unmatched/declined ones.
  static Query<Map<String, dynamic>> base(String uid, {bool hideEnded = true}) {
    Query<Map<String, dynamic>> q = FirebaseFirestore.instance
        .collection(kCollectionChats)
        .where(kMembers, arrayContains: uid);

    if (hideEnded) {
      // Show active OR ended by block
      q = q.where(
        Filter.or(
          Filter(kIsEnded, isEqualTo: false),
          Filter.and(
            Filter(kIsEnded, isEqualTo: true),
            Filter(kEndedReason, isEqualTo: 'blocked'),
          ),
        ),
      );
    }

    return q
        .orderBy(kLastMessageAt, descending: true)
        .orderBy(FieldPath.documentId, descending: true);
  }

  /// Top stream for live inbox – usually no cursor, just a limit
  static Stream<QuerySnapshot<Map<String, dynamic>>> streamTop({
    required String uid,
    int limitTo = 30,
    bool hideEnded = true,
  }) {
    return base(uid, hideEnded: hideEnded).limit(limitTo).snapshots();
  }

  /// First page – one-shot fetch for initial list or older pages logic
  static Future<QuerySnapshot<Map<String, dynamic>>> pageFirst({
    required String uid,
    int limitTo = 30,
    bool hideEnded = true,
  }) {
    return base(uid, hideEnded: hideEnded).limit(limitTo).get();
  }

  /// Next page – pass the last document of the previous page
  static Future<QuerySnapshot<Map<String, dynamic>>> pageNext({
    required String uid,
    required DocumentSnapshot<Map<String, dynamic>> lastDoc,
    int limitTo = 30,
    bool hideEnded = true,
  }) {
    return base(uid, hideEnded: hideEnded)
        .startAfterDocument(lastDoc)
        .limit(limitTo)
        .get();
  }

  /// Optional – run once to verify field types in your data
  /// Expect kLastMessageAt to always be a Timestamp
  static Future<void> probeTypes(String uid) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection(kCollectionChats)
          .where(kMembers, arrayContains: uid)
          .limit(10)
          .get();

      for (final d in snap.docs) {
        final v = d.data()[kLastMessageAt];
        // ignore: avoid_print
        print('[PROBE] ${d.id} $kLastMessageAt => $v (${v.runtimeType})');
      }
    } catch (e, st) {
      // ignore: avoid_print
      print('[PROBE][ERROR] $e\n$st');
    }
  }
}
