// lib/screens/messages/messages_screen.dart
import "package:flutter/material.dart";
import "package:google_fonts/google_fonts.dart";
import "package:cloud_firestore/cloud_firestore.dart";
import "package:firebase_auth/firebase_auth.dart";
import "package:cached_network_image/cached_network_image.dart";
import "package:flutter/services.dart";
import 'package:intl/intl.dart';
import "dart:async";

import "package:provider/provider.dart"; // ← uses BlocksRepository
import "../../repositories/blocks_repository.dart";

import "../../utils/constants.dart";
import "../../utils/api_client.dart";
import "../discover/discover_screen.dart";
import "../matches/matches_screen.dart";
import "conversation_screen.dart";
import "../profile/profile_screen.dart";
import "../settings/settings_screen.dart";

// ⬇️ Reusable, themed refresh control
import "../../widgets/themed_refresh.dart";

// ⬇️ Centralized chats query (now uses ChatQueries.base / startAfterDocument)
import "../../utils/chat_queries.dart";

// ⬇️ Shared shimmer
import "../../widgets/shimmer.dart";

// ⬇️ NEW: unread notifications badge
import "../../repositories/notifications_repository.dart";

// ⬇️ NEW: notifications screen
import "../notifications/notifications_screen.dart";

// ⬇️ NEW: profile preview sheet (for View profile)
import '../../widgets/profile_preview_sheet.dart'; // ⬅️ ADDED

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
      return Colors.teal; // Friendly neutral
    default:
      return Colors.black54; // fallback
  }
}

/// Inline Name + gender icon (puts the icon NEXT TO THE NAME — not age)
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

