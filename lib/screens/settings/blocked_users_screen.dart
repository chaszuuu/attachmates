// lib/screens/settings/blocked_users_screen.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../repositories/blocks_repository.dart';
import '../../utils/constants.dart';

// ---- Layout
const double _kAvatar = 56;
const double _kHPad = 16;
const double _kVPad = 12;

// ===== Gender helpers =====
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
  final s = raw.trim().toLowerCase();
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
      return const Color.fromARGB(255, 37, 149, 247);
    case "Female":
      return AppColors.primaryColor;
    case "Non-binary":
      return const Color(0xFF7E57C2);
    case "Other":
      return Colors.teal;
    default:
      return Colors.black54;
  }
}

// ===== Unified label formatters (match other screens) =====
String _formatAttachmentLabel(String s) => _titleize(s);

String _formatLoveLabel(String s) {
  final t = _titleize(s);
  // keep small words lowercase so keys like "Words of affirmation" match your color map
  return t.replaceAllMapped(
    RegExp(r'\b(Of|And|For|To|In|On|With|A|An)\b'),
    (m) => m.group(0)!.toLowerCase(),
  );
}

// ===== Pastel color helpers (reuse the global maps from constants.dart) =====
Color _attachmentPastel(String raw) {
  final label = _formatAttachmentLabel(raw);
  return attachmentColors[label] ?? AppColors.lightPink;
}

Color _lovePastel(String raw) {
  final label = _formatLoveLabel(raw);
  return loveLanguageColors[label] ?? AppColors.lightPink;
}

Color _darkenPastel(Color pastel, [double factor = 0.8]) {
  final h = HSLColor.fromColor(pastel);
  return h.withLightness((h.lightness * factor).clamp(0.0, 1.0)).toColor();
}

