// lib/widgets/chat/message_bubble.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../utils/time_format.dart';
import '../../utils/image_url_cache.dart';
import '../../utils/constants.dart'; // AppColors + reaction constants
import '../../utils/chat_service.dart'; // reactions: toggle & counts

// Reaction tray (Instagram-style row)
import 'reaction_picker.dart';

// Image viewer screen (+ gallery item)
import '../../screens/messages/image_viewer_screen.dart'
    show ImageViewerScreen, ChatImageItem;

// Must match your backend env SUPABASE_CHATS_BUCKET
const String kChatMediaBucket = 'chats';

/// Props to enable reply + jump behaviors
typedef ReplyCallback = void Function(
    String messageId, Map<String, dynamic> msg);
typedef JumpCallback = void Function(String messageId);

class MessageBubble extends StatelessWidget {
  // identifiers needed for reactions
  final String chatId;
  final String messageId;
  final String currentUid;

  final Map<String, dynamic> message;
  final bool isMe;

  // Optional IG-style props your screen passes (safe defaults)
  final bool showTime;
  final bool connectPrev;
  final bool connectNext;
  final String? peerPhotoUrl;
  final String? networkStatus;

  // retry & remove callbacks (for image upload failures)
  final void Function(Map<String, dynamic> message)? onRetry;
  final void Function(Map<String, dynamic> message)? onRemove;

  // NEW: reply and jump hooks
  final ReplyCallback? onReply;
  final JumpCallback? onJumpTo;

  const MessageBubble({
    super.key,
    required this.chatId,
    required this.messageId,
    required this.currentUid,
    required this.message,
    required this.isMe,
    this.showTime = false,
    this.connectPrev = false,
    this.connectNext = false,
    this.peerPhotoUrl,
    this.networkStatus,
    this.onRetry,
    this.onRemove,
    this.onReply,
    this.onJumpTo,
  });

  // ------- helpers for reply meta -------
  String? get _replyToId {
    return (message['reply_to_id'] ??
        message['replyToId'] ??
        message['reply_message_id'] ??
        message['replyMessageId']) as String?;
  }

  String? get _replySenderUid {
    return (message['reply_sender_uid'] ??
        message['replySenderUid'] ??
        message['reply_from_uid']) as String?;
  }

  String? get _replyTextPreview {
    final t = (message['reply_text'] ??
        message['replyText'] ??
        message['reply_preview'] ??
        message['replyPreview'] ??
        message['reply_body']) as String?;
    if (t == null) return null;
    final s = t.trim();
    return s.isEmpty ? null : s;
  }

  String? get _replyThumb {
    final s = (message['reply_thumb'] ??
        message['replyThumb'] ??
        message['reply_image'] ??
        message['replyImage']) as String?;
    if (s == null) return null;
    return s.isEmpty ? null : s;
  }

  String get _replyType {
    return (message['reply_type'] ??
            message['replyType'] ??
            (message['reply_thumb'] != null ? 'image' : 'text')) as String? ??
        'text';
  }

  bool get _replyDeleted {
    return (message['reply_deleted'] ?? message['replyDeleted'] ?? false)
        as bool;
  }

  bool get _hasReply => _replyToId != null && _replyToId!.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final createdAt = (message['created_at'] as Timestamp?)?.toDate();

    final String type = (message['type'] ?? '') as String? ?? '';
    final String rawText = (message['text'] ?? '') as String? ?? '';
    final bool isHeart = type == 'heart' ||
        message['isHeart'] == true ||
        message['is_heart'] == true ||
        rawText.trim() == '❤️';

    // Label logic like IG
    final bool iAmSender = isMe;
    final bool repliedToSelf = _hasReply &&
        _replySenderUid != null &&
        _replySenderUid == currentUid &&
        iAmSender;
    final bool youReplied = _hasReply && iAmSender && !repliedToSelf;

    final Widget? contextLabel = (!youReplied && !repliedToSelf)
        ? null
        : Padding(
            padding: const EdgeInsets.only(bottom: 4, left: 4, right: 4),
            child: Text(
              repliedToSelf ? 'Replied to yourself' : 'You replied',
              style: TextStyle(
                fontSize: 10,
                color: Colors.grey.shade500,
                fontWeight: FontWeight.w600,
              ),
            ),
          );

