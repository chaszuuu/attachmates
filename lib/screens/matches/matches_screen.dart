// lib/screens/matches/matches_screen.dart
import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:google_fonts/google_fonts.dart";
import "package:firebase_auth/firebase_auth.dart"; // ← auth-aware unread stream
import "package:provider/provider.dart"; // ← NEW
import "../../utils/constants.dart";
import "../../utils/api_client.dart";
import "../../utils/chat_service.dart";
import "../discover/discover_screen.dart"; // for navigation to Discover
import "../messages/messages_screen.dart";
import "../messages/conversation_screen.dart";
import "../profile/profile_screen.dart";
import "../settings/settings_screen.dart";
import '../notifications/notifications_screen.dart'; // ← navigate to notifications
import 'package:cached_network_image/cached_network_image.dart';

// ⬇️ Shared shimmer (centralized)
import "../../widgets/shimmer.dart";

// 🔔 Unread notifications badge
import '../../repositories/notifications_repository.dart';

// ⬇️ NEW: Blocks repo
import '../../repositories/blocks_repository.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart' as cache;
import '../../utils/interest_categories.dart';

const double kPhotoSize = 84;
const double kTitleSize = 17;
const double kBioSize = 12.5;
const double kCardPadding = 10;

final cache.BaseCacheManager _fallbackCacheManager = cache.CacheManager(
  cache.Config(
    'attachmates_images_preview_v7',
    stalePeriod: const Duration(days: 14),
    maxNrOfCacheObjects: 250,
  ),
);

// ===== Gender helpers (match Discover) =====
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
      return Colors.black54; // fallback for unknown
  }
}

// --- Pastel color lookups from constants.dart ---
Color _attachmentPastel(String label) => attachmentColorFor(label);
Color _lovePastel(String label) => loveLanguageColorFor(label);


/// Inline "Name, Age" + gender icon (no extra gap)
Widget _nameAgeWithGender({
  required String nameAge,
  required String genderLabel,
  double fontSize = kTitleSize,
  double iconSize = 18,
}) {
  final style = TextStyle(
    fontSize: fontSize,
    fontWeight: FontWeight.w700,
    height: .98,
    color: Colors.black,
  );

  if (genderLabel.trim().isEmpty) {
    return Text(
      nameAge,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
      textHeightBehavior: const TextHeightBehavior(
        applyHeightToFirstAscent: false,
        applyHeightToLastDescent: false,
      ),
    );
  }

  return RichText(
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    textHeightBehavior: const TextHeightBehavior(
      applyHeightToFirstAscent: false,
      applyHeightToLastDescent: false,
    ),
    text: TextSpan(
      style: style,
      children: [
        TextSpan(text: nameAge),
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

class _MatchCardPreview extends StatefulWidget {
  final String candidateUid;
  final cache.BaseCacheManager cacheManager;

  // Which tab we are on (drives buttons):
  // "incoming_like" => Liked You (Pass / Like back)
  // else => New (Start conversation / Unmatch)
  final String status;

  final VoidCallback? onStartConversation; // New tab primary
  final VoidCallback? onUnmatch; // New tab secondary
  final VoidCallback? onLikeBack; // Liked You primary
  final VoidCallback? onPass; // Liked You secondary

  const _MatchCardPreview({
    required this.candidateUid,
    required this.cacheManager,
    required this.status,
    this.onStartConversation,
    this.onUnmatch,
    this.onLikeBack,
    this.onPass,
  });

  @override
  State<_MatchCardPreview> createState() => _MatchCardPreviewState();
}

class _MatchCardPreviewState extends State<_MatchCardPreview> {
  Stream<DocumentSnapshot<Map<String, dynamic>>> _docStream() {
    return FirebaseFirestore.instance
        .collection('users')
        .doc(widget.candidateUid)
        .snapshots();
  }

  // ---------- helpers replicated from preview sheet ----------
  String _titleize(String s) {
    final clean = s.replaceAll(RegExp(r'[_\\-]+'), ' ').trim();
    if (clean.isEmpty) return "";
    return clean
        .split(RegExp(r'\\s+'))
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
    if (g == 'nb' || g == 'enby' || g.contains('genderqueer'))
      return Icons.transgender;
    if (g.contains('agender') || g.contains('gender fluid'))
      return Icons.transgender;
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

  String? _categoryForInterest(String label) {
    final needle = label.trim();
    for (final entry in kInterestCategories.entries) {
      if (entry.value.contains(needle)) return entry.key;
      if (entry.value.any((e) => e.toLowerCase() == needle.toLowerCase())) {
        return entry.key;
      }
    }
    return null;
  }

  int? _intFromAny(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is String) return int.tryParse(v);
    return null;
  }

  Widget _chip(String text, Color bg, {Color? border, Color? textColor}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: border ?? darkenPastel(bg), width: 1.25),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: textColor ?? Colors.black,
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
                        child: CircularProgressIndicator(color: Colors.white),
                      ),
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

  bool get _isIncoming => widget.status == "incoming_like";
  bool get _isChatting => widget.status == "chatting";

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final sheetHeight = constraints.maxHeight;

        return SafeArea(
          top: false,
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

                final data = snap.data!.data() ?? <String, dynamic>{};
                final pinfo = (data['personal_info'] is Map)
                    ? Map<String, dynamic>.from(data['personal_info'] as Map)
                    : <String, dynamic>{};

                // Name (first only), age, gender
                final displayName =
                    (pinfo['first_name'] ?? data['first_name'] ?? 'User')
                        .toString()
                        .trim();
                final age = _intFromAny(pinfo['age']);
                final genderStr = _readGender(data, pinfo);
                final genderIcon = _iconForGender(genderStr);
                final genderColor = _colorForGender(genderStr);

                final bio = (pinfo['bio'] ?? data['bio'] ?? '').toString();

                // Profile image (hero)
                final profileImageUrl = (data['profile_image_url'] ??
                        data['profileImageUrl'] ??
                        data['profile_image_local_url'])
                    ?.toString();

                // Gallery: only gallery images; exclude profile image
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

                // Tags (attachment + love languages)
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
final loveSecondary = normalizeLoveLanguage(rawLoveSecondary.trim());


                // Interests
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

                final String primaryText = _isIncoming
                    ? "Like back"
                    : (_isChatting
                        ? "Go to conversation"
                        : "Start a conversation");

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

                    // --- HERO (top half)
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
                                          child: Icon(Icons.broken_image)),
                                    ),
                                  )
                                : Container(
                                    color: Colors.grey.shade200,
                                    child: const Center(
                                        child: Icon(Icons.person, size: 48)),
                                  ),
                          ),

                          // gradient overlay
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

                          // close
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

                          // name/age + gender + chips
                          Positioned(
                            left: 14,
                            right: 14,
                            bottom: 12,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
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
  _chip(attachment, attachmentColorFor(attachment)),
if (lovePrimary.isNotEmpty)
  _chip(lovePrimary, loveLanguageColorFor(lovePrimary)),
if (loveSecondary.isNotEmpty)
  _chip(loveSecondary, loveLanguageColorFor(loveSecondary)),

                                    ],
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    // --- DETAILS (About, Interests, Photos)
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
    final display = _titleize(it);
    final cat = categoryForInterest(it);                 // from interest_categories.dart
    final fill = interestColorForLabel(it);              // label-aware fill
    if (cat == null) {
      return _chip(
        display,
        AppColors.lightPink,
        border: AppColors.primaryColor,
        textColor: Colors.black,
      );
    }
    final border = interestBorderColor(cat);
    return _chip(
      display,
      fill,
      border: border,
      textColor: Colors.black,
    );
  })(),

                                ],
                              ),
                              const SizedBox(height: 16),
                            ],
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
                                itemCount: gallery.length,
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

                    // --- ACTIONS (only difference from profile preview)
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
                        child: _isIncoming
                            // Liked You: Pass / Like back
                            ? Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: () {
                                        Navigator.pop(context);
                                        widget.onPass?.call();
                                      },
                                      icon: const Icon(Icons.close),
                                      label: const Text("Pass"),
                                      style: OutlinedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 12),
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(10),
                                        ),
                                        side: BorderSide(
                                          color: Colors.black.withOpacity(0.26),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: ElevatedButton.icon(
                                      onPressed: () {
                                        Navigator.pop(context);
                                        widget.onLikeBack?.call();
                                      },
                                      icon: const Icon(Icons.favorite_border),
                                      label: const Text("Like back"),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: AppColors.primaryColor,
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 12),
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(10),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              )
                            // New: Start conversation / Unmatch
                            : Row(
                                children: [
                                  Expanded(
                                    child: ElevatedButton.icon(
                                      onPressed: () {
                                        Navigator.pop(context);
                                        widget.onStartConversation?.call();
                                      },
                                      icon: Icon(
                                        _isChatting
                                            ? Icons.chat_bubble
                                            : Icons.chat_bubble_outline,
                                      ),
                                      label: Text(_isChatting
                                          ? "Go to conversation"
                                          : "Start a conversation"),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: AppColors.primaryColor,
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 12),
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(10),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: () {
                                        Navigator.pop(context);
                                        widget.onUnmatch?.call();
                                      },
                                      icon: const Icon(Icons.block),
                                      label: const Text("Unmatch"),
                                      style: OutlinedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 12),
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(10),
                                        ),
                                        side: BorderSide(
                                          color: Colors.red.withOpacity(0.35),
                                        ),
                                        foregroundColor: Colors.red,
                                      ),
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

