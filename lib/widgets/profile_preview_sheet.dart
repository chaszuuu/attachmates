// lib/widgets/profile_preview_sheet.dart
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../utils/constants.dart';
import '../utils/interest_categories.dart';

final CacheManager _fallbackCacheManager = CacheManager(
  Config(
    'attachmates_images_preview_v7',
    stalePeriod: Duration(days: 14),
    maxNrOfCacheObjects: 250,
  ),
);

Future<void> showProfilePreviewSheet({
  required BuildContext context,
  required String candidateUid,
  CacheManager? cacheManager,
  VoidCallback? onLike,
  VoidCallback? onPass,
  bool showActions = true, // ⬅️ NEW
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    // cap the height so it won't hit the AppBar bottom
    constraints: () {
      final mq = MediaQuery.of(context);
      final topPadding = mq.padding.top + kToolbarHeight; // status + AppBar
      final maxH = mq.size.height - topPadding - 12; // leave a small gap
      return BoxConstraints(maxHeight: maxH);
    }(),
    backgroundColor: Colors.white,
    barrierColor: Colors.black.withOpacity(0.35),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      return _DiscoverCardPreview(
        candidateUid: candidateUid,
        cacheManager: cacheManager ?? _fallbackCacheManager,
        onLike: onLike,
        onPass: onPass,
        showActions: showActions, // ⬅️ NEW
      );
    },
  );
}

class _DiscoverCardPreview extends StatefulWidget {
  final String candidateUid;
  final CacheManager cacheManager;
  final VoidCallback? onLike;
  final VoidCallback? onPass;
  final bool showActions; // ⬅️ NEW

  const _DiscoverCardPreview({
    required this.candidateUid,
    required this.cacheManager,
    this.onLike,
    this.onPass,
    this.showActions = true, // ⬅️ NEW
  });

  @override
  State<_DiscoverCardPreview> createState() => _DiscoverCardPreviewState();
}

class _DiscoverCardPreviewState extends State<_DiscoverCardPreview> {
  Stream<DocumentSnapshot<Map<String, dynamic>>> _docStream() {
    return FirebaseFirestore.instance
        .collection('users')
        .doc(widget.candidateUid)
        .snapshots();
  }

  // ---------- helpers aligned with Discover/Profile ----------
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

  IconData? _iconForGender(String? raw) {
    if (raw == null) return null;
    final g = raw.trim().toLowerCase();
    if (g.isEmpty) return null;
    if ({'male', 'man', 'm'}.contains(g)) return Icons.male;
    if ({'female', 'woman', 'f'}.contains(g)) return Icons.female;
    if (g.startsWith('trans')) return Icons.transgender;
    if (g.contains('non') && g.contains('binary')) return Icons.transgender;
    if (g == 'nb' || g == 'enby' || g.contains('genderqueer')) {
      return Icons.transgender;
    }
    if (g.contains('agender') || g.contains('gender fluid')) {
      return Icons.transgender;
    }
    if (g == 'other' ||
        g == 'others' ||
        (g.contains('prefer') && g.contains('not'))) {
      return Icons.person_outline;
    }
    return null;
  }

  Color _colorForGender(String? raw) {
    if (raw == null) return Colors.white70;
    final g = raw.trim().toLowerCase();
    if ({'male', 'man', 'm'}.contains(g)) return const Color(0xFF2595F7);
    if ({'female', 'woman', 'f'}.contains(g)) return AppColors.primaryColor;
    if (g.startsWith('trans') ||
        (g.contains('non') && g.contains('binary')) ||
        g == 'nb' ||
        g == 'enby' ||
        g.contains('genderqueer') ||
        g.contains('agender') ||
        g.contains('gender fluid')) return const Color(0xFF7E57C2);
    if (g == 'other' ||
        g == 'others' ||
        (g.contains('prefer') && g.contains('not'))) {
      return Colors.teal;
    }
    return Colors.white70;
  }

  String? _readGender(Map<String, dynamic> data, Map<String, dynamic> pinfo) {
    final cand = [
      pinfo['gender'],
      pinfo['gender_identity'],
      data['gender'],
      data['gender_identity'],
    ].firstWhere((e) => (e is String && e.trim().isNotEmpty),
        orElse: () => null);
    return (cand is String) ? cand : null;
  }