/// Inline "Name, Age" + gender icon
Widget _nameAgeWithGender({
  required String nameAge,
  required String genderLabel,
  double fontSize = 16.0, // slightly smaller for tighter fit
  double iconSize = 16, // slightly smaller
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

class BlockedUsersScreen extends StatefulWidget {
  const BlockedUsersScreen({super.key});

  @override
  State<BlockedUsersScreen> createState() => _BlockedUsersScreenState();
}

class _BlockedUsersScreenState extends State<BlockedUsersScreen> {
  final Set<String> _busy = {};
  final _db = FirebaseFirestore.instance;

  Future<void> _ensureLoaded(BlocksRepository repo) async {
    if (!repo.isLoaded) {
      await repo.refresh();
    }
  }

  Future<_UserRowData> _fetchRow(String uid) async {
    final doc = await _db.collection('users').doc(uid).get();
    final root = doc.data() ?? const {};
    final Map<String, dynamic> pi =
        (root['personal_info'] as Map?)?.cast<String, dynamic>() ?? const {};

    final String firstName =
        (pi['first_name'] ?? pi['firstname'] ?? pi['given_name'] ?? '')
            .toString();
    final int? age = (pi['age'] is int)
        ? (pi['age'] as int)
        : int.tryParse('${pi['age'] ?? ''}'.trim());
    final String genderRaw = (pi['gender'] ?? pi['sex'] ?? '').toString();
    final String bio = (pi['bio'] ?? '').toString();

    final String attach = (root['attachment_style'] ??
            root['attachment'] ??
            pi['attachment_style'] ??
            pi['attachment'] ??
            '')
        .toString();

    final String loveLang = (root['love_language'] ??
            root['love_primary'] ??
            pi['love_language'] ??
            pi['love_primary'] ??
            '')
        .toString();

    final String avatar =
        (root['profile_image_url'] ?? root['image_url'] ?? '').toString();

    return _UserRowData(
      uid: uid,
      name: firstName.isNotEmpty ? firstName : uid,
      age: age ?? 0,
      genderLabel: _formatGenderLabel(genderRaw),
      avatarUrl: avatar,
      bio: bio,
      attachment: attach,
      loveLanguage: loveLang,
    );
  }

  Future<void> _showUnblockConfirmSheet({
    required String otherUid,
    required String? otherName,
    required BlocksRepository repo,
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
                          await _doUnblock(
                              repo: repo, otherUid: otherUid, otherName: name);
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

  Future<void> _doUnblock({
    required BlocksRepository repo,
    required String otherUid,
    required String? otherName,
  }) async {
    try {
      await repo.unblock(otherUid);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text((otherName?.isNotEmpty ?? false)
                ? "Unblocked $otherName"
                : "User unblocked")),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Unblock failed — $e")));
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<BlocksRepository>();
    final primary = AppColors.primaryColor;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.chevron_left, color: primary, size: 30),
          onPressed: () => Navigator.pop(context),
          splashRadius: 24,
        ),
        centerTitle: true,
        title: Text(
          "Blocked Users",
          style: TextStyle(
            color: primary,
            fontWeight: FontWeight.bold,
            fontSize: 20,
          ),
        ),
      ),
      body: FutureBuilder(
        future: _ensureLoaded(repo),
        builder: (context, snapshot) {
          final waiting = (!repo.isLoaded) ||
              snapshot.connectionState == ConnectionState.waiting;
          if (waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline,
                        size: 40, color: Colors.redAccent),
                    const SizedBox(height: 12),
                    Text(
                      'Couldn’t load blocked users.\n${snapshot.error}',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    ElevatedButton(
                      onPressed: () => setState(() {}),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            );
          }

          final blocked = repo.blocked;
          if (blocked.isEmpty) {
            return const Center(
              child: Text('You haven’t blocked anyone yet.',
                  style: TextStyle(color: Colors.black)),
            );
          }

          return ListView(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(_kHPad, 10, _kHPad, 6),
                child: Text(
                  "Blocked Accounts",
                  style: TextStyle(
                    color: Colors.grey.shade700,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
              ...blocked.map((uid) {
                final rowBusy = _busy.contains(uid);
                return FutureBuilder<_UserRowData>(
                  future: _fetchRow(uid),
                  builder: (context, snap) {
                    final loading =
                        snap.connectionState == ConnectionState.waiting;
                    final data = snap.data;
                    return InkWell(
                      onTap: () {},
                      splashColor: Colors.grey.withOpacity(0.15),
                      highlightColor: Colors.grey.shade100,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: _kHPad, vertical: _kVPad),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            _Avatar(
                                url: data?.avatarUrl ?? '', loading: loading),
                            const SizedBox(width: 12),
                            Expanded(
                              child: loading
                                  ? const _LoadingTexts()
                                  : Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        _nameAgeWithGender(
                                          nameAge: "${data!.name}, ${data.age}",
                                          genderLabel: data.genderLabel,
                                          fontSize: 16.0,
                                          iconSize: 16,
                                        ),
                                        const SizedBox(height: 4),
                                        if (data.bio.trim().isNotEmpty)
                                          ConstrainedBox(
                                            constraints: const BoxConstraints(
                                                maxWidth:
                                                    220), // prevent layout push
                                            child: Text(
                                              data.bio.length > 80
                                                  ? '${data.bio.substring(0, 80)}...'
                                                  : data
                                                      .bio, // manual fallback if very long
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              softWrap: false,
                                              style: TextStyle(
                                                color: Colors.grey.shade700,
                                                fontSize: 12.5,
                                                height: 1.15,
                                              ),
                                            ),
                                          ),
                                        const SizedBox(height: 6),
                                        Wrap(
                                          spacing: 4, // tighter spacing
                                          runSpacing: 3,
                                          children: [
                                            if (data.attachment
                                                .trim()
                                                .isNotEmpty)
                                              _buildTag.tiny(
                                                text: _formatAttachmentLabel(
                                                    data.attachment),
                                                bg: _attachmentPastel(
                                                    data.attachment),
                                              ),
                                            if (data.loveLanguage
                                                .trim()
                                                .isNotEmpty)
                                              _buildTag.tiny(
                                                text: _formatLoveLabel(
                                                    data.loveLanguage),
                                                bg: _lovePastel(
                                                    data.loveLanguage),
                                              ),
                                          ],
                                        ),
                                      ],
                                    ),
                            ),
                            const SizedBox(width: 10),
                            if (loading || rowBusy)
                              const SizedBox(
                                width: 24,
                                height: 24,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            else
                              OutlinedButton(
                                onPressed: () async {
                                  final name = data?.name;
                                  await _showUnblockConfirmSheet(
                                    otherUid: uid,
                                    otherName: name,
                                    repo: repo,
                                  );
                                },
                                style: OutlinedButton.styleFrom(
                                  side: const BorderSide(
                                      color: Colors.teal, width: 1.2),
                                  minimumSize: const Size(0, 32),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 8),
                                  foregroundColor: Colors.teal,
                                  textStyle: const TextStyle(fontSize: 12.5),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                                child: const Text('Unblock'),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              }).toList(),
            ],
          );
        },
      ),
    );
  }
}

// ===== Small widgets =====
class _Avatar extends StatelessWidget {
  final String url;
  final bool loading;
  const _Avatar({required this.url, required this.loading});

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(_kAvatar / 2);
    return ClipRRect(
      borderRadius: radius,
      child: SizedBox(
        width: _kAvatar,
        height: _kAvatar,
        child: loading
            ? Container(color: Colors.grey.shade200)
            : (url.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: url,
                    fit: BoxFit.cover,
                    placeholder: (_, __) =>
                        Container(color: Colors.grey.shade200),
                    errorWidget: (_, __, ___) => Container(
                      color: Colors.grey.shade200,
                      child: const Icon(Icons.person,
                          size: 28, color: Colors.grey),
                    ),
                  )
                : Container(
                    color: Colors.grey.shade200,
                    child:
                        const Icon(Icons.person, size: 28, color: Colors.grey),
                  )),
      ),
    );
  }
}

class _LoadingTexts extends StatelessWidget {
  const _LoadingTexts();
  @override
  Widget build(BuildContext context) {
    BoxDecoration pill() => BoxDecoration(
          color: Colors.grey.shade200,
          borderRadius: BorderRadius.circular(999),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(height: 14, width: 120, color: Colors.grey.shade200),
        const SizedBox(height: 6),
        Container(height: 10, width: 160, color: Colors.grey.shade200),
        const SizedBox(height: 6),
        Row(
          children: [
            Container(height: 18, width: 56, decoration: pill()),
            const SizedBox(width: 6),
            Container(height: 18, width: 74, decoration: pill()),
          ],
        ),
      ],
    );
  }
}