    // IMAGE bubble
    if (type == 'image') {
      final bubbleContent = _ImageBubble(
        chatId: chatId,
        messageId: messageId,
        currentUid: currentUid,
        message: message,
        isMe: isMe,
        showTime: showTime,
        connectPrev: connectPrev,
        connectNext: connectNext,
        networkStatus: networkStatus,
        onRetry: onRetry,
        onRemove: onRemove,
        onReply: onReply,
        onJumpTo: onJumpTo,
      );

      return Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(
            bottom: 8, // tighter default
            left: 8,
            right: 8,
          ),
          child: Column(
            crossAxisAlignment:
                isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              if (contextLabel != null) contextLabel,
              if (_hasReply)
                _ReplyPreview(
                  isMe: isMe,
                  type: _replyType,
                  text: _replyTextPreview,
                  thumb: _replyThumb,
                  deleted: _replyDeleted,
                  onTap: _replyToId != null && onJumpTo != null
                      ? () => onJumpTo!(_replyToId!)
                      : null,
                ),
              // photos: add space only when a react pill exists
              _ReactionSpacer(
                countsStream: ChatService.reactionCounts(chatId, messageId),
                child: bubbleContent,
              ),
              // Smooth timestamp show/hide (slide + fade)
              _AnimatedTime(
                visible: showTime && createdAt != null,
                child: _TimeBelowBubble(
                  chatId: chatId,
                  messageId: messageId,
                  isMe: isMe,
                  text: _timeWithStatus(
                    isMe: isMe,
                    createdAt: createdAt ?? DateTime.now(),
                    networkStatus: networkStatus,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // ❤️ HEART bubble (swipable + long-press reactions)
    if (isHeart) {
      final chips =
          _CornerChips(chatId: chatId, messageId: messageId, isMe: isMe);

      final heartStack = Stack(
        clipBehavior: Clip.none,
        children: [
          const SizedBox(
            width: 36,
            height: 36,
            child: Center(
              child:
                  Icon(Icons.favorite, color: AppColors.primaryColor, size: 36),
            ),
          ),
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onDoubleTap: () => ChatService.toggleReaction(
                chatId: chatId,
                messageId: messageId,
                emoji: "❤️",
              ),
              onLongPressStart: (d) =>
                  _showPickerCentered(context, d.globalPosition),
            ),
          ),
          Positioned(
            bottom: -14, // tighter chip offset
            right: isMe ? 6 : null,
            left: isMe ? null : 6,
            child: chips,
          ),
        ],
      );

      final swipeHeart = _SwipeToReply(
        isMe: isMe,
        onConfirm: () => onReply?.call(messageId, message),
        child: heartStack,
      );

      return Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8, left: 8, right: 8),
          child: Column(
            crossAxisAlignment:
                isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              if (contextLabel != null) contextLabel,
              if (_hasReply)
                _ReplyPreview(
                  isMe: isMe,
                  type: _replyType,
                  text: _replyTextPreview,
                  thumb: _replyThumb,
                  deleted: _replyDeleted,
                  onTap: _replyToId != null && onJumpTo != null
                      ? () => onJumpTo!(_replyToId!)
                      : null,
                ),
              // Add bottom space ONLY when pills exist (no phantom space)
              _ReactionSpacer(
                countsStream: ChatService.reactionCounts(chatId, messageId),
                child: swipeHeart,
              ),
              _AnimatedTime(
                visible: showTime && createdAt != null,
                child: _TimeBelowBubble(
                  chatId: chatId,
                  messageId: messageId,
                  isMe: isMe,
                  text: _timeWithStatus(
                    isMe: isMe,
                    createdAt: createdAt ?? DateTime.now(),
                    networkStatus: networkStatus,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // -------- TEXT bubble --------
    final text = rawText;

    // The visible bubble
    final baseBubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * (isMe ? 0.65 : 0.7),
      ),
      decoration: BoxDecoration(
        color:
            isMe ? Theme.of(context).colorScheme.primary : Colors.grey.shade200,
        borderRadius: _bubbleRadius(isMe, connectPrev, connectNext),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: isMe ? Colors.white : Colors.black87,
          fontSize: 14,
        ),
      ),
    );

    // Wrap with reactions gestures (double-tap/long-press)
    final reactionWrapped = _withReactionsWrapper(
      context: context,
      child: baseBubble,
      isImage: false,
    );

    // Chips near the bubble (corner-hug)
    final chips =
        _CornerChips(chatId: chatId, messageId: messageId, isMe: isMe);

    // Stack for bubble + chips (no permanent padding here)
    final stackThatMoves = Stack(
      clipBehavior: Clip.none,
      children: [
        reactionWrapped,
        Positioned(
          bottom: -14, // tighter chip offset
          right: isMe ? 6 : null,
          left: isMe ? null : 6,
          child: chips,
        ),
      ],
    );

    // Swipe-to-reply wrapper that slides the WHOLE stack now
    final swipeAll = _SwipeToReply(
      isMe: isMe,
      onConfirm: () => onReply?.call(messageId, message),
      child: stackThatMoves,
    );

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: connectNext ? 4 : 8, // tighter external spacing
          left: 8,
          right: 8,
        ),
        child: Column(
          crossAxisAlignment:
              isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (contextLabel != null) contextLabel,
            if (_hasReply)
              _ReplyPreview(
                isMe: isMe,
                type: _replyType,
                text: _replyTextPreview,
                thumb: _replyThumb,
                deleted: _replyDeleted,
                onTap: _replyToId != null && onJumpTo != null
                    ? () => onJumpTo!(_replyToId!)
                    : null,
              ),
            // Add bottom space ONLY when pills exist (no phantom space)
            _ReactionSpacer(
              countsStream: ChatService.reactionCounts(chatId, messageId),
              child: swipeAll,
            ),
            _AnimatedTime(
              visible: showTime && createdAt != null,
              child: _TimeBelowBubble(
                chatId: chatId,
                messageId: messageId,
                isMe: isMe,
                text: _timeWithStatus(
                  isMe: isMe,
                  // ✅ Null-safe now to avoid crash if serverTimestamp hasn't resolved yet
                  createdAt: createdAt ?? DateTime.now(),
                  networkStatus: networkStatus,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Wraps a child with gesture detectors for reactions
  Widget _withReactionsWrapper({
    required BuildContext context,
    required Widget child,
    required bool isImage,
  }) {
    if (isImage) return child;

    return GestureDetector(
      onDoubleTap: () => ChatService.toggleReaction(
        chatId: chatId,
        messageId: messageId,
        emoji: "❤️",
      ),
      onLongPressStart: (d) => _showPickerCentered(context, d.globalPosition),
      child: child,
    );
  }

  // Centered (Instagram-style) reaction tray for TEXT/HEART bubbles
  void _showPickerCentered(BuildContext context, Offset tapPos) {
    final overlay = Overlay.of(context);
    if (overlay == null) return;

    late OverlayEntry entry;

    // approximate tray height; place slightly above the finger
    const double trayHeight = 56;
    const double vGap = 10;

    final size = MediaQuery.of(context).size;
    final top = (tapPos.dy - trayHeight - vGap).clamp(8.0, size.height - 140.0);

    entry = OverlayEntry(
      builder: (_) => Stack(
        children: [
          // tap-outside to dismiss
          Positioned.fill(
            child: GestureDetector(
              onTap: () {
                if (entry.mounted) entry.remove();
              },
            ),
          ),
          // centered horizontally like Instagram
          Positioned(
            top: top.toDouble(),
            left: 0,
            right: 0,
            child: Center(
              child: ReactionPicker(
                emojis: kSupportedReactions,
                emojiSize: kReactionTrayEmojiSize,
                onPick: (emoji) async {
                  await ChatService.toggleReaction(
                    chatId: chatId,
                    messageId: messageId,
                    emoji: emoji,
                  );
                  if (entry.mounted) entry.remove();
                },
              ),
            ),
          ),
        ],
      ),
    );

    overlay.insert(entry);

    // auto-dismiss like IG
    Future.delayed(kReactionTrayAutoDismiss, () {
      if (entry.mounted) entry.remove();
    });
  }

  static BorderRadius _bubbleRadius(
      bool isMe, bool connectPrev, bool connectNext) {
    const outer = 18.0;
    const inner = 6.0;
    final topLeft = isMe ? outer : (connectNext ? inner : outer);
    final bottomLeft = isMe ? outer : (connectPrev ? inner : outer);
    final topRight = isMe ? (connectNext ? inner : outer) : outer;
    final bottomRight = isMe ? (connectPrev ? inner : outer) : outer;
    return BorderRadius.only(
      topLeft: Radius.circular(topLeft),
      bottomLeft: Radius.circular(bottomLeft),
      topRight: Radius.circular(topRight),
      bottomRight: Radius.circular(bottomRight),
    );
  }

  static String _timeWithStatus({
    required bool isMe,
    required DateTime createdAt,
    String? networkStatus,
  }) {
    final time = TimeFormat.exactTime(createdAt);
    if (!isMe) return time;
    final s = (networkStatus ?? 'sent');
    final human = (s == 'uploading')
        ? 'Uploading…'
        : (s == 'sent' ? 'Sent' : (s == 'failed' ? 'Failed' : s));
    return '$time · $human';
  }
}

// ---------- Corner Chips (chips hug bubble) ----------
class _CornerChips extends StatelessWidget {
  final String chatId;
  final String messageId;
  final bool isMe;
  const _CornerChips({
    required this.chatId,
    required this.messageId,
    required this.isMe,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Map<String, int>>(
      stream: ChatService.reactionCounts(chatId, messageId),
      builder: (context, snap) {
        final counts = snap.data ?? const {};
        if (counts.isEmpty) return const SizedBox.shrink();

        return Container(
          padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 6),
          decoration: BoxDecoration(
            color: kReactionChipFill,
            borderRadius: BorderRadius.circular(kReactionChipRadius),
            border: Border.all(color: kReactionChipBorder),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.06),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Wrap(
            spacing: 4,
            children: counts.entries.map((e) {
              return Text(
                "${e.key} ${e.value}",
                style: const TextStyle(fontSize: kReactionChipFontSize),
              );
            }).toList(),
          ),
        );
      },
    );
  }
}

// ---------- Timestamp helper (with small top gap only when pills exist) ----------
class _TimeBelowBubble extends StatelessWidget {
  final String chatId;
  final String messageId;
  final bool isMe;
  final String text;

  const _TimeBelowBubble({
    required this.chatId,
    required this.messageId,
    required this.isMe,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Map<String, int>>(
      stream: ChatService.reactionCounts(chatId, messageId),
      builder: (context, snap) {
        final hasReactions = (snap.data ?? const {}).isNotEmpty;
        return Padding(
          // If there are pills, leave a small top gap; else keep a tight 4px
          padding: EdgeInsets.only(top: hasReactions ? 8 : 4),
          child: Text(
            text,
            style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
          ),
        );
      },
    );
  }
}

// ---------- Animated show/hide container for timestamp ----------
class _AnimatedTime extends StatelessWidget {
  final bool visible;
  final Widget child;
  const _AnimatedTime({required this.visible, required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 160),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, anim) {
        // slide up a bit + fade
        final slide = Tween<Offset>(
          begin: const Offset(0, .15),
          end: Offset.zero,
        ).animate(anim);
        return FadeTransition(
          opacity: anim,
          child: SlideTransition(position: slide, child: child),
        );
      },
      child: visible
          ? KeyedSubtree(
              key: const ValueKey('time-visible'),
              child: child,
            )
          : const KeyedSubtree(
              key: ValueKey('time-hidden'),
              child: SizedBox.shrink(),
            ),
    );
  }
}

// ---------- Reply preview pill (Instagram style with connector) ----------
class _ReplyPreview extends StatelessWidget {
  final bool isMe;
  final String type; // "text" | "image"
  final String? text;
  final String? thumb;
  final bool deleted;
  final VoidCallback? onTap;
  const _ReplyPreview({
    required this.isMe,
    required this.type,
    required this.text,
    required this.thumb,
    required this.deleted,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // IG style: white mini-bubble on light; deep gray on dark
    final Color bubbleBg = isDark ? const Color(0xFF2B2B2D) : Colors.white;
    final Color bubbleFg =
        isDark ? Colors.white.withOpacity(.85) : Colors.black87;

    // subtle border only on light theme
    final BoxBorder? bubbleBorder =
        !isDark ? Border.all(color: const Color(0xFFE0E0E0), width: 0.6) : null;

    // connector sticks to the inside edge (right for "me", left for peer)
    final Widget connector = Container(
      width: 2,
      height: 28,
      decoration: BoxDecoration(
        color: isDark ? Colors.white12 : Colors.black12,
        borderRadius: BorderRadius.circular(1),
      ),
    );

    // mini-bubble contents
    final List<Widget> contents = [
      if (thumb != null && thumb!.isNotEmpty) ...[
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.network(
            thumb!,
            width: 34,
            height: 34,
            fit: BoxFit.cover,
          ),
        ),
        const SizedBox(width: 8),
      ] else if (type == 'image') ...[
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: isDark ? Colors.white12 : Colors.black12,
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(Icons.image, size: 18, color: Colors.black38),
        ),
        const SizedBox(width: 8),
      ],
      Flexible(
        child: Text(
          deleted
              ? 'Original message deleted'
              : (text?.isNotEmpty == true
                  ? text!
                  : (type == 'image' ? 'Photo' : 'Message'))!,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontSize: 13, color: bubbleFg, fontWeight: FontWeight.w500),
        ),
      ),
    ];

    final miniBubble = Container(
      constraints: const BoxConstraints(maxWidth: 320),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: bubbleBg,
        borderRadius: BorderRadius.circular(18),
        border: bubbleBorder,
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: contents),
    );

    final children = <Widget>[
      if (!isMe) connector,
      if (!isMe) const SizedBox(width: 6),
      Flexible(child: miniBubble),
      if (isMe) const SizedBox(width: 6),
      if (isMe) connector,
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: 6, left: 4, right: 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Row(
          mainAxisAlignment:
              isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
      ),
    );
  }
}

class _ImageBubble extends StatelessWidget {
  // identifiers for reactions in image bubbles
  final String chatId;
  final String messageId;
  final String currentUid;

  final Map<String, dynamic> message;
  final bool isMe;
  final bool showTime;
  final bool connectPrev;
  final bool connectNext;
  final String? networkStatus;
  final void Function(Map<String, dynamic> message)? onRetry;
  final void Function(Map<String, dynamic> message)? onRemove;

  final ReplyCallback? onReply;
  final JumpCallback? onJumpTo;

  const _ImageBubble({
    required this.chatId,
    required this.messageId,
    required this.currentUid,
    required this.message,
    required this.isMe,
    required this.showTime,
    required this.connectPrev,
    required this.connectNext,
    this.networkStatus,
    this.onRetry,
    this.onRemove,
    this.onReply,
    this.onJumpTo,
  });

  @override
  Widget build(BuildContext context) {
    final createdAt = (message['created_at'] as Timestamp?)?.toDate();
    final int? w = (message['w'] as num?)?.toInt();
    final int? h = (message['h'] as num?)?.toInt();

    final String status = (message['status'] as String?) ?? 'sent';
    final String? localPath = message['local_path'] as String?;

    final String? storagePath = (message['storage_path'] as String?) ??
        (message['image_path'] as String?) ??
        (message['path'] as String?);
    final String? signedFromBackend = message['image_url'] as String?;

    final maxBubbleW = MediaQuery.of(context).size.width * (isMe ? 0.65 : 0.7);
    final aspect = (w != null && h != null && w > 0 && h > 0) ? (w / h) : 4 / 5;

    // --- Base content (image or placeholder) ---
    Widget baseContent;
    if (signedFromBackend != null && signedFromBackend.isNotEmpty) {
      baseContent = Image.network(
        signedFromBackend,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      );
    } else if (storagePath != null && storagePath.isNotEmpty) {
      baseContent = FutureBuilder<String>(
        future: ImageUrlCache.signedUrl(
          bucket: kChatMediaBucket,
          path: storagePath,
        ),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(
              child: SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          }
          final url = snap.data!;
          return Image.network(
            url,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) {
              ImageUrlCache.invalidate(storagePath);
              return const SizedBox.shrink();
            },
          );
        },
      );
    } else if (localPath != null &&
        localPath.isNotEmpty &&
        File(localPath).existsSync()) {
      baseContent = Image.file(File(localPath), fit: BoxFit.cover);
    } else {
      baseContent = Container(
        color: Colors.grey.shade300,
        child: const Center(
          child: Icon(Icons.broken_image, size: 24, color: Colors.black38),
        ),
      );
    }

    // --- Overlays for uploading/failed ---
    final List<Widget> overlays = [];
    if (status == 'uploading') {
      overlays.add(Container(
        color: Colors.black.withOpacity(0.2),
        child: const Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ));
    } else if (status == 'failed') {
      overlays.add(Container(
        color: Colors.black.withOpacity(0.35),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: InkResponse(
                onTap: onRetry == null ? null : () => onRetry!(message),
                radius: 36,
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: const BoxDecoration(
                    color: AppColors.primaryColor,
                    shape: BoxShape.circle,
                  ),
                  child:
                      const Icon(Icons.refresh, size: 28, color: Colors.white),
                ),
              ),
            ),
            Positioned(
              top: 6,
              right: 6,
              child: InkResponse(
                onTap: onRemove == null ? null : () => onRemove!(message),
                child: Container(
                  decoration: const BoxDecoration(
                    color: Colors.black54,
                    shape: BoxShape.circle,
                  ),
                  padding: const EdgeInsets.all(4),
                  child: const Icon(Icons.close, size: 18, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      ));
    }

    final contentStack = Stack(
      fit: StackFit.expand,
      children: [
        baseContent,
        ...overlays,
      ],
    );

    final bool canOpenViewer =
        (signedFromBackend != null && signedFromBackend.isNotEmpty) ||
            (storagePath != null && storagePath.isNotEmpty);

    final String heroKey = (storagePath?.isNotEmpty ?? false)
        ? storagePath!
        : ((signedFromBackend?.isNotEmpty ?? false)
            ? signedFromBackend!
            : (localPath ??
                (createdAt?.millisecondsSinceEpoch.toString() ?? 'img')));

    Widget tappable = contentStack;
    if (canOpenViewer) {
      tappable = InkWell(
        onTap: () {
          final item = ChatImageItem(
            messageId: messageId,
            directUrl: signedFromBackend,
            storagePath: storagePath,
          );
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ImageViewerScreen(items: [item], initialIndex: 0),
              fullscreenDialog: true,
            ),
          );
        },
        child: contentStack,
      );
    }

    // Wrap with reactions handlers (overlay so InkWell tap still works)
    final withReactions = Stack(
      children: [
        tappable,
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onDoubleTap: () => ChatService.toggleReaction(
              chatId: chatId,
              messageId: messageId,
              emoji: "❤️",
            ),
            onLongPressStart: (d) =>
                _showPickerCentered(context, d.globalPosition),
          ),
        ),
      ],
    );