  int? _intFromAny(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is String) return int.tryParse(v);
    return null;
  }

  // FORCE BLACK TEXT on chips
  Widget _chip(String text, Color bg, {Color? border, Color? textColor}) {
    final Color effectiveText = textColor ?? Colors.black;
    final Color effectiveBorder = border ?? darkenPastel(bg);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: effectiveBorder, width: 1.25),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: effectiveText,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  void _openViewer(String url) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return Dialog(
          backgroundColor: Colors.black,
          insetPadding: const EdgeInsets.all(0),
          child: Stack(
            children: [
              Positioned.fill(
                child: InteractiveViewer(
                  minScale: 0.8,
                  maxScale: 4.0,
                  child: Center(
                    child: CachedNetworkImage(
                      imageUrl: url,
                      cacheManager: widget.cacheManager,
                      fit: BoxFit.contain,
                      placeholder: (_, __) => const Center(
                          child:
                              CircularProgressIndicator(color: Colors.white)),
                      errorWidget: (_, __, ___) => const Icon(
                          Icons.broken_image,
                          color: Colors.white70,
                          size: 48),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 16,
                left: 8,
                child: IconButton(
                  onPressed: () => Navigator.pop(ctx),
                  icon: const Icon(Icons.close, color: Colors.white),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // Read the height cap from the parent constraint (set in showModalBottomSheet)
    return LayoutBuilder(
      builder: (context, constraints) {
        final sheetHeight = constraints.maxHeight;

        return SafeArea(
          top: false,
          // keep bottom safe from gesture/nav bar
          child: SizedBox(
            height: sheetHeight,
            child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: _docStream(),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting &&
                    !snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (!snap.hasData || !snap.data!.exists) {
                  return _error("Profile not found.");
                }

                final data = snap.data!.data() ?? {};
                final pinfo = (data['personal_info'] is Map)
                    ? Map<String, dynamic>.from(data['personal_info'] as Map)
                    : <String, dynamic>{};

                // FIRST NAME ONLY
                final displayName =
                    (pinfo['first_name'] ?? data['first_name'] ?? 'User')
                        .toString()
                        .trim();

                final age = _intFromAny(pinfo['age']);
                final genderStr = _readGender(data, pinfo);
                final genderIcon = _iconForGender(genderStr);
                final genderColor = _colorForGender(genderStr);

                final bio = (pinfo['bio'] ?? data['bio'] ?? '').toString();

                // ---- Hero: strictly profile_image_url (no gallery fallback) ----
                final profileImageUrl = (data['profile_image_url'] ??
                        data['profileImageUrl'] ??
                        data['profile_image_local_url'])
                    ?.toString();

                // ---- Gallery: ONLY gallery images; never include PFP ----
                final List<String> gallery = (() {
                  final cands = [
                    data['photos'],
                    pinfo['photos'],
                    data['gallery'],
                    pinfo['gallery'],
                    data['images'],
                    pinfo['images'],
                  ].whereType<List>().toList();

                  if (cands.isEmpty) return <String>[];
                  final urls = cands.first
                      .map((e) => (e ?? '').toString())
                      .where((s) => s.startsWith('http'))
                      .toList();

                  if (profileImageUrl != null && profileImageUrl.isNotEmpty) {
                    urls.removeWhere((u) => u == profileImageUrl);
                  }
                  return urls.take(9).toList();
                })();

                // Tags (normalized via constants)
                final rawAttachment =
                    (data['attachment_style'] ?? pinfo['attachment_style'])
                            ?.toString() ??
                        '';
                final rawLovePrimary =
                    (data['love_primary'] ?? pinfo['love_primary'])
                            ?.toString() ??
                        '';
                final rawLoveSecondary =
                    (data['love_secondary'] ?? pinfo['love_secondary'])
                            ?.toString() ??
                        '';

                final attachment = normalizeAttachment(rawAttachment.trim());
                final lovePrimary = normalizeLoveLanguage(rawLovePrimary.trim());
                final loveSecondary =
                    normalizeLoveLanguage(rawLoveSecondary.trim());

                // Interests (keep raw strings; normalize in helpers)
                final List<String> interests = (() {
                  final cands = [
                    data['interests'],
                    pinfo['interests'],
                    data['tags'],
                    pinfo['tags'],
                    data['hobbies'],
                    pinfo['hobbies'],
                  ].whereType<List>().toList();
                  if (cands.isEmpty) return <String>[];
                  return cands.first
                      .map((e) => (e ?? '').toString().trim())
                      .where((s) => s.isNotEmpty)
                      .toSet()
                      .toList();
                })();

                return Column(
                  children: [
                    const SizedBox(height: 10),
                    Container(
                      width: 48,
                      height: 5,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(height: 10),

                    // --- TOP HALF: single hero image from profile_image_url
                    SizedBox(
                      height: sheetHeight * 0.5,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          ClipRRect(
                            borderRadius: const BorderRadius.only(
                              topLeft: Radius.circular(16),
                              topRight: Radius.circular(16),
                            ),
                            child: (profileImageUrl != null &&
                                    profileImageUrl.isNotEmpty &&
                                    profileImageUrl.startsWith('http'))
                                ? CachedNetworkImage(
                                    imageUrl: profileImageUrl,
                                    cacheManager: widget.cacheManager,
                                    fit: BoxFit.cover,
                                    placeholder: (_, __) =>
                                        Container(color: Colors.grey.shade200),
                                    errorWidget: (_, __, ___) => Container(
                                      color: Colors.grey.shade300,
                                      child: const Center(
                                        child: Icon(Icons.broken_image),
                                      ),
                                    ),
                                  )
                                : Container(
                                    color: Colors.grey.shade200,
                                    child: const Center(
                                      child: Icon(Icons.person, size: 48),
                                    ),
                                  ),
                          ),

                          // gradient like Discover
                          Positioned.fill(
                            child: IgnorePointer(
                              child: Container(
                                decoration: BoxDecoration(
                                  borderRadius: const BorderRadius.only(
                                    topLeft: Radius.circular(16),
                                    topRight: Radius.circular(16),
                                  ),
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Colors.transparent,
                                      Colors.transparent,
                                      Colors.black.withOpacity(0.1),
                                      Colors.black.withOpacity(0.55),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),

                          // close button
                          Positioned(
                            right: 8,
                            top: 8,
                            child: Material(
                              color: Colors.black38,
                              borderRadius: BorderRadius.circular(20),
                              child: InkWell(
                                onTap: () => Navigator.pop(context),
                                borderRadius: BorderRadius.circular(20),
                                child: const Padding(
                                  padding: EdgeInsets.all(6.0),
                                  child: Icon(Icons.close, color: Colors.white),
                                ),
                              ),
                            ),
                          ),

                          // BOTTOM OVERLAY: name/age (+ gender) and chips
                          Positioned(
                            left: 14,
                            right: 14,
                            bottom: 12,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // name/age + gender icon — no bio line here
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Flexible(
                                      child: Text.rich(
                                        TextSpan(
                                          children: [
                                            TextSpan(
                                              text: displayName,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 24,
                                                fontWeight: FontWeight.w800,
                                              ),
                                            ),
                                            if (age != null)
                                              const TextSpan(
                                                text: ", ",
                                                style: TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 24,
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                            if (age != null)
                                              TextSpan(
                                                text: "$age",
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 24,
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                          ],
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    if (genderIcon != null) ...[
                                      const SizedBox(width: 6),
                                      Icon(genderIcon,
                                          size: 22, color: genderColor),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 8),

                                if (attachment.isNotEmpty ||
                                    lovePrimary.isNotEmpty ||
                                    loveSecondary.isNotEmpty)
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      if (attachment.isNotEmpty)
                                        _chip(
                                          attachment,
                                          attachmentColorFor(attachment),
                                        ),
                                      if (lovePrimary.isNotEmpty)
                                        _chip(
                                          lovePrimary,
                                          loveLanguageColorFor(lovePrimary),
                                        ),
                                      if (loveSecondary.isNotEmpty)
                                        _chip(
                                          loveSecondary,
                                          loveLanguageColorFor(loveSecondary),
                                        ),
                                    ],
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    // --- BOTTOM HALF: scrollable details (About, Interests, Photos grid – view only)
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (bio.isNotEmpty) ...[
                              const Text(
                                "About",
                                style: TextStyle(
                                    fontSize: 16, fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 6),
                              Text(bio,
                                  style: const TextStyle(
                                      fontSize: 14, height: 1.5)),
                              const SizedBox(height: 16),
                            ],

                            if (interests.isNotEmpty) ...[
                              const Text(
                                "Interests",
                                style: TextStyle(
                                    fontSize: 16, fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  for (final it in interests)
                                    (() {
                                      // UI-only formatting (spaces instead of -/_ and Title Case)
                                      final display = _titleize(it);

                                      // Use shared normalized helpers
                                      final cat = categoryForInterest(it);
                                      final fill = interestColorForLabel(it);

                                      if (cat == null) {
                                        return _chip(
                                          display,
                                          AppColors.lightPink,
                                          border: AppColors.primaryColor,
                                        );
                                      }

                                      final border = interestBorderColor(cat);
                                      return _chip(
                                        display,
                                        fill,
                                        border: border,
                                      );
                                    })(),
                                ],
                              ),
                              const SizedBox(height: 16),
                            ],

                            // -------- Photos (view-only; gallery only; no PFP) ----------
                            const Text(
                              "Photos",
                              style: TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 8),

                            if (gallery.isEmpty)
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 14),
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade100,
                                  borderRadius: BorderRadius.circular(12),
                                  border:
                                      Border.all(color: Colors.grey.shade300),
                                ),
                                child: const Text(
                                  "No photos yet — once they upload, you’ll see them here.",
                                  style: TextStyle(
                                      fontSize: 13, color: Colors.black87),
                                ),
                              )
                            else
                              GridView.builder(
                                itemCount:
                                    gallery.length, // ✅ only uploaded photos
                                gridDelegate:
                                    const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 3,
                                  crossAxisSpacing: 8,
                                  mainAxisSpacing: 8,
                                ),
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                itemBuilder: (context, index) {
                                  final url = gallery[index];
                                  return GestureDetector(
                                    onTap: () => _openViewer(url),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: CachedNetworkImage(
                                        imageUrl: url,
                                        cacheManager: widget.cacheManager,
                                        fit: BoxFit.cover,
                                        placeholder: (_, __) => Container(
                                            color: Colors.grey.shade200),
                                        errorWidget: (_, __, ___) => Container(
                                          color: Colors.grey.shade300,
                                          alignment: Alignment.center,
                                          child: const Icon(Icons.broken_image),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            const SizedBox(height: 8),
                          ],
                        ),
                      ),
                    ),

                    // --- ACTIONS: same circular buttons as the card
                    // ⬇️ Only show if requested
                    if (widget.showActions)
                      SafeArea(
                        top: false,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.06),
                                blurRadius: 10,
                                offset: const Offset(0, -4),
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              // PASS
                              InkWell(
                                borderRadius: BorderRadius.circular(50),
                                onTap: () {
                                  widget.onPass?.call();
                                  Navigator.pop(context);
                                },
                                child: Container(
                                  width: 60,
                                  height: 60,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                        color: Colors.grey.shade400, width: 2),
                                  ),
                                  child: Icon(Icons.close,
                                      color: Colors.grey.shade400, size: 30),
                                ),
                              ),
                              const SizedBox(width: 24),
                              // LIKE
                              InkWell(
                                borderRadius: BorderRadius.circular(50),
                                onTap: () {
                                  widget.onLike?.call();
                                  Navigator.pop(context);
                                },
                                child: Container(
                                  width: 60,
                                  height: 60,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                        color: AppColors.primaryColor,
                                        width: 2),
                                  ),
                                  child: Icon(Icons.favorite,
                                      color: AppColors.primaryColor, size: 30),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _error(String msg) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Text(
            msg,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: Colors.black54),
          ),
        ),
      );
}