class _MatchPreviewModal extends StatelessWidget {
  final Map<String, dynamic> match;
  final VoidCallback? onStartConversation; // New tab primary
  final VoidCallback? onUnmatch; // New tab secondary
  final VoidCallback? onLikeBack; // Liked You primary
  final VoidCallback? onPass; // Liked You secondary

  const _MatchPreviewModal({
    required this.match,
    this.onStartConversation,
    this.onUnmatch,
    this.onLikeBack,
    this.onPass,
  });

  bool get _isIncoming => (match["status"] == "incoming_like");
  bool get _isChatting => (match["status"] == "chatting");

  @override
  Widget build(BuildContext context) {
    final String name = (match["name"] ?? "User").toString();
    final int age = (match["age"] is int) ? match["age"] as int : 0;
    final String image = (match["image"] ?? "").toString();
    final String bio = (match["bio"] ?? "").toString();
    final String attachment = (match["attachment"] ?? "").toString();
    final String loveLanguage = (match["love_language"] ?? "").toString();
    final String genderLabel = (match["gender"] ?? "").toString();

    final String primaryText = _isIncoming
        ? "Like back"
        : (_isChatting ? "Go to conversation" : "Start a conversation");

    return LayoutBuilder(
      builder: (context, constraints) {
        final sheetHeight = constraints.maxHeight;

        return SafeArea(
          top: false,
          child: SizedBox(
            height: sheetHeight,
            child: Column(
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

                // ---------- HERO (top ~50%) ----------
                SizedBox(
                  height: sheetHeight * 0.50,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ClipRRect(
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(16),
                          topRight: Radius.circular(16),
                        ),
                        child: image.isEmpty
                            ? Container(color: Colors.grey.shade200)
                            : CachedNetworkImage(
                                imageUrl: image,
                                fit: BoxFit.cover,
                                placeholder: (_, __) =>
                                    Container(color: Colors.grey.shade200),
                                errorWidget: (_, __, ___) => Container(
                                  color: Colors.grey.shade300,
                                  child: const Center(
                                    child: Icon(Icons.broken_image),
                                  ),
                                ),
                              ),
                      ),
                      // gradient overlay
                      Positioned.fill(
                        child: IgnorePointer(
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.transparent,
                                  Colors.transparent,
                                  Colors.black.withOpacity(0.10),
                                  Colors.black.withOpacity(0.55),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      // close
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
                      // name, age, gender, chips
                      Positioned(
  left: 14,
  right: 14,
  bottom: 12,
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _nameAgeWithGender(
        nameAge: age > 0 ? "$name, $age" : name,
        genderLabel: genderLabel,
        fontSize: 24,
        iconSize: 22,
      ),
      const SizedBox(height: 8),

      // Tags (attachment + love language) using normalized labels + centralized colors
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: (() {
          final _att = normalizeAttachment(attachment.trim());
          final _love = normalizeLoveLanguage(loveLanguage.trim());

          final List<Widget> list = [];
          if (_att.isNotEmpty) {
            list.add(_buildTag(_att, _attachmentPastel(_att)));
          }
          if (_love.isNotEmpty) {
            list.add(_buildTag(_love, _lovePastel(_love)));
          }
          return list;
        })(),
      ),
    ],
  ),
),

                    ],
                  ),
                ),

                // ---------- DETAILS ----------
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (bio.trim().isNotEmpty) ...[
                          const Text(
                            "About",
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            bio,
                            style: const TextStyle(fontSize: 14, height: 1.5),
                          ),
                          const SizedBox(height: 12),
                        ],
                      ],
                    ),
                  ),
                ),

                // ---------- ACTION BAR ----------
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
                    child: _isIncoming
                        // Liked You: Pass / Like back
                        ? Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: () {
                                    Navigator.pop(context);
                                    onPass?.call();
                                  },
                                  icon: const Icon(Icons.close),
                                  label: const Text("Pass"),
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 12),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    side: BorderSide(
                                      color: Colors.black.withOpacity(0.26),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: ElevatedButton.icon(
                                  onPressed: () {
                                    Navigator.pop(context);
                                    onLikeBack?.call();
                                  },
                                  icon: const Icon(Icons.favorite_border),
                                  label: const Text("Like back"),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppColors.primaryColor,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 12),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          )
                        // New: Start conversation / Unmatch
                        : Row(
                            children: [
                              Expanded(
                                child: ElevatedButton.icon(
                                  onPressed: () {
                                    Navigator.pop(context);
                                    onStartConversation?.call();
                                  },
                                  icon: Icon(
                                    _isChatting
                                        ? Icons.chat_bubble
                                        : Icons.chat_bubble_outline,
                                  ),
                                  label: Text(primaryText),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppColors.primaryColor,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 12),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: () {
                                    Navigator.pop(context);
                                    onUnmatch?.call();
                                  },
                                  icon: const Icon(Icons.block),
                                  label: const Text("Unmatch"),
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 12),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    side: BorderSide(
                                      color: Colors.red.withOpacity(0.35),
                                    ),
                                    foregroundColor: Colors.red,
                                  ),
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class MatchesScreen extends StatefulWidget {
  /// 0 = New, 1 = Liked You
  final int initialTab;

  const MatchesScreen({super.key, this.initialTab = 0});

  @override
  State<MatchesScreen> createState() => _MatchesScreenState();
}

class _MatchesScreenState extends State<MatchesScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  late final VoidCallback _animTick;
  int _current = 0;

  bool _loading = true;
  List<Map<String, dynamic>> _newMatches = [];
  List<Map<String, dynamic>> _likesYou = [];

  // 🔔 notifications
  final _notifsRepo = NotificationsRepository();
  late final Stream<int> _unreadStream; // ← now late + non-null

  // 🔒 NEW: blocks
  BlocksRepository? _blocks;

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void initState() {
    super.initState();
    _tab = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialTab, // ← honor deep links / notifs
    );
    _current = _tab.index;
    _tab.addListener(() {
      if (!_tab.indexIsChanging && mounted) {
        setState(() => _current = _tab.index);
      }
    });
    _animTick = () {
      if (mounted) setState(() {});
    };
    _tab.animation?.addListener(_animTick);

    // 🔔 start unread counter stream (auth-aware, follows sign-in/out)
    _unreadStream =
        FirebaseAuth.instance.authStateChanges().asyncExpand((user) async* {
      if (user == null) {
        yield 0;
      } else {
        yield* _notifsRepo.unreadCountStream(uid: user.uid);
      }
    });

    // 🔒 NEW: hook up Blocks repository after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _blocks = context.read<BlocksRepository>();
      if (!(_blocks!.isLoaded)) {
        try {
          await _blocks!.refresh();
        } catch (_) {}
      }
      _blocks!.addListener(_onBlocksChanged);
      // ensure current lists respect blocks if we loaded before blocks
      _applyBlockFilter();
    });

    _loadMatches();
  }

  @override
  void dispose() {
    _tab.animation?.removeListener(_animTick);
    _tab.dispose();
    _blocks?.removeListener(_onBlocksChanged); // NEW
    super.dispose();
  }

  // 🔒 NEW: filter helpers
  List<Map<String, dynamic>> _filterOutBlocked(List<Map<String, dynamic>> src) {
    final b = _blocks;
    if (b == null) return src;
    return src.where((m) {
      final uid = (m["other_uid"] ?? "").toString();
      if (uid.isEmpty) return false;
      return !b.isBlockedWith(uid);
    }).toList();
  }

  void _applyBlockFilter() {
    setState(() {
      _newMatches = _filterOutBlocked(_newMatches);
      _likesYou = _filterOutBlocked(_likesYou);
    });
  }

  void _onBlocksChanged() {
    if (!mounted) return;
    _applyBlockFilter();
  }

  Future<void> _loadMatches() async {
    setState(() => _loading = true);

    try {
      // Use the typed helper which wraps GET /matches
      final pairs = await ApiClient.listPairs(
          limit: 100); // [{match_id, other_uid, status, chat_id, ...}]

      // hydrate profiles in small concurrent batches (faster than serial loop)
      Future<Map<String, dynamic>> _fetchProfile(String uid) async {
        try {
          final p = await ApiClient.getJson("/profile/$uid");
          return {
            "name": (p["name"] ?? "Someone").toString(),
            "age": (p["age"] is int)
                ? p["age"] as int
                : int.tryParse("${p["age"] ?? ""}") ?? 0,
            "image": (p["image_url"] ?? p["image"] ?? "").toString(),
            "attachment":
                (p["attachment_style"] ?? p["attachment"] ?? "").toString(),
            "love_language":
                (p["love_primary"] ?? p["love_language"] ?? "").toString(),
            "bio": (p["bio"] ?? "").toString(),
            // 🔹 NEW: gender (personal_info.gender or root gender/sex if your API returns it)
            "gender":
                (p["gender"] ?? p["sex"] ?? p["personal_info"]?["gender"] ?? "")
                    .toString(),
          };
        } catch (_) {
          return {
            "name": "Someone",
            "age": 0,
            "image": "",
            "attachment": "",
            "love_language": "",
            "bio": "",
            "gender": "",
          };
        }
      }

      // limit concurrency so we don't spam the server
      Future<List<Map<String, dynamic>>> _hydrateAll() async {
        const int batch = 8;
        final out = <Map<String, dynamic>>[];
        for (var i = 0; i < pairs.length; i += batch) {
          final chunk = pairs.sublist(i, (i + batch).clamp(0, pairs.length));
          final futures = chunk.map((m) async {
            final other = (m["other_uid"] ?? "").toString();
            final prof = other.isEmpty
                ? <String, dynamic>{}
                : await _fetchProfile(other);
            return {
              "match_id": m["match_id"],
              "other_uid": other,
              "status": (m["status"] ?? "").toString(),
              "chat_id": (m["chat_id"] as String?),
              "name": (prof["name"] ?? "Someone").toString(),
              "age": prof["age"] is int ? prof["age"] as int : 0,
              "image": (prof["image"] ?? "").toString(),
              "attachment": (prof["attachment"] ?? "").toString(),
              "love_language": (prof["love_language"] ?? "").toString(),
              "bio": (prof["bio"] ?? "").toString(),
              // 🔹 NEW: normalized gender label
              "gender": _formatGenderLabel((prof["gender"] ?? "").toString()),
            };
          }).toList();
          out.addAll(await Future.wait(futures));
        }
        return out;
      }

      final hydrated = await _hydrateAll();

      // split by status. Backend may include: incoming_like, waiting_opener, chatting
      final newMatches = <Map<String, dynamic>>[];
      final likesYou = <Map<String, dynamic>>[];

      for (final m in hydrated) {
        final s = (m["status"] ?? "").toString();
        if (s == "incoming_like") {
          likesYou.add(m);
        } else if (s == "waiting_opener") {
          newMatches.add(m);
        } else {
          // chatting/ended not shown here (Messages has chatting)
        }
      }

      // 🔒 filter out blocked pairs before rendering
      final filteredNew = _filterOutBlocked(newMatches);
      final filteredLikes = _filterOutBlocked(likesYou);

      if (!mounted) return;
      setState(() {
        _newMatches = filteredNew;
        _likesYou = filteredLikes;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showSnack("Failed to load matches: $e");
    }
  }

  // ===== Navigation =====
  void _goDiscover() => Navigator.pushReplacement(
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

  void _goMessages() => Navigator.push(
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

  void _goNotifications() => Navigator.push(
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

  void _goProfile() => Navigator.push(
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

  // ===== Helpers =====
  void _removeNewMatchById(String matchId) {
    final idx = _newMatches.indexWhere((e) => e["match_id"] == matchId);
    if (idx >= 0) {
      setState(() {
        _newMatches.removeAt(idx);
      });
    }
  }

  void _removeEverywhereByMatchId(String matchId) {
    setState(() {
      _newMatches.removeWhere((e) => e["match_id"] == matchId);
      _likesYou.removeWhere((e) => e["match_id"] == matchId);
    });
  }

  // ===== Styled Confirm Dialog =====
  Future<bool?> _showStyledConfirmDialog({
    required String title,
    required String message,
    String cancelText = "Cancel",
    String confirmText = "Confirm",
    Color? confirmColor,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (dialogCtx) {
        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          elevation: 0,
          backgroundColor: Colors.transparent,
          child: Container(
            width: MediaQuery.of(dialogCtx).size.width * 0.8,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: _ConfirmDialogContent(
              title: title,
              message: message,
              cancelText: cancelText,
              confirmText: confirmText,
              confirmColor: confirmColor ?? AppColors.primaryColor,
            ),
          ),
        );
      },
    );
  }

  // ===== Actions =====
  Future<void> _startConversation({
    required String matchId,
    String? existingChatId,
  }) async {
    try {
      setState(() => _loading = true);
      final chatId =
          existingChatId ?? await ChatService.startChatViaBackend(matchId);
      if (!mounted) return;

      final result = await Navigator.push<bool>(
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

      if (result == true) {
        _removeNewMatchById(matchId);
      }

      await _loadMatches();
    } catch (e) {
      if (!mounted) return;
      _showSnack("Couldn’t start conversation: $e");
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // Decline an incoming like
  Future<void> _declineIncoming({
    required Map<String, dynamic> m,
    required int index,
  }) async {
    try {
      final res = await ApiClient.postJson(
        "/matches/respond",
        {"other_uid": m["other_uid"], "action": "decline"},
      );
      if (res.statusCode >= 200 && res.statusCode < 300) {
        if (!mounted) return;
        setState(() {
          _likesYou.removeAt(index);
        });
      } else {
        _showSnack("Decline failed (${res.statusCode})");
      }
    } catch (e) {
      if (!mounted) return;
      _showSnack("Decline error: $e");
    }
  }

  Future<void> _acceptIncoming({
    required Map<String, dynamic> m,
    required int index,
  }) async {
    try {
      final res = await ApiClient.postJson(
        "/matches/respond",
        {"other_uid": m["other_uid"], "action": "accept"},
      );

      if (res.statusCode >= 200 && res.statusCode < 300) {
        if (!mounted) return;
        setState(() {
          final moved = {...m, "status": "waiting_opener"};
          _likesYou.removeAt(index);
          _newMatches.insert(0, moved);
        });
        _tab.animateTo(0,
            duration: const Duration(milliseconds: 420),
            curve: Curves.easeOutCubic);
        _showSnack("It's a match! Start a conversation.");
        // Re-apply block filter in case the other user is blocked
        _applyBlockFilter();
      } else {
        if (!mounted) return;
        _showSnack("Accept failed (${res.statusCode})");
      }
    } catch (e) {
      if (!mounted) return;
      _showSnack("Accept error: $e");
    }
  }

  // Unmatch flow
  Future<void> _confirmAndUnmatch(Map<String, dynamic> m) async {
    final ok = await _showStyledConfirmDialog(
      title: "Unmatch",
      message:
          "You will no longer see or chat with ${m['name'] ?? 'this user'}.",
      confirmText: "Unmatch",
      confirmColor: AppColors.primaryColor,
    );

    if (ok != true) return;

    try {
      final res = await ApiClient.postJson("/matches/unmatch", {
        "match_id": m["match_id"],
        "other_uid": m["other_uid"],
      });

      if (res.statusCode >= 200 && res.statusCode < 300) {
        if (!mounted) return;
        _removeEverywhereByMatchId(m["match_id"] as String);
        _showSnack("Unmatched");
      } else {
        _showSnack("Unmatch failed (${res.statusCode})");
      }
    } catch (e) {
      _showSnack("Unmatch error: $e");
    }
  }

  // ----- Button styles -----
  ButtonStyle _pillFilledButton(BuildContext context, {Color? bg}) {
    return ElevatedButton.styleFrom(
      backgroundColor: bg ?? AppColors.primaryColor,
      foregroundColor: Colors.white,
      minimumSize: const Size.fromHeight(48),
      padding: const EdgeInsets.symmetric(vertical: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      elevation: 0,
    );
  }

  ButtonStyle _pillOutlinedButton(BuildContext context,
      {Color? fg, Color? border}) {
    final c = fg ?? Theme.of(context).colorScheme.onSurface.withOpacity(.85);
    return OutlinedButton.styleFrom(
      foregroundColor: c,
      side: BorderSide(color: border ?? c.withOpacity(.28), width: 1),
      minimumSize: const Size.fromHeight(48),
      padding: const EdgeInsets.symmetric(vertical: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    );
  }

  // ===== Quicksheet (auto height, no blank space below) =====
  Future<void> _showMatchQuickSheet({required Map<String, dynamic> m}) async {
    HapticFeedback.selectionClick();

    final String candidateUid = (m["other_uid"] ?? "").toString();
    if (candidateUid.isEmpty) {
      _showSnack("Missing candidate ID");
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      barrierColor: Colors.black.withOpacity(0.35),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      constraints: () {
        final mq = MediaQuery.of(context);
        final topPadding = mq.padding.top + kToolbarHeight; // status + AppBar
        final maxH = mq.size.height - topPadding - 12; // leave a small gap
        return BoxConstraints(maxHeight: maxH);
      }(),
      builder: (ctx) {
        return _MatchCardPreview(
          candidateUid: candidateUid,
          cacheManager: _fallbackCacheManager,
          status: (m["status"] ?? "")
              .toString(), // incoming_like / waiting_opener / chatting
          onStartConversation: () => _startConversation(
            matchId: m["match_id"],
            existingChatId:
                (m["status"] == "chatting") ? (m["chat_id"] as String?) : null,
          ),
          onUnmatch: () => _confirmAndUnmatch(m),
          onLikeBack: () async {
            final idx =
                _likesYou.indexWhere((x) => x["match_id"] == m["match_id"]);
            if (idx >= 0) {
              await _acceptIncoming(m: m, index: idx);
            } else {
              try {
                final res = await ApiClient.postJson(
                  "/matches/respond",
                  {"other_uid": m["other_uid"], "action": "accept"},
                );
                if (res.statusCode >= 200 && res.statusCode < 300) {
                  await _loadMatches();
                } else {
                  _showSnack("Accept failed (${res.statusCode})");
                }
              } catch (e) {
                _showSnack("Accept error: $e");
              }
            }
          },
          onPass: () async {
            final idx =
                _likesYou.indexWhere((x) => x["match_id"] == m["match_id"]);
            if (idx >= 0) {
              await _declineIncoming(m: m, index: idx);
            } else {
              try {
                final res = await ApiClient.postJson(
                  "/matches/respond",
                  {"other_uid": m["other_uid"], "action": "decline"},
                );
                if (res.statusCode >= 200 && res.statusCode < 300) {
                  await _loadMatches();
                } else {
                  _showSnack("Decline failed (${res.statusCode})");
                }
              } catch (e) {
                _showSnack("Decline error: $e");
              }
            }
          },
        );
      },
    );
  }

  // ===== UI =====
  @override
  Widget build(BuildContext context) {
    final likesCount = _likesYou.length;
    final newCount = _newMatches.length;
    final bottomPad = 24.0 + MediaQuery.of(context).viewPadding.bottom;

    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      appBar: _buildAppBar(),
      body: Column(
        children: [
          const SizedBox(height: 6),
          Container(
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: _SlidingCapsuleTabs(
              controller: _tab,
              leftLabel: "New${newCount > 0 ? " $newCount" : ""}",
              rightLabel: "Liked You${likesCount > 0 ? " •" : ""}",
              onLeftTap: () => _tab.animateTo(0,
                  duration: const Duration(milliseconds: 420),
                  curve: Curves.easeOutCubic),
              onRightTap: () => _tab.animateTo(1,
                  duration: const Duration(milliseconds: 420),
                  curve: Curves.easeOutCubic),
            ),
          ),
          Expanded(
            child: _loading
                ? ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: 4,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (_, __) => const _ShimmerCard(),
                  )
                : TabBarView(
                    controller: _tab,
                    physics: const BouncingScrollPhysics(),
                    children: [
                      // ===== NEW =====
                      _newMatches.isEmpty
                          ? _emptyState(
                              title: "No new matches yet",
                              subtitle:
                                  "Like people in Discover to create a match.",
                              cta: "Go to Discover",
                              onCta: _goDiscover,
                            )
                          : ListView.separated(
                              padding:
                                  EdgeInsets.fromLTRB(16, 14, 16, bottomPad),
                              itemCount: _newMatches.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 12),
                              itemBuilder: (_, i) {
                                final m = _newMatches[i];
                                return _NewCard(
                                  name: m["name"],
                                  age: m["age"],
                                  image: m["image"],
                                  bio: m["bio"],
                                  attachment: m["attachment"],
                                  loveLanguage: m["love_language"],
                                  genderLabel: (m["gender"] ?? "") as String,
                                  onStart: () => _startConversation(
                                    matchId: m["match_id"],
                                    existingChatId: m["status"] == "chatting"
                                        ? (m["chat_id"] as String?)
                                        : null,
                                  ),
                                  onMore: () => _showMatchQuickSheet(m: m),
                                  onLongPress: () => _showMatchQuickSheet(m: m),
                                );
                              },
                            ),
                      // ===== LIKED YOU =====
                      _likesYou.isEmpty
                          ? _emptyState(
                              title: "No likes yet",
                              subtitle:
                                  "People who liked you will appear here.",
                              cta: "Explore Discover",
                              onCta: _goDiscover,
                            )
                          : ListView.separated(
                              padding:
                                  EdgeInsets.fromLTRB(16, 14, 16, bottomPad),
                              itemCount: _likesYou.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 12),
                              itemBuilder: (_, i) {
                                final m = _likesYou[i];
                                return _LikesYouCard(
                                  name: m["name"],
                                  age: m["age"],
                                  image: m["image"],
                                  bio: m["bio"],
                                  attachment: m["attachment"],
                                  loveLanguage: m["love_language"],
                                  genderLabel: (m["gender"] ?? "") as String,
                                  onPass: () =>
                                      _declineIncoming(m: m, index: i),
                                  onLikeBack: () =>
                                      _acceptIncoming(m: m, index: i),
                                  onMore: () => _showMatchQuickSheet(m: m),
                                  onLongPress: () => _showMatchQuickSheet(m: m),
                                );
                              },
                            ),
                    ],
                  ),
          ),
        ],
      ),
      bottomNavigationBar: _bottomNav(),
    );
  }

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
                  "Matches",
                  style: TextStyle(
                    color: Colors.grey.shade600,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
            Row(
              children: [
                // 🔔 bell with unread dot
                StreamBuilder<int>(
                  stream: _unreadStream,
                  builder: (context, snap) {
                    final count = (snap.data ?? 0);
                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        IconButton(
                          onPressed: _goNotifications,
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
    );
  }

  // ===== Bottom nav =====
  Widget _bottomNav() {
    return SafeArea(
      top: false,
      bottom: true,
      child: BottomNavigationBar(
        currentIndex: 1, // 0: Discover, 1: Matches, 2: Messages, 3: Profile
        backgroundColor: Colors.white,
        elevation: 0,
        type: BottomNavigationBarType.fixed,
        selectedItemColor: AppColors.primaryColor,
        unselectedItemColor: Colors.grey,
        onTap: (i) {
          if (i == 0) _goDiscover();
          if (i == 1) {
            // already here
          }
          if (i == 2) _goMessages();
          if (i == 3) _goProfile();
        },
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.search), label: "Discover"),
          BottomNavigationBarItem(icon: Icon(Icons.favorite), label: "Matches"),
          BottomNavigationBarItem(
              icon: Icon(Icons.chat_bubble_outline), label: "Messages"),
          BottomNavigationBarItem(
              icon: Icon(Icons.person_outline), label: "Profile"),
        ],
      ),
    );
  }

  Widget _emptyState({
    required String title,
    required String subtitle,
    required String cta,
    required VoidCallback onCta,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.primaryColor.withOpacity(.12)),
              child: Icon(Icons.favorite_border,
                  size: 44, color: AppColors.primaryColor),
            ),
            const SizedBox(height: 16),
            Text(title,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.black54)),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: onCta,
              icon: const Icon(Icons.search),
              label: Text(cta),
              style: ElevatedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12)),
            ),
          ],
        ),
      ),
    );
  }
}