    final imageBody = ClipRRect(
      borderRadius: MessageBubble._bubbleRadius(isMe, connectPrev, connectNext),
      child: AspectRatio(
        aspectRatio: aspect,
        child: withReactions,
      ),
    );

    // Corner chips
    final chips =
        _CornerChips(chatId: chatId, messageId: messageId, isMe: isMe);

    final stack = Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          constraints: BoxConstraints(maxWidth: maxBubbleW),
          child: imageBody,
        ),
        Positioned(
          bottom: -14, // tighter chip offset
          right: isMe ? 6 : null,
          left: isMe ? null : 6,
          child: chips,
        ),
      ],
    );

    final swipeAll = _SwipeToReply(
      isMe: isMe,
      onConfirm: () => onReply?.call(messageId, message),
      child: stack,
    );

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
        // photos: add space only when pill exists
        child: _ReactionSpacer(
          countsStream: ChatService.reactionCounts(chatId, messageId),
          child: swipeAll,
        ),
      ),
    );
  }

  // Centered (Instagram-style) reaction tray for IMAGE bubbles
  void _showPickerCentered(BuildContext context, Offset tapPos) {
    final overlay = Overlay.of(context);
    if (overlay == null) return;

    late OverlayEntry entry;

    const double trayHeight = 56;
    const double vGap = 10;

    final size = MediaQuery.of(context).size;
    final top = (tapPos.dy - trayHeight - vGap).clamp(8.0, size.height - 140.0);

    entry = OverlayEntry(
      builder: (_) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () {
                if (entry.mounted) entry.remove();
              },
            ),
          ),
          Positioned(
            top: top.toDouble(),
            left: 0,
            right: 0,
            child: Center(
              child: ReactionPicker(
                emojis: kSupportedReactions,
                emojiSize: kReactionTrayEmojiSize,
                onPick: (emoji) async {
                  await ChatService.toggleReaction(
                    chatId: chatId,
                    messageId: messageId,
                    emoji: emoji,
                  );
                  if (entry.mounted) entry.remove();
                },
              ),
            ),
          ),
        ],
      ),
    );

    overlay.insert(entry);
    Future.delayed(kReactionTrayAutoDismiss, () {
      if (entry.mounted) entry.remove();
    });
  }
}

