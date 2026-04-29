// lib/screens/discover/discover_screen.dart
import "package:flutter/material.dart";
import "dart:math" as math;
import "dart:convert";
import "dart:async"; // ← NEW: for TimeoutException, timers
import "package:google_fonts/google_fonts.dart";
import "package:firebase_auth/firebase_auth.dart";
import "package:cloud_firestore/cloud_firestore.dart"; // kept for hydration
import 'package:flutter/animation.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/services.dart'; // ← for SystemUiOverlayStyle
import 'package:provider/provider.dart'; // ← NEW

import "../../utils/animations.dart";
import "../../utils/constants.dart";
import "../../utils/api_client.dart";
import "../../utils/api_json.dart"; // ← NEW

import "../matches/matches_screen.dart";
import "../messages/messages_screen.dart";
import "../profile/profile_screen.dart";
import "../settings/settings_screen.dart";

// ⬇️ NEW: notifications UI + repo
import "../notifications/notifications_screen.dart";
import "../../repositories/notifications_repository.dart";

// ⬇️ NEW: blocks repo + (optional) sheet
import "../../repositories/blocks_repository.dart";
import "../../widgets/block_unblock_sheet.dart";

// ⬇️ Shared shimmer (centralized)
import "../../widgets/shimmer.dart";

// ⬇️ NEW: profile preview sheet
import '../../widgets/profile_preview_sheet.dart';

