// lib/screens/notifications/notifications_screen.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';

import '../../models/app_notification.dart';
import '../../repositories/notifications_repository.dart';
import '../../utils/constants.dart';
import '../../utils/api_client.dart';

import '../discover/discover_screen.dart';
import '../messages/messages_screen.dart';
import '../messages/conversation_screen.dart';
import '../matches/matches_screen.dart';
import '../profile/profile_screen.dart';
import '../results/profile_verification_screen.dart';
import '../settings/settings_screen.dart';

// ⬇️ Same pull-to-refresh control used in Messages
import '../../widgets/themed_refresh.dart';

// ⬇️ Shared shimmer (same component used by Messages)
import '../../widgets/shimmer.dart';

/// Toggle to print extra troubleshooting logs for avatars and payloads.
const bool kNotifAvatarDebug = true;

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});
  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen>
    with TickerProviderStateMixin {
  // Tabs: All, Messages, Matches (includes Likes/Likebacks), Verification
  static const _kTabs = ['All', 'Messages', 'Matches', 'Verification'];

  late final TabController _tab;
  final _repo = NotificationsRepository();

  // Cache first names & avatars (mirrors Messages behavior)
  final Map<String, String> _firstNameCache = {};
  final Map<String, String> _avatarCache = {};

  // Cache chatId -> otherUid to avoid repeated lookups
  final Map<String, String> _chatOtherUidCache = {};

  // Cache notifId -> actorUid for likes/likebacks/matches
  final Map<String, String> _notifActorCache = {};

  // 🔹 Locally “disabled as read” (swiped or tapped) this session
  final Set<String> _disabledIds = <String>{};

  // Pull-to-refresh state (mirrors Messages behavior)
  bool _isRefreshing = false;

  // Skeleton gate (same pattern as Messages to avoid flicker)
  bool _allowSkeleton = false;
  Timer? _skeletonGate;

  // 🔹 Speed-dial FAB (driven by controller; no setState rebuilds)
  late final AnimationController _fabCtrl;
  late final Animation<double> _fade;
  late final Animation<double> _scale;
  late final Animation<Offset> _slide1;
  late final Animation<Offset> _slide2;
  late final Animation<double> _turns;

  bool get _isFabOpen =>
      _fabCtrl.status != AnimationStatus.dismissed && _fabCtrl.value > 0.001;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: _kTabs.length, vsync: this);
    _tab.addListener(() {
      if (!_tab.indexIsChanging && mounted) setState(() {});
    });

    // Show skeleton if loading exceeds 120ms (matches Messages)
    _skeletonGate = Timer(const Duration(milliseconds: 120), () {
      if (mounted) setState(() => _allowSkeleton = true);
    });

    // FAB animations
    _fabCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );

    final curve = CurvedAnimation(parent: _fabCtrl, curve: Curves.easeOutCubic);
    _fade = CurvedAnimation(parent: _fabCtrl, curve: Curves.easeOut);
    _scale = Tween<double>(begin: 0.92, end: 1.0).animate(curve);

    // Stagger the children so they slide up one after the other a hair
    _slide1 = Tween<Offset>(begin: const Offset(0, 0.25), end: Offset.zero)
        .animate(CurvedAnimation(
            parent: _fabCtrl,
            curve: const Interval(0.0, 0.8, curve: Curves.easeOutCubic)));
    _slide2 = Tween<Offset>(begin: const Offset(0, 0.40), end: Offset.zero)
        .animate(CurvedAnimation(
            parent: _fabCtrl,
            curve: const Interval(0.15, 1.0, curve: Curves.easeOutCubic)));

    _turns = Tween<double>(begin: 0.0, end: 0.5) // 0.5 turn = 180°
        .animate(CurvedAnimation(parent: _fabCtrl, curve: Curves.easeOutCubic));
  }

  @override
  void dispose() {
    _tab.dispose();
    _fabCtrl.dispose();
    _skeletonGate?.cancel();
    super.dispose();
  }

  void _toggleFabOpen() {
    HapticFeedback.selectionClick();
    if (_isFabOpen) {
      _fabCtrl.reverse();
    } else {
      _fabCtrl.forward();
    }
  }

  // ===== Helpers for actor, name & avatar resolving =====
  String? _actorUidFor(AppNotification n) {
    final data = n.data;
    const keys = [
      'other_uid',
      'from_uid',
      'sender_uid',
      'liker_uid',
      'matched_uid',
      'user_uid',
      'uid',
      'senderId',
      'sender_id',
      'from',
      'otherUid',
    ];
    for (final k in keys) {
      final v = data[k]?.toString();
      if (v != null && v.isNotEmpty) return v;
    }
    if (kNotifAvatarDebug) {
      debugPrint(
          '[NOTIF][actorUidFor] no actor uid. id=${n.id} data=${n.data}');
    }
    return null;
  }

  String _extractFirstName(Map<String, dynamic> m) {
    String pick(dynamic x) => (x ?? '').toString().trim();
    final candidates = [
      pick(m['first_name']),
      pick(m['firstName']),
      pick(m['name']),
      pick(m['display_name']),
    ].where((e) => e.isNotEmpty).toList();

    if (candidates.isEmpty) return '';
    final raw = candidates.first;
    return raw.split(' ').first.trim();
  }

  // Try Firestore first (personal_info), then fallback to ApiClient
  Future<void> _ensureFirstName(String uid) async {
    if (_firstNameCache.containsKey(uid)) return;

    Future<bool> tryDoc(DocumentReference ref, {String? debugLabel}) async {
      final snap = await ref.get(const GetOptions(source: Source.server));
      final data = snap.data() as Map<String, dynamic>?;
      if (data == null) return false;
      final first = _extractFirstName(data);
      if (first.isNotEmpty) {
        if (!mounted) return true;
        setState(() => _firstNameCache[uid] = first);
        if (kNotifAvatarDebug) {
          debugPrint(
              '[NOTIF][firstName][FS] $uid via ${debugLabel ?? ref.path} -> "$first"');
        }
        return true;
      }
      return false;
    }

    try {
      final fs = FirebaseFirestore.instance;
      if (await tryDoc(fs.doc('personal_info/$uid'),
          debugLabel: 'personal_info/$uid')) return;
      if (await tryDoc(fs.doc('users/$uid/personal_info/profile'),
          debugLabel: 'users/$uid/personal_info/profile')) return;
      if (await tryDoc(fs.doc('users/$uid/personal_info/personal_info'),
          debugLabel: 'users/$uid/personal_info/personal_info')) return;
      if (await tryDoc(fs.doc('users/$uid'), debugLabel: 'users/$uid')) return;

      // Fallback to API
      try {
        final p = await ApiClient.getJson("/profile/$uid");
        final first = _extractFirstName(p);
        if (!mounted) return;
        setState(() => _firstNameCache[uid] = first);
        if (kNotifAvatarDebug) {
          debugPrint('[NOTIF][firstName][API] $uid -> "$first"');
        }
      } catch (e) {
        if (kNotifAvatarDebug) {
          debugPrint('[NOTIF][firstName][API][ERROR] $uid -> $e');
        }
        if (!mounted) return;
        setState(() => _firstNameCache[uid] = '');
      }
    } catch (e) {
      if (kNotifAvatarDebug) {
        debugPrint('[NOTIF][firstName][FS][ERROR] $uid -> $e');
      }
      try {
        final p = await ApiClient.getJson("/profile/$uid");
        final first = _extractFirstName(p);
        if (!mounted) return;
        setState(() => _firstNameCache[uid] = first);
        if (kNotifAvatarDebug) {
          debugPrint('[NOTIF][firstName][API] $uid -> "$first"');
        }
      } catch (e2) {
        if (kNotifAvatarDebug) {
          debugPrint('[NOTIF][firstName][API][ERROR] $uid -> $e2');
        }
        if (!mounted) return;
        setState(() => _firstNameCache[uid] = '');
      }
    }
  }

  Future<void> _ensureAvatarUrl(String uid) async {
    if (_avatarCache.containsKey(uid)) return;
    try {
      final p = await ApiClient.getJson("/profile/$uid");
      final url =
          (p['profile_image_url'] ?? p['image_url'] ?? '').toString().trim();
      if (kNotifAvatarDebug) debugPrint('[NOTIF][avatar] $uid -> "$url"');
      if (!mounted) return;
      setState(() => _avatarCache[uid] = url);
    } catch (e) {
      if (kNotifAvatarDebug) debugPrint('[NOTIF][avatar][ERROR] $uid -> $e');
      if (!mounted) return;
      setState(() => _avatarCache[uid] = '');
    }
  }

  Future<void> _resolveActorUidFromChat(String chatId) async {
    if (_chatOtherUidCache.containsKey(chatId)) return;
    try {
      final doc = await FirebaseFirestore.instance
          .doc('chats/$chatId')
          .get(const GetOptions(source: Source.server));
      final data = doc.data() as Map<String, dynamic>?;
      if (data == null) return;

      final me = FirebaseAuth.instance.currentUser?.uid;
      final members = List<String>.from(data['members'] ?? const <String>[]);
      if (me == null || members.isEmpty) return;

      final other = members.firstWhere((m) => m != me, orElse: () => '');
      if (other.isEmpty) return;

      _chatOtherUidCache[chatId] = other;

      await Future.wait([_ensureAvatarUrl(other), _ensureFirstName(other)]);
      if (mounted) setState(() {});
    } catch (e) {
      if (kNotifAvatarDebug) {
        debugPrint('[NOTIF][resolve][ERROR] chat=$chatId -> $e');
      }
    }
  }

  Future<void> _resolveActorUidForLike(AppNotification n) async {
    if (_notifActorCache.containsKey(n.id)) return;

    try {
      final me = FirebaseAuth.instance.currentUser?.uid;

      // 1) matchId -> matches/{matchId}
      final matchId = (n.data['matchId'] ?? n.data['match_id'])?.toString();
      if (matchId != null && matchId.isNotEmpty) {
        final doc = await FirebaseFirestore.instance
            .doc('matches/$matchId')
            .get(const GetOptions(source: Source.server));
        final data = doc.data() as Map<String, dynamic>?;

        String? other;
        if (data != null) {
          final lists = [
            (data['members'] as List?)?.map((e) => e.toString()).toList(),
            (data['userIds'] as List?)?.map((e) => e.toString()).toList(),
            (data['users'] as List?)?.map((e) => e.toString()).toList(),
          ].whereType<List<String>>().toList();

          for (final l in lists) {
            if (l.isNotEmpty && me != null) {
              final o = l.firstWhere((m) => m != me, orElse: () => '');
              if (o.isNotEmpty) {
                other = o;
                break;
              }
            }
          }

          if (other == null && me != null) {
            final candidates = [
              data['user1'],
              data['user2'],
              data['uid1'],
              data['uid2'],
              data['a'],
              data['b'],
            ]
                .map((e) => e?.toString())
                .where((e) => e != null && e!.isNotEmpty)
                .cast<String>()
                .toList();
            for (final c in candidates) {
              if (c != me) {
                other = c;
                break;
              }
            }
          }
        }

        if ((other ?? '').isNotEmpty) {
          _notifActorCache[n.id] = other!;
          await Future.wait(
              [_ensureAvatarUrl(other!), _ensureFirstName(other!)]);
          if (mounted) setState(() {});
          return;
        }
      }

      // 2) chatId -> chats/{chatId}
      final chatId = (n.data['chatId'] ?? n.data['chat_id'])?.toString();
      if (chatId != null && chatId.isNotEmpty) {
        await _resolveActorUidFromChat(chatId);
        final other = _chatOtherUidCache[chatId];
        if ((other ?? '').isNotEmpty) {
          _notifActorCache[n.id] = other!;
          await Future.wait([_ensureAvatarUrl(other), _ensureFirstName(other)]);
          if (mounted) setState(() {});
          return;
        }
      }

      // 3) likes/{likeId} (legacy fallback)
      final likeId = (n.data['likeId'] ?? n.data['id'] ?? n.id).toString();
      try {
        final doc = await FirebaseFirestore.instance
            .doc('likes/$likeId')
            .get(const GetOptions(source: Source.server));
        final data = doc.data() as Map<String, dynamic>?;
        final other = (data?['liker_uid'] ??
                data?['from_uid'] ??
                data?['uid'] ??
                data?['from'])
            ?.toString();

        if ((other ?? '').isNotEmpty) {
          _notifActorCache[n.id] = other!;
          await Future.wait([_ensureAvatarUrl(other), _ensureFirstName(other)]);
          if (mounted) setState(() {});
          return;
        }
      } catch (_) {}
    } catch (e) {
      if (kNotifAvatarDebug) {
        debugPrint('[NOTIF][like.resolve][ERROR] ${n.id} -> $e');
      }
    }
  }

  // ===== Bulk/row actions =====

  Future<void> _markAllAsRead() async {
    // tiny haptic like the other screen
    HapticFeedback.selectionClick();

    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;

      final col = FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('notifications');

      // 🔹 If nothing is unread, just show a message and bail out.
      final anyUnread =
          await col.where('read', isEqualTo: false).limit(1).get();
      if (anyUnread.docs.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text("You're all caught up — nothing to mark as read.")),
        );
        return;
      }

      // 🔹 Batch update unread -> read, in chunks
      int updated = 0;
      const batchSize = 400;
      while (true) {
        final qs =
            await col.where('read', isEqualTo: false).limit(batchSize).get();
        if (qs.docs.isEmpty) break;

        final batch = FirebaseFirestore.instance.batch();
        for (final d in qs.docs) {
          batch.update(d.reference, {'read': true});
        }
        await batch.commit();

        updated += qs.docs.length;

        if (mounted) {
          setState(() {
            for (final d in qs.docs) {
              _disabledIds.add(d.id); // reflect locally
            }
          });
        }

        if (qs.docs.length < batchSize) break;
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  "Marked $updated notification${updated == 1 ? '' : 's'} as read.")),
        );
      }
    } catch (e) {
      debugPrint('[NOTIF] markAllAsRead error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to mark all as read')),
        );
      }
    }
  }

  Future<void> _deleteNotification(String id) async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;
      final ref = FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('notifications')
          .doc(id);
      await ref.delete();
      if (mounted) {
        setState(() {
          _disabledIds.remove(id);
        });
      }
    } catch (e) {
      debugPrint('[NOTIF] delete error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to delete notification')),
        );
      }
    }
  }

  Future<void> _clearAllNotifications() async {
    // tiny haptic like the other screen
    HapticFeedback.selectionClick();

    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;

      final col = FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('notifications');

      // 🔹 If there are no notifications, just show a message and bail out.
      final any = await col.limit(1).get();
      if (any.docs.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text("You're all caught up — nothing to clear.")),
        );
        return;
      }

      // Otherwise, confirm with the user
      final ok = await showModalBottomSheet<bool>(
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
                          color: Colors.redAccent.withOpacity(.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.delete_forever,
                            color: Colors.redAccent),
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          "Clear all notifications?",
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    "This will permanently delete all your notifications. You can’t undo this.",
                    style:
                        TextStyle(color: Colors.grey.shade700, fontSize: 13.5),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text("Cancel"),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.redAccent,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text("Clear all"),
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

      if (ok != true) return;

      // 🔹 Perform batched delete, counting how many we remove
      int deleted = 0;
      const batchSize = 400;
      while (true) {
        final snap = await col.limit(batchSize).get();
        if (snap.docs.isEmpty) break;

        final batch = FirebaseFirestore.instance.batch();
        for (final d in snap.docs) {
          batch.delete(d.reference);
        }
        await batch.commit();
        deleted += snap.docs.length;

        if (snap.docs.length < batchSize) break;
      }

      if (mounted) {
        setState(() => _disabledIds.clear());
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  "Cleared $deleted notification${deleted == 1 ? '' : 's'}.")),
        );
      }
    } catch (e) {
      debugPrint('[NOTIF] clearAll error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to clear notifications')),
        );
      }
    }
  }

  // ===== Bottom nav (copied style) =====
  Widget _bottomNav() {
    return SafeArea(
      top: false,
      bottom: true,
      child: BottomNavigationBar(
        currentIndex: 0,
        backgroundColor: Colors.white,
        elevation: 0,
        type: BottomNavigationBarType.fixed,
        selectedItemColor: Colors.grey,
        unselectedItemColor: Colors.grey,
        onTap: (i) {
          if (i == 0) {
            Navigator.pushReplacement(
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
          }
          if (i == 1) {
            Navigator.pushReplacement(
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
          }
          if (i == 2) {
            Navigator.pushReplacement(
              context,
              PageRouteBuilder(
                pageBuilder: (_, __, ___) => const MessagesScreen(),
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
          }
          if (i == 3) {
            Navigator.push(
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
              ),
            );
          }
        },
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.search), label: "Discover"),
          BottomNavigationBarItem(
              icon: Icon(Icons.favorite_border), label: "Matches"),
          BottomNavigationBarItem(
              icon: Icon(Icons.chat_bubble_outline), label: "Messages"),
          BottomNavigationBarItem(
              icon: Icon(Icons.person_outline), label: "Profile"),
        ],
      ),
    );
  }

  // ===== AppBar (matches other screens) =====
  AppBar _buildAppBar() {
    return AppBar(
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
      elevation: 4,
      shadowColor: Colors.black.withOpacity(0.1),
      titleSpacing: 0,
      title: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            // ⬇️ Make the left group flexible so the right icons never force overflow
            Expanded(
              child: Row(
                children: [
                  // Brand
                  Flexible(
                    flex: 0,
                    child: Text(
                      "AttachMates",
                      overflow: TextOverflow.fade,
                      softWrap: false,
                      style: GoogleFonts.indieFlower(
                        textStyle: TextStyle(
                          color: AppColors.primaryColor,
                          fontSize: 26,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  // Section label can ellipsis if space is tight
                  Flexible(
                    child: Text(
                      "Notifications",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.grey.shade600,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Right icons keep their normal size; they no longer push overflow
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Notifications',
                  onPressed: () {}, // already here
                  icon:
                      Icon(Icons.notifications, color: AppColors.primaryColor),
                ),
                IconButton(
                  tooltip: 'Settings',
                  onPressed: () => Navigator.push(
                    context,
                    PageRouteBuilder(
                      pageBuilder: (_, __, ___) => const SettingsScreen(),
                      transitionsBuilder: (_, a, __, child) => SlideTransition(
                        position: a.drive(
                            Tween(begin: const Offset(1, 0), end: Offset.zero)
                                .chain(CurveTween(curve: Curves.easeInOut))),
                        child: child,
                      ),
                      transitionDuration: const Duration(milliseconds: 300),
                    ),
                  ),
                  icon: Icon(Icons.settings, color: AppColors.primaryColor),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onRefresh() async {
    if (_isRefreshing) return;
    setState(() => _isRefreshing = true);
    try {
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      setState(() {}); // just re-build; streams will emit
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  // Effective read = server read OR locally disabled (swiped/tapped)
  bool _isRead(AppNotification n) => n.read || _disabledIds.contains(n.id);

  @override
  Widget build(BuildContext context) {
    // We wrap the scroll view in a Stack so we can overlay our speed-dial buttons
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: _buildAppBar(),
      body: Stack(
        children: [
          StreamBuilder<List<AppNotification>>(
            stream: _repo.streamAll(limit: 200),
            builder: (context, snap) {
              final items = (snap.data ?? const <AppNotification>[]).toList();

              // Counts per category (Likes are merged into Matches) using effective read
              final unreadAll = items.where((n) => !_isRead(n)).length;
              final msgCount = items
                  .where((n) => n.type == AppNotifType.message && !_isRead(n))
                  .length;
              final matchCount = items
                  .where((n) =>
                      (n.type == AppNotifType.match ||
                          n.type == AppNotifType.like ||
                          n.type == AppNotifType.likeback) &&
                      !_isRead(n))
                  .length;
              final verCount = items
                  .where(
                      (n) => n.type == AppNotifType.verification && !_isRead(n))
                  .length;

              List<AppNotification> _filterByTab(int i) {
                switch (i) {
                  case 1:
                    return items
                        .where((n) => n.type == AppNotifType.message)
                        .toList();
                  case 2:
                    return items
                        .where((n) =>
                            n.type == AppNotifType.match ||
                            n.type == AppNotifType.like ||
                            n.type == AppNotifType.likeback)
                        .toList();
                  case 3:
                    return items
                        .where((n) => n.type == AppNotifType.verification)
                        .toList();
                  default:
                    return items;
                }
              }

              const labelAll = 'All';
              const labelMsg = 'Messages';
              const labelMatches = 'Matches';
              const labelVer = 'Verification';

              final currentList = _filterByTab(_tab.index);

              final isWaiting =
                  snap.connectionState == ConnectionState.waiting &&
                      items.isEmpty;

              return CustomScrollView(
                physics: const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics(),
                ),
                slivers: [
                  // Pull to refresh (from Messages)
                  ThemedSliverRefreshControl(
                    onRefresh: _onRefresh,
                    color: AppColors.primaryColor,
                    indicatorExtent: 60.0,
                    fadeOutWhenCollapsed: true,
                  ),

                  // Tabs with small-circle badges
                  SliverToBoxAdapter(
                    child: Container(
                      color: Colors.white,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: _SlidingCapsuleTabs4(
                        controller: _tab,
                        labels: const [
                          labelAll,
                          labelMsg,
                          labelMatches,
                          labelVer
                        ],
                        badges: [unreadAll, msgCount, matchCount, verCount],
                        onTapIndex: (i) => _tab.animateTo(
                          i,
                          duration: const Duration(milliseconds: 420),
                          curve: Curves.easeOutCubic,
                        ),
                      ),
                    ),
                  ),

                  // ===== Content for current tab =====
                  if (isWaiting && !_allowSkeleton)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: SizedBox.shrink(),
                    )
                  else if (isWaiting && _allowSkeleton)
                    // ⬇️ Skeleton list that matches the real row spacing/shape
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(0, 6, 0, 24),
                      sliver: SliverList.builder(
                        itemCount: 8,
                        itemBuilder: (_, __) => const RepaintBoundary(
                          child: _SkeletonNotifTile(),
                        ),
                      ),
                    )
                  else if (currentList.isEmpty)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: RepaintBoundary(
                        child: _Empty(),
                      ),
                    )
                  else
                    SliverList.separated(
                      itemCount: currentList.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (_, idx) {
                        final n = currentList[idx];
                        final isRead = _isRead(n);

                        // === AVATAR & NAME HANDLING ===
                        String? avatarUrl = '';
                        String? uid = _actorUidFor(n);

                        if (n.type == AppNotifType.message) {
                          if (uid == null) {
                            final chatId =
                                (n.data['chatId'] ?? n.data['chat_id'])
                                    ?.toString();
                            if (chatId != null && chatId.isNotEmpty) {
                              uid = _chatOtherUidCache[chatId];
                              if (uid == null) {
                                _resolveActorUidFromChat(chatId); // async
                              }
                            }
                          }
                        } else if (n.type == AppNotifType.like ||
                            n.type == AppNotifType.likeback ||
                            n.type == AppNotifType.match) {
                          if (uid == null) {
                            uid = _notifActorCache[n.id];
                            if (uid == null) {
                              _resolveActorUidForLike(n); // async
                            }
                          }
                        }

                        if (uid != null) {
                          _ensureAvatarUrl(uid); // async cache
                          _ensureFirstName(uid); // async cache
                          avatarUrl = (_avatarCache[uid] ?? '').toString();
                        }

                        final firstName =
                            uid != null ? _firstNameCache[uid] ?? '' : '';

                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Dismissible(
                            key: ValueKey(n.id),

                            // Allow both swipe directions
                            direction: DismissDirection.horizontal,

                            // → Swipe right (startToEnd) = Delete
                            background: _swipeBg(
                              Colors.redAccent,
                              Icons.delete,
                              'Delete',
                              alignRight: false,
                            ),

                            // ← Swipe left (endToStart) = Mark read (disabled if already read)
                            secondaryBackground: isRead
                                ? _swipeBgDisabled(Icons.done, 'Already read',
                                    alignRight: true)
                                : _swipeBg(
                                    Colors.green,
                                    Icons.done,
                                    'Mark read',
                                    alignRight: true,
                                  ),

                            confirmDismiss: (dir) async {
                              final isUnread =
                                  !n.read && !_disabledIds.contains(n.id);

                              if (dir == DismissDirection.startToEnd) {
                                // → Delete
                                await _deleteNotification(n.id);
                                return true; // remove tile
                              } else if (dir == DismissDirection.endToStart) {
                                // ← Mark as read (only if unread)
                                if (isUnread) {
                                  await _repo.markRead(n.id);
                                  setState(() => _disabledIds.add(n.id));
                                }
                                return false; // keep tile in place
                              }
                              return false;
                            },

                            child: _NotifTile(
                              notif: n,
                              firstName: firstName,
                              avatarUrlForMessage: avatarUrl,
                              asRead:
                                  isRead, // render as read when disabled/marked
                              onTap: () async {
                                // Open deep link, then mark read if needed
                                await _handleDeepLink(n);
                                if (!n.read) {
                                  await _repo.markRead(n.id);
                                  if (mounted) {
                                    setState(() => _disabledIds.add(n.id));
                                  }
                                }
                              },
                            ),
                          ),
                        );
                      },
                    ),
                  const SliverToBoxAdapter(child: SizedBox(height: 24)),
                ],
              );
            },
          ),

          // ======= FAB overlay (backdrop + speed-dial) driven by controller only =======
          AnimatedBuilder(
            animation: _fabCtrl,
            builder: (context, _) {
              final open = _isFabOpen;
              return IgnorePointer(
                ignoring: !open,
                child: Stack(
                  children: [
                    if (open)
                      Positioned.fill(
                        child: GestureDetector(
                          onTap: _toggleFabOpen,
                          child: FadeTransition(
                            opacity: _fade,
                            child: Container(color: Colors.transparent),
                          ),
                        ),
                      ),
                    if (open)
                      Positioned(
                        right: 16,
                        bottom: 88, // sits above the bottom nav
                        child: FadeTransition(
                          opacity: _fade,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              SlideTransition(
                                position: _slide1,
                                child: ScaleTransition(
                                  scale: _scale,
                                  child: _FabChildButton(
                                    big: true,
                                    label: 'Mark all as read',
                                    icon: Icons.done_all,
                                    color: Colors.green,
                                    onTap: () async {
                                      _toggleFabOpen();
                                      await _markAllAsRead();
                                    },
                                  ),
                                ),
                              ),
                              const SizedBox(height: 14),
                              SlideTransition(
                                position: _slide2,
                                child: ScaleTransition(
                                  scale: _scale,
                                  child: _FabChildButton(
                                    big: true,
                                    label: 'Clear all',
                                    icon: Icons.delete,
                                    color: Colors.redAccent,
                                    onTap: () async {
                                      _toggleFabOpen();
                                      await _clearAllNotifications();
                                    },
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ],
      ),

      // Main FAB (toggles the speed-dial) — icon reacts to controller only
      floatingActionButton: FloatingActionButton(
        backgroundColor: AppColors.primaryColor,
        onPressed: _toggleFabOpen,
        child: AnimatedBuilder(
          animation: _fabCtrl,
          builder: (context, _) {
            final open = _isFabOpen;
            return RotationTransition(
              turns: _turns,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 160),
                transitionBuilder: (child, anim) =>
                    FadeTransition(opacity: anim, child: child),
                child: SizedBox.square(
                  key: ValueKey(open),
                  dimension: 32, // fixed box prevents layout shifts
                  child: Center(
                    child: Icon(
                      open ? Icons.close : Icons.add,
                      color: Colors.white,
                      size: open ? 28 : 32, // add is a touch larger
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),

      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,

      bottomNavigationBar: _bottomNav(),
    );
  }

  // ===== Deep links =====
  Future<void> _handleDeepLink(AppNotification n) async {
    switch (n.type) {
      case AppNotifType.message:
        {
          final chatId = (n.data['chatId'] ?? n.data['chat_id'])?.toString();
          if (chatId != null && chatId.isNotEmpty) {
            if (!mounted) return;
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ConversationScreen(chatId: chatId),
              ),
            );
          }
          break;
        }
      case AppNotifType.match:
      case AppNotifType.like:
      case AppNotifType.likeback:
        {
          if (!mounted) return;
          await Navigator.push(
            context,
            PageRouteBuilder(
              pageBuilder: (_, __, ___) => const MatchesScreen(initialTab: 1),
              transitionsBuilder: (_, animation, __, child) => SlideTransition(
                position: animation.drive(
                  Tween(begin: const Offset(1, 0), end: Offset.zero)
                      .chain(CurveTween(curve: Curves.easeInOut)),
                ),
                child: child,
              ),
              transitionDuration: const Duration(milliseconds: 300),
            ),
          );
          break;
        }
      case AppNotifType.verification:
        {
          final status = (n.data['status'] ?? '').toString().toLowerCase();
          if (!mounted) return;
          if (status == 'rejected') {
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    const ProfileVerificationScreen(status: 'rejected'),
              ),
            );
          } else if (status == 'approved') {
            await Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            );
          } else {
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    const ProfileVerificationScreen(status: 'pending'),
              ),
            );
          }
          break;
        }
      case AppNotifType.unknown:
        break;
    }
  }

  // ===== UI bits =====
  Widget _swipeBg(Color c, IconData icon, String label,
          {bool alignRight = false}) =>
      Container(
        decoration: BoxDecoration(
          color: c.withOpacity(.10),
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
        child: Row(
          mainAxisAlignment:
              alignRight ? MainAxisAlignment.end : MainAxisAlignment.start,
          children: alignRight
              ? [
                  Text(label,
                      style: TextStyle(color: c, fontWeight: FontWeight.w700)),
                  const SizedBox(width: 8),
                  Icon(icon, color: c),
                ]
              : [
                  Icon(icon, color: c),
                  const SizedBox(width: 8),
                  Text(label,
                      style: TextStyle(color: c, fontWeight: FontWeight.w700)),
                ],
        ),
      );

  Widget _swipeBgDisabled(IconData icon, String label,
          {bool alignRight = false}) =>
      Container(
        decoration: BoxDecoration(
          color: Colors.grey.withOpacity(.10),
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
        child: Row(
          mainAxisAlignment:
              alignRight ? MainAxisAlignment.end : MainAxisAlignment.start,
          children: alignRight
              ? [
                  Text(label,
                      style: const TextStyle(
                          color: Colors.grey, fontWeight: FontWeight.w700)),
                  const SizedBox(width: 8),
                  Icon(icon, color: Colors.grey),
                ]
              : [
                  Icon(icon, color: Colors.grey),
                  const SizedBox(width: 8),
                  Text(label,
                      style: const TextStyle(
                          color: Colors.grey, fontWeight: FontWeight.w700)),
                ],
        ),
      );
}

// === Small helper widget for speed-dial mini buttons ===
class _FabChildButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final bool big;

  const _FabChildButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
    this.big = false,
  });

  @override
  Widget build(BuildContext context) {
    final padV = big ? 12.0 : 10.0;
    final padH = big ? 14.0 : 12.0;
    final iconSize = big ? 22.0 : 20.0;
    final fontSize = big ? 14.0 : 13.0;
    return Material(
      color: Colors.white,
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: padH, vertical: padV),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: iconSize),
              const SizedBox(width: 12),
              Text(label,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: fontSize,
                  )),
            ],
          ),
        ),
      ),
    );
  }
}

// === Tile that behaves like Messages: shimmer -> direct to final text (no interim) ===
class _NotifTile extends StatelessWidget {
  final AppNotification notif;
  final String? firstName;

  /// Used for message, like, likeback
  final String? avatarUrlForMessage;

  /// Null onTap disables the tile (read/disabled state)
  final VoidCallback? onTap;

  /// Force render as read (used when locally disabled)
  final bool asRead;

  /// Kept for API compatibility; not used to gate title/subtitle anymore.
  final bool isLoading;

  const _NotifTile({
    required this.notif,
    this.firstName,
    this.avatarUrlForMessage,
    this.onTap,
    this.asRead = false,
    this.isLoading = false,
  });

  IconData _icon(AppNotifType t) {
    switch (t) {
      case AppNotifType.message:
        return Icons.chat_bubble_outline;
      case AppNotifType.match:
        return Icons.favorite;
      case AppNotifType.like:
        return Icons.thumb_up_alt_outlined;
      case AppNotifType.likeback:
        return Icons.repeat;
      case AppNotifType.verification:
        return Icons.verified_user_outlined;
      case AppNotifType.unknown:
        return Icons.notifications;
    }
  }

  String _compactAgo(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inSeconds < 60) return '${diff.inSeconds}s';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    final weeks = (diff.inDays / 7).floor();
    if (weeks < 5) return '${weeks}w';
    final months = (diff.inDays / 30).floor();
    if (months < 12) return '${months}mo';
    final years = (diff.inDays / 365).floor();
    return '${years}y';
  }

  Widget _avatarStack(String url, {IconData? overlay}) {
    final image = CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      placeholder: (_, __) =>
          Image.asset('assets/default_pfp.png', fit: BoxFit.cover),
      errorWidget: (_, __, ___) =>
          Image.asset('assets/default_pfp.png', fit: BoxFit.cover),
      fadeInDuration: const Duration(milliseconds: 120),
      fadeOutDuration: const Duration(milliseconds: 80),
    );

    if (overlay == null) return image;

    return Stack(
      children: [
        Positioned.fill(child: image),
        Positioned(
          right: 0,
          bottom: 0,
          child: Container(
            width: 18,
            height: 18,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
            child: Icon(overlay, size: 14, color: AppColors.primaryColor),
          ),
        ),
      ],
    );
  }

  Widget _shimmerLine(double w, double h, {double r = 4}) {
    return Shimmer(
      child: Container(
        width: w,
        height: h,
        decoration: BoxDecoration(
          color: Colors.grey.shade300,
          borderRadius: BorderRadius.circular(r),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rawBody = (notif.body ?? '').trim();
    final ts = notif.createdAt;

    final name = (firstName ?? '').trim();

    // For person-based notifs, wait for the name before revealing text.
    final wantsName = notif.type == AppNotifType.message ||
        notif.type == AppNotifType.like ||
        notif.type == AppNotifType.likeback ||
        notif.type == AppNotifType.match;

    final ready = wantsName ? name.isNotEmpty : true;

    // === Leading widget === (show avatar for message + like + likeback)
    final showPfp = notif.type == AppNotifType.message ||
        notif.type == AppNotifType.like ||
        notif.type == AppNotifType.likeback;

    final isRead = asRead || notif.read;

    Widget leading;
    if (showPfp) {
      final url = (avatarUrlForMessage ?? '').trim();
      final overlayIcon = notif.type == AppNotifType.like
          ? Icons.thumb_up_alt
          : (notif.type == AppNotifType.likeback ? Icons.repeat : null);

      leading = ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: SizedBox(
          width: 40,
          height: 40,
          child: url.isNotEmpty
              ? _avatarStack(url, overlay: overlayIcon)
              : Stack(
                  children: [
                    Positioned.fill(
                      child: Image.asset('assets/default_pfp.png',
                          fit: BoxFit.cover),
                    ),
                    if (overlayIcon != null)
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          width: 18,
                          height: 18,
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            overlayIcon,
                            size: 14,
                            color: AppColors.primaryColor,
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      );
    } else {
      leading = CircleAvatar(
        backgroundColor: isRead
            ? Colors.grey.shade200
            : AppColors.primaryColor.withOpacity(.12),
        child: Icon(
          _icon(notif.type),
          color: isRead ? Colors.grey : AppColors.primaryColor,
        ),
      );
    }

    // Compose final title/body (only used when ready)
    String title;
    String body;

    if (notif.type == AppNotifType.message) {
      if (rawBody.startsWith('[Heart]')) {
        title = '$name sent you a heart';
        body = 'Tap to view';
      } else if (rawBody.startsWith('[Photo]')) {
        title = '$name sent a photo';
        body = 'Tap to view';
      } else if (rawBody.startsWith('[Audio]')) {
        title = '$name sent a voice message';
        body = 'Tap to listen';
      } else {
        title = '$name messaged you';
        body = rawBody.isEmpty ? 'Tap to view' : rawBody;
      }
    } else if (notif.type == AppNotifType.like) {
      title = '$name liked you';
      body = 'Tap to view their profile';
    } else if (notif.type == AppNotifType.likeback) {
      title = '$name liked you back';
      body = 'It’s a match! Tap to view';
    } else if (notif.type == AppNotifType.match) {
      title = 'It’s a match with $name!';
      body = 'Tap to open Matches';
    } else if (notif.type == AppNotifType.verification) {
      final status = (notif.data['status'] ?? '').toString().toLowerCase();
      if (status == 'rejected') {
        title = 'Verification rejected';
        body = 'Tap to see details';
      } else if (status == 'approved') {
        title = 'Verification approved';
        body = 'You’re all set';
      } else {
        title = 'Verification update';
        body = 'Tap to view';
      }
    } else {
      title = 'Notification';
      body = rawBody;
    }

    // === Behave like Messages: shimmer -> real content ===
    final titleStack = Stack(
      alignment: Alignment.centerLeft,
      children: [
        AnimatedOpacity(
          opacity: ready ? 0 : 1,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          child: _shimmerLine(160, 16),
        ),
        AnimatedOpacity(
          opacity: ready ? 1 : 0,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          child: Text(
            ready ? title : ' ', // reserve height
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: isRead ? FontWeight.w500 : FontWeight.w700,
            ),
          ),
        ),
      ],
    );

    final subtitleStack = Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          AnimatedOpacity(
            opacity: ready ? 0 : 1,
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            child: _shimmerLine(220, 12),
          ),
          AnimatedOpacity(
            opacity: ready ? 1 : 0,
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            child: (body.isEmpty
                ? const SizedBox.shrink()
                : Text(
                    body,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  )),
          ),
        ],
      ),
    );

    final trailingWidget = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (ts != null)
          Text(
            _compactAgo(ts.toLocal()),
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
        if (!isRead)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Icon(Icons.brightness_1, size: 8, color: Colors.redAccent),
          ),
      ],
    );

    return Material(
      color: isRead ? Colors.white : AppColors.primaryColor.withOpacity(.06),
      borderRadius: BorderRadius.circular(12),
      child: ListTile(
        onTap: onTap, // null => disabled
        enabled: onTap != null, // clarity
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: leading,
        title: titleStack,
        subtitle: subtitleStack,
        trailing: trailingWidget,
      ),
    );
  }
}

// === “Sliding capsule” tabs (4 items) with small-circle badges ===
class _SlidingCapsuleTabs4 extends StatefulWidget {
  final TabController controller;
  final List<String> labels; // length 4
  final List<int>? badges; // optional badge counts per tab
  final void Function(int index) onTapIndex;

  const _SlidingCapsuleTabs4({
    required this.controller,
    required this.labels,
    required this.onTapIndex,
    this.badges,
  });

  @override
  State<_SlidingCapsuleTabs4> createState() => _SlidingCapsuleTabs4State();
}

class _SlidingCapsuleTabs4State extends State<_SlidingCapsuleTabs4> {
  late final VoidCallback _tick;

  double get _rawT {
    final anim = widget.controller.animation;
    if (anim == null) return widget.controller.index.toDouble();
    return (widget.controller.index + widget.controller.offset)
        .clamp(0.0, (widget.labels.length - 1).toDouble());
  }

  @override
  void initState() {
    super.initState();
    _tick = () {
      if (mounted) setState(() {});
    };
    widget.controller.animation?.addListener(_tick);
  }

  @override
  void didUpdateWidget(covariant _SlidingCapsuleTabs4 old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.animation?.removeListener(_tick);
      widget.controller.animation?.addListener(_tick);
    }
  }

  @override
  void dispose() {
    widget.controller.animation?.removeListener(_tick);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primary = AppColors.primaryColor;
    final inactive = Colors.black.withOpacity(.70);
    final t = _rawT; // keep raw 0..3 for positioning

    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 8.0;
        final width = constraints.maxWidth;
        final seg = (width - gap * 3) / 4; // 4 tabs, 3 gaps
        final sliderLeft = t * (seg + gap);
        final pillRadius = BorderRadius.circular(999);
        final badges = widget.badges ?? const [0, 0, 0, 0];

        Color selColor(int i) {
          final dist = (t - i).abs().clamp(0.0, 1.0);
          final sel = 1.0 - dist;
          return Color.lerp(inactive, Colors.white, sel) ?? Colors.white;
        }

        return SizedBox(
          height: 40,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: sliderLeft,
                top: 0,
                width: seg,
                height: 40,
                child: Container(
                  decoration: BoxDecoration(
                    color: primary,
                    borderRadius: pillRadius,
                  ),
                ),
              ),
              Row(
                children: List.generate(4, (i) {
                  final hasBadge = i < badges.length ? badges[i] > 0 : false;
                  return Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(right: i < 3 ? gap : 0),
                      child: Material(
                        type: MaterialType.transparency,
                        child: InkWell(
                          borderRadius: pillRadius,
                          splashColor: Colors.white24,
                          highlightColor: Colors.transparent,
                          onTap: () => widget.onTapIndex(i),
                          child: Center(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                AnimatedDefaultTextStyle(
                                  duration: const Duration(milliseconds: 160),
                                  curve: Curves.easeOutCubic,
                                  style: TextStyle(
                                    color: selColor(i),
                                    fontWeight: (t - i).abs() < 0.5
                                        ? FontWeight.w700
                                        : FontWeight.w600,
                                    fontSize: 13,
                                  ),
                                  child: Text(
                                    widget.labels[i],
                                    textAlign: TextAlign.center,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (hasBadge) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    width: 9,
                                    height: 9,
                                    decoration: BoxDecoration(
                                      color: Colors.redAccent,
                                      shape: BoxShape.circle,
                                      boxShadow: [
                                        BoxShadow(
                                          color:
                                              Colors.redAccent.withOpacity(.45),
                                          blurRadius: 6,
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.notifications, size: 72, color: Colors.black26),
            SizedBox(height: 12),
            Text('No notifications yet',
                style: TextStyle(fontWeight: FontWeight.w700)),
            SizedBox(height: 6),
            Text(
              'You’ll see likes, matches, and messages here.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

// === Skeleton row that matches the real notification tile layout ===
class _SkeletonNotifTile extends StatelessWidget {
  const _SkeletonNotifTile();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: SizedBox(
            width: 40,
            height: 40,
            child: Shimmer(
              child: Container(color: Colors.grey.shade300),
            ),
          ),
        ),
        title: Shimmer(
          child: Container(
            height: 16,
            width: 160,
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
              width: 220,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ),
        trailing: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Shimmer(
              child: Container(
                height: 12,
                width: 32,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
            const SizedBox(height: 6), // space where unread dot might appear
          ],
        ),
      ),
    );
  }
}