/// Slide-to-reply wrapper. Drag horizontally; if beyond threshold, fires onConfirm.
class _SwipeToReply extends StatefulWidget {
  final Widget child;
  final bool isMe;
  final VoidCallback? onConfirm;
  const _SwipeToReply({
    required this.child,
    required this.isMe,
    this.onConfirm,
  });

  @override
  State<_SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<_SwipeToReply>
    with SingleTickerProviderStateMixin {
  static const double _trigger = 56; // px needed to trigger
  static const double _maxReveal = 72;

  double _dx = 0;
  bool _armed = false;

  @override
  Widget build(BuildContext context) {
    final sign = widget.isMe ? -1.0 : 1.0;

    return Stack(
      alignment: widget.isMe ? Alignment.centerRight : Alignment.centerLeft,
      children: [
        // Reply icon pinned to right, centered vertically
        Align(
          alignment: Alignment.centerRight,
          child: Opacity(
            opacity: (_dx.abs() / _trigger).clamp(0, 1),
            child: const Padding(
              padding: EdgeInsets.only(right: 8),
              child: SizedBox(
                width: 36,
                height: 36,
                child: Icon(Icons.reply, size: 30, color: Colors.black54),
              ),
            ),
          ),
        ),

        // The entire child (bubble + chips) now slides
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (_) {
            _dx = 0;
            _armed = false;
          },
          onHorizontalDragUpdate: (d) {
            final delta = d.delta.dx * sign;
            setState(() {
              _dx = (_dx + delta).clamp(0, _maxReveal);
              _armed = _dx >= _trigger;
            });
          },
          onHorizontalDragEnd: (_) {
            if (_armed && widget.onConfirm != null) widget.onConfirm!();
            setState(() {
              _dx = 0;
              _armed = false;
            });
          },
          onHorizontalDragCancel: () {
            setState(() {
              _dx = 0;
              _armed = false;
            });
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            transform: Matrix4.translationValues(_dx * sign, 0, 0),
            child: widget.child,
          ),
        ),
      ],
    );
  }
}

/// Adds bottom padding only when reaction pills exist (prevents phantom space).
class _ReactionSpacer extends StatelessWidget {
  final Widget child;
  final Stream<Map<String, int>>? countsStream;
  final double expandedBottom;

  const _ReactionSpacer({
    required this.child,
    this.countsStream,
    this.expandedBottom = 10, // enough room for chips, tighter look
  });

  @override
  Widget build(BuildContext context) {
    if (countsStream == null) return child;

    return StreamBuilder<Map<String, int>>(
      stream: countsStream,
      builder: (context, snap) {
        final hasPills = (snap.data ?? const {}).isNotEmpty;
        final pad = hasPills ? expandedBottom : 0.0;
        return AnimatedPadding(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          padding: EdgeInsets.only(bottom: pad),
          child: child,
        );
      },
    );
  }
}
