// lib/utils/chat_service.dart
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import 'api_client.dart';
import 'api_config.dart';
import 'reply_meta.dart';

class ChatService {
  ChatService._();

  // ---- Backend actions -------------------------------------------------------

  static Future<String> startChatViaBackend(String matchId) async {
    final resp = await ApiClient.postJson('/start-chat', {'match_id': matchId});
    if (resp.statusCode != 200) {
      throw Exception('Start chat failed: ${resp.statusCode} ${resp.body}');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['chat_id'] as String);
  }

  static Future<void> unmatchViaBackend(String matchId) async {
    final resp = await ApiClient.postJson('/unmatch', {'match_id': matchId});
    if (resp.statusCode != 200) {
      throw Exception('Unmatch failed: ${resp.statusCode} ${resp.body}');
    }
  }

  /// Send a message via backend (text or heart).
  /// Returns `true` iff this was the **first** message in the chat.
  ///
  /// If [reply] is provided, we also PATCH the created Firestore message with the
  /// reply_* fields so the UI can render the quoted preview (in case the backend
  /// doesn't persist them).
  static Future<bool> sendMessage({
    required String chatId,
    String? text,
    bool isHeart = false,
    ReplyMeta? reply,
  }) async {
    if (chatId.isEmpty) {
      throw Exception('chat_id cannot be empty');
    }

    final Map<String, dynamic> payload = {
      'chat_id': chatId,
      if (isHeart) 'type': 'heart' else 'text': (text ?? '').trim(),
    };

    if (!isHeart && ((payload['text'] as String).isEmpty)) {
      throw Exception('Message text cannot be empty');
    }

    // Include both the new keys (UI) and legacy ones (backend compat)
    _mergeReply(payload, reply);

    final resp = await ApiClient.postJson('/send-message', payload);
    if (resp.statusCode != 200) {
      throw Exception('Send message failed: ${resp.statusCode} ${resp.body}');
    }

    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final bool first = body['first_message'] == true;

    // --- ⬇️ IMPORTANT PATCH: ensure Firestore doc has reply_* so UI can show it ---
    final String? createdMessageId = body['message_id'] as String?;
    if (reply != null &&
        createdMessageId != null &&
        createdMessageId.isNotEmpty) {
      try {
        final msgRef = _db
            .collection('chats')
            .doc(chatId)
            .collection('messages')
            .doc(createdMessageId);

        final patch = <String, dynamic>{};
        _mergeReply(patch, reply); // writes both new + legacy keys

        await msgRef.set(patch, SetOptions(merge: true));
      } catch (_) {
        // non-fatal; message still sent even if patch fails
      }
    }
    // --- ⬆️ END PATCH ---

    return first;
  }

  // ---- Image messages (backend) ---------------------------------------------