/// ---------------------------------------------------------------------------
/// Discover Screen
/// ---------------------------------------------------------------------------
class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen>
    with SingleTickerProviderStateMixin {
  // ====== backend-driven candidates ======
  List<Map<String, dynamic>> _candidates = []; // normalized maps for UI
  int _currentProfileIndex = 0;

  // loading / error
  bool _loading = true;
  String? _error;

  // heart animation
  bool _showHeartAnimation = false;
  late AnimationController _heartAnimController;
  late Animation<double> _heartSizeAnimation;
  late Animation<double> _heartOpacityAnimation;

  // card gesture state
  Offset _cardPosition = Offset.zero;
  double _cardAngle = 0;
  bool _isDragging = false;
  bool _isExiting = false;
  String? _exitDirection;

  // network throttling (avoid double taps during animation)
  bool _sendingAction = false;

  // ====== refresh tracking ======
  final Set<String> _knownUids = {}; // track uids we've seen to detect "new"
  bool _isManualRefresh = false; // only SnackBar on user-initiated refresh

  // Soon message (to mirror MessagesScreen)
  static const String kSoonMessage = "Feature Will Updated Soon";

  // ====== NEW: notifications ======
  late final NotificationsRepository _notifsRepo;
  late final Stream<int> _unreadStream;

  // ====== NEW: blocks repo (injected via Provider) ======
  BlocksRepository? _blocks;

  // ====== NEW: silent top-up ======
  static const int _TOPUP_THRESHOLD = 5; // when <= 5 cards, fetch more
  bool _toppingUp = false;

  // ====== NEW: warm-up guard ======
  bool _didWarmup = false;

  @override
  void initState() {
    super.initState();

    // notifications wiring (auth-aware)
    _notifsRepo = NotificationsRepository();
    _unreadStream =
        FirebaseAuth.instance.authStateChanges().asyncExpand((user) async* {
      if (user == null) {
        yield 0;
      } else {
        // Prefer a repo API that accepts uid
        yield* _notifsRepo.unreadCountStream(uid: user.uid);
      }
    });

    _heartAnimController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    _heartSizeAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.0, end: 1.5)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 60,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.5, end: 0.0)
            .chain(CurveTween(curve: Curves.easeIn)),
        weight: 40,
      ),
    ]).animate(_heartAnimController);
    _heartOpacityAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.0, end: 1.0)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 20,
      ),
      TweenSequenceItem(tween: ConstantTween<double>(1.0), weight: 40),
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.0, end: 0.0)
            .chain(CurveTween(curve: Curves.easeIn)),
        weight: 40,
      ),
    ]).animate(_heartAnimController);
    _heartAnimController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        if (!mounted) return;
        setState(() {
          _showHeartAnimation = false;
        });
        _heartAnimController.reset();
      }
    });

    // Ensure blocks are ready
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _blocks = context.read<BlocksRepository>();
      if (!(_blocks!.isLoaded)) {
        try {
          await _blocks!.refresh();
        } catch (_) {}
      }
      _blocks!.addListener(_onBlocksChanged);
    });

    // 🔥 NEW: warm up auth + backend first, then fetch matches.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _warmUpAuthAndBackend();
      await _loadMatches(preferFreshToken: true);
    });
  }

  @override
  void dispose() {
    _heartAnimController.dispose();
    _blocks?.removeListener(_onBlocksChanged); // NEW
    super.dispose();
  }

  // ================== REFRESH HELPERS ==================
  Future<void> _onRefresh() async {
    _isManualRefresh = true;
    try {
      await _loadMatches(); // full refresh (not silent)
    } finally {
      _isManualRefresh = false; // always clear so RefreshIndicator can finish
    }
  }

  // NEW: silent top-up helper
  Future<void> _topUpIfLow() async {
    if (_toppingUp || _loading) return;
    if (_candidates.length > _TOPUP_THRESHOLD) return;

    _toppingUp = true;
    try {
      await _loadMatches(silent: true, append: true);
    } finally {
      _toppingUp = false;
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    // Match MessagesScreen – simple, default SnackBar
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  void _soon() => _showSnack(kSoonMessage);

  // ================== NEW: WARM-UP ==================
  /// Pre-warm Firebase token and nudge backend without blocking UI.
  Future<void> _warmUpAuthAndBackend() async {
    if (_didWarmup) return;
    _didWarmup = true;

    final u = FirebaseAuth.instance.currentUser;
    if (u != null) {
      // Ensure a not-near-expiry token before first /match
      try {
        await u.getIdToken(true);
      } catch (_) {
        // ignore – _loadMatches has its own auth safety
      }
    }

    // Fire a best-effort /health ping with a *short* timeout to wake cold backends.
    // Do NOT surface health errors; this is a non-blocking warm-up.
    unawaited(_healthPing());
  }

  Future<void> _healthPing() async {
    try {
      await ApiClient.getJson(
        '/health',
        // keep this short – it’s just a wake-up
        timeout: const Duration(seconds: 3),
        // don’t force refresh – /health usually doesn’t need auth
      );
    } catch (_) {
      // ignore entirely
    }
  }

  // ================== BACKEND INTERACTIONS ==================
  Future<void> _sendLike(String targetUid) async {
    try {
      final data = await ApiClient.likeUser(targetUid); // sends { other_uid }
      final bool mutual = data['mutual_match'] == true;

      if (mutual) {
        _showSnack("It's a match! 🎉");
        // (optional) _navigateToMatches();
      }
    } catch (e) {
      _showSnack('Like error: $e');
    }
  }

  Future<void> _sendPass(String targetUid) async {
    try {
      await ApiClient.passUser(targetUid); // sends { other_uid }
      // fire-and-forget
    } catch (e) {
      _showSnack('Pass error: $e');
    }
  }

  // =============== SMART POST RETRY (for /match) ===============
  /// First attempt: shorter timeout. On TimeoutException, retry once with a longer timeout
  /// and a forced fresh token. This specifically addresses “first open” cold starts.
  Future<Map<String, dynamic>> _postJsonWithWarmRetry(
    String path,
    Map<String, dynamic> body, {
    bool preferFreshToken = false,
  }) async {
    try {
      // Attempt 1 — modest timeout; optionally start with forced refresh
      final res = await ApiClient.postJson(
        path,
        body,
        timeout: const Duration(seconds: 12),
        forceRefreshFirst: preferFreshToken,
      );
      ensureOk(res);
      return asJson(res);
    } on TimeoutException {
      // Attempt 2 — longer timeout AND force-refresh token
      final res = await ApiClient.postJson(
        path,
        body,
        timeout: const Duration(seconds: 25),
        forceRefreshFirst: true,
      );
      ensureOk(res);
      return asJson(res);
    }
  }

  // ================== DATA LOADING ==================

  // Merge helper — preserves UI-facing fields (name/age) while fresh data loads
  List<Map<String, dynamic>> _mergeCandidatesPreservingUi(
    List<Map<String, dynamic>> fresh,
  ) {
    final prevByUid = {
      for (final c in _candidates)
        if ((c["uid"] ?? "").toString().isNotEmpty) c["uid"]: c
    };

    return fresh.map((c) {
      final uid = (c["uid"] ?? "").toString();
      final prev = prevByUid[uid];
      if (prev != null) {
        // keep previously shown name/age to avoid UI flicker
        c["name"] = (prev["name"] ?? c["name"]);
        c["age"] = (prev["age"] ?? c["age"]);
        // keep already shown tags if present
        c["attachmentStyle"] =
            (prev["attachmentStyle"] ?? c["attachmentStyle"]);
        c["loveLanguage"] = (prev["loveLanguage"] ?? c["loveLanguage"]);
        // NEW: keep gender to prevent flicker
        c["gender"] = (prev["gender"] ?? c["gender"]);
      }
      return c;
    }).toList();
  }

  // UPDATED: support silent + append for top-up
  Future<void> _loadMatches({
    bool silent = false,
    bool append = false,
    bool preferFreshToken = false, // ← NEW: for first call after warmup
  }) async {
    final isInitial = _candidates.isEmpty && _error == null;

    if (!silent) {
      if (isInitial) {
        setState(() {
          _loading = true;
          _error = null;
          _candidates = [];
          _currentProfileIndex = 0;
        });
      } else {
        // keep current list visible during pull-to-refresh
        setState(() {
          _error = null;
        });
      }
    } // else: silent → keep current UI untouched

    try {
      // 🔒 Safe user fetch (avoid crash on null currentUser)
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = "Not signed in.";
        });
        return;
      }
      final uid = user.uid;

      // 1) call backend /match (returns {"candidates": [...]} or {"results":[...]})
      final data = await _postJsonWithWarmRetry(
        "/match",
        {
          "userId": uid,
          "topN": 20,
        },
        preferFreshToken: preferFreshToken,
      );

      final List rawCandidates =
          (data["candidates"] as List?) ?? (data["results"] as List? ?? []);

      // 2) Normalize for UI – read primary trait names from ROOT keys
      final List<Map<String, dynamic>> built =
          rawCandidates.map<Map<String, dynamic>>((c) {
        final map = Map<String, dynamic>.from(c as Map);

        final attRaw = (map["attachment_style"] ?? "").toString();
        final loveRaw = (map["love_primary"] ?? "").toString();

        return {
          "uid": map["uid"],
          "name": (map["display_name"] ?? "User").toString(),
          "age": null, // hydrate from Firestore – merge preserves previous
          "bio": (map["bio"] ?? "").toString(),
          "profileImageUrl": (map["image_url"] ?? "").toString(),

          // Primary tags
          "attachmentStyle": _formatAttachmentLabel(attRaw),
          "loveLanguage": _formatLoveLabel(loveRaw),

          // NEW: placeholder for gender – filled during hydration
          "gender": "",

          "score":
              (map["score"] is num) ? (map["score"] as num).toDouble() : 0.0,
          "breakdown": map["breakdown"],
        };
      }).toList();

      // preserve currently displayed fields to prevent flicker
      final merged = _mergeCandidatesPreservingUi(built);

      // Ensure blocks are loaded (first run)
      final b = _blocks ?? (mounted ? context.read<BlocksRepository>() : null);
      if (b != null && !b.isLoaded) {
        try {
          await b.refresh();
        } catch (_) {}
      }

      // Filter out blocked users (both directions)
      final filtered = _filterBlocked(merged);

      // ---- append vs replace ----
      List<Map<String, dynamic>> nextList;
      if (append) {
        final seen = _candidates
            .map((m) => (m["uid"] ?? "").toString())
            .where((s) => s.isNotEmpty)
            .toSet();
        final uniques = filtered.where((m) {
          final id = (m["uid"] ?? "").toString();
          return id.isNotEmpty && !seen.contains(id);
        }).toList();
        nextList = [..._candidates, ...uniques];
      } else {
        nextList = filtered;
      }

      // Calculate new matches (by uid) vs what we've seen before
      final currentUids = nextList
          .map((m) => (m["uid"] ?? "").toString())
          .where((s) => s.isNotEmpty)
          .toSet();
      final newUids = currentUids.difference(_knownUids);

      if (!mounted) return;
      setState(() {
        _candidates = nextList;
        if (!silent) _loading = false;
        _knownUids
          ..clear()
          ..addAll(currentUids);
        // keep the same index if possible
        if (_currentProfileIndex >= _candidates.length) {
          _currentProfileIndex = 0;
        }
      });

      // Hydrate first_name + age + (fallback) tags + gender from Firestore root doc
      _hydrateNamesAgesAndPrimaryTags();

      // Only notify on user-initiated refresh (non-silent)
      if (!silent && _isManualRefresh) {
        if (newUids.isNotEmpty) {
          _showSnack(
              "${newUids.length} new match${newUids.length == 1 ? '' : 'es'}");
        } else {
          _showSnack("No new matches");
        }
      }

      // 3) Preload first images so the first card shows instantly
      _precacheTopImages(4); // intentionally unawaited
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        if (!silent) _loading = false;
      });
    }
  }

  // ---------- formatting helpers for labels ----------
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

  // --- Normalize labels to match the constants keys ---
  String _formatAttachmentLabel(String s) => _titleize(s);

  // Keep small words lowercase so keys like "Words of Affirmation" match.
  String _formatLoveLabel(String s) {
    final t = _titleize(s);
    return t.replaceAllMapped(
      RegExp(r'\b(Of|And|For|To|In|On|With|A|An)\b'),
      (m) => m.group(0)!.toLowerCase(),
    );
  }

  // ===== NEW: gender helpers =====
  String _formatGenderLabel(String s) {
    final raw = s.trim().toLowerCase();
    if (raw.isEmpty) return "";
    if ({"m", "male", "man", "boy"}.contains(raw)) return "Male";
    if ({"f", "female", "woman", "girl"}.contains(raw)) return "Female";
    if ({"non-binary", "nonbinary", "nb", "enby"}.contains(raw)) {
      return "Non-binary";
    }
    if ({"others", "other", "prefer not to say", "prefer-not", "na", "n/a"}
        .contains(raw)) {
      return "Other";
    }
    return _titleize(raw);
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

  // ===== Gender colors & size =====
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
        return Colors.white70; // Fallback on unknown
    }
  }

  static const double _genderIconSize = 30.0;
  // ----------------------------------------------------

  // ===== Pastel color helpers =====
  Color _attachmentPastel(String label) {
    // labels are already Title Cased by _formatAttachmentLabel
    return attachmentColors[label] ?? AppColors.lightPink;
  }

  Color _lovePastel(String label) {
    return loveLanguageColors[label] ?? AppColors.lightPink;
  }

  Future<void> _hydrateNamesAgesAndPrimaryTags() async {
    try {
      // de-dup to minimize whereIn slots
      final uids = _candidates
          .map((c) => c["uid"] as String?)
          .where((u) => (u ?? '').isNotEmpty)
          .cast<String>()
          .toSet()
          .toList();

      const chunkSize = 10; // Firestore whereIn max
      for (var i = 0; i < uids.length; i += chunkSize) {
        final batch = uids.sublist(i, math.min(i + chunkSize, uids.length));

        final snaps = await FirebaseFirestore.instance
            .collection('users')
            .where(FieldPath.documentId, whereIn: batch)
            .get();

        final infoByUid = <String, Map<String, dynamic>>{};
        for (final doc in snaps.docs) {
          final data = doc.data();
          final pinfo = (data["personal_info"] is Map)
              ? Map<String, dynamic>.from(data["personal_info"] as Map)
              : <String, dynamic>{};

          // first name only (no last name)
          final first =
              ((pinfo["first_name"] ?? data["first_name"] ?? "").toString())
                  .trim();

          // age from personal_info.age (int or string)
          int? age;
          final a = pinfo["age"];
          if (a is int) {
            age = a;
          } else if (a is String) {
            age = int.tryParse(a);
          }

          // Root-level primary tags (fallback)
          final attRaw = (data["attachment_style"] ?? "").toString();
          final loveRaw = (data["love_primary"] ?? "").toString();

          // NEW: gender, prefer personal_info.gender then root fallbacks
          final genderRaw = (() {
            final g1 = (pinfo["gender"] ?? "").toString();
            if (g1.trim().isNotEmpty) return g1;
            final g2 = (data["gender"] ?? data["sex"] ?? "").toString();
            return g2;
          })();

          infoByUid[doc.id] = {
            "first": first,
            "age": age,
            "att": attRaw,
            "love": loveRaw,
            "gender": genderRaw,
          };
        }

        if (!mounted) return;
        // Only fill missing fields to avoid visible "blink"
        setState(() {
          _candidates = _candidates.map((c) {
            final uid = c["uid"];
            if (uid is String && infoByUid.containsKey(uid)) {
              final info = infoByUid[uid]!;
              final hasName = (c["name"] as String?)?.trim().isNotEmpty == true;
              final hasAge = c["age"] != null;
              final hasAtt =
                  (c["attachmentStyle"] as String?)?.trim().isNotEmpty == true;
              final hasLove =
                  (c["loveLanguage"] as String?)?.trim().isNotEmpty == true;
              final hasGender =
                  (c["gender"] as String?)?.trim().isNotEmpty == true;

              return {
                ...c,
                if (!hasName)
                  "name":
                      ((info["first"] as String?)?.trim().isNotEmpty ?? false)
                          ? info["first"]
                          : (c["name"] ?? "User"),
                if (!hasAge) "age": info["age"],
                if (!hasAtt)
                  "attachmentStyle":
                      _formatAttachmentLabel((info["att"] as String?) ?? ""),
                if (!hasLove)
                  "loveLanguage":
                      _formatLoveLabel((info["love"] as String?) ?? ""),
                // NEW: fill gender if empty
                if (!hasGender)
                  "gender":
                      _formatGenderLabel((info["gender"] as String?) ?? ""),
              };
            }
            return c;
          }).toList();
        });
      }
    } catch (_) {
      // Optional fields – ignore failures.
    }
  }

  Future<void> _precacheTopImages(int n) async {
    if (!mounted) return;
    final ctx = context;
    final mq = MediaQuery.of(ctx);
    final pxW = (mq.size.width - 32).toInt();
    final pxH = (mq.size.height * 0.65).toInt();

    final limit = math.min(n, _candidates.length);
    for (var i = 0; i < limit; i++) {
      final rawUrl = (_candidates[i]["profileImageUrl"] as String?) ?? "";
      final url = _buildTransformedUrl(rawUrl, pxW, pxH);
      if (url.startsWith("http")) {
        final provider = CachedNetworkImageProvider(
          url,
          maxWidth: pxW,
          maxHeight: pxH,
        );
        try {
          await precacheImage(provider, ctx);
        } catch (_) {
          // ignore single-image failures
        }
      }
    }
  }

  static int? _intFromAny(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is String) {
      final p = int.tryParse(v);
      return p;
    }
    return null;
  }

  // ================== UI & INTERACTION ==================

  // NEW: open profile preview sheet on simple tap
  void _openPreviewForCurrent() {
    if (_candidates.isEmpty) return;
    final uid = (_candidates[_currentProfileIndex]['uid'] ?? '').toString();
    if (uid.isEmpty) return;

    showProfilePreviewSheet(
      context: context,
      candidateUid: uid,
      onPass: () async {
        if (_sendingAction) return;
        _sendingAction = true;
        try {
          await _sendPass(uid); // hits ApiClient.passUser → backend /pass
          // Remove from list so it doesn't come back
          setState(() {
            _candidates.removeWhere((c) => (c['uid'] ?? '') == uid);
            if (_currentProfileIndex >= _candidates.length) {
              _currentProfileIndex = 0;
            }
          });
          // NEW: silent top-up after removal
          _topUpIfLow();
        } catch (e) {
          _showSnack('Pass error: $e');
        } finally {
          _sendingAction = false;
        }
      },
      onLike: () async {
        if (_sendingAction) return;
        _sendingAction = true;
        try {
          await _sendLike(
              uid); // hits ApiClient.likeUser → backend /like (notif should fire here)
          // Heart effect (optional, to mirror card like)
          setState(() {
            _showHeartAnimation = true;
          });
          _heartAnimController.forward();

          // Remove from list so it doesn't come back
          setState(() {
            _candidates.removeWhere((c) => (c['uid'] ?? '') == uid);
            if (_currentProfileIndex >= _candidates.length) {
              _currentProfileIndex = 0;
            }
          });
          // NEW: silent top-up after removal
          _topUpIfLow();
        } catch (e) {
          _showSnack('Like error: $e');
        } finally {
          _sendingAction = false;
        }
      },
    );
  }

  void _handleLike() {
    if (_candidates.isEmpty || _sendingAction) return;
    final targetUid =
        (_candidates[_currentProfileIndex]['uid'] ?? '').toString();
    if (targetUid.isEmpty) return;

    // guard if user became blocked mid-gesture
    final blocked = context.read<BlocksRepository>().isBlockedWith(targetUid);
    if (blocked) {
      _moveToNextProfile();
      return;
    }

    _sendingAction = true;
    setState(() {
      _showHeartAnimation = true;
      _isExiting = true;
      _exitDirection = "right";
    });
    _heartAnimController.forward();

    _sendLike(targetUid).whenComplete(() => _sendingAction = false);
    Future.delayed(const Duration(milliseconds: 300), _moveToNextProfile);
  }

  void _handleDislike() {
    if (_candidates.isEmpty || _sendingAction) return;
    final targetUid =
        (_candidates[_currentProfileIndex]['uid'] ?? '').toString();
    if (targetUid.isEmpty) return;

    // guard if user became blocked mid-gesture
    final blocked = context.read<BlocksRepository>().isBlockedWith(targetUid);
    if (blocked) {
      _moveToNextProfile();
      return;
    }

    _sendingAction = true;
    setState(() {
      _isExiting = true;
      _exitDirection = "left";
    });

    _sendPass(targetUid).whenComplete(() => _sendingAction = false);
    Future.delayed(const Duration(milliseconds: 300), _moveToNextProfile);
  }

  void _moveToNextProfile() {
    if (_candidates.isEmpty) return;
    setState(() {
      _currentProfileIndex = (_currentProfileIndex + 1) % _candidates.length;
      _cardPosition = Offset.zero;
      _cardAngle = 0;
      _isExiting = false;
      _exitDirection = null;
    });
    // Warm the next images (keeps upcoming cards instant)
    _precacheTopImages(4); // unawaited
    // NEW: check if list is running low and silently top-up
    _topUpIfLow();
  }

  void _onPanStart(DragStartDetails details) {
    setState(() => _isDragging = true);
  }

  void _onPanUpdate(DragUpdateDetails details) {
    setState(() {
      _cardPosition += details.delta;
      _cardAngle = _cardPosition.dx * 0.003;
    });
  }

  // Swipe RIGHT = LIKE, Swipe LEFT = PASS
  void _onPanEnd(DragEndDetails details) {
    final screenWidth = MediaQuery.of(context).size.width;
    const threshold = 0.4;

    setState(() => _isDragging = false);

    if (_candidates.isEmpty) {
      setState(() {
        _cardPosition = Offset.zero;
        _cardAngle = 0;
      });
      return;
    }

    final targetUid =
        (_candidates[_currentProfileIndex]['uid'] ?? '').toString();
    if (targetUid.isEmpty) {
      setState(() {
        _cardPosition = Offset.zero;
        _cardAngle = 0;
      });
      return;
    }

    if (_cardPosition.dx.abs() > screenWidth * threshold) {
      final right = _cardPosition.dx > 0;
      setState(() {
        _isExiting = true;
        _exitDirection = right ? "right" : "left";
        if (right) {
          _showHeartAnimation = true;
          _heartAnimController.forward();
        }
      });

      if (!_sendingAction) {
        _sendingAction = true;

        // guard if user became blocked mid-gesture
        final blocked =
            context.read<BlocksRepository>().isBlockedWith(targetUid);
        if (blocked) {
          _sendingAction = false;
        } else {
          (right ? _sendLike(targetUid) : _sendPass(targetUid))
              .whenComplete(() => _sendingAction = false);
        }
      }

      Future.delayed(const Duration(milliseconds: 300), _moveToNextProfile);
    } else {
      setState(() {
        _cardPosition = Offset.zero;
        _cardAngle = 0;
      });
    }
  }

  // navigation helpers
  void _navigateToMatches() {
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            const MatchesScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(-1.0, 0.0);
          const end = Offset.zero;
          const curve = Curves.easeInOut;
          var tween =
              Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
          return SlideTransition(
              position: animation.drive(tween), child: child);
        },
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );
  }

  void _navigateToMessages() {
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            const MessagesScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(-1.0, 0.0);
          const end = Offset.zero;
          const curve = Curves.easeInOut;
          var tween =
              Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
          return SlideTransition(
              position: animation.drive(tween), child: child);
        },
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );
  }

  void _navigateToNotifications() {
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const NotificationsScreen(),
        transitionsBuilder: (_, a, __, child) => SlideTransition(
            position: a.drive(Tween(begin: const Offset(1, 0), end: Offset.zero)
                .chain(CurveTween(curve: Curves.easeInOut))),
            child: child),
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );
  }

  // =========================
  // Scaffold with sticky bars
  // =========================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: _buildAppBar(), // always visible
      body: _buildBody(context), // swaps per state
      bottomNavigationBar: _buildBottomNavBar(), // always visible
    );
  }

  Widget _buildBody(BuildContext context) {
    // Loading — show shimmering skeleton instead of spinner
    if (_loading) {
      return _buildSkeletonBody();
    }

    // Error — show retry inside content area
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24.0),
              child: Text(_error!, textAlign: TextAlign.center),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _loadMatches,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primaryColor,
                shape: const CircleBorder(),
                padding: const EdgeInsets.all(14),
              ),
              child: const Icon(Icons.refresh, color: Colors.white),
            ),
          ],
        ),
      );
    }

    // Empty-state
    if (_candidates.isEmpty) {
      return RefreshIndicator(
        onRefresh: _onRefresh,
        child: CustomScrollView(
          primary: true,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverFillRemaining(
              hasScrollBody:
                  false, // <-- allows overscroll even with no content
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.people_outline,
                          size: 80, color: Colors.grey.shade400),
                      const SizedBox(height: 16),
                      const Text(
                        "No matches yet",
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        "We couldn’t find compatible users right now.\n"
                        "Pull down to refresh.",
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 14, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    // Normal content with pull-down-to-refresh
    return RefreshIndicator(
      onRefresh: _onRefresh,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // AlwaysScrollable so you can pull even if content fits the screen
          return SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: SizedBox(
                height: constraints.maxHeight,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _buildProfileCard(constraints), // centered card
                    if (_showHeartAnimation)
                      AnimatedBuilder(
                        animation: _heartAnimController,
                        builder: (context, child) {
                          return Center(
                            child: Opacity(
                              opacity: _heartOpacityAnimation.value,
                              child: Transform.scale(
                                scale: _heartSizeAnimation.value,
                                child: const Icon(
                                  Icons.favorite,
                                  color: Color(0xFFB5276A),
                                  size: 150,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ---------------------------
  // Shimmering skeleton builders
  // ---------------------------
  Widget _buildSkeletonBody() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final containerWidth = constraints.maxWidth;
        final cardWidth = containerWidth - 32; // same as real card
        final screenSize = MediaQuery.of(context).size;
        final cardHeight = screenSize.height * 0.65; // same ratio as real card
        final top = (constraints.maxHeight - cardHeight) / 2;
        final left = (containerWidth - cardWidth) / 2;

        return Stack(
          children: [
            Positioned(
              top: top,
              left: left,
              child: _buildSkeletonCard(cardWidth, cardHeight),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSkeletonCard(double w, double h) {
    // Match the *real* image area height:
    // In the live card, the image is `Expanded` and the bottom buttons section
    // has – vertical padding (16 * 2) + circle size (60) = 92 px total.
    const double _kBtnSize = 60;
    const double _kBtnPadV = 16;
    final double buttonsSectionHeight = _kBtnSize + (_kBtnPadV * 2); // 92
    final double imageAreaHeight = (h - buttonsSectionHeight).clamp(0.0, h);

    return Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          // SINGLE image-area skeleton — exact same height as the loaded image
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            child: SizedBox(
              height: imageAreaHeight,
              width: double.infinity,
              child: Shimmer(
                child: Container(color: Colors.grey.shade300),
              ),
            ),
          ),

          // Bottom buttons skeleton (kept)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: _kBtnPadV),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Shimmer(
                  child: Container(
                    width: _kBtnSize,
                    height: _kBtnSize,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.grey.shade300,
                      border: Border.all(color: Colors.grey.shade300, width: 2),
                    ),
                  ),
                ),
                const SizedBox(width: 24),
                Shimmer(
                  child: Container(
                    width: _kBtnSize,
                    height: _kBtnSize,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.grey.shade300,
                      border: Border.all(color: Colors.grey.shade300, width: 2),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------

  // Messages-style AppBar (copied & adapted)
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
      titleSpacing: 0, // ensures flush alignment with edge
      title: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // Left-aligned title
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
                  "Discover",
                  style: TextStyle(
                    color: Colors.grey.shade600,
                    fontSize: 14,
                  ),
                ),
              ],
            ),

            // Right-aligned icons
            Row(
              children: [
                // ─── NEW: Notifications icon + unread badge ───
                StreamBuilder<int>(
                  stream: _unreadStream,
                  builder: (context, snap) {
                    final count = (snap.data ?? 0);
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
                  tooltip: 'Settings',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProfileCard(BoxConstraints parentConstraints) {
    final current = _candidates[_currentProfileIndex];

    // Use parent width for accurate centering
    final containerWidth = parentConstraints.maxWidth;
    final cardWidth = containerWidth - 32; // visual 16px side gutters
    final screenSize = MediaQuery.of(context).size;
    final cardHeight = screenSize.height * 0.65; // keep your original ratio

    // Center within the available area
    final top = (parentConstraints.maxHeight - cardHeight) / 2;
    final leftBase = (containerWidth - cardWidth) / 2;

    // Swipe/exit offsets and angle
    final screenWidth = screenSize.width;
    final x = _isExiting && _exitDirection != null
        ? (_exitDirection == "right" ? screenWidth * 1.5 : -screenWidth * 1.5)
        : _cardPosition.dx;
    final angle = _isExiting && _exitDirection != null
        ? (_exitDirection == "right" ? 0.3 : -0.3)
        : _cardAngle;

    final imageUrl = current["profileImageUrl"] as String?;
    final attachment = (current["attachmentStyle"] as String? ?? "").trim();
    final loveLang = (current["loveLanguage"] as String? ?? "").trim();

    // NEW: gender label for UI row
    final genderLabel =
        _formatGenderLabel((current["gender"] as String?) ?? "");

    return AnimatedPositioned(
      duration: _isExiting
          ? const Duration(milliseconds: 300)
          : const Duration(milliseconds: 100),
      curve: Curves.easeOutCubic,
      left: leftBase + x, // center + swipe delta
      top: top, // vertical center
      child: AnimatedRotation(
        turns: angle / (2 * math.pi),
        duration: _isExiting
            ? const Duration(milliseconds: 300)
            : const Duration(milliseconds: 100),
        curve: Curves.easeOutCubic,
        child: GestureDetector(
          onPanStart: _onPanStart,
          onPanUpdate: _onPanUpdate,
          onPanEnd: _onPanEnd,
          onDoubleTap: _handleLike, // double-tap = like
          onTap: _openPreviewForCurrent, // SIMPLE TAP OPENS PREVIEW
          child: Container(
            width: cardWidth,
            height: cardHeight,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              children: [
                // Image + overlay
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ClipRRect(
                        borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(16)),
                        child: _buildProfileImage(imageUrl),
                      ),
                      Container(
                        decoration: BoxDecoration(
                          borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(16)),
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              Colors.transparent,
                              Colors.transparent,
                              Colors.black.withOpacity(0.1),
                              Colors.black.withOpacity(0.5),
                            ],
                          ),
                        ),
                      ),

                      // top-right overflow menu for Block action
                      Positioned(
                        top: 8,
                        right: 8,
                        child: Material(
                          color: Colors.transparent,
                          child: PopupMenuButton<String>(
                            icon: const Icon(Icons.more_vert,
                                color: Colors.white),
                            color: Colors.white,
                            onSelected: (value) async {
                              if (value == 'block') {
                                final uid = (current["uid"] ?? '').toString();
                                if (uid.isEmpty) return;
                                try {
                                  final repo = context.read<BlocksRepository>();
                                  await repo.block(uid);
                                  await repo.refresh();
                                  if (!mounted) return;
                                  setState(() {
                                    _candidates.removeWhere(
                                        (c) => (c['uid'] ?? '') == uid);
                                    if (_currentProfileIndex >=
                                        _candidates.length) {
                                      _currentProfileIndex = 0;
                                    }
                                  });
                                  _showSnack("User blocked");
                                  // NEW: after removal, silently top up if low
                                  _topUpIfLow();
                                } catch (e) {
                                  _showSnack("Block failed: $e");
                                }
                              }
                            },
                            itemBuilder: (ctx) => const [
                              PopupMenuItem(
                                value: 'block',
                                child: Text('Block user'),
                              ),
                            ],
                          ),
                        ),
                      ),

                      if (_isDragging)
                        Positioned(
                          top: 20,
                          right: _cardPosition.dx < 0 ? null : 20,
                          left: _cardPosition.dx < 0 ? 20 : null,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: _cardPosition.dx < 0
                                  ? Colors.red.withOpacity(0.8)
                                  : AppColors.primaryColor.withOpacity(0.8),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: Colors.white.withOpacity(0.9),
                                width: 1,
                              ),
                            ),
                            child: Text(
                              _cardPosition.dx < 0 ? "nay" : "yay",
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 18,
                              ),
                            ),
                          ),
                        ),

                      Positioned(
                        left: 16,
                        right: 16,
                        bottom: 16,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Name, Age, Gender Icon
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Text(
                                  _formatNameAge(
                                      current["name"], current["age"]),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 24,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                if (genderLabel.isNotEmpty) ...[
                                  const SizedBox(width: 6),
                                  Icon(
                                    _genderIcon(genderLabel),
                                    size: _genderIconSize,
                                    color: _genderColor(genderLabel),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              (current["bio"] as String?) ?? "",
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                              ),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 12),

                            // Primary tags BELOW the bio
                            if (attachment.isNotEmpty || loveLang.isNotEmpty)
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  if (attachment.isNotEmpty)
                                    _buildTag(
                                      attachment,
                                      _attachmentPastel(attachment),
                                    ),
                                  if (loveLang.isNotEmpty)
                                    _buildTag(
                                      loveLang,
                                      _lovePastel(loveLang),
                                    ),
                                ],
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                // Bottom buttons
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // PASS
                      AnimatedPressable(
                        onPressed: _handleDislike,
                        child: Container(
                          width: 60,
                          height: 60,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: Colors.grey.shade400, width: 2),
                          ),
                          child: Icon(
                            Icons.close,
                            color: Colors.grey.shade400,
                            size: 30,
                          ),
                        ),
                      ),
                      const SizedBox(width: 24),
                      // LIKE
                      AnimatedPressable(
                        onPressed: _handleLike,
                        child: Container(
                          width: 60,
                          height: 60,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: AppColors.primaryColor, width: 2),
                          ),
                          child: Icon(
                            Icons.favorite,
                            color: AppColors.primaryColor,
                            size: 30,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Build a Supabase-transformed image URL if it's a Supabase public object.
  /// Otherwise return the original URL.
  String _buildTransformedUrl(String rawUrl, int pxW, int pxH) {
    if (rawUrl.isEmpty) return rawUrl;

    // Supabase public object pattern – ...supabase.co/storage/v1/object/public/<bucket>/<path>
    final isSupabase =
        rawUrl.contains(".supabase.co/storage/v1/object/public/");
    if (isSupabase) {
      final uri = Uri.parse(rawUrl);
      final q = Map<String, String>.from(uri.queryParameters);
      // Tell Supabase to resize & convert on the edge
      q["width"] = "$pxW";
      q["height"] = "$pxH";
      q["resize"] = "cover";
      q["format"] = "webp";
      q["quality"] = "80";
      final newUri = uri.replace(queryParameters: q);
      return newUri.toString();
    }

    return rawUrl;
  }

  Widget _buildProfileImage(String? imageUrl) {
    final mq = MediaQuery.of(context);
    final pxW = (mq.size.width - 32).toInt();
    final pxH = (mq.size.height * 0.65).toInt();

    final url = (imageUrl ?? "").trim();
    if (url.startsWith("http")) {
      final u = _buildTransformedUrl(url, pxW, pxH);

      return CachedNetworkImage(
        imageUrl: u,
        memCacheWidth: pxW,
        memCacheHeight: pxH,
        fit: BoxFit.cover,
        placeholder: (_, __) => _assetFallback(),
        errorWidget: (_, __, ___) => _assetFallback(),
        // 🚫 remove cross-fade
        fadeInDuration: Duration.zero,
        fadeOutDuration: Duration.zero,
      );
    }
    // fallback shimmer (keeps consistency with loading)
    return _assetFallback();
  }

  // Shimmering fallback while images load or if url is missing
  Widget _assetFallback() {
    return Shimmer(
      child: Container(
        color: Colors.grey.shade300,
        width: double.infinity,
        height: double.infinity,
      ),
    );
  }

  String _formatNameAge(dynamic name, dynamic age) {
    final n = (name ?? "User").toString().trim();
    final a = _intFromAny(age);
    return a == null ? n : "$n, $a";
  }

  Widget _buildTag(String text, Color bg,
      {Color? textColor, Color? borderColor}) {
    final Color _text =
        textColor ?? AppColors.black; // darker text for pastel bg
    final Color _border = borderColor ?? bg.withOpacity(0.9);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {}, // optional; keeps ripple. Remove if not tappable.
        borderRadius: BorderRadius.circular(20),
        splashColor: Colors.black12,
        highlightColor:
            Colors.black.withOpacity(0.06), // light grey ‘pressed’ effect
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: bg, // pastel fill
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: darkenPastel(bg), width: 1.25),
          ),
          child: Text(
            text,
            style: TextStyle(
              color: _text,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  // =======================
  // UNIFIED BOTTOM NAV BAR
  // (matches Messages/Matches)
  // =======================
  Widget _buildBottomNavBar() {
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 4,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: BottomNavigationBar(
          currentIndex: 0, // Discover tab
          backgroundColor: Colors.white,
          elevation: 0,
          type: BottomNavigationBarType.fixed,
          selectedItemColor: AppColors.primaryColor,
          unselectedItemColor: Colors.grey,
          onTap: (i) {
            if (i == 1) _navigateToMatches();
            if (i == 2) _navigateToMessages();
            if (i == 3) _navigateToProfile();
          },
          items: const [
            BottomNavigationBarItem(
                icon: Icon(Icons.search), label: "Discover"),
            BottomNavigationBarItem(
                icon: Icon(Icons.favorite_border), label: "Matches"),
            BottomNavigationBarItem(
                icon: Icon(Icons.chat_bubble_outline), label: "Messages"),
            BottomNavigationBarItem(
                icon: Icon(Icons.person_outline), label: "Profile"),
          ],
        ),
      ),
    );
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
        ),
      );

  void _navigateToProfile() {
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (context, a, b) => const ProfileScreen(),
        transitionsBuilder: (context, a, b, child) {
          const begin = Offset(-1.0, 0.0), end = Offset.zero;
          const curve = Curves.easeInOut;
          var tween =
              Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
          return SlideTransition(position: a.drive(tween), child: child);
        },
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );
  }

  // =======================
  // NEW: Blocks integration
  // =======================
  void _onBlocksChanged() {
    if (!mounted) return;
    setState(() {
      _candidates = _filterBlocked(_candidates);
      if (_currentProfileIndex >= _candidates.length) {
        _currentProfileIndex = _candidates.isEmpty ? 0 : 0;
      }
    });
    // After block list changes, ensure we top-up if it shrank the deck
    _topUpIfLow();
  }

  List<Map<String, dynamic>> _filterBlocked(List<Map<String, dynamic>> items) {
    final b = _blocks;
    if (b == null) return items;
    return items.where((c) {
      final raw = c['uid'] ?? c['user_id'] ?? c['other_uid'];
      final uid = (raw is String) ? raw : raw?.toString() ?? '';
      if (uid.isEmpty) return false;
      return !b.isBlockedWith(uid);
    }).toList();
  }
}
