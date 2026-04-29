// lib/screens/messages/conversation_screen.dart
import "package:flutter/material.dart";
import "dart:async";
import "dart:io";
import "dart:ui" as ui;
import "package:cloud_firestore/cloud_firestore.dart";
import "package:firebase_auth/firebase_auth.dart";
import "package:image_picker/image_picker.dart";
import "package:path/path.dart" as p;
import "package:path_provider/path_provider.dart";
import "../../utils/constants.dart";
import "../../utils/chat_service.dart";
import "../../utils/presence_service.dart";
import "package:flutter_image_compress/flutter_image_compress.dart";
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/services.dart';
import '../../widgets/profile_preview_sheet.dart';

// Match MessagesScreen fallbacks
import "../../utils/api_client.dart";

import "../../utils/chat_helpers.dart";
import "../../utils/time_format.dart";
import "../../widgets/chat/message_bubble.dart";
import "../../widgets/chat/date_divider.dart";

// ⬇️ NEW imports for reply feature
import "../../utils/reply_meta.dart";
import "../../widgets/chat/reply_banner.dart";

// ⬇️ NEW: open photo viewer at tapped reply like IG/Messenger
import '../../screens/messages/image_viewer_screen.dart'
    show ImageViewerScreen, ChatImageItem;

// ⬇️ NEW: audio UI
import '../../widgets/chat/audio_message_bubble.dart';
import '../../widgets/chat/voice_record_bar.dart';

// ⬇️ Blocks (Provider)
import 'package:provider/provider.dart';
import '../../repositories/blocks_repository.dart';

/// =======================
/// Gender helpers (shared)
/// =======================
String _titleize(String s) {
  final clean = s.replaceAll(RegExp(r'[_\-]+'), ' ').trim();
  if (clean.isEmpty) return "";
  return clean
      .split(RegExp(r'\s+'))
      .map((w) => w.isEmpty
          ? ""
          : "${w[0].toUpperCase()}${w.substring(1).toLowerCase()}")
      .join(" ");
}

String _formatGenderLabel(String raw) {
  final s = (raw).trim().toLowerCase();
  if (s.isEmpty) return "";
  if ({"m", "male", "man", "boy"}.contains(s)) return "Male";
  if ({"f", "female", "woman", "girl"}.contains(s)) return "Female";
  if ({"non-binary", "nonbinary", "nb", "enby"}.contains(s))
    return "Non-binary";
  if ({"others", "other", "prefer not to say", "prefer-not", "na", "n/a"}
      .contains(s)) {
    return "Other";
  }
  return _titleize(s);
}

IconData _genderIcon(String label) {
  switch (label) {
    case "Male":
      return Icons.male;
    case "Female":
      return Icons.female;
    case "Non-binary":
      return Icons.transgender;
    case "Other":
      return Icons.person_outline;
    default:
      return Icons.help_outline;
  }
}

Color _genderColor(String label) {
  switch (label) {
    case "Male":
      return const Color.fromARGB(255, 37, 149, 247); // Blue 600
    case "Female":
      return AppColors.primaryColor; // Brand magenta
    case "Non-binary":
      return const Color(0xFF7E57C2); // Deep Purple 400
    case "Other":
      return Colors.teal;
    default:
      return Colors.black54;
  }
}

/// Inline Name + gender icon (puts the icon NEXT TO THE NAME)
Widget _nameWithGender({
  required String name,
  required String genderLabel,
  double fontSize = 16,
  double iconSize = 16,
  FontWeight fontWeight = FontWeight.w700,
}) {
  final style = TextStyle(
    fontWeight: fontWeight,
    fontSize: fontSize,
    color: Colors.black,
  );

  if (genderLabel.trim().isEmpty) {
    return Text(
      name.isEmpty ? " " : name,
      style: style,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  return RichText(
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    text: TextSpan(
      style: style,
      children: [
        TextSpan(text: name),
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Icon(
              _genderIcon(genderLabel),
              size: iconSize,
              color: _genderColor(genderLabel),
            ),
          ),
        ),
      ],
    ),
  );
}

class ConversationScreen extends StatefulWidget {
  final String chatId;
  const ConversationScreen({super.key, required this.chatId});

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  // Bottom sheet state + heart
  bool _showAttachmentMenu = false;
  bool _showHeartAnimation = false;
  Timer? _heartAnimationTimer;

  // UI state
  bool _showCompactHeader = false;
  bool _sending = false;

  // Live tail + pagination state
  static const int kPageSize = 40;
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> _docs = [];
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _tailSub;
  bool _liveTail = true;
  int _pendingNew = 0;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _lastMarkedHeadId;
  String? _lastDeliveredHeadId;

  // Peer
  String? _peerUid;

  // Profile fallbacks (mirrors MessagesScreen)
  final Map<String, Map<String, String>> _profileCache = {};
  String? _peerDisplayName; // from _profileCache
  String? _peerPhotoUrl; // from _profileCache
  String? _peerGenderLabel; // normalized gender label

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _peerSub;
  Stream<Map<String, dynamic>>? _presence$;
  Timer? _presenceTicker; // kept for backward compat; not used now

  bool _sentFirstFromThisOpen = false;

  // receipts (Delivered/Seen)
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _chatSub;
  Map<String, dynamic> _receipts = {};

  // 🔹 NEW: keep the chat doc’s match_id if present
  String? _chatMatchId;

  // tap-to-show timestamp
  final Set<String> _forceShowTime = {};

  // cluster & gap
  final Duration _clusterGap = const Duration(minutes: 5);

  // Big gap divider threshold (re-stamp a center divider after ≥1 hour silence)
  final Duration _timeMarkerGap = const Duration(hours: 1);

  static const String kSoonMessage = "Feature will be updated soon!";

  // Layout constants
  static const double _composerHeight = 56.0;
  static const double _attachmentBarHeight = 116.0; // visible height of sheet

  // ⬇️ Reply state + jump keys
  ReplyMeta? _replying;
  final Map<String, GlobalKey> _itemKeys = {};

  // ⬇️ Flash highlight state
  String? _flashId;
  Timer? _flashTimer;

  // Block
  bool get _iBlockedPeer =>
      _peerUid != null &&
      context.read<BlocksRepository>().isBlockedByMe(_peerUid!);

  bool get _peerBlockedMe =>
      _peerUid != null &&
      context.read<BlocksRepository>().hasBlockedMe(_peerUid!);

  // ⬇️ Scroll throttle
  int _lastScrollMarkMs = 0;