  static Future<Map<String, dynamic>> uploadImageToBackend({
    required String chatId,
    required File file,
    String? contentType,
    String? messageId,
    ReplyMeta? reply,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('Not authenticated');
    final token = await user.getIdToken();

    final uri = Uri.parse('${ApiConfig.baseUrl}/messages/image/upload');
    final ct = contentType ?? _guessImageContentType(file.path);

    final req = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer $token'
      ..fields['chat_id'] = chatId;

    if (messageId != null && messageId.isNotEmpty) {
      req.fields['message_id'] = messageId;
    }

    // include both key sets in multipart fields
    _mergeReplyIntoFields(req.fields, reply);

    req.files.add(
      await http.MultipartFile.fromPath(
        'file',
        file.path,
        contentType: ct != null ? MediaType.parse(ct) : null,
      ),
    );

    final resp = await req.send();
    final body = await resp.stream.bytesToString();
    if (resp.statusCode != 200) {
      throw Exception('Image upload failed: ${resp.statusCode} $body');
    }
    final Map<String, dynamic> json = jsonDecode(body) as Map<String, dynamic>;
    return json;
  }

  static String? _guessImageContentType(String path) {
    final p = path.toLowerCase();
    if (p.endsWith('.jpg') || p.endsWith('.jpeg')) return 'image/jpeg';
    if (p.endsWith('.png')) return 'image/png';
    if (p.endsWith('.webp')) return 'image/webp';
    if (p.endsWith('.gif')) return 'image/gif';
    return null;
  }

  // === Two-step flow (compat) ================================================

  static final FirebaseFirestore _db = FirebaseFirestore.instance;
  static String get _uid => FirebaseAuth.instance.currentUser!.uid;

  static Future<String> createPendingImageMessage({
    required String chatId,
    required int w,
    required int h,
    required int sizeBytes,
    ReplyMeta? reply,
  }) async {
    final payload = {
      'chat_id': chatId,
      'w': w,
      'h': h,
      'size_bytes': sizeBytes,
    };

    // include both key sets so backend seeds the doc with what UI reads
    _mergeReply(payload, reply);

    final resp = await ApiClient.postJson('/messages/image/start', payload);
    if (resp.statusCode != 200) {
      throw Exception(
          'start image message failed: ${resp.statusCode} ${resp.body}');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final messageId = (body['message_id'] as String?) ?? '';
    if (messageId.isEmpty) {
      throw Exception('start image message: missing message_id');
    }
    return messageId;
  }

  static Future<void> finalizeImageMessage({
    required String chatId,
    required String messageId,
    String? imageUrl,
    String? storagePath,
  }) async {
    if ((imageUrl == null || imageUrl.isEmpty) &&
        (storagePath == null || storagePath.isEmpty)) {
      throw Exception('finalizeImageMessage: provide storagePath or imageUrl');
    }

    final payload = {
      'chat_id': chatId,
      'message_id': messageId,
      if (storagePath != null) 'storage_path': storagePath,
      if (imageUrl != null) 'image_url': imageUrl,
    };

    final resp = await ApiClient.postJson('/messages/image/finalize', payload);
    if (resp.statusCode != 200) {
      throw Exception('finalize image failed: ${resp.statusCode} ${resp.body}');
    }
  }

  // ---- 🔊 Audio messages (Supabase via backend) -----------------------------

  /// Uploads a voice note to Supabase through the backend and returns the created `messageId`.
  /// Backend also bumps chat/match aggregates to show `[Audio]`.
  static Future<String> sendAudioMessage({
    required String chatId,
    required File file,
    required double durationSec,
    ReplyMeta? reply,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('Not authenticated');
    if (chatId.isEmpty) throw Exception('chatId is empty');

    // Optional pre-checks (keep UX consistent with old client-side flow)
    if (durationSec <= 0 || durationSec > 30.5) {
      throw Exception('Invalid duration (${durationSec.toStringAsFixed(1)}s)');
    }
    const double maxBytes = 2.5 * 1024 * 1024; // 2.5 MB
    final int bytes = await file.length();
    if (bytes > maxBytes) {
      throw Exception(
        'Audio too large (${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB > 2.5 MB)',
      );
    }

    final token = await user.getIdToken();
    final uri = Uri.parse('${ApiConfig.baseUrl}/messages/audio/upload');
    final ct = _guessAudioContentType(
        file.path); // helps the backend pick the right extension

    final req = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer $token'
      ..fields['chat_id'] = chatId
      ..fields['duration_sec'] = durationSec.toString();

    // include both key sets in multipart fields (reply preview support)
    _mergeReplyIntoFields(req.fields, reply);

    req.files.add(
      await http.MultipartFile.fromPath(
        'file',
        file.path,
        contentType: ct != null ? MediaType.parse(ct) : null,
      ),
    );

    final resp = await req.send();
    final body = await resp.stream.bytesToString();
    if (resp.statusCode != 200) {
      throw Exception('Audio upload failed: ${resp.statusCode} $body');
    }

    final json = jsonDecode(body) as Map<String, dynamic>;
    final messageId = (json['message_id'] as String?) ?? '';
    if (messageId.isEmpty) {
      throw Exception('Audio upload succeeded but missing message_id');
    }
    return messageId;
  }

  static String? _guessAudioContentType(String path) {
    final p = path.toLowerCase();
    if (p.endsWith('.m4a')) return 'audio/m4a'; // iOS/Android AAC in MP4
    if (p.endsWith('.aac')) return 'audio/aac';
    if (p.endsWith('.mp3')) return 'audio/mpeg';
    if (p.endsWith('.ogg')) return 'audio/ogg';
    if (p.endsWith('.webm')) return 'audio/webm';
    if (p.endsWith('.3gp')) return 'audio/3gpp';
    if (p.endsWith('.3g2')) return 'audio/3gpp2';
    return null; // backend will still accept and infer via filename
  }

  // ---- Receipts --------------------------------------------------------------

  static Future<void> ackDelivered({
    required String chatId,
    required String messageId,
  }) async {
    final resp = await ApiClient.postJson('/messages/ack-delivered', {
      'chat_id': chatId,
      'message_id': messageId,
    });
    if (resp.statusCode != 200) {
      throw Exception('ack-delivered failed: ${resp.statusCode} ${resp.body}');
    }
  }

  static Future<void> ackRead({
    required String chatId,
    required String messageId,
  }) async {
    final resp = await ApiClient.postJson('/messages/ack-read', {
      'chat_id': chatId,
      'message_id': messageId,
    });
    if (resp.statusCode != 200) {
      throw Exception('ack-read failed: ${resp.statusCode} ${resp.body}');
    }
  }

  // ---- Message removal -------------------------------------------------------

  static Future<void> removeMessageLocally({
    required String chatId,
    required String messageId,
  }) async {
    final msgRef = _db
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .doc(messageId);

    await msgRef.delete();
  }

  static Future<void> removeMessageViaBackend({
    required String chatId,
    required String messageId,
  }) async {
    final resp = await ApiClient.postJson('/messages/delete', {
      'chat_id': chatId,
      'message_id': messageId,
    });
    if (resp.statusCode != 200) {
      throw Exception('Delete failed: ${resp.statusCode} ${resp.body}');
    }
  }

  // ---- Firestore helpers -----------------------------------------------------

  static Future<void> markRead(String chatId) async {
    final chatRef = _db.collection('chats').doc(chatId);
    await _db.runTransaction((tx) async {
      final snap = await tx.get(chatRef);
      if (!snap.exists) return;
      final data = snap.data() as Map<String, dynamic>;
      final members = List<String>.from(data['members'] ?? const []);
      if (!members.contains(_uid)) return;

      final unread = Map<String, dynamic>.from(data['unread'] ?? {});
      if ((unread[_uid] ?? 0) > 0) {
        unread[_uid] = 0;
        tx.update(chatRef, {'unread': unread});
      }
    });
  }

  static Query<Map<String, dynamic>> inboxQuery() {
    return _db.collection('chats').where('members', arrayContains: _uid);
  }

  static Stream<QuerySnapshot<Map<String, dynamic>>> inboxStream() {
    return inboxQuery().snapshots(includeMetadataChanges: true);
  }

  // ---- Reactions (backend-driven) -------------------------------------------

  /// Toggle a reaction via backend.
  /// Returns `true` if the reaction is now active (set), `false` if it was removed.
  static Future<bool> toggleReaction({
    required String chatId,
    required String messageId,
    required String emoji,
  }) async {
    final resp = await ApiClient.postJson('/messages/react', {
      'chat_id': chatId,
      'message_id': messageId,
      'emoji': emoji,
    });

    if (resp.statusCode != 200) {
      throw Exception(
          'Toggle reaction failed: ${resp.statusCode} ${resp.body}');
    }

    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    // Backend returns: { ok, active: true/false, removed: bool }
    return (body['active'] == true);
  }

  /// Stream reaction counts for a message from the message doc's `reaction_counts` map.
  static Stream<Map<String, int>> reactionCounts(
    String chatId,
    String messageId,
  ) {
    final doc = _db
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .doc(messageId);

    return doc.snapshots().map((snap) {
      if (!snap.exists) return <String, int>{};
      final data = snap.data() as Map<String, dynamic>? ?? const {};
      final raw = (data['reaction_counts'] as Map?) ?? const {};
      final out = <String, int>{};
      for (final entry in raw.entries) {
        final k = entry.key?.toString() ?? '';
        final v = entry.value is int
            ? entry.value as int
            : int.tryParse('${entry.value}') ?? 0;
        if (k.isNotEmpty && v > 0) out[k] = v;
      }

      return out;
    });
  }

  // ===== Type & label helpers (NEW) ==========================================

  static String _canonicalReplyType(String? raw) {
    final t = (raw ?? '').trim().toLowerCase();
    if (t.isEmpty) return 'text';
    // Common aliases → canonical
    if (t == 'voice' || t == 'voice_note' || t == 'voicenote') return 'audio';
    if (t == 'pic' || t == 'photo') return 'image';
    const allowed = {'text', 'image', 'audio', 'video', 'file', 'heart'};
    return allowed.contains(t) ? t : 'text';
  }

  static String _defaultLabelForType(String type) {
    switch (type) {
      case 'audio':
        return 'Voice Message';
      case 'image':
        return 'Photo';
      case 'video':
        return 'Video';
      case 'file':
        return 'File';
      case 'heart':
        return 'Heart';
      default:
        return 'Message';
    }
  }

  // ===== Reply merge helpers ==================================================

  /// Merge reply meta into a JSON payload for POST requests.
  /// Writes BOTH new keys (used by UI) and legacy keys (backend compatibility).
  static void _mergeReply(Map<String, dynamic> payload, ReplyMeta? reply) {
    if (reply == null) return;

    final type = _canonicalReplyType(reply.type);
    final txt = reply.text?.trim();
    final th = reply.thumb;

    // New keys (what MessageBubble reads)
    payload['reply_to_id'] = reply.messageId;
    payload['reply_sender_uid'] = reply.senderUid;
    if (txt != null && txt.isNotEmpty) {
      payload['reply_text'] = txt;
    } else {
      // ensure a friendly label for non-text types (esp. audio)
      payload['reply_text'] = _defaultLabelForType(type);
    }
    payload['reply_type'] = type;
    if (th != null && th.isNotEmpty) {
      payload['reply_thumb'] = th;
    }
    payload['reply_deleted'] = reply.deleted;

    // Legacy keys (what your backend may already expect)
    payload['reply_to_message_id'] = reply.messageId;
    payload['reply_to_sender_uid'] = reply.senderUid;
    if (txt != null && txt.isNotEmpty) {
      payload['reply_to_text'] = txt;
    } else {
      payload['reply_to_text'] = _defaultLabelForType(type);
    }
    payload['reply_to_type'] = type;
    if (th != null && th.isNotEmpty) {
      payload['reply_to_thumb'] = th;
    }
    payload['reply_to_deleted'] = reply.deleted;
  }

  /// Merge reply meta into multipart form fields (image/audio upload).
  static void _mergeReplyIntoFields(
      Map<String, String> fields, ReplyMeta? reply) {
    if (reply == null) return;

    final type = _canonicalReplyType(reply.type);
    final txt = reply.text?.trim();
    final th = reply.thumb;

    // New keys
    fields['reply_to_id'] = reply.messageId;
    fields['reply_sender_uid'] = reply.senderUid;
    if (txt != null && txt.isNotEmpty) {
      fields['reply_text'] = txt;
    } else {
      fields['reply_text'] = _defaultLabelForType(type);
    }
    fields['reply_type'] = type;
    if (th != null && th.isNotEmpty) {
      fields['reply_thumb'] = th!;
    }
    fields['reply_deleted'] = reply.deleted ? 'true' : 'false';

    // Legacy keys
    fields['reply_to_message_id'] = reply.messageId;
    fields['reply_to_sender_uid'] = reply.senderUid;
    if (txt != null && txt.isNotEmpty) {
      fields['reply_to_text'] = txt;
    } else {
      fields['reply_to_text'] = _defaultLabelForType(type);
    }
    fields['reply_to_type'] = type;
    if (th != null && th.isNotEmpty) {
      fields['reply_to_thumb'] = th!;
    }
    fields['reply_to_deleted'] = reply.deleted ? 'true' : 'false';
  }
}