class MessagesScreen extends StatefulWidget {
  const MessagesScreen({super.key});
  @override
  State<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends State<MessagesScreen>
    with AutomaticKeepAliveClientMixin<MessagesScreen> {
  static const String kSoonMessage = "Feature will be added soon!";
  final Map<String, Map<String, dynamic>> _profileCache = {};
  String _query = "";
  int _filterIndex = 0;

  // ---- notifications unread badge ----
  final _notifsRepo = NotificationsRepository();
  late final Stream<int> _unreadStream; // ← auth-aware & non-null

  // ---- Stream state ----
  Query<Map<String, dynamic>>? _baseQuery;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sub;
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _docs = [];
  bool _seeded = false;

  // Shimmer gate
  bool _allowSkeleton = false;
  Timer? _skeletonGate;

  // Bottom nav sizing
  final GlobalKey _bottomNavKey = GlobalKey();
  double _bottomNavHeight = kBottomNavigationBarHeight;

  // Refresh state
  bool _isRefreshing = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();

    final uid = FirebaseAuth.instance.currentUser!.uid;

    // ✅ Use the new centralized query (no inequality on message_count)
    _baseQuery = ChatQueries.base(uid).limit(50);

    // 🔔 notifications unread stream (auth-aware: follows sign-in/out)
    _unreadStream =
        FirebaseAuth.instance.authStateChanges().asyncExpand((user) async* {
      if (user == null) {
        yield 0;
      } else {
        yield* _notifsRepo.unreadCountStream(uid: user.uid);
      }
    });

    _skeletonGate = Timer(const Duration(milliseconds: 120), () {
      if (mounted) setState(() => _allowSkeleton = true);
    });

    _seedFromCacheThenStream();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureBottomNav());
  }

  void _measureBottomNav() {
    final ctx = _bottomNavKey.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject() as RenderBox?;
    final h = box?.size.height;
    if (h != null && h > 0 && (h - _bottomNavHeight).abs() > 0.5) {
      setState(() => _bottomNavHeight = h);
    }
  }

  Future<void> _seedFromCacheThenStream() async {
    try {
      if (_baseQuery == null) return;
      final cached =
          await _baseQuery!.get(const GetOptions(source: Source.cache));
      if (mounted && cached.docs.isNotEmpty) {
        _docs = cached.docs;
        _seeded = true;
        setState(() {});
        debugPrint('[INBOX] seeded from cache: ${cached.docs.length} docs');
      }
    } catch (_) {}
    await _attachStream();
  }

  Future<void> _attachStream() async {
    await _sub?.cancel();
    if (_baseQuery == null) return;
    debugPrint('[INBOX] attaching stream…');

    _sub = _baseQuery!.snapshots(includeMetadataChanges: true).listen((snap) {
      if (!mounted) return;
      _docs = snap.docs;
      _seeded = true;
      setState(() {});
      final top = snap.docs.isNotEmpty ? snap.docs.first.data() : null;
      final ts =
          (top?['last_activity_at'] as Timestamp?)?.toDate().toString() ??
              (top?['last_message_at'] as Timestamp?)?.toDate().toString() ??
              '—';
      debugPrint('[INBOX] snapshot '
          'docs=${snap.docs.length} fromCache=${snap.metadata.isFromCache} top.last_activity=$ts');
    }, onError: (e, st) async {
      debugPrint('[INBOX][ERROR:stream] $e');
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _skeletonGate?.cancel();
    super.dispose();
  }

  Future<void> _ensureProfile(String uid) async {
    if (_profileCache.containsKey(uid)) return;
    try {
      final p = await ApiClient.getJson("/profile/$uid");
      if (!mounted) return;
      setState(() {
        _profileCache[uid] = {
          "name": (p["first_name"] ?? p["name"] ?? "").toString(),
          "image_url":
              (p["profile_image_url"] ?? p["image_url"] ?? "").toString(),
          // 🔹 NEW: save normalized gender to cache
          "gender": _formatGenderLabel(
            (p["gender"] ??
                    p["sex"] ??
                    (p["personal_info"] is Map
                        ? (p["personal_info"]["gender"] ?? "")
                        : "")) //
                .toString(),
          ),
        };
      });
    } catch (_) {}
  }

  // ---------- Refresh logic ----------
  Future<void> _onRefresh({bool silent = false}) async {
    if (_isRefreshing) return;
    setState(() => _isRefreshing = true);
    try {
      if (_baseQuery == null) return;
      final snap =
          await _baseQuery!.get(const GetOptions(source: Source.server));
      if (!mounted) return;
      _docs = snap.docs;
      _seeded = true;

      final me = FirebaseAuth.instance.currentUser!.uid;
      for (final doc in _docs.take(8)) {
        final d = doc.data();
        final members = List<String>.from(d['members'] ?? const []);
        final otherUid = members.firstWhere((m) => m != me, orElse: () => me);
        // ignore: unawaited_futures
        _ensureProfile(otherUid);
      }

      setState(() {});
      if (!silent) {
        HapticFeedback.mediumImpact();
      }
    } catch (e) {
      debugPrint('[INBOX][REFRESH][ERROR] $e');
      await _attachStream();
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  void _navigateToDiscover() => Navigator.pushReplacement(
        context,
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => const DiscoverScreen(),
          transitionsBuilder: (_, a, __, child) => SlideTransition(
            position: a.drive(
              Tween(begin: const Offset(-1, 0), end: Offset.zero)
                  .chain(CurveTween(curve: Curves.easeInOut)),
            ),
            child: child,
          ),
          transitionDuration: const Duration(milliseconds: 300),
        ),
      );

  void _navigateToMatches() => Navigator.pushReplacement(
        context,
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => const MatchesScreen(),
          transitionsBuilder: (_, a, __, child) => SlideTransition(
            position: a.drive(
              Tween(begin: const Offset(-1, 0), end: Offset.zero)
                  .chain(CurveTween(curve: Curves.easeInOut)),
            ),
            child: child,
          ),
          transitionDuration: const Duration(milliseconds: 300),
        ),
      );

  // Await push → silent refresh when coming back
  void _navigateToConversation(String chatId) async {
    await Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => ConversationScreen(chatId: chatId),
        transitionsBuilder: (_, a, __, child) => SlideTransition(
          position: a.drive(
            Tween(begin: const Offset(1, 0), end: Offset.zero)
                .chain(CurveTween(curve: Curves.easeInOut)),
          ),
          child: child,
        ),
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );
    _onRefresh(silent: true);
  }

  void _navigateToSettings() => Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const SettingsScreen(),
        transitionsBuilder: (_, a, __, child) => SlideTransition(
          position: a.drive(
            Tween(begin: const Offset(1, 0), end: Offset.zero)
                .chain(CurveTween(curve: Curves.easeInOut)),
          ),
          child: child,
        ),
        transitionDuration: const Duration(milliseconds: 300),
      ));

  void _navigateToProfile() => Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const ProfileScreen(),
        transitionsBuilder: (_, a, __, child) => SlideTransition(
          position: a.drive(
            Tween(begin: const Offset(1, 0), end: Offset.zero)
                .chain(CurveTween(curve: Curves.easeInOut)),
          ),
          child: child,
        ),
        transitionDuration: const Duration(milliseconds: 300),
      ));

  // ⬇️ NEW: go to Notifications screen
  void _navigateToNotifications() => Navigator.push(
        context,
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => const NotificationsScreen(),
          transitionsBuilder: (_, a, __, child) => SlideTransition(
            position: a.drive(
              Tween(begin: const Offset(1, 0), end: Offset.zero)
                  .chain(CurveTween(curve: Curves.easeInOut)),
            ),
            child: child,
          ),
          transitionDuration: const Duration(milliseconds: 300),
        ),
      );

  // ---------- Unmatch wiring (uses pair match_id) ----------
  // ---------- Unmatch confirmation as a bottom sheet (same name) ----------
  Future<void> _confirmUnmatch({
    required String chatId,
    required String matchId,
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
                        color: Colors.red.withOpacity(.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child:
                          const Icon(Icons.cancel_outlined, color: Colors.red),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        "Unmatch ${name.isEmpty ? 'this user' : name}?",
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
                  name.isEmpty
                      ? "You won’t be able to message this user again."
                      : "You won’t be able to message $name again.",
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
                          await _unmatch(
                            chatId: chatId,
                            matchId: matchId,
                            otherUid: otherUid,
                          );
                        },
                        child: const Text("Unmatch"),
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

  Future<void> _unmatch({
    required String chatId,
    required String matchId,
    required String otherUid,
  }) async {
    HapticFeedback.heavyImpact();

    final oldDocs =
        List<QueryDocumentSnapshot<Map<String, dynamic>>>.from(_docs);
    setState(() {
      _docs = _docs.where((d) => d.id != chatId).toList();
    });

    try {
      await ApiClient.postJson(
        "/matches/unmatch",
        {
          "match_id": matchId, // pair id, e.g., a_b
          "other_uid": otherUid, // helps backend validate membership
        },
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Unmatched")),
      );
    } catch (e) {
      setState(() => _docs = oldDocs);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Unmatch failed — $e")),
      );
    }
  }

  // ---------- Block confirmation quicksheet ----------
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

  // ---------- Block via repository (keeps local state in sync) ----------
  Future<void> _blockUser({
    required String otherUid,
    required String otherName,
  }) async {
    HapticFeedback.heavyImpact();
    try {
      await context.read<BlocksRepository>().block(otherUid);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                otherName.isNotEmpty ? "Blocked $otherName" : "User blocked")),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Block failed — $e")),
      );
    }
  }

  // ---------- Unblock confirm sheet ----------
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
                            otherUid: otherUid,
                            otherName: name.isEmpty ? null : name,
                          );
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

  // ---------- Unblock via repository ----------
  Future<void> _unblockUser({
    required String otherUid,
    String? otherName,
  }) async {
    HapticFeedback.selectionClick();
    try {
      await context.read<BlocksRepository>().unblock(otherUid);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            (otherName != null && otherName.trim().isNotEmpty)
                ? "Unblocked $otherName"
                : "User unblocked",
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Unblock failed — $e")),
      );
    }
  }

  // UPDATED: include matchId + BLOCK/UNBLOCK toggle based on BlocksRepository
  Future<void> _showChatActions({
    required BuildContext context,
    required String chatId,
    required String matchId,
    required String otherUid,
    required String? otherName,
    required bool isPinned,
    required bool hasUnread,
  }) async {
    HapticFeedback.selectionClick();

    // Ask BlocksRepository if this user is blocked by me.
    bool iBlockedPeer = false;
    try {
      final repo = context.read<BlocksRepository>();
      iBlockedPeer = repo.isBlockedByMe(otherUid);
    } catch (_) {
      // repo optional; fail open (iBlockedPeer=false)
    }

    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      isScrollControlled: true,
      builder: (_) {
        final bottomInset = MediaQuery.of(context).viewInsets.bottom;
        return SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.only(bottom: bottomInset > 0 ? bottomInset : 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ActionTile(
                  icon: Icons.person_outline,
                  label: "View profile",
                  onTap: () {
                    Navigator.pop(context);
                    HapticFeedback.lightImpact();
                    showProfilePreviewSheet(
                      context: context,
                      candidateUid: otherUid,
                      showActions: false, // ⬅️ hide Like/Pass in Messages
                    );
                  },
                ),
                _ActionTile(
                  icon: isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                  label: isPinned ? "Unpin" : "Pin to top",
                  onTap: () {
                    Navigator.pop(context);
                    _soonAction();
                  },
                ),
                _ActionTile(
                  icon: hasUnread
                      ? Icons.mark_email_read_outlined
                      : Icons.mark_email_unread_outlined,
                  label: hasUnread ? "Mark as read" : "Mark as unread",
                  onTap: () {
                    Navigator.pop(context);
                    _soonAction();
                  },
                ),
                _ActionTile(
                  icon: Icons.notifications_off_outlined,
                  label: "Mute…",
                  onTap: () {
                    Navigator.pop(context);
                    _showMuteSheet(context);
                  },
                ),
                const Divider(height: 8),
                _ActionTile(
                  icon: Icons.archive_outlined,
                  label: "Archive",
                  onTap: () {
                    Navigator.pop(context);
                    _soonAction();
                  },
                ),
                _ActionTile(
                  icon: Icons.delete_outline,
                  label: "Delete chat (for me)",
                  danger: true,
                  onTap: () {
                    Navigator.pop(context);
                    _soonAction();
                  },
                ),

                // 🔻 Toggle between UNBLOCK vs BLOCK & REPORT
                if (iBlockedPeer)
                  _ActionTile(
                    icon: Icons.lock_open,
                    label: "Unblock",
                    danger: true,
                    onTap: () {
                      Navigator.pop(context);
                      _showUnblockConfirmSheet(
                        otherUid: otherUid,
                        otherName: otherName,
                      );
                    },
                  )
                else
                  _ActionTile(
                    icon: Icons.block,
                    label: "Block",
                    danger: true,
                    onTap: () {
                      Navigator.pop(context);
                      _showBlockConfirmSheet(
                        otherUid: otherUid,
                        otherName: otherName,
                      );
                    },
                  ),

                _ActionTile(
                  icon: Icons.cancel_outlined,
                  label: "Unmatch",
                  danger: true,
                  onTap: () {
                    Navigator.pop(context);
                    _confirmUnmatch(
                      chatId: chatId,
                      matchId: matchId,
                      otherUid: otherUid,
                      otherName: otherName,
                    );
                  },
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showMuteSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
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
              _ActionTile(
                  icon: Icons.schedule,
                  label: "Mute for 8 hours",
                  onTap: () {
                    Navigator.pop(context);
                    _soonAction();
                  }),
              _ActionTile(
                  icon: Icons.today,
                  label: "Mute for 1 day",
                  onTap: () {
                    Navigator.pop(context);
                    _soonAction();
                  }),
              _ActionTile(
                  icon: Icons.date_range,
                  label: "Mute for 7 days",
                  onTap: () {
                    Navigator.pop(context);
                    _soonAction();
                  }),
              _ActionTile(
                  icon: Icons.volume_off,
                  label: "Mute forever",
                  onTap: () {
                    Navigator.pop(context);
                    _soonAction();
                  }),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  void _soonAction() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("This feature will be added soon")),
    );
  }

  Widget _defaultAvatarImage() {
    return Image.asset(
      'assets/default_pfp.png',
      fit: BoxFit.cover,
    );
  }

  // keep for per-row graceful reveal (not the initial skeleton list)
  Widget _skeletonLine({double width = 120, double height = 14}) {
    return Shimmer(
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: Colors.grey.shade300,
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // keep-alive
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        systemOverlayStyle: const SystemUiOverlayStyle(
          statusBarColor: Colors.white,
          statusBarIconBrightness: Brightness.dark,
          statusBarBrightness: Brightness.light,
        ),
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(0.5),
          child: Container(height: 0.5, color: Colors.black.withOpacity(.08)),
        ),
        titleSpacing: 0,
        title: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Text(
                    "AttachMates",
                    style: GoogleFonts.indieFlower(
                      textStyle: TextStyle(
                        color: AppColors.primaryColor,
                        fontSize: 26,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    "Messages",
                    style: TextStyle(
                      color: Colors.grey.shade600,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  // 🔔 Notifications with numeric badge + 99+ cap (same as Discover/Matches)
                  StreamBuilder<int>(
                    stream: _unreadStream,
                    builder: (context, snapshot) {
                      final count = (snapshot.data ?? 0);
                      return Stack(
                        clipBehavior: Clip.none,
                        children: [
                          IconButton(
                            onPressed: _navigateToNotifications,
                            icon: Icon(
                              Icons.notifications_none,
                              color: AppColors.primaryColor,
                            ),
                            tooltip: 'Notifications',
                          ),
                          if (count > 0)
                            Positioned(
                              right: 6,
                              top: 6,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.redAccent,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                constraints: const BoxConstraints(minWidth: 20),
                                child: Text(
                                  count > 99 ? '99+' : '$count',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                  IconButton(
                    onPressed: _navigateToSettings,
                    icon: Icon(Icons.settings, color: AppColors.primaryColor),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      body: _buildScrollView(),
      bottomNavigationBar: SafeArea(
        key: _bottomNavKey,
        top: false,
        bottom: true,
        child: _buildBottomNavBar(),
      ),
    );
  }

  // ---------- SCROLL VIEW (IG-style pull) ----------
  Widget _buildScrollView() {
    return CustomScrollView(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      slivers: [
        ThemedSliverRefreshControl(
          onRefresh: () => _onRefresh(),
          color: AppColors.primaryColor,
          indicatorExtent: 60.0,
          fadeOutWhenCollapsed: true,
        ),
        SliverToBoxAdapter(child: _buildSearchAndFilters()),
        ..._buildSliverBody(),
      ],
    );
  }

  List<Widget> _buildSliverBody() {
    final uid = FirebaseAuth.instance.currentUser!.uid;

    if (!_seeded && !_allowSkeleton) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: SizedBox.shrink(),
        )
      ];
    }

    // ⬇️ skeleton that matches the real ListTile layout
    if (!_seeded) {
      return [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(0, 6, 0, _bottomNavHeight + 12),
          sliver: SliverList.builder(
            itemCount: 6,
            itemBuilder: (_, __) => const _SkeletonConversationTile(),
          ),
        ),
      ];
    }

    var docs = _docs;

    docs.sort((a, b) {
      final ta = ((a.data()['last_activity_at'] as Timestamp?) ??
              (a.data()['last_message_at'] as Timestamp?))
          ?.toDate();
      final tb = ((b.data()['last_activity_at'] as Timestamp?) ??
              (b.data()['last_message_at'] as Timestamp?))
          ?.toDate();
      if (ta == null && tb == null) return 0;
      if (ta == null) return 1;
      if (tb == null) return -1;
      return tb.compareTo(ta);
    });

    docs = docs.where((doc) {
      final d = doc.data();
      final members = List<String>.from(d['members'] ?? const []);
      final otherUid = members.firstWhere((m) => m != uid, orElse: () => uid);

      final Map<String, dynamic>? pMap =
          (d['last_activity_preview_by_user'] as Map?)?.map(
        (k, v) => MapEntry<String, dynamic>(k.toString(), v),
      );
      final String? personal = pMap != null ? (pMap[uid] as String?) : null;
      final String shared = (d['last_message_text'] as String?) ?? '';
      final previewForSearch = (personal ?? shared).toLowerCase();

      final prof = _profileCache[otherUid];
      final name = ((prof?['name'] ?? "") as String).toLowerCase();

      final rawUnread = d['unread'];
      int myUnread = 0;
      if (rawUnread is Map && rawUnread[uid] is int) {
        myUnread = rawUnread[uid] as int;
      }

      if (_filterIndex == 1 && myUnread <= 0) return false;
      if (_filterIndex == 2 && (d['pinned'] != true)) return false;

      if (_query.isEmpty) return true;
      return name.contains(_query) ||
          previewForSearch.contains(_query) ||
          otherUid.toLowerCase().contains(_query);
    }).toList();

    if (docs.isEmpty) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _EmptyInbox(),
        )
      ];
    }

    return [
      SliverPadding(
        padding: EdgeInsets.fromLTRB(0, 6, 0, _bottomNavHeight + 12),
        sliver: SliverList.builder(
          itemCount: docs.length,
          itemBuilder: (context, index) {
            final doc = docs[index];
            final d = doc.data();
            final chatId = doc.id;
            final members = List<String>.from(d['members'] ?? const []);
            final otherUid =
                members.firstWhere((m) => m != uid, orElse: () => uid);

            _ensureProfile(otherUid);
            final p = _profileCache[otherUid];
            final otherName = (p?['name'] as String? ?? '').trim();
            final imageUrl = (p?['image_url'] as String?) ?? "";
            final genderLabel = (p?['gender'] as String? ?? ""); // ← NEW

            final Map<String, dynamic>? pMap =
                (d['last_activity_preview_by_user'] as Map?)?.map(
              (k, v) => MapEntry<String, dynamic>(k.toString(), v),
            );
            final String? personal =
                pMap != null ? (pMap[uid] as String?) : null;

            final String sharedMsg =
                ((d['last_message_text'] as String?) ?? '').trim();

            final String? lastMsgSender = (d['last_message_sender'] ??
                    d['last_sender'] ??
                    d['last_sender_uid'] ??
                    d['last_message_user_id'] ??
                    d['last_message_from'])
                ?.toString();
            final bool iWasLastMessageSender = lastMsgSender == uid;

            final String displayShared =
                sharedMsg.isNotEmpty ? sharedMsg : 'Message';
            final String preview = iWasLastMessageSender
                ? 'You: $displayShared'
                : ((personal != null && personal.trim().isNotEmpty)
                    ? personal.trim()
                    : displayShared);

            final DateTime? activityAt =
                ((d['last_activity_at'] as Timestamp?) ??
                        (d['last_message_at'] as Timestamp?))
                    ?.toDate();

            final rawUnread = d['unread'];
            int myUnread = 0;
            if (rawUnread is Map && rawUnread[uid] is int) {
              myUnread = rawUnread[uid] as int;
            }

            final isPinned = d['pinned'] == true;
            final hasUnread = myUnread > 0;
            final ready = otherName.isNotEmpty;

            // ---------- get the correct pair match_id ----------
            final String matchIdFromDoc = (d['match_id'] as String?) ?? '';
            final String computedPairId = (uid.compareTo(otherUid) < 0)
                ? '${uid}_$otherUid'
                : '${otherUid}_$uid';
            final String matchId =
                matchIdFromDoc.isNotEmpty ? matchIdFromDoc : computedPairId;

            return ListTile(
              onTap: () => _navigateToConversation(chatId),
              onLongPress: () => _showChatActions(
                context: context,
                chatId: chatId,
                matchId: matchId,
                otherUid: otherUid,
                otherName: otherName,
                isPinned: isPinned,
                hasUnread: hasUnread,
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: SizedBox(
                  width: 56,
                  height: 56,
                  child: imageUrl.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: imageUrl,
                          fit: BoxFit.cover,
                          placeholder: (_, __) => _defaultAvatarImage(),
                          errorWidget: (_, __, ___) => _defaultAvatarImage(),
                          fadeInDuration: const Duration(milliseconds: 120),
                          fadeOutDuration: const Duration(milliseconds: 80),
                        )
                      : _defaultAvatarImage(),
                ),
              ),
              title: Stack(
                alignment: Alignment.centerLeft,
                children: [
                  Positioned.fill(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: AnimatedOpacity(
                        opacity: ready ? 0 : 1,
                        duration: const Duration(milliseconds: 160),
                        curve: Curves.easeOut,
                        child: _skeletonLine(width: 140, height: 16),
                      ),
                    ),
                  ),
                  AnimatedOpacity(
                    opacity: ready ? 1 : 0,
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeOut,
                    // ✅ Name with gender icon inline
                    child: _nameWithGender(
                      name: otherName.isEmpty ? ' ' : otherName,
                      genderLabel: genderLabel,
                      fontSize: 16,
                      iconSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                    Positioned.fill(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: AnimatedOpacity(
                          opacity: ready ? 0 : 1,
                          duration: const Duration(milliseconds: 160),
                          curve: Curves.easeOut,
                          child: _skeletonLine(width: 180, height: 12),
                        ),
                      ),
                    ),
                    AnimatedOpacity(
                      opacity: ready ? 1 : 0,
                      duration: const Duration(milliseconds: 160),
                      curve: Curves.easeOut,
                      child: Text(
                        (preview.isEmpty)
                            ? 'Tap to continue the conversation'
                            : preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color:
                              hasUnread ? Colors.black87 : Colors.grey.shade600,
                          fontWeight:
                              hasUnread ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              trailing: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    activityAt != null ? _fmtTimeSmart(activityAt) : '',
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                  ),
                  if (hasUnread) ...[
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: AppColors.primaryColor,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        myUnread > 9 ? "9+" : "$myUnread",
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    ];
  }

  Widget _buildSearchAndFilters() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        children: [
          TextField(
            onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
            decoration: InputDecoration(
              hintText: "Search conversations",
              prefixIcon: const Icon(Icons.search),
              contentPadding:
                  const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
              filled: true,
              fillColor: Colors.grey.shade100,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _FilterChip(
                  label: "All",
                  active: _filterIndex == 0,
                  onTap: () => setState(() => _filterIndex = 0)),
              const SizedBox(width: 8),
              _FilterChip(
                  label: "Unread",
                  active: _filterIndex == 1,
                  onTap: () => setState(() => _filterIndex = 1)),
              const SizedBox(width: 8),
              _FilterChip(
                  label: "Pinned",
                  active: _filterIndex == 2,
                  onTap: () => setState(() => _filterIndex = 2)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBottomNavBar() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 4,
            offset: const Offset(0, -2),
          )
        ],
      ),
      child: BottomNavigationBar(
        currentIndex: 2,
        backgroundColor: Colors.white,
        elevation: 0,
        type: BottomNavigationBarType.fixed,
        selectedItemColor: AppColors.primaryColor,
        unselectedItemColor: Colors.grey,
        onTap: (i) {
          if (i == 0) _navigateToDiscover();
          if (i == 1) _navigateToMatches();
          if (i == 3) _navigateToProfile();
        },
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.search), label: "Discover"),
          BottomNavigationBarItem(
              icon: Icon(Icons.favorite_border), label: "Matches"),
          BottomNavigationBarItem(
              icon: Icon(Icons.chat_bubble), label: "Messages"),
          BottomNavigationBarItem(
              icon: Icon(Icons.person_outline), label: "Profile"),
        ],
      ),
    );
  }

  void _soon() {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text(kSoonMessage)));
  }

  // Time formatting
  static String _fmtTimeSmart(DateTime dt) {
    final now = DateTime.now();
    final localDt = dt;

    bool sameDay(DateTime a, DateTime b) =>
        a.year == b.year && a.month == b.month && a.day == b.day;

    if (sameDay(localDt, now)) {
      return DateFormat.jm().format(localDt);
    }

    final yesterday = now.subtract(const Duration(days: 1));
    if (sameDay(localDt, yesterday)) {
      return "Yesterday";
    }

    if (now.difference(localDt).inDays < 7) {
      const weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
      return weekdays[localDt.weekday - 1];
    }

    return DateFormat.Md().format(localDt);
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _FilterChip(
      {required this.label, required this.active, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: active ? AppColors.primaryColor : Colors.grey.shade200,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? Colors.white : Colors.grey.shade800,
            fontWeight: FontWeight.w600,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

class _EmptyInbox extends StatelessWidget {
  final VoidCallback? onExplore;
  const _EmptyInbox({this.onExplore});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.chat_bubble_outline,
              color: AppColors.primaryColor, size: 42),
          const SizedBox(height: 16),
          const Text('No conversations yet',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text('Start a conversation from your Matches.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade700)),
          const SizedBox(height: 14),
          if (onExplore != null)
            TextButton.icon(
              onPressed: onExplore,
              icon: const Icon(Icons.info_outline),
              label: const Text("Feature will be added soon!"),
              style:
                  TextButton.styleFrom(foregroundColor: AppColors.primaryColor),
            ),
        ]),
      ),
    );
  }
}

// ⬇️ NEW: skeleton row that matches the real conversation tile layout
class _SkeletonConversationTile extends StatelessWidget {
  const _SkeletonConversationTile();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 0),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: SizedBox(
            width: 56,
            height: 56,
            child: Shimmer(
              child: Container(color: Colors.grey.shade300),
            ),
          ),
        ),
        title: Shimmer(
          child: Container(
            height: 16,
            width: 140,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Shimmer(
            child: Container(
              height: 12,
              width: 180,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ),
        trailing: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Shimmer(
              child: Container(
                height: 12,
                width: 44,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
            // keep space where the unread pill might appear
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;
  const _ActionTile(
      {required this.icon,
      required this.label,
      required this.onTap,
      this.danger = false});
  @override
  Widget build(BuildContext context) {
    final color = danger ? Colors.red : Colors.black87;
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(label,
          style: TextStyle(color: color, fontWeight: FontWeight.w600)),
      onTap: onTap,
    );
  }
}