  @override
  void initState() {
    super.initState();

    // Ensure RTDB presence is running (safe to call multiple times)
    // ignore: discarded_futures
    PresenceService().start();

    _scrollController.addListener(_onScroll);

    // Removed: global setState() per keystroke. Composer will use ValueListenableBuilder.

    _resolvePeer().then((_) async {
      await _loadInitial();
      _subscribeChatDoc(); // ← picks up receipts + match_id
      _subscribeHead();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _maybeAckDelivered();
        _maybeMarkRead();
      });
    });

    // Removed the 30s ticker that rebuilt the whole screen
    // _presenceTicker = Timer.periodic(const Duration(seconds: 30), (_) {
    //   if (mounted) setState(() {});
    // });
  }

  @override
  void dispose() {
    _hideSnack();
    _tailSub?.cancel();
    _peerSub?.cancel();
    _chatSub?.cancel();
    _presenceTicker?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    _heartAnimationTimer?.cancel();
    _flashTimer?.cancel();
    super.dispose();
  }

  // ---------- SnackBar helper ----------
  double _safeBottom(BuildContext ctx) => MediaQuery.of(ctx).viewPadding.bottom;

  /// Offset so default SnackBar sits just above the composer (ignores sheet).
  double _snackBottomOffset(BuildContext ctx) {
    return _safeBottom(ctx) +
        _composerHeight +
        (_showAttachmentMenu ? _attachmentBarHeight : 0);
  }

  void _hideSnack() {
    final m = ScaffoldMessenger.maybeOf(context);
    m?.clearSnackBars();
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.fromLTRB(0, 0, 0, _snackBottomOffset(context)),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        dismissDirection: DismissDirection.down,
      ),
    );
  }

  // ---------- Peer & receipts ----------
  Future<void> _resolvePeer() async {
    final myUid = FirebaseAuth.instance.currentUser!.uid;
    final chatSnap = await FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.chatId)
        .get();
    final data = chatSnap.data() as Map<String, dynamic>? ?? {};
    final members = (data['members'] as List?)?.cast<String>() ?? const [];
    final altMembers = (data['participants'] as List?)?.cast<String>() ??
        (data['member_uids'] as List?)?.cast<String>() ??
        const [];
    final all = members.isNotEmpty ? members : altMembers;
    if (all.isEmpty) return;

    final other = all.firstWhere((u) => u != myUid, orElse: () => myUid);
    if (other == myUid) return;

    setState(() {
      _peerUid = other;
      _presence$ = PresenceService.watch(other); // RTDB presence
    });

    // ensure block lists are fresh (no-op if already loaded)
    context.read<BlocksRepository>().refresh().catchError((_) {});

    // Firestore user doc (for profile fields only)
    final userDocRef =
        FirebaseFirestore.instance.collection('users').doc(other);
    _peerSub?.cancel();
    _peerSub = userDocRef.snapshots().listen((doc) {
      final d = doc.data() ?? {};
      final Map<String, dynamic> personal =
          (d['personal_info'] as Map?)?.cast<String, dynamic>() ?? const {};

      final firstName = (personal['first_name'] ?? '') as String? ?? '';
      final photoUrl = (d['profile_image_url'] ??
              d['photo_url'] ??
              d['avatar_url']) as String? ??
          '';

      // 🔹 gender from personal_info first, then root fallbacks
      final rawGender =
          (personal['gender'] ?? d['gender'] ?? d['sex']) as String? ?? '';
      final normalizedGender = _formatGenderLabel(rawGender);

      if (firstName.isNotEmpty || photoUrl.isNotEmpty || rawGender.isNotEmpty) {
        _profileCache[other] = {
          'name': firstName,
          'image_url': photoUrl,
          'gender': normalizedGender,
        };
        setState(() {
          _peerDisplayName =
              (_profileCache[other]?['name'] ?? '').trim().isNotEmpty
                  ? _profileCache[other]!['name']
                  : 'Chat';
          _peerPhotoUrl = _profileCache[other]?['image_url'];
          _peerGenderLabel = (_profileCache[other]?['gender'] ?? '');
        });
      }
    });

    _ensureProfile(other);
  }

  Future<void> _ensureProfile(String uid) async {
    if (_profileCache.containsKey(uid)) {
      setState(() {
        _peerDisplayName = (_profileCache[uid]?['name'] ?? '').trim().isNotEmpty
            ? _profileCache[uid]!['name']
            : 'Chat';
        _peerPhotoUrl = _profileCache[uid]?['image_url'];
        _peerGenderLabel = (_profileCache[uid]?['gender'] ?? '');
      });
      return;
    }
    try {
      final p = await ApiClient.getJson("/profile/$uid");
      if (!mounted) return;

      final apiName = (p["first_name"] ?? p["name"] ?? "").toString();
      final apiPhoto =
          (p["profile_image_url"] ?? p["image_url"] ?? "").toString();
      final rawGender = (p["gender"] ??
              p["sex"] ??
              (p["personal_info"] is Map
                  ? (p["personal_info"]["gender"] ?? "")
                  : ""))
          .toString();
      final normalized = _formatGenderLabel(rawGender);

      _profileCache[uid] = {
        "name": apiName,
        "image_url": apiPhoto,
        "gender": normalized,
      };

      setState(() {
        _peerDisplayName = apiName.trim().isNotEmpty ? apiName : 'Chat';
        _peerPhotoUrl = apiPhoto;
        _peerGenderLabel = normalized;
      });
    } catch (_) {}
  }

  void _subscribeChatDoc() {
    _chatSub?.cancel();
    _chatSub = FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.chatId)
        .snapshots()
        .listen((doc) {
      final data = doc.data() ?? {};
      setState(() {
        _receipts = Map<String, dynamic>.from(data['receipts'] ?? {});
        _chatMatchId = (data['match_id']?.toString().trim().isNotEmpty ?? false)
            ? data['match_id'].toString()
            : _chatMatchId; // keep if already set
      });
    });
  }

  // ---------- Scroll/pagination ----------
  bool get _isNearBottom {
    if (!_scrollController.hasClients) return true;
    return _scrollController.offset <= 150.0;
  }

  bool get _isNearTop {
    if (!_scrollController.hasClients) return false;
    final pos = _scrollController.position;
    return pos.pixels >= (pos.maxScrollExtent - 200.0);
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;

    // Throttle reactions to ~60ms
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastScrollMarkMs < 60) return;
    _lastScrollMarkMs = now;

    final show = _scrollController.offset > 150;
    if (show != _showCompactHeader) setState(() => _showCompactHeader = show);

    final atBottom = _isNearBottom;
    if (atBottom && !_liveTail) {
      setState(() {
        _liveTail = true;
        if (_pendingNew > 0) _pendingNew = 0;
      });
      _animateToBottom();
      _maybeAckDelivered();
      _maybeMarkRead();
    } else if (!atBottom && _liveTail) {
      setState(() => _liveTail = false);
    }

    if (_isNearTop && !_loadingMore && _hasMore) {
      _loadMoreOlder();
    }
  }

  void _animateToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      0.0,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  Future<void> _loadInitial() async {
    final qs = await FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.chatId)
        .collection('messages')
        .orderBy('created_at', descending: true)
        .limit(kPageSize)
        .get();

    setState(() {
      _docs
        ..clear()
        ..addAll(qs.docs);
      _hasMore = qs.docs.length == kPageSize;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _animateToBottom();
      _maybeAckDelivered();
      _maybeMarkRead();
    });
  }

  void _subscribeHead() {
    _tailSub?.cancel();
    _tailSub = FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.chatId)
        .collection('messages')
        .orderBy('created_at', descending: true)
        .limit(kPageSize)
        .snapshots()
        .listen((snap) {
      if (snap.docs.isEmpty) {
        setState(() {
          _docs.clear();
          _hasMore = true;
        });
        return;
      }

      final incoming = snap.docs;

      // First attach → just load
      if (_docs.isEmpty) {
        setState(() {
          _docs
            ..clear()
            ..addAll(incoming);
          _hasMore = incoming.length == kPageSize;
        });
        if (_liveTail) _animateToBottom();
        _maybeAckDelivered();
        _maybeMarkRead();
        return;
      }

      // How many NEW docs were inserted at the head?
      final currentHeadId = _docs.first.id;
      int inserted = 0;
      for (final d in incoming) {
        if (d.id == currentHeadId) break;
        inserted++;
      }

      // 🔑 Did any existing docs change (e.g., image status/upload fields)?
      final bool hasModified =
          snap.docChanges.any((c) => c.type == DocumentChangeType.modified);

      // If nothing inserted AND nothing modified AND structure looks identical,
      // skip the rebuild. Otherwise, replace the page with the latest snapshot.
      if (inserted == 0 && !hasModified) {
        final sameSize = _docs.length == incoming.length;
        final sameHead = _docs.first.id == incoming.first.id;
        if (sameSize && sameHead) return;
      }

      if (_liveTail) {
        setState(() {
          _docs
            ..clear()
            ..addAll(incoming);
          _hasMore = incoming.length == kPageSize || _hasMore;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) => _animateToBottom());
        _maybeAckDelivered();
        _maybeMarkRead();
      } else {
        // Off the live tail → show the "new messages" chip, but still update list
        setState(() {
          _docs
            ..clear()
            ..addAll(incoming);
          if (inserted > 0) _pendingNew += inserted;
          _hasMore = incoming.length == kPageSize || _hasMore;
        });
      }
    });
  }

  DateTime _lastLoadMore = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> _loadMoreOlder() async {
    if (_docs.isEmpty) return;
    if (DateTime.now().difference(_lastLoadMore) <
        const Duration(milliseconds: 300)) {
      return;
    }
    _lastLoadMore = DateTime.now();

    setState(() => _loadingMore = true);
    try {
      final oldest = _docs.last;
      final qs = await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId)
          .collection('messages')
          .orderBy('created_at', descending: true)
          .startAfterDocument(oldest)
          .limit(kPageSize)
          .get();

      if (qs.docs.isEmpty) {
        setState(() => _hasMore = false);
      } else {
        setState(() {
          _docs.addAll(qs.docs);
          _hasMore = qs.docs.length == kPageSize;
        });
      }
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  // ---------- Receipts ----------
  void _maybeMarkRead() {
    if (!_liveTail || !_isNearBottom || _docs.isEmpty) return;
    final headId = _docs.first.id;
    if (_lastMarkedHeadId == headId) return;

    final newestSender =
        (_docs.first.data()['sender_uid'] ?? '') as String? ?? '';
    if (newestSender == FirebaseAuth.instance.currentUser!.uid) {
      _lastMarkedHeadId = headId;
      return;
    }

    _lastMarkedHeadId = headId;
    ChatService.ackRead(chatId: widget.chatId, messageId: headId)
        .catchError((_) {});
    ChatService.markRead(widget.chatId); // legacy
  }

  void _maybeAckDelivered() {
    if (!_liveTail || !_isNearBottom || _docs.isEmpty) return;

    final newest = _docs.first;
    final newestId = newest.id;
    final newestSender = (newest.data()['sender_uid'] ?? '') as String? ?? '';
    if (newestSender == FirebaseAuth.instance.currentUser!.uid) return;
    if (_lastDeliveredHeadId == newestId) return;

    _lastDeliveredHeadId = newestId;
    ChatService.ackDelivered(chatId: widget.chatId, messageId: newestId)
        .catchError((_) {});
  }

  /// Compute outgoing (my message) status based on chat.receipts + timestamps/heads.
  String _statusForOutgoing(Map<String, dynamic> msg, String msgId) {
    final String base = (msg['status'] as String?) ?? 'sent';
    // Don't override local transient states
    if (base == 'uploading' || base == 'failed') return base;

    final DateTime? created =
        ChatHelpers.asLocal(msg['created_at'] as Timestamp?);
    if (_receipts.isEmpty || _peerUid == null || created == null) {
      return base;
    }

    final Map<String, dynamic> peer =
        Map<String, dynamic>.from(_receipts[_peerUid!] ?? const {});

    // Timestamps
    DateTime? deliveredAt;
    DateTime? readAt;
    final dAt = peer['delivered_at'] ?? peer['deliveredAt'];
    final rAt = peer['read_at'] ?? peer['readAt'];
    if (dAt is Timestamp) deliveredAt = dAt.toDate();
    if (rAt is Timestamp) readAt = rAt.toDate();

    // Head IDs
    final String? deliveredHeadId =
        (peer['delivered_head_id'] ?? peer['deliveredHeadId']) as String?;
    final String? readHeadId =
        (peer['read_head_id'] ?? peer['readHeadId']) as String?;

    // Prefer READ over DELIVERED
    if (readHeadId != null && readHeadId == msgId) return 'Seen';
    if (readAt != null && !created.isAfter(readAt)) return 'Seen';

    if (deliveredHeadId != null && deliveredHeadId == msgId) return 'Delivered';
    if (deliveredAt != null && !created.isAfter(deliveredAt)) {
      return 'Delivered';
    }

    return base; // likely 'sent'
  }

  // ---------- Build ----------
  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser!.uid;

    final blocks = context.watch<BlocksRepository>();
    final bool composerDisabledByPeer =
        _peerUid != null && blocks.hasBlockedMe(_peerUid!);
    final bool composerDisabledBySelf =
        _peerUid != null && blocks.isBlockedByMe(_peerUid!);

    return WillPopScope(
      onWillPop: () async {
        _hideSnack();
        if (_showAttachmentMenu) {
          setState(() => _showAttachmentMenu = false);
          return false;
        }
        Navigator.pop(context, _sentFirstFromThisOpen);
        return false;
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        body: Stack(
          children: [
            // Main content column
            Column(
              children: [
                _showCompactHeader
                    ? _buildCompactAppBar(context)
                    : _buildFullAppBar(context),

                // 🔹 Block/Unblock banners (sit under app bar)
                if (composerDisabledByPeer || composerDisabledBySelf)
                  _buildBlockBanner(context),

                Expanded(
                  child: Stack(
                    children: [
                      _docs.isEmpty
                          ? const _EmptyThread()
                          : ListView.builder(
                              key: const PageStorageKey<String>(
                                  'conversation_list'),
                              controller: _scrollController,
                              reverse: true,
                              padding: const EdgeInsets.all(16),
                              cacheExtent:
                                  1200, // prebuild a bit for smoothness
                              itemCount: _docs.length + (_loadingMore ? 1 : 0),
                              itemBuilder: (_, i) {
                                if (_loadingMore && i == _docs.length) {
                                  return const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 12),
                                    child: Center(
                                      child: SizedBox(
                                        height: 20,
                                        width: 20,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2),
                                      ),
                                    ),
                                  );
                                }

                                final doc = _docs[i];
                                final m = doc.data();
                                final me = m['sender_uid'] == uid;
                                final DateTime? ts = ChatHelpers.asLocal(
                                    m['created_at'] as Timestamp?);
                                final String? status = m['status'] as String?;
                                final currId = doc.id;

                                // tap-to-show toggle
                                bool shouldShowTime =
                                    _forceShowTime.contains(currId);
                                void toggleTime() {
                                  setState(() {
                                    if (_forceShowTime.contains(currId)) {
                                      _forceShowTime.clear();
                                    } else {
                                      _forceShowTime
                                        ..clear()
                                        ..add(currId);
                                    }
                                  });
                                }

                                // connected corners
                                final connectsPrev = ChatHelpers.connectsToPrev(
                                  i,
                                  _docs,
                                  clusterGap: _clusterGap,
                                );
                                final connectsNext = ChatHelpers.connectsToNext(
                                  i,
                                  _docs,
                                  clusterGap: _clusterGap,
                                );

                                // Centered dividers: day break OR ≥1h silence
                                Widget? divider;
                                if (ts != null) {
                                  final bool isLast = i == _docs.length - 1;
                                  final DateTime? nextTs = isLast
                                      ? null
                                      : ChatHelpers.asLocal(
                                          _docs[i + 1].data()['created_at']
                                              as Timestamp?,
                                        );

                                  final bool dayBreak = (nextTs == null) ||
                                      !ChatHelpers.isSameDay(nextTs, ts);

                                  if (dayBreak) {
                                    divider = DateDivider(
                                      text: TimeFormat.dividerLabel(ts),
                                    );
                                  } else {
                                    final bool bigGap = nextTs != null &&
                                        ts.difference(nextTs).abs() >=
                                            _timeMarkerGap;

                                    if (bigGap) {
                                      divider = DateDivider(
                                        text: TimeFormat.dividerLabel(ts),
                                      );
                                    }
                                  }
                                }

                                // Key for jump-to-original
                                final key = _itemKeys.putIfAbsent(
                                    currId, () => GlobalKey());

                                // Bubble (audio vs everything else)
                                final bubble = GestureDetector(
                                  onTap: toggleTime,
                                  onLongPress: toggleTime,
                                  child: (m['type'] == 'audio')
                                      ? AudioMessageBubble(
                                          chatId: widget.chatId,
                                          messageId: currId,
                                          currentUid: uid,
                                          message: m,
                                          isMe: me,
                                          showTime: shouldShowTime,
                                          connectPrev: connectsPrev,
                                          connectNext: connectsNext,
                                          networkStatus: me
                                              ? _statusForOutgoing(m, currId)
                                              : status,
                                          onReply: _startReplyFrom,
                                        )
                                      : MessageBubble(
                                          chatId: widget.chatId,
                                          messageId: currId,
                                          currentUid: uid,
                                          message: m,
                                          isMe: me,
                                          showTime: shouldShowTime,
                                          connectPrev: connectsPrev,
                                          connectNext: connectsNext,
                                          peerPhotoUrl: _peerPhotoUrl,
                                          networkStatus: me
                                              ? _statusForOutgoing(m, currId)
                                              : status,
                                          onRetry: _handleRetry,
                                          onRemove: _handleRemove,
                                          onReply: _startReplyFrom,
                                          onJumpTo: _jumpToMessage,
                                        ),
                                );

                                // Avatar grouping
                                final bool hasPrev = i > 0;
                                final Map<String, dynamic>? prev =
                                    hasPrev ? _docs[i - 1].data() : null;

                                final String currSender =
                                    (m['sender_uid'] ?? '') as String? ?? '';
                                final String prevSender = hasPrev
                                    ? (prev?['sender_uid'] ?? '') as String? ??
                                        ''
                                    : '';

                                final DateTime? currTs = ts;
                                final DateTime? prevTs = hasPrev
                                    ? ChatHelpers.asLocal(
                                        prev?['created_at'] as Timestamp?)
                                    : null;

                                bool dayBreakFromPrev = false;
                                bool longGapFromPrev = false;
                                if (prevTs != null && currTs != null) {
                                  dayBreakFromPrev =
                                      !ChatHelpers.isSameDay(prevTs, currTs);
                                  longGapFromPrev =
                                      prevTs.difference(currTs).abs() >=
                                          _timeMarkerGap;
                                }

                                final bool isPeer = !me;
                                final bool newSenderBlock =
                                    hasPrev ? (prevSender != currSender) : true;
                                final bool startsPeerBlock = isPeer &&
                                    (newSenderBlock ||
                                        dayBreakFromPrev ||
                                        longGapFromPrev);

                                final bool showPeerAvatar = startsPeerBlock;

                                const double _kAvatarSize = 40;
                                const double _kAvatarNudge = -12;

                                final row = Row(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    if (isPeer) ...[
                                      SizedBox(
                                        width: _kAvatarSize,
                                        child: Align(
                                          alignment: Alignment.bottomCenter,
                                          child: showPeerAvatar
                                              ? Transform.translate(
                                                  offset: const Offset(
                                                      0, _kAvatarNudge),
                                                  child: _SmallAvatar(
                                                    photoUrl: _peerPhotoUrl,
                                                    size: _kAvatarSize,
                                                  ),
                                                )
                                              : const SizedBox.shrink(),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(child: bubble),
                                    ] else ...[
                                      Expanded(
                                        child: Align(
                                          alignment: Alignment.centerRight,
                                          child: bubble,
                                        ),
                                      ),
                                    ],
                                  ],
                                );

                                // 🔆 Flash highlight wrapper (darker-white shade)
                                Widget highlighted(Widget child) {
                                  final bool flashing = currId == _flashId;
                                  return AnimatedContainer(
                                    key: key,
                                    duration: const Duration(milliseconds: 250),
                                    curve: Curves.easeOut,
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 2, horizontal: 4),
                                    decoration: BoxDecoration(
                                      color: flashing
                                          ? Colors.black.withOpacity(0.06)
                                          : Colors.transparent,
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: child,
                                  );
                                }

                                final built = (divider != null)
                                    ? highlighted(
                                        Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            divider!,
                                            const SizedBox(height: 6),
                                            row,
                                          ],
                                        ),
                                      )
                                    : highlighted(row);

                                // Stable key to help Flutter diff rows cheaply
                                return KeyedSubtree(
                                  key: ValueKey(currId),
                                  child: built,
                                );
                              },
                            ),

                      // Jump to latest
                      if (_pendingNew > 0 && !_liveTail)
                        Positioned(
                          bottom: 80,
                          left: 0,
                          right: 0,
                          child: Center(
                            child: GestureDetector(
                              onTap: () {
                                setState(() {
                                  _pendingNew = 0;
                                  _liveTail = true;
                                });
                                _animateToBottom();
                                _maybeAckDelivered();
                                _maybeMarkRead();
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 8),
                                decoration: BoxDecoration(
                                  color: AppColors.primaryColor,
                                  borderRadius: BorderRadius.circular(18),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.12),
                                      blurRadius: 10,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: const Text(
                                  "Jump to latest",
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600),
                                ),
                              ),
                            ),
                          ),
                        ),

                      // Heart overlay
                      if (_showHeartAnimation)
                        Center(
                          child: TweenAnimationBuilder<double>(
                            tween: Tween<double>(begin: 0.0, end: 1.0),
                            duration: const Duration(milliseconds: 500),
                            builder: (context, value, child) {
                              return Opacity(
                                opacity:
                                    value > 0.5 ? 2 - 2 * value : 2 * value,
                                child: Transform.scale(
                                  scale: 1 + value,
                                  child: const Icon(
                                    Icons.favorite,
                                    color: Color(0xFFB5276A),
                                    size: 100,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                    ],
                  ),
                ),

                // Reply banner above composer
                if (_replying != null)
                  ReplyBanner(
                    title: _replyingTitle(),
                    textPreview: _replying!.text,
                    mediaThumb: (_replying!.thumb != null &&
                            _replying!.thumb!.isNotEmpty)
                        ? Image.network(
                            _replying!.thumb!,
                            width: 36,
                            height: 36,
                            fit: BoxFit.cover,
                          )
                        : null,
                    onCancel: () => setState(() => _replying = null),
                  ),

                // Composer (padding animates up when sheet is open)
                AnimatedPadding(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                  padding: EdgeInsets.only(
                    bottom: _safeBottom(context) +
                        (_showAttachmentMenu ? _attachmentBarHeight : 0),
                  ),
                  child: _buildMessageInput(
                    disabledByPeer: composerDisabledByPeer,
                    disabledBySelf: composerDisabledBySelf,
                  ), // keeps its own top shadow/etc.
                ),
              ],
            ),

            // Bottom sheet BELOW the message bar (pushes composer up)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0, // always anchored to the screen bottom
              child: IgnorePointer(
                ignoring: !_showAttachmentMenu ||
                    composerDisabledByPeer ||
                    composerDisabledBySelf,
                child: AnimatedSlide(
                  offset:
                      _showAttachmentMenu ? Offset.zero : const Offset(0, 1),
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                  child: _AttachmentBar(
                    height: _attachmentBarHeight,
                    onCamera: () => _pickAndSendImage(ImageSource.camera),
                    onGallery: () => _pickAndSendImage(ImageSource.gallery),
                    onLocation: _showSoon,
                    onAudio: _openVoiceRecordBar, // ⬅️ UPDATED
                    onGif: _showSoon,
                    onClose: () => setState(() => _showAttachmentMenu = false),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- App bars & presence ----------
  Widget _buildFullAppBar(BuildContext context) {
    final photo = _peerPhotoUrl;

    return Container(
      color: Colors.white,
      child: SafeArea(
        child: Container(
          // align chevron with '+': 8 horizontal
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              // Back chevron — primary color, no circular border
              IconButton(
                icon: const Icon(Icons.chevron_left, size: 28),
                color: AppColors.primaryColor,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () => Navigator.pop(context, _sentFirstFromThisOpen),
              ),
              const SizedBox(width: 12),
              _SmallAvatar(photoUrl: photo, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Stack(
                      alignment: Alignment.centerLeft,
                      children: [
                        Positioned.fill(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: AnimatedOpacity(
                              opacity: (_peerDisplayName?.isNotEmpty ?? false)
                                  ? 0
                                  : 1,
                              duration: const Duration(milliseconds: 160),
                              curve: Curves.easeOut,
                              child: _skeletonLine(width: 140, height: 16),
                            ),
                          ),
                        ),
                        AnimatedOpacity(
                          opacity:
                              (_peerDisplayName?.isNotEmpty ?? false) ? 1 : 0,
                          duration: const Duration(milliseconds: 160),
                          curve: Curves.easeOut,
                          child: _nameWithGender(
                            name: (_peerDisplayName?.isNotEmpty ?? false)
                                ? _peerDisplayName!
                                : ' ',
                            genderLabel: _peerGenderLabel ?? '',
                            fontSize: 16,
                            iconSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    _presenceSubtitle(),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.more_vert, size: 24),
                color: AppColors.primaryColor,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: _openMoreSheet, // ← UPDATED
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCompactAppBar(BuildContext context) {
    final photo = _peerPhotoUrl;

    return Container(
      color: Colors.white,
      child: SafeArea(
        child: Container(
          // align chevron with '+': 8 horizontal
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              // Back chevron — primary color, no circular border
              IconButton(
                icon: const Icon(Icons.chevron_left, size: 28),
                color: AppColors.primaryColor,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () => Navigator.pop(context, _sentFirstFromThisOpen),
              ),
              const SizedBox(width: 12),
              _SmallAvatar(photoUrl: photo, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Stack(
                      alignment: Alignment.centerLeft,
                      children: [
                        Positioned.fill(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: AnimatedOpacity(
                              opacity: (_peerDisplayName?.isNotEmpty ?? false)
                                  ? 0
                                  : 1,
                              duration: const Duration(milliseconds: 160),
                              curve: Curves.easeOut,
                              child: _skeletonLine(width: 140, height: 16),
                            ),
                          ),
                        ),
                        AnimatedOpacity(
                          opacity:
                              (_peerDisplayName?.isNotEmpty ?? false) ? 1 : 0,
                          duration: const Duration(milliseconds: 160),
                          curve: Curves.easeOut,
                          child: _nameWithGender(
                            name: (_peerDisplayName?.isNotEmpty ?? false)
                                ? _peerDisplayName!
                                : ' ',
                            genderLabel: _peerGenderLabel ?? '',
                            fontSize: 16,
                            iconSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    _presenceSubtitle(),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.more_vert, size: 24),
                color: AppColors.primaryColor,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: _openMoreSheet, // ← UPDATED
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Presence subtitle that trusts RTDB only.
  Widget _presenceSubtitle() {
    if (_peerUid == null) return const SizedBox(height: 16, width: 60);

    // Neutral placeholder while RTDB stream attaches
    if (_presence$ == null) {
      return Row(
        children: [
          _presenceDot(false),
          const SizedBox(width: 6),
          Text(
            ' ',
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey.shade600,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );
    }

    return StreamBuilder<Map<String, dynamic>>(
      stream: _presence$,
      builder: (context, snap) {
        final data = snap.data ?? const {};
        // 3-minute grace to avoid flicker after restarts/reconnects
        final isNow = PresenceService.isActiveNow(data, graceMs: 180000);
        final la = data['last_active'];
        final last = (la is num) ? la.toInt() : 0; // handles int or double
        final label = isNow ? 'Active now' : _formatActiveAgo(last);

        return Row(
          children: [
            _presenceDot(isNow),
            const SizedBox(width: 6),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: isNow ? Colors.green : Colors.grey.shade600,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _presenceDot(bool isOnline) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: isOnline ? Colors.green : Colors.grey,
          shape: BoxShape.circle,
        ),
      );

  String _formatActiveAgo(dynamic ts) {
    if (ts is! int || ts <= 0) return '';
    final last = DateTime.fromMillisecondsSinceEpoch(ts).toLocal();
    final now = DateTime.now();
    final diff = now.difference(last);

    if (diff.inMinutes < 1) return 'Active just now';
    if (diff.inMinutes < 60) return 'Active ${diff.inMinutes}m ago';
    if (diff.inHours < 24) return 'Active ${diff.inHours}h ago';

    // For ≥ 1 day → exact days
    final days = diff.inDays;
    return days == 1 ? 'Active 1 day ago' : 'Active $days days ago';
  }

  // ---------- Composer ----------
  Widget _buildMessageInput({
    required bool disabledByPeer,
    required bool disabledBySelf,
  }) {
    final disabled = disabledByPeer || disabledBySelf;

    return Container(
      padding: EdgeInsets.only(left: 8, right: 8, bottom: _safeBottom(context)),
      decoration: const BoxDecoration(color: Colors.white),
      child: Center(
        child: Opacity(
          opacity: disabled ? 0.6 : 1.0,
          child: IgnorePointer(
            ignoring: disabled || _sending,
            child: SizedBox(
              height: _composerHeight,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  IconButton(
                    icon: Icon(Icons.add,
                        color: AppColors.primaryColor, size: 24),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () {
                      setState(
                          () => _showAttachmentMenu = !_showAttachmentMenu);
                    },
                  ),
                  const SizedBox(width: 8),

                  // Listen to the text field to know if user is typing
                  Expanded(
                    child: ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _messageController,
                      builder: (context, value, _) {
                        final isTyping = value.text.trim().isNotEmpty;
                        return Row(
                          children: [
                            // The pill
                            Expanded(
                              child: Container(
                                height: 40,
                                padding: const EdgeInsets.only(
                                    left: 16,
                                    right: 8), // tighter right padding
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade100,
                                  borderRadius: BorderRadius.circular(24),
                                ),
                                alignment: Alignment.center,
                                child: TextField(
                                  controller: _messageController,
                                  enabled: !disabled,
                                  maxLines: 1,
                                  textAlignVertical: TextAlignVertical.center,
                                  decoration: InputDecoration(
                                    hintText: disabledByPeer
                                        ? "You can’t reply to this conversation"
                                        : disabledBySelf
                                            ? "You’ve blocked this user"
                                            : "Message...",
                                    border: InputBorder.none,
                                    isCollapsed: true,
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                  textCapitalization:
                                      TextCapitalization.sentences,
                                  onSubmitted: (t) => _sendMessage(t),
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),

                            // Send / Heart button
                            IconButton(
                              icon: Icon(
                                isTyping ? Icons.send : Icons.favorite,
                                color: AppColors.primaryColor,
                                size: 24,
                              ),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              onPressed: _sending
                                  ? null
                                  : () {
                                      if (isTyping) {
                                        _sendMessage(_messageController.text);
                                      } else {
                                        _sendHeart();
                                      }
                                    },
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---------- Actions ----------
  void _showSoon() {
    _showSnack(kSoonMessage);
    if (_showAttachmentMenu) {
      setState(() => _showAttachmentMenu = false);
    }
  }

  // 🔹 “More” sheet adds Unblock (if I blocked), and hides risky actions when peer blocked me
  Future<void> _openMoreSheet() async {
    HapticFeedback.selectionClick();
    final otherName = (_peerDisplayName?.trim().isNotEmpty ?? false)
        ? _peerDisplayName!.trim()
        : null;

    final String myUid = FirebaseAuth.instance.currentUser!.uid;
    final String? otherUid = _peerUid;

    // Build a safe pair id if the chat doc doesn't carry match_id
    String? effectiveMatchId = _chatMatchId;
    if ((effectiveMatchId == null || effectiveMatchId.isEmpty) &&
        otherUid != null &&
        otherUid.isNotEmpty) {
      effectiveMatchId = (myUid.compareTo(otherUid) < 0)
          ? '${myUid}_$otherUid'
          : '${otherUid}_$myUid';
    }

    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: const Text(
                  "View profile",
                  style: TextStyle(
                      fontWeight: FontWeight.w600, color: Colors.black87),
                ),
                onTap: () {
                  Navigator.pop(context);

                  final targetUid =
                      _peerUid; // or use the local otherUid var if you prefer
                  if (targetUid == null || targetUid.isEmpty) {
                    _showSnack("Profile unavailable.");
                    return;
                  }

                  showProfilePreviewSheet(
                    context: context,
                    candidateUid: targetUid,
                    showActions: false, // ← hides Like/Pass, view-only
                  );
                },
              ),
              const Divider(height: 8),
              if (!_peerBlockedMe) // hide “Delete chat” if they blocked me
                ListTile(
                  leading: const Icon(Icons.delete_outline),
                  title: const Text("Delete chat (for me)",
                      style: TextStyle(
                          fontWeight: FontWeight.w600, color: Colors.red)),
                  onTap: () {
                    Navigator.pop(context);
                    _showSoon();
                  },
                ),
              if (_iBlockedPeer)
                ListTile(
                  leading: const Icon(Icons.lock_open),
                  title: const Text("Unblock",
                      style: TextStyle(
                          fontWeight: FontWeight.w600, color: Colors.red)),
                  onTap: () async {
                    Navigator.pop(context);
                    if (otherUid == null || otherUid.isEmpty) {
                      _showSnack("Unable to unblock (missing user).");
                      return;
                    }
                    await _showUnblockConfirmSheet(
                      otherUid: otherUid,
                      otherName: otherName,
                    );
                  },
                )
              else
                ListTile(
                  leading: const Icon(Icons.block),
                  title: const Text("Block",
                      style: TextStyle(
                          fontWeight: FontWeight.w600, color: Colors.red)),
                  onTap: () {
                    Navigator.pop(context);
                    final targetUid = _peerUid;
                    if (targetUid == null || targetUid.isEmpty) {
                      _showSnack("Unable to block (missing user).");
                      return;
                    }
                    _showBlockConfirmSheet(
                        otherUid: targetUid, otherName: otherName);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.cancel_outlined),
                title: const Text("Unmatch",
                    style: TextStyle(
                        fontWeight: FontWeight.w600, color: Colors.red)),
                onTap: () async {
                  Navigator.pop(context);
                  if (otherUid == null ||
                      otherUid.isEmpty ||
                      effectiveMatchId == null ||
                      effectiveMatchId.isEmpty) {
                    _showSnack("Unable to unmatch (missing pair id).");
                    return;
                  }
                  await _confirmUnmatch(
                    otherName: otherName,
                    otherUid: otherUid,
                    matchId: effectiveMatchId,
                  );
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openVoiceRecordBar() async {
    // Request mic permission here so the sheet only opens when we're allowed
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      if (status.isPermanentlyDenied) {
        _showSnack('Microphone is disabled. Please enable it in Settings.');
        await openAppSettings();
      } else {
        _showSnack('Microphone permission is required to record audio.');
      }
      return;
    }

    // hide the tray behind the sheet
    if (_showAttachmentMenu) {
      setState(() => _showAttachmentMenu = false);
    }

    await showModalBottomSheet(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewPadding.bottom + 12,
            left: 12,
            right: 12,
            top: 12,
          ),
          child: VoiceRecordBar(
            maxSeconds: 30,
            onSend: (file, durationSec) async {
              try {
                await ChatService.sendAudioMessage(
                  chatId: widget.chatId,
                  file: file,
                  durationSec: durationSec,
                  reply: _replying,
                );
                if (_replying != null) setState(() => _replying = null);
                setState(() {
                  _liveTail = true;
                  _pendingNew = 0;
                });
                _animateToBottom();
                _maybeMarkRead();
              } catch (e) {
                if (!mounted) return;
                _showSnack('Audio send failed: $e');
              } finally {
                if (mounted) Navigator.of(ctx).maybePop();
              }
            },
          ),
        );
      },
    );
  }

  Future<void> _sendMessage(String text, {bool isHeart = false}) async {
    // Guard against blocked states — don’t send if either side blocks
    if (_iBlockedPeer) {
      _showSnack("You’ve blocked this user. Unblock to send messages.");
      return;
    }
    if (_peerBlockedMe) {
      _showSnack("You can’t message this conversation.");
      return;
    }

    if (!isHeart && text.trim().isEmpty) return;
    setState(() {
      _sending = true;
    });

    final wasEmptyBefore = _docs.isEmpty;
    try {
      if (isHeart) {
        await ChatService.sendMessage(
          chatId: widget.chatId,
          isHeart: true,
          reply: _replying, // include reply
        );
      } else {
        await ChatService.sendMessage(
          chatId: widget.chatId,
          text: text.trim(),
          reply: _replying, // include reply
        );
      }
      _messageController.clear();

      if (_replying != null) {
        setState(() => _replying = null); // clear banner
      }

      if (wasEmptyBefore && !_sentFirstFromThisOpen) {
        setState(() {
          _sentFirstFromThisOpen = true;
        });
      }

      setState(() {
        _liveTail = true;
        _pendingNew = 0;
      });
      _animateToBottom();
      _maybeMarkRead();
    } catch (e) {
      if (!mounted) return;
      _showSnack('Failed to send: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _sendHeart() {
    if (_iBlockedPeer || _peerBlockedMe) {
      _showSnack("Can’t react in this conversation.");
      return;
    }
    setState(() => _showHeartAnimation = true);
    _sendMessage("", isHeart: true);
    _heartAnimationTimer?.cancel();
    _heartAnimationTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _showHeartAnimation = false);
    });
  }

  Future<void> _pickAndSendImage(ImageSource source) async {
    if (_iBlockedPeer || _peerBlockedMe) {
      _showSnack("Can’t send media in this conversation.");
      return;
    }
    try {
      final picker = ImagePicker();
      final XFile? xfile = await picker.pickImage(
        source: source,
        maxWidth: 2000,
        maxHeight: 2000,
        imageQuality: 95,
      );
      if (xfile == null) return;

      if (_showAttachmentMenu) {
        setState(() {
          _showAttachmentMenu = false;
        });
      }

      File file = File(xfile.path);
      int sizeBytes = await file.length();

      const int kCompressThreshold = 1500000; // ~1.5 MB
      if (sizeBytes > kCompressThreshold) {
        try {
          final tmpDir = await getTemporaryDirectory();
          final outPath = p.join(
            tmpDir.path,
            'am_${DateTime.now().microsecondsSinceEpoch}.jpg',
          );
          final XFile? compressedX =
              await FlutterImageCompress.compressAndGetFile(
            file.absolute.path,
            outPath,
            quality: 85,
            format: CompressFormat.jpeg,
          );
          if (compressedX != null) {
            file = File(compressedX.path);
            sizeBytes = await file.length();
          }
        } catch (_) {}
      }

      final bytes = await file.readAsBytes();
      // Small yield to avoid blocking current frame on heavy decode
      await Future<void>.delayed(Duration.zero);
      final imgSize = await _decodeImageSize(bytes);
      await _sendImageFile(
        file,
        width: imgSize.width.toInt(),
        height: imgSize.height.toInt(),
        sizeBytes: sizeBytes,
      );
    } catch (e) {
      if (!mounted) return;
      _showSnack('Image pick failed: $e');
    }
  }

  Future<ui.Size> _decodeImageSize(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return ui.Size(frame.image.width.toDouble(), frame.image.height.toDouble());
  }

  Future<void> _sendImageFile(
    File file, {
    required int width,
    required int height,
    required int sizeBytes,
  }) async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    final chatRef =
        FirebaseFirestore.instance.collection('chats').doc(widget.chatId);

    // 1) Create the pending Firestore doc our backend will finalize
    final msgRef = chatRef.collection('messages').doc();

    final Map<String, dynamic> base = {
      'sender_uid': uid,
      'type': 'image',
      'status': 'uploading',
      'created_at': FieldValue.serverTimestamp(),
      'w': width,
      'h': height,
      'size_bytes': sizeBytes,
      'storage_path': null,
      'image_url': null,
      'local_path': file.path,
    };

    if (_replying != null) {
      base.addAll(_replying!.toMap()); // seed reply so preview shows instantly
    }

    await msgRef.set(base);

    try {
      setState(() {
        _liveTail = true;
        _pendingNew = 0;
      });

      // 2) Upload and ask backend to finalize THIS doc id
      await ChatService.uploadImageToBackend(
        chatId: widget.chatId,
        file: file,
        messageId: msgRef.id,
        reply: _replying,
      );

      // 3) Success
      if (_replying != null) {
        setState(() => _replying = null);
      }

      _animateToBottom();
      _maybeMarkRead();
    } catch (e) {
      try {
        await msgRef.update({'status': 'failed'});
      } catch (_) {}
      if (!mounted) return;
      _showSnack('Upload failed: $e');
    }
  }

  // Retry handler used by MessageBubble's Retry button
  Future<void> _handleRetry(Map<String, dynamic> message) async {
    final String? localPath = message['local_path'] as String?;
    if (localPath == null ||
        localPath.isEmpty ||
        !File(localPath).existsSync()) {
      _showSnack('Original image not available to retry.');
      return;
    }

    final chatRef =
        FirebaseFirestore.instance.collection('chats').doc(widget.chatId);

    QueryDocumentSnapshot<Map<String, dynamic>>? pendingDoc;
    try {
      pendingDoc = _docs.firstWhere(
        (d) => (d.data()['local_path'] as String?) == localPath,
      );
    } catch (_) {
      try {
        final uid = FirebaseAuth.instance.currentUser!.uid;
        pendingDoc = _docs.firstWhere((d) {
          final md = d.data();
          return (md['sender_uid'] == uid) &&
              (md['status'] == 'failed') &&
              (md['type'] == 'image');
        });
      } catch (_) {}
    }

    if (pendingDoc == null) {
      await _sendImageFile(
        File(localPath),
        width: (message['w'] as num?)?.toInt() ?? 1000,
        height: (message['h'] as num?)?.toInt() ?? 1000,
        sizeBytes: File(localPath).lengthSync(),
      );
      return;
    }

    final msgRef = chatRef.collection('messages').doc(pendingDoc.id);
    await msgRef.update({'status': 'uploading'});

    try {
      await ChatService.uploadImageToBackend(
        chatId: widget.chatId,
        file: File(localPath),
        messageId: pendingDoc.id,
        reply: _replying, // harmless if null
      );
    } catch (e) {
      await msgRef.update({'status': 'failed'});
      if (!mounted) return;
      _showSnack('Retry failed: $e');
    }
  }

  // Remove handler used by MessageBubble's ❌ button
  Future<void> _handleRemove(Map<String, dynamic> message) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove photo?'),
        content: const Text('This will remove the photo from this chat.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    QueryDocumentSnapshot<Map<String, dynamic>>? target;
    try {
      final lp = message['local_path'] as String?;
      if (lp != null && lp.isNotEmpty) {
        target =
            _docs.firstWhere((d) => (d.data()['local_path'] as String?) == lp);
      }
    } catch (_) {}

    if (target == null) {
      try {
        final sp = message['storage_path'] as String?;
        if (sp != null && sp.isNotEmpty) {
          target = _docs
              .firstWhere((d) => (d.data()['storage_path'] as String?) == sp);
        }
      } catch (_) {}
    }

    if (target == null) {
      try {
        final iu = message['image_url'] as String?;
        if (iu != null && iu.isNotEmpty) {
          target =
              _docs.firstWhere((d) => (d.data()['image_url'] as String?) == iu);
        }
      } catch (_) {}
    }

    if (target == null) {
      _showSnack("Couldn't find the image message in this page.");
      return;
    }

    final msgId = target.id;
    final msgRef = FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.chatId)
        .collection('messages')
        .doc(msgId);

    try {
      await ChatService.removeMessageViaBackend(
        chatId: widget.chatId,
        messageId: msgId,
      );
    } catch (e) {
      try {
        await msgRef.delete();
      } catch (_) {
        _showSnack('Failed to remove: $e');
        return;
      }
    }

    setState(() {
      _docs.removeWhere((d) => d.id == msgId);
    });
  }

  // ---------- Reply helpers ----------
  // Prefer a good preview image if present.
  String? _bestThumb(Map<String, dynamic> m) {
    final cands = <String?>[
      (m['thumb'] as String?),
      (m['image_thumb'] as String?),
      (m['image_url'] as String?),
    ];
    for (final s in cands) {
      if (s != null && s.trim().isNotEmpty) return s.trim();
    }
    return null;
  }

  void _startReplyFrom(String messageId, Map<String, dynamic> m) {
    final String type = (m['type'] as String?)?.trim() ?? 'text';
    final String? text = (m['text'] as String?)?.trim();
    final String? thumb = _bestThumb(m);

    setState(() {
      _replying = ReplyMeta(
        messageId: messageId,
        senderUid: (m['sender_uid'] as String?) ?? '',
        text: (text != null && text.isNotEmpty) ? text : null,
        type: type,
        thumb: thumb,
        deleted: false,
      );
    });
  }

  String _replyingTitle() {
    if (_replying == null) return 'Replying';
    final me = FirebaseAuth.instance.currentUser?.uid;
    if (me != null && _replying!.senderUid == me) {
      return 'Replying to yourself';
    }
    final name =
        (_peerDisplayName?.isNotEmpty ?? false) ? _peerDisplayName! : 'message';
    return 'Replying to $name';
  }

  // ⬇️ UPDATED: IG/Messenger-style jump — text/heart scroll, photo opens viewer
  Future<void> _jumpToMessage(String messageId) async {
    // 0) If it’s already mounted, just scroll + flash.
    final mountedKey = _itemKeys[messageId];
    if (mountedKey != null && mountedKey.currentContext != null) {
      _flashTimer?.cancel();
      setState(() => _flashId = messageId);
      Scrollable.ensureVisible(
        mountedKey.currentContext!,
        duration: const Duration(milliseconds: 280),
        alignment: 0.3,
        curve: Curves.easeOut,
      );
      _flashTimer = Timer(const Duration(milliseconds: 1200), () {
        if (!mounted) return;
        setState(() => _flashId = null);
      });
      return;
    }

    // 1) Fetch target to know its type & created_at
    final msgRef = FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.chatId)
        .collection('messages')
        .doc(messageId);

    final snap = await msgRef.get();
    if (!snap.exists) {
      _showSnack("Original message not found.");
      return;
    }
    final data = snap.data() as Map<String, dynamic>;
    final String type = (data['type'] as String?)?.toLowerCase() ?? 'text';
    final ts = data['created_at'] as Timestamp?;
    if (ts == null) {
      _showSnack("Original message missing timestamp.");
      return;
    }
    final targetAt = ts.toDate();

    // If it's an image, open the viewer like IG/Messenger
    if (type == 'image') {
      await _openViewerAtMessage(messageId, data);
      return;
    }

    // Helper to refresh window bounds.
    DateTime? _newestLoaded() => _docs.isNotEmpty
        ? ((_docs.first.data()['created_at'] as Timestamp?)?.toDate())
        : null;
    DateTime? _oldestLoaded() => _docs.isNotEmpty
        ? ((_docs.last.data()['created_at'] as Timestamp?)?.toDate())
        : null;

    // 2) If target is newer than our newest, snap to bottom and retry a few frames.
    final newest = _newestLoaded();
    if (newest != null && targetAt.isAfter(newest)) {
      setState(() {
        _liveTail = true;
        _pendingNew = 0;
      });
      _animateToBottom();
      for (int i = 0; i < 6; i++) {
        if (!mounted) return;
        await Future<void>.delayed(const Duration(milliseconds: 80));
        final k = _itemKeys[messageId];
        if (k != null && k.currentContext != null) {
          _flashTimer?.cancel();
          setState(() => _flashId = messageId);
          Scrollable.ensureVisible(
            k.currentContext!,
            duration: const Duration(milliseconds: 280),
            alignment: 0.3,
            curve: Curves.easeOut,
          );
          _flashTimer = Timer(const Duration(milliseconds: 1200), () {
            if (!mounted) return;
            setState(() => _flashId = null);
          });
          return;
        }
      }
      _showSnack("Couldn't jump to the original message.");
      return;
    }

    // 3) Page older until we include the target (or run out).
    int safety = 60; // hard stop
    while (mounted) {
      final key = _itemKeys[messageId];
      if (key != null && key.currentContext != null) break;

      final oldest = _oldestLoaded();
      if (!_hasMore || oldest == null) break;

      if (oldest.isAfter(targetAt)) {
        if (_loadingMore) {
          await Future<void>.delayed(const Duration(milliseconds: 120));
        } else {
          await _loadMoreOlder();
        }
        await WidgetsBinding.instance.endOfFrame;
        if (--safety <= 0) break;
        continue;
      }
      break;
    }

    // 4) Try to scroll to the mounted widget now.
    final k2 = _itemKeys[messageId];
    if (k2 != null && k2.currentContext != null) {
      _flashTimer?.cancel();
      setState(() => _flashId = messageId);
      Scrollable.ensureVisible(
        k2.currentContext!,
        duration: const Duration(milliseconds: 320),
        alignment: 0.28,
        curve: Curves.easeOut,
      );
      _flashTimer = Timer(const Duration(milliseconds: 1200), () {
        if (!mounted) return;
        setState(() => _flashId = null);
      });
      return;
    }

    // 5) Fallback: scroll to the closest-by-time item we DO have, then try once more.
    if (_docs.isNotEmpty) {
      int bestIdx = 0;
      Duration bestDiff = const Duration(days: 36500);
      for (int i = 0; i < _docs.length; i++) {
        final t = (_docs[i].data()['created_at'] as Timestamp?)?.toDate();
        if (t == null) continue;
        final d = (t.difference(targetAt)).abs();
        if (d < bestDiff) {
          bestDiff = d;
          bestIdx = i;
        }
      }
      final bestId = _docs[bestIdx].id;
      final bestKey = _itemKeys[bestId];
      if (bestKey != null && bestKey.currentContext != null) {
        await Scrollable.ensureVisible(
          bestKey.currentContext!,
          duration: const Duration(milliseconds: 320),
          alignment: 0.2,
          curve: Curves.easeOut,
        );
        await WidgetsBinding.instance.endOfFrame;
        final k3 = _itemKeys[messageId];
        if (k3 != null && k3.currentContext != null) {
          _flashTimer?.cancel();
          setState(() => _flashId = messageId);
          await Scrollable.ensureVisible(
            k3.currentContext!,
            duration: const Duration(milliseconds: 260),
            alignment: 0.3,
            curve: Curves.easeOut,
          );
          _flashTimer = Timer(const Duration(milliseconds: 1200), () {
            if (!mounted) return;
            setState(() => _flashId = null);
          });
          return;
        }
      }
    }

    _showSnack("Couldn't jump to the original message.");
  }

  // ⬇️ NEW: open the viewer positioned on the tapped photo (IG/Messenger behavior)
  Future<void> _openViewerAtMessage(
      String targetId, Map<String, dynamic> targetData) async {
    // Ensure the target image is in memory (page older if needed).
    DateTime? targetAt;
    final ts = targetData['created_at'] as Timestamp?;
    if (ts != null) targetAt = ts.toDate();

    int safety = 30;
    while (mounted) {
      final hasTargetInPage = _docs.any((d) => d.id == targetId);
      if (hasTargetInPage) break;

      if (!_hasMore || targetAt == null) break;

      final oldest = (_docs.isNotEmpty)
          ? ((_docs.last.data()['created_at'] as Timestamp?)?.toDate())
          : null;
      if (oldest == null || !oldest.isAfter(targetAt)) break;

      if (_loadingMore) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
      } else {
        await _loadMoreOlder();
      }
      await WidgetsBinding.instance.endOfFrame;
      if (--safety <= 0) break;
    }

    // Build gallery items from what's currently loaded (newest→oldest).
    final items = <ChatImageItem>[];
    int initialIndex = 0;

    for (int i = 0; i < _docs.length; i++) {
      final d = _docs[i];
      final m = d.data();
      if ((m['type'] as String?)?.toLowerCase() != 'image') continue;

      final storagePath = (m['storage_path'] as String?) ??
          (m['image_path'] as String?) ??
          (m['path'] as String?);

      final directUrl = m['image_url'] as String?;
      final idForViewer = d.id;

      if (d.id == targetId) initialIndex = items.length;

      items.add(ChatImageItem(
        messageId: idForViewer,
        directUrl: directUrl,
        storagePath: storagePath,
      ));
    }

    if (items.isEmpty) {
      // Fallback: if somehow not collected, just snap to latest.
      _showSnack("Opening photo…");
      _animateToBottom();
      return;
    }

    // ignore: use_build_context_synchronously
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ImageViewerScreen(
          items: items,
          initialIndex: initialIndex,
        ),
        fullscreenDialog: true,
      ),
    );
  }

  // ---------- Unmatch helpers ----------
  Future<void> _confirmUnmatch({
    required String matchId,
    required String otherUid,
    String? otherName,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Unmatch?"),
        content: Text(
          (otherName != null && otherName.isNotEmpty)
              ? "You won’t be able to message $otherName again."
              : "You won’t be able to message this user again.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text("Unmatch"),
          ),
        ],
      ),
    );

    if (ok == true) {
      await _unmatch(matchId: matchId, otherUid: otherUid);
    }
  }

  // ---------- Block helpers ----------
  Future<void> _showBlockConfirmSheet({
    required String otherUid,
    required String? otherName,
  }) async {
    HapticFeedback.selectionClick();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final name = (otherName ?? "").trim();
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
              top: 8,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: AppColors.primaryColor.withOpacity(.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(Icons.block, color: AppColors.primaryColor),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        "Block ${name.isEmpty ? 'this user' : name}?",
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  "They won’t be able to message you. "
                  "You can unblock them later in Settings → Blocked users.",
                  style: TextStyle(color: Colors.grey.shade700),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text("Cancel"),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white,
                        ),
                        onPressed: () async {
                          Navigator.pop(ctx);
                          await _blockUser(otherUid: otherUid, otherName: name);
                        },
                        child: const Text("Block"),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _blockUser({
    required String otherUid,
    required String otherName,
  }) async {
    HapticFeedback.heavyImpact();
    try {
      await context.read<BlocksRepository>().block(otherUid);
      if (!mounted) return;
      _showSnack(otherName.isNotEmpty ? "Blocked $otherName" : "User blocked");
    } catch (e) {
      if (!mounted) return;
      _showSnack("Block failed — $e");
    }
  }

  Future<void> _showUnblockConfirmSheet({
    required String otherUid,
    required String? otherName,
  }) async {
    final name = (otherName ?? "").trim();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
              top: 8,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: const Color(0xFFD32F2F).withOpacity(.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child:
                          const Icon(Icons.lock_open, color: Color(0xFFD32F2F)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        "Unblock ${name.isEmpty ? 'this user' : name}?",
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  "They’ll be able to message you again. You can block them anytime.",
                  style: TextStyle(color: Colors.grey.shade700, fontSize: 13.5),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text("Cancel"),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFD32F2F),
                          foregroundColor: Colors.white,
                        ),
                        onPressed: () async {
                          Navigator.pop(ctx);
                          await _unblockUser(
                              otherUid: otherUid, otherName: name);
                        },
                        child: const Text("Unblock"),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _unblockUser({
    required String otherUid,
    String? otherName,
  }) async {
    HapticFeedback.selectionClick();
    try {
      await context.read<BlocksRepository>().unblock(otherUid);
      if (!mounted) return;
      _showSnack(
        (otherName != null && otherName.trim().isNotEmpty)
            ? "Unblocked $otherName"
            : "User unblocked",
      );
    } catch (e) {
      if (!mounted) return;
      _showSnack("Unblock failed — $e");
    }
  }

  Future<void> _unmatch({
    required String matchId,
    required String otherUid,
  }) async {
    try {
      await ApiClient.postJson("/matches/unmatch", {
        "match_id": matchId, // pair id (a_b)
        "other_uid": otherUid, // helps backend validate membership
      });
      if (!mounted) return;
      _showSnack("Unmatched");
      Navigator.pop(context, true); // go back to inbox; allow refresh
    } catch (e) {
      if (!mounted) return;
      _showSnack("Unmatch failed — $e");
    }
  }

  Widget _buildBlockBanner(BuildContext context) {
    final name = (_peerDisplayName ?? '').trim();
    final isIBlocked = _iBlockedPeer;

    const brightRed = Color(0xFFD32F2F);
    const double kEdgePadLeft = 20;
    const double kEdgePadRight = 16; // keep right edge snug
    const double kGap = 12;

    // No manual \n — let the layout wrap naturally.
    final copy = isIBlocked
        ? (name.isNotEmpty
            ? "You blocked $name. You won’t receive their messages."
            : "You blocked this user. You won’t receive their messages.")
        : "You can’t reply to this conversation.";

    return Container(
      width: double.infinity,
      color: brightRed,
      padding: const EdgeInsets.only(
        left: kEdgePadLeft,
        right: kEdgePadRight,
        top: 10,
        bottom: 10,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(Icons.block, size: 24, color: Colors.white),
          const SizedBox(width: kGap),
          // Text takes remaining space and may wrap to 2 lines
          Expanded(
            child: Text(
              copy,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 13.0,
                height: 1.25,
              ),
            ),
          ),
          if (isIBlocked) ...[
            const SizedBox(width: kGap),
            // Prevent overflow on very small screens by allowing gentle downscale
            FittedBox(
              fit: BoxFit.scaleDown,
              child: TextButton(
                onPressed: () {
                  final target = _peerUid;
                  if (target == null || target.isEmpty) {
                    _showSnack("Unable to unblock (missing user).");
                    return;
                  }
                  _showUnblockConfirmSheet(otherUid: target, otherName: name);
                },
                style: TextButton.styleFrom(
                  foregroundColor: brightRed,
                  backgroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
                  shape: const StadiumBorder(),
                  visualDensity: VisualDensity.compact,
                  minimumSize: const Size(0, 0),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text(
                  "Unblock",
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13.0,
                    letterSpacing: .2,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ---------- Small helpers ----------
  Widget _skeletonLine({double width = 120, double height = 14}) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(.06),
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }
}

// ---------- Small sub-widgets ----------
class _SmallAvatar extends StatelessWidget {
  final String? photoUrl;
  final double size;
  const _SmallAvatar({required this.photoUrl, required this.size});

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: Colors.grey.shade200,
      backgroundImage: (photoUrl != null && photoUrl!.isNotEmpty)
          ? NetworkImage(photoUrl!)
          : null,
      child: (photoUrl == null || photoUrl!.isEmpty)
          ? const Icon(Icons.person, color: Colors.black54)
          : null,
    );
  }
}

/// Attachment bar that appears BELOW the message bar and pushes it up.
/// Flat corners, single theme color, **no labels**.
class _AttachmentBar extends StatelessWidget {
  final double height;
  final VoidCallback onCamera, onGallery, onLocation, onAudio, onGif, onClose;
  const _AttachmentBar({
    required this.height,
    required this.onCamera,
    required this.onGallery,
    required this.onLocation,
    required this.onAudio,
    required this.onGif,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.primaryColor;
    final safeBottom = MediaQuery.of(context).viewPadding.bottom;

    return GestureDetector(
      onVerticalDragUpdate: (d) {
        if (d.primaryDelta != null && d.primaryDelta! > 6) {
          onClose(); // swipe down to dismiss
        }
      },
      child: Material(
        color: Colors.white,
        elevation: 8,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        child: SizedBox(
          height: height + safeBottom,
          child: Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 12,
              bottom: 12 + safeBottom,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _Action(icon: Icons.camera_alt, color: c, onTap: onCamera),
                _Action(icon: Icons.photo, color: c, onTap: onGallery),
                _Action(icon: Icons.location_on, color: c, onTap: onLocation),
                _Action(icon: Icons.mic, color: c, onTap: onAudio),
                _Action(icon: Icons.gif_box, color: c, onTap: onGif),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _Action({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Clean circular ripple bounded to the circle, no gray hover highlight
    return Material(
      color: color.withOpacity(.12),
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        splashColor: color.withOpacity(.22),
        highlightColor: Colors.transparent,
        hoverColor: Colors.transparent,
        focusColor: Colors.transparent,
        child: SizedBox(
          width: 56,
          height: 56,
          child: Icon(icon, color: color, size: 24),
        ),
      ),
    );
  }
}

class _EmptyThread extends StatelessWidget {
  const _EmptyThread();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(
              Icons.chat_bubble_outline,
              color: AppColors.primaryColor,
              size: 44,
            ),
            SizedBox(height: 12),
            Text('Say hi 👋', style: TextStyle(fontWeight: FontWeight.w700)),
            SizedBox(height: 6),
            Text(
              'Your conversation will appear here once you send a message.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