// =================== SLIDING CAPSULE TABS ===================
// (unchanged)
class _SlidingCapsuleTabs extends StatefulWidget {
  final TabController controller;
  final String leftLabel;
  final String rightLabel;
  final VoidCallback onLeftTap;
  final VoidCallback onRightTap;

  const _SlidingCapsuleTabs({
    required this.controller,
    required this.leftLabel,
    required this.rightLabel,
    required this.onLeftTap,
    required this.onRightTap,
  });

  @override
  State<_SlidingCapsuleTabs> createState() => _SlidingCapsuleTabsState();
}

class _SlidingCapsuleTabsState extends State<_SlidingCapsuleTabs> {
  late final VoidCallback _tick;
  bool _hoverLeft = false;
  bool _hoverRight = false;

  double get _rawT {
    final anim = widget.controller.animation;
    if (anim == null) return widget.controller.index.toDouble();
    return (widget.controller.index + widget.controller.offset).clamp(0.0, 1.0);
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
  void didUpdateWidget(covariant _SlidingCapsuleTabs old) {
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
    final Color primary = AppColors.primaryColor;
    final Color inactive = Colors.black.withOpacity(.70);
    final double t = Curves.easeInOutCubic.transform(_rawT);

    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 8.0;
        final width = constraints.maxWidth;
        final half = (width - gap) / 2;
        final sliderLeft = t * (half + gap);
        final pillRadius = BorderRadius.circular(999);

        final double leftSel = 1.0 - t;
        final double rightSel = t;

        final Color leftText = Color.lerp(inactive, Colors.white, leftSel)!;
        final Color rightText = Color.lerp(inactive, Colors.white, rightSel)!;

        return SizedBox(
          height: 44,
          child: Stack(
            children: [
              Positioned(
                left: sliderLeft,
                top: 0,
                width: half,
                height: 44,
                child: Container(
                  decoration: BoxDecoration(
                    color: primary,
                    borderRadius: pillRadius,
                  ),
                ),
              ),
              if (_hoverLeft)
                Positioned(
                  left: 0,
                  top: 0,
                  width: half,
                  height: 44,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 150),
                    opacity: widget.controller.index == 0 ? 0.0 : 1.0,
                    child: Container(
                      decoration: BoxDecoration(
                        color: primary.withOpacity(.10),
                        borderRadius: pillRadius,
                      ),
                    ),
                  ),
                ),
              if (_hoverRight)
                Positioned(
                  left: half + gap,
                  top: 0,
                  width: half,
                  height: 44,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 150),
                    opacity: widget.controller.index == 1 ? 0.0 : 1.0,
                    child: Container(
                      decoration: BoxDecoration(
                        color: primary.withOpacity(.10),
                        borderRadius: pillRadius,
                      ),
                    ),
                  ),
                ),
              Row(
                children: [
                  Expanded(
                    child: MouseRegion(
                      onEnter: (_) => setState(() => _hoverLeft = true),
                      onExit: (_) => setState(() => _hoverLeft = false),
                      child: Material(
                        type: MaterialType.transparency,
                        child: InkWell(
                          borderRadius: pillRadius,
                          splashColor: (leftSel > .5
                              ? Colors.white24
                              : primary.withOpacity(.14)),
                          highlightColor: Colors.transparent,
                          onTap: widget.onLeftTap,
                          child: Center(
                            child: AnimatedDefaultTextStyle(
                              duration: const Duration(milliseconds: 160),
                              curve: Curves.easeOutCubic,
                              style: TextStyle(
                                color: leftText,
                                fontWeight: leftSel > .5
                                    ? FontWeight.w700
                                    : FontWeight.w600,
                                fontSize: 16,
                              ),
                              child: Text(widget.leftLabel,
                                  textAlign: TextAlign.center),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: gap),
                  Expanded(
                    child: MouseRegion(
                      onEnter: (_) => setState(() => _hoverRight = true),
                      onExit: (_) => setState(() => _hoverRight = false),
                      child: Material(
                        type: MaterialType.transparency,
                        child: InkWell(
                          borderRadius: pillRadius,
                          splashColor: (rightSel > .5
                              ? Colors.white24
                              : primary.withOpacity(.14)),
                          highlightColor: Colors.transparent,
                          onTap: widget.onRightTap,
                          child: Center(
                            child: AnimatedDefaultTextStyle(
                              duration: const Duration(milliseconds: 160),
                              curve: Curves.easeOutCubic,
                              style: TextStyle(
                                color: rightText,
                                fontWeight: rightSel > .5
                                    ? FontWeight.w700
                                    : FontWeight.w600,
                                fontSize: 16,
                              ),
                              child: Text(widget.rightLabel,
                                  textAlign: TextAlign.center),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

// =================== CARDS ===================

// (unchanged below except for the imports at top and uses)

class _MiniDiscoverPhoto extends StatelessWidget {
  final String image;
  final double size;
  const _MiniDiscoverPhoto({required this.image, this.size = kPhotoSize});

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(12);

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(.18),
            blurRadius: 12,
            spreadRadius: 1,
            offset: const Offset(0, 6),
          ),
        ],
        border: Border.all(color: Colors.black12),
      ),
      clipBehavior: Clip.hardEdge,
      child: image.isEmpty
          ? _squareShimmer(size)
          : CachedNetworkImage(
              imageUrl: image,
              fit: BoxFit.cover,
              placeholder: (_, __) => _squareShimmer(size),
              errorWidget: (_, __, ___) => _squareShimmer(size),
              memCacheWidth: size.toInt() * 2,
              memCacheHeight: size.toInt() * 2,
            ),
    );
  }

  Widget _squareShimmer(double s) {
    return Shimmer(
      child: Container(
        width: s,
        height: s,
        color: Colors.grey.shade300,
      ),
    );
  }
}

class _buildTag extends StatelessWidget {
  final String text;
  final Color bg;
  final Color? textColor;
  const _buildTag(this.text, this.bg, {this.textColor});

  @override
  Widget build(BuildContext context) {
    if (text.trim().isEmpty) return const SizedBox.shrink();
    final Color _text = textColor ?? AppColors.black;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {}, // optional ripple
        borderRadius: BorderRadius.circular(999),
        splashColor: Colors.black12,
        highlightColor: Colors.black.withOpacity(0.06),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: bg, // pastel fill
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: darkenPastel(bg), width: 1.25),
          ),
          child: Text(
            text,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 11.5,
              color: _text,
            ),
          ),
        ),
      ),
    );
  }
}

class _BaseCard extends StatelessWidget {
  final String image;
  final String nameAge;
  final String bio;
  final String genderLabel;
  final List<Widget> chips;
  final List<Widget> bottomRow;
  final VoidCallback? onMore;
  final VoidCallback? onLongPress;

  const _BaseCard({
    required this.image,
    required this.nameAge,
    required this.bio,
    required this.genderLabel,
    required this.chips,
    required this.bottomRow,
    this.onMore,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(14);

    return Material(
      color: Colors.transparent,
      borderRadius: borderRadius,
      child: InkWell(
        borderRadius: borderRadius,
        onLongPress: onLongPress,
        child: Container(
          padding: const EdgeInsets.all(kCardPadding),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: borderRadius,
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withOpacity(.16),
                  blurRadius: 20,
                  spreadRadius: 2,
                  offset: const Offset(0, 8)),
              const BoxShadow(
                  color: Color(0x14000000),
                  blurRadius: 3,
                  offset: Offset(0, 1)),
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _MiniDiscoverPhoto(image: image, size: kPhotoSize),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(
                        child: _nameAgeWithGender(
                          nameAge: nameAge,
                          genderLabel: genderLabel,
                          fontSize: kTitleSize,
                          iconSize: 18,
                        ),
                      ),
                      if (onMore != null)
                        IconButton(
                          icon: const Icon(Icons.more_vert),
                          onPressed: onMore,
                          visualDensity:
                              const VisualDensity(horizontal: -2, vertical: -2),
                          padding: EdgeInsets.zero,
                          constraints:
                              const BoxConstraints(minWidth: 32, minHeight: 32),
                        ),
                    ]),
                    const SizedBox(height: 0),
                    Text(
                      bio,
                      textHeightBehavior: const TextHeightBehavior(
                          applyHeightToFirstAscent: false,
                          applyHeightToLastDescent: false),
                      style: TextStyle(
                          fontSize: kBioSize,
                          color: Colors.black87,
                          height: 1.05),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Wrap(spacing: 6, runSpacing: 6, children: chips),
                    const SizedBox(height: 10),
                    Row(children: bottomRow),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NewCard extends StatelessWidget {
  final String name;
  final int age;
  final String image;
  final String bio;
  final String attachment;
  final String loveLanguage;
  final String genderLabel;
  final VoidCallback onStart;
  final VoidCallback onMore;
  final VoidCallback? onLongPress;

  const _NewCard({
    required this.name,
    required this.age,
    required this.image,
    required this.bio,
    required this.attachment,
    required this.loveLanguage,
    required this.genderLabel,
    required this.onStart,
    required this.onMore,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return _BaseCard(
      image: image,
      nameAge: "$name, $age",
      bio: bio,
      genderLabel: genderLabel,
      chips: [
        if (attachment.isNotEmpty)
          ...() {
            final label = (attachment);
            return [_buildTag(label, _attachmentPastel(label))];
          }(),
        if (loveLanguage.isNotEmpty)
          ...() {
            final label = (loveLanguage);
            return [_buildTag(label, _lovePastel(label))];
          }(),
      ],
      bottomRow: [
        Expanded(
          child: ElevatedButton.icon(
            onPressed: onStart,
            icon: const Icon(Icons.chat_bubble_outline),
            label: const Text("Start conversation"),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primaryColor,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 10),
              minimumSize: const Size.fromHeight(40),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ),
      ],
      onMore: onMore,
      onLongPress: onLongPress,
    );
  }
}

class _LikesYouCard extends StatelessWidget {
  final String name;
  final int age;
  final String image;
  final String bio;
  final String attachment;
  final String loveLanguage;
  final String genderLabel;
  final VoidCallback onPass;
  final VoidCallback onLikeBack;
  final VoidCallback onMore;
  final VoidCallback? onLongPress;

  const _LikesYouCard({
    required this.name,
    required this.age,
    required this.image,
    required this.bio,
    required this.attachment,
    required this.loveLanguage,
    required this.genderLabel,
    required this.onPass,
    required this.onLikeBack,
    required this.onMore,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return _BaseCard(
      image: image,
      nameAge: "$name, $age",
      bio: bio,
      genderLabel: genderLabel,
      chips: [
        if (attachment.isNotEmpty)
          ...() {
            final label = (attachment);
            return [_buildTag(label, _attachmentPastel(label))];
          }(),
        if (loveLanguage.isNotEmpty)
          ...() {
            final label = (loveLanguage);
            return [_buildTag(label, _lovePastel(label))];
          }(),
      ],
      bottomRow: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: onPass,
            icon: const Icon(Icons.close),
            label: const Text("Pass"),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 10),
              minimumSize: const Size.fromHeight(40),
              side: BorderSide(color: Colors.black.withOpacity(.26)),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: ElevatedButton.icon(
            onPressed: onLikeBack,
            icon: const Icon(Icons.favorite_border),
            label: const Text("Like Back"),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primaryColor,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 10),
              minimumSize: const Size.fromHeight(40),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ),
      ],
      onMore: onMore,
      onLongPress: onLongPress,
    );
  }
}

class _MiniPreviewCard extends StatelessWidget {
  final String image;
  final String title; // name, age
  final String subtitle; // attachment · love_language (no gender text)
  final String genderLabel;
  const _MiniPreviewCard(
      {required this.image,
      required this.title,
      required this.subtitle,
      required this.genderLabel});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      padding: const EdgeInsets.all(10),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 64,
              height: 64,
              child: image.isNotEmpty
                  ? Image.network(image, fit: BoxFit.cover)
                  : Container(color: Colors.grey.shade300),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _nameAgeWithGender(
                  nameAge: title, // e.g., "Alex, 23"
                  genderLabel: genderLabel, // icon only, no text
                  fontSize: 15.5,
                  iconSize: 16,
                ),
                const SizedBox(height: 2),
                Text(subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.black.withOpacity(.7))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ShimmerCard extends StatelessWidget {
  const _ShimmerCard();
  @override
  Widget build(BuildContext context) {
    return Shimmer(
      child: Container(
        height: 130,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Padding(
              padding: const EdgeInsets.all(kCardPadding),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  width: kPhotoSize,
                  height: kPhotoSize,
                  color: Colors.grey.shade300,
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(
                  top: kCardPadding + 6,
                  right: kCardPadding,
                  bottom: kCardPadding,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      height: 16,
                      width: 140,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      height: 12,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      height: 12,
                      width: 160,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    const Spacer(),
                    Row(
                      children: [
                        Expanded(
                          child: Container(
                            height: 40,
                            decoration: BoxDecoration(
                              color: Colors.grey.shade300,
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Container(
                            height: 40,
                            decoration: BoxDecoration(
                              color: Colors.grey.shade300,
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ===== Shared confirm dialog content =====
class _ConfirmDialogContent extends StatelessWidget {
  final String title;
  final String message;
  final String cancelText;
  final String confirmText;
  final Color confirmColor;

  const _ConfirmDialogContent({
    required this.title,
    required this.message,
    required this.cancelText,
    required this.confirmText,
    required this.confirmColor,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            color: AppColors.primaryColor,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          message,
          style: TextStyle(
            color: Colors.grey.shade600,
            fontSize: 14,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: Container(
                height: 44,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: AppColors.primaryColor,
                    width: 1,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  style: TextButton.styleFrom(
                    backgroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: Text(
                    cancelText,
                    style: TextStyle(
                      color: AppColors.primaryColor,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: SizedBox(
                height: 44,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  style: TextButton.styleFrom(
                    backgroundColor: confirmColor,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: Text(
                    confirmText, // ← was "Unmatch"
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