class _buildTag extends StatelessWidget {
  final String text;
  final EdgeInsets padding;
  final double fontSize;
  final Color bg; // pastel fill

  const _buildTag({
    required this.text,
    required this.bg,
    this.padding = const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    this.fontSize = 11.5,
  });

  const _buildTag.small({
    required String text,
    required Color bg,
  }) : this(
          text: text,
          bg: bg,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          fontSize: 10.5,
        );

  // 👇 NEW: extra-small chip for tighter screens & to prevent overflow
  const _buildTag.tiny({
    required String text,
    required Color bg,
  }) : this(
          text: text,
          bg: bg,
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          fontSize: 9.8,
        );

  @override
  Widget build(BuildContext context) {
    if (text.trim().isEmpty) return const SizedBox.shrink();

    final Color outline = _darkenPastel(bg); // ~20% darker
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: bg, // pastel fill
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: outline, width: 1.15), // slightly thinner
      ),
      child: Text(
        text,
        overflow: TextOverflow.ellipsis,
        softWrap: false,
        style: TextStyle(
          color: AppColors.black, // dark text on pastel
          fontWeight: FontWeight.w600,
          fontSize: fontSize,
          height: 1,
        ),
      ),
    );
  }
}

class _UserRowData {
  final String uid;
  final String name;
  final int age;
  final String genderLabel;
  final String avatarUrl;
  final String bio;
  final String attachment;
  final String loveLanguage;
  _UserRowData({
    required this.uid,
    required this.name,
    required this.age,
    required this.genderLabel,
    required this.avatarUrl,
    required this.bio,
    required this.attachment,
    required this.loveLanguage,
  });
}
