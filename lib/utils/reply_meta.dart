// lib/utils/reply_meta.dart
import 'package:flutter/foundation.dart';

/// Lightweight metadata stored on the *replying* message
/// so bubbles can render a fast quoted preview without joins.
@immutable
class ReplyMeta {
  final String messageId; // original message id being replied to
  final String senderUid; // original sender uid
  final String? text;     // short text fallback (if any)
  final String type;      // 'text' | 'image' | 'audio' | 'video' | 'file'
  final String? thumb;    // optional tiny media preview (URL or storage path)
  final bool deleted;     // original got deleted/redacted

  const ReplyMeta({
    required this.messageId,
    required this.senderUid,
    this.text,
    this.type = 'text',
    this.thumb,
    this.deleted = false,
  });

  /// Keys used by MessageBubble (must match!)
  ///  - reply_to_id
  ///  - reply_sender_uid
  ///  - reply_text
  ///  - reply_thumb
  ///  - reply_type
  ///  - reply_deleted
  Map<String, dynamic> toMap() => {
        'reply_to_id': messageId,
        'reply_sender_uid': senderUid,
        if (text != null && text!.isNotEmpty) 'reply_text': text,
        'reply_type': type,
        if (thumb != null && thumb!.isNotEmpty) 'reply_thumb': thumb,
        'reply_deleted': deleted,
      };

  /// Backward-compatible factory: will read both the new keys (above)
  /// and your previous schema (reply_to_message_id, reply_to_sender_uid, …).
  factory ReplyMeta.from(Map<String, dynamic> m) => ReplyMeta(
        messageId: (m['reply_to_id'] ??
                m['replyToId'] ??
                m['reply_message_id'] ??
                m['replyMessageId'] ??
                m['reply_to_message_id']) as String,
        senderUid: (m['reply_sender_uid'] ??
                m['replySenderUid'] ??
                m['reply_from_uid'] ??
                m['reply_to_sender_uid']) as String,
        text: (m['reply_text'] ??
                m['replyText'] ??
                m['reply_preview'] ??
                m['replyPreview'] ??
                m['reply_body'] ??
                m['reply_to_text']) as String?,
        type: (m['reply_type'] ??
                m['replyType'] ??
                (m['reply_thumb'] != null ? 'image' : null) ??
                m['reply_to_type'] ??
                'text') as String,
        thumb: (m['reply_thumb'] ??
                m['replyThumb'] ??
                m['reply_image'] ??
                m['replyImage'] ??
                m['reply_to_thumb']) as String?,
        deleted: (m['reply_deleted'] ??
                m['replyDeleted'] ??
                m['reply_to_deleted'] ??
                false) as bool,
      );

  ReplyMeta copyWith({
    String? messageId,
    String? senderUid,
    String? text,
    String? type,
    String? thumb,
    bool? deleted,
  }) {
    return ReplyMeta(
      messageId: messageId ?? this.messageId,
      senderUid: senderUid ?? this.senderUid,
      text: text ?? this.text,
      type: type ?? this.type,
      thumb: thumb ?? this.thumb,
      deleted: deleted ?? this.deleted,
    );
  }
}
