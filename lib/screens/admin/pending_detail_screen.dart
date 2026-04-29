// lib/screens/admin/admin_detail_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;
import 'package:intl/intl.dart';

import '../../repositories/admin_repository.dart';
import '../../utils/constants.dart'; // AppColors.primaryColor

class PendingDetailScreen extends StatefulWidget {
  final Map<String, dynamic> user;
  const PendingDetailScreen({super.key, required this.user});

  @override
  State<PendingDetailScreen> createState() => _PendingDetailScreenState();
}

class _PendingDetailScreenState extends State<PendingDetailScreen> {
  bool _working = false;
  bool _showFullBio = false;

  Color get primary => AppColors.primaryColor;

  // ---------- Safe getters ----------
  String _str(dynamic v) => v == null ? "" : v.toString();
  Map<String, dynamic> _map(dynamic v) =>
      (v is Map) ? Map<String, dynamic>.from(v) : <String, dynamic>{};
  List<String> _listStr(dynamic v) {
    if (v is List) {
      return v.map((e) => _str(e).trim()).where((s) => s.isNotEmpty).toList();
    }
    if (v is String) {
      return v
          .split(RegExp(r'[,\n]'))
          .map((e) => e.trim())
          .where((s) => s.isNotEmpty)
          .toList();
    }
    return const [];
  }

  // ---------- Titleize ----------
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

  // ---------- Gender helpers ----------
  String _formatGenderLabel(String s) {
    final raw = s.trim().toLowerCase();
    if (raw.isEmpty) return "";
    if ({"m", "male", "man", "boy"}.contains(raw)) return "Male";
    if ({"f", "female", "woman", "girl"}.contains(raw)) return "Female";
    if ({"non-binary", "nonbinary", "nb", "enby"}.contains(raw))
      return "Non-binary";
    if ({"others", "other", "prefer not to say", "prefer-not", "na", "n/a"}
        .contains(raw)) return "Other";
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
        return Colors.white70;
    }
  }

  static const double _genderIconSize = 30.0;

  // ---------- DOB coercion (copied pattern from EditProfileScreen) ----------
  DateTime? _coerceDob(dynamic raw) {
    if (raw == null) return null;

    if (raw is Timestamp) return raw.toDate();

    if (raw is int) {
      final isMs = raw > 2000000000;
      return DateTime.fromMillisecondsSinceEpoch(isMs ? raw : raw * 1000);
    }

    if (raw is Map && raw['seconds'] is int) {
      return DateTime.fromMillisecondsSinceEpoch(
          (raw['seconds'] as int) * 1000);
    }

    if (raw is String) {
      final s = raw.trim();
      if (s.isEmpty) return null;
      try {
        final dt = DateTime.parse(s);
        return DateTime(dt.year, dt.month, dt.day);
      } catch (_) {
        try {
          final parts = s.split("-");
          if (parts.length == 3) {
            final y = int.parse(parts[0]);
            final m = int.parse(parts[1]);
            final d = int.parse(parts[2]);
            return DateTime(y, m, d);
          }
        } catch (_) {}
      }
    }
    return null;
  }

  int _calculateAge(DateTime dob) {
    final now = DateTime.now();
    int age = now.year - dob.year;
    final hadBirthday = (now.month > dob.month) ||
        (now.month == dob.month && now.day >= dob.day);
    if (!hadBirthday) age--;
    return age;
  }

  // ---------- Actions ----------
  Future<void> _approve() async {
    if (_working) return;
    setState(() => _working = true);
    try {
      await AdminRepository.approve(widget.user['uid'] as String);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Approved')));
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Approve failed: $e')));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _reject() async {
    if (_working) return;
    final primary = AppColors.primaryColor;

    String? reason;
    final controller = TextEditingController();

    // Common rejection reasons
    final reasons = [
      "Blurry or unreadable ID photo",
      "Selfie does not match ID photo",
      "Incomplete or missing information",
      "Fake or invalid document",
      "Suspicious or inappropriate content",
      "Others",
    ];

    int? selectedIndex;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final h = MediaQuery.of(ctx).size.height;
        final sheetFactor = h < 700 ? 0.55 : 0.50;

        return StatefulBuilder(
          builder: (context, setModalState) {
            return AnimatedPadding(
              duration: const Duration(milliseconds: 200),
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom,
              ),
              child: FractionallySizedBox(
                heightFactor: sheetFactor,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(24)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.12),
                        blurRadius: 24,
                        offset: const Offset(0, -8),
                      ),
                    ],
                  ),
                  child: SafeArea(
                    top: false,
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // drag handle
                          Center(
                            child: Container(
                              width: 44,
                              height: 4,
                              margin: const EdgeInsets.only(bottom: 14),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.08),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),

                          // header
                          Row(
                            children: [
                              Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: Colors.red.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                alignment: Alignment.center,
                                child: const Icon(Icons.cancel,
                                    color: Colors.red, size: 22),
                              ),
                              const SizedBox(width: 12),
                              const Expanded(
                                child: Text(
                                  'Reject Verification',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.black87,
                                  ),
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 12),

                          const Text(
                            'Select a reason for rejection. This helps the user fix and resubmit their verification.',
                            textAlign: TextAlign.justify,
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.black87,
                              height: 1.35,
                            ),
                          ),

                          const SizedBox(height: 14),

                          // Radio options
                          Expanded(
                            child: ListView.separated(
                              itemCount: reasons.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 6),
                              itemBuilder: (ctx, i) {
                                final isSelected = selectedIndex == i;
                                return InkWell(
                                  onTap: () {
                                    setModalState(() {
                                      selectedIndex = i;
                                    });
                                  },
                                  borderRadius: BorderRadius.circular(8),
                                  child: Row(
                                    children: [
                                      Radio<int>(
                                        value: i,
                                        groupValue: selectedIndex,
                                        activeColor: primary,
                                        onChanged: (v) => setModalState(
                                            () => selectedIndex = v),
                                      ),
                                      Expanded(
                                        child: Text(
                                          reasons[i],
                                          style: const TextStyle(
                                              fontSize: 14,
                                              color: Colors.black87),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),

                          // Others input
                          if (selectedIndex == reasons.length - 1)
                            Padding(
                              padding:
                                  const EdgeInsets.only(top: 6, bottom: 12),
                              child: TextField(
                                controller: controller,
                                maxLines: 3,
                                minLines: 1,
                                decoration: InputDecoration(
                                  hintText: "Enter custom reason",
                                  filled: true,
                                  fillColor: Colors.grey.shade50,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    borderSide:
                                        BorderSide(color: Colors.grey.shade300),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    borderSide:
                                        BorderSide(color: primary, width: 1.5),
                                  ),
                                ),
                              ),
                            ),

                          // Buttons
                          SafeArea(
                            top: false,
                            bottom: true,
                            minimum: const EdgeInsets.only(bottom: 24),
                            child: Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: () => Navigator.of(ctx).pop(),
                                    style: OutlinedButton.styleFrom(
                                      side: BorderSide(
                                          color: Colors.grey.shade400),
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 14),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                    ),
                                    child: const Text('Cancel'),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: ElevatedButton(
                                    onPressed: () {
                                      if (selectedIndex == null) return;

                                      final selected = reasons[selectedIndex!];
                                      final custom = controller.text.trim();

                                      if (selected == "Others") {
                                        if (custom.length < 3) return;
                                        reason = custom;
                                      } else {
                                        reason = selected;
                                      }

                                      Navigator.of(ctx).pop();
                                    },
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.red.shade700,
                                      foregroundColor: Colors.white,
                                      elevation: 0,
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 14),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                    ),
                                    child: const Text('Reject'),
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
              ),
            );
          },
        );
      },
    );

    if (reason == null || reason!.trim().length < 3) return;

    setState(() => _working = true);
    try {
      await AdminRepository.reject(widget.user['uid'] as String, reason!);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Rejected')));
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Reject failed: $e')));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  static String _two(int n) => n < 10 ? '0$n' : '$n';

  String _formatSubmittedAt(Map<String, dynamic> u) {
    final iv = _map(u['identity_verification']);
    final raw = iv['submitted_at'] ?? u['verificationSubmittedAt'];
    if (raw == null) return '';
    if (raw is Timestamp) {
      final dt = raw.toDate();
      return '${dt.year}-${_two(dt.month)}-${_two(dt.day)} ${_two(dt.hour)}:${_two(dt.minute)}';
    }
    final s = _str(raw);
    final dt = DateTime.tryParse(s);
    return dt != null
        ? '${dt.year}-${_two(dt.month)}-${_two(dt.day)} ${_two(dt.hour)}:${_two(dt.minute)}'
        : s;
  }

  // ---------- Extract user fields (now matches EditProfile logic for dob/age) ----------
  Map<String, dynamic> _extractPI(Map<String, dynamic> u) {
    final pi = _map(u['personal_info']);

    final first = _str(pi['first_name'] ?? u['first_name']).trim();
    final last = _str(pi['last_name'] ?? u['last_name']).trim();
    final bio = _str(pi['bio'] ?? u['bio']).trim();

    final genderRaw = _str(pi['gender'] ?? u['gender']);
    final gender = _formatGenderLabel(genderRaw);

    // DOB & Age (same approach as EditProfileScreen)
    final dobRaw = pi.containsKey('dob') ? pi['dob'] : u['dob'];
    final dt = _coerceDob(dobRaw);

    // Show dob_display if present; else derive from dob
    String dobDisplay = _str(pi['dob_display']);
    if (dobDisplay.isEmpty && dt != null) {
      dobDisplay = DateFormat('MM/dd/yyyy').format(dt);
    }

    int? age;
    if (pi['age'] is int) {
      age = pi['age'] as int;
    } else if (dt != null) {
      age = _calculateAge(dt);
    } else if (u['age'] is int) {
      age = u['age'] as int;
    }

    final pfp = _str(
      pi['profile_image_url'] ?? u['profile_image_url'] ?? u['profileImageUrl'],
    );

    final interests = _listStr(pi['interests'] ?? u['interests']);

    return {
      'first_name': first,
      'last_name': last,
      'bio': bio,
      'gender': gender,
      'dob_display': dobDisplay,
      'age': age,
      'profile_image_url': pfp,
      'interests': interests,
    };
  }

  Future<void> _copyToClipboard(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Copied to clipboard')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Copy failed: $e')));
    }
  }

  // ---------- Pastel chips ----------
  final List<Color> _pastels = const [
    Color(0xFFFFE4EC), // pink-100
    Color(0xFFEDE7F6), // deep-purple-50
    Color(0xFFE3F2FD), // blue-50
    Color(0xFFE0F7FA), // cyan-50
    Color(0xFFE8F5E9), // green-50
    Color(0xFFFFF8E1), // amber-50
    Color(0xFFF3E5F5), // purple-50
    Color(0xFFFFF3E0), // orange-50
  ];
  final List<Color> _pastelBorders = const [
    Color(0xFFF8BBD0), // pink-200
    Color(0xFFD1C4E9), // deep-purple-100
    Color(0xFFBBDEFB), // blue-100
    Color(0xFFB2EBF2), // cyan-100
    Color(0xFFC8E6C9), // green-100
    Color(0xFFFFECB3), // amber-100
    Color(0xFFE1BEE7), // purple-100
    Color(0xFFFFE0B2), // orange-100
  ];
  int _hash(String s) {
    var h = 0;
    for (final ch in s.codeUnits) {
      h = (h * 31 + ch) & 0x7fffffff;
    }
    return h;
  }

  List<Widget> _buildInterests(List<String> interests) {
    if (interests.isEmpty) return const [];
    return [
      const Divider(height: 24),
      const Text('Interests', style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: interests.map((s) {
          final idx = _hash(s) % _pastels.length;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: _pastels[idx],
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: _pastelBorders[idx]),
            ),
            child: Text(s,
                style: const TextStyle(fontSize: 12, color: Colors.black87)),
          );
        }).toList(),
      ),
    ];
  }

  Widget _sectionHeader(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Text(title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      );

  Widget _labelAndValue(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
        const SizedBox(height: 4),
        Text(
          value.isEmpty ? '—' : value,
          style: const TextStyle(fontWeight: FontWeight.w400, fontSize: 14),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  // ---------- Profile card ----------
  Widget _profileCard(Map<String, String> media) {
    final u = widget.user;
    final uid = _str(u['uid']);
    final pi = _extractPI(u);
    final submittedAt = _formatSubmittedAt(u);

    final avatarUrl = _str(pi['profile_image_url']).isNotEmpty
        ? _str(pi['profile_image_url'])
        : _str(media['selfie_url']);

    final genderLabel = _str(pi['gender']);
    final gColor = _genderColor(genderLabel);
    final gIcon = _genderIcon(genderLabel);

    final first = _str(pi['first_name']);
    final last = _str(pi['last_name']);
    final dobDisplay = _str(pi['dob_display']);
    final bio = _str(pi['bio']).trim();
    final int? age = pi['age'] is int ? (pi['age'] as int) : null;

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      surfaceTintColor: Colors.white,
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top row — gender sits TOP-RIGHT
            Row(
              crossAxisAlignment: CrossAxisAlignment.start, // ⬅️ top-align
              children: [
                // Avatar
                InkWell(
                  onTap: avatarUrl.isEmpty
                      ? null
                      : () =>
                          _showImageViewer(context, avatarUrl, 'Profile Photo'),
                  borderRadius: BorderRadius.circular(56),
                  child: Container(
                    width: 112,
                    height: 112,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: primary, width: 3),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(56),
                      child: avatarUrl.isNotEmpty
                          ? Image.network(
                              avatarUrl,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Image.asset(
                                  'assets/default_pfp.png',
                                  fit: BoxFit.cover),
                            )
                          : Image.asset('assets/default_pfp.png',
                              fit: BoxFit.cover),
                    ),
                  ),
                ),
                const SizedBox(width: 14),

                // Names column
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _labelAndValue('First Name', first),
                      const SizedBox(height: 10),
                      _labelAndValue('Last Name', last),
                    ],
                  ),
                ),

                const SizedBox(width: 8),

                // ⬇️ Gender column is now at the very right, top-aligned
                Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Icon(gIcon, color: gColor, size: _genderIconSize),
                    const SizedBox(height: 4),
                    Text(
                      genderLabel.isEmpty ? '—' : genderLabel,
                      style: TextStyle(
                          fontSize: 12,
                          color: gColor,
                          fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ],
            ),

            const SizedBox(height: 12),

            // UID row (unchanged)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('UID',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        uid.isEmpty ? '—' : uid,
                        style: const TextStyle(
                            fontWeight: FontWeight.w400, fontSize: 14),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    InkWell(
                      onTap: uid.isEmpty ? null : () => _copyToClipboard(uid),
                      borderRadius: BorderRadius.circular(6),
                      child: Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Icon(Icons.copy,
                            size: 16, color: Colors.grey.shade700),
                      ),
                    ),
                  ],
                ),
              ],
            ),

            const SizedBox(height: 12),

            if (submittedAt.isNotEmpty)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _chip(submittedAt,
                      icon: Icons.schedule, color: Colors.black87),
                ],
              ),

            // Birthday & Age — no weekday, "years old"
            if (dobDisplay.isNotEmpty || age != null) ...[
              const Divider(height: 24),
              const Text('Birthday & Age',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text(
                [
                  if (dobDisplay.isNotEmpty) dobDisplay,
                  if (age != null) '$age years old',
                ].where((s) => s.isNotEmpty).join(' • '),
                style: const TextStyle(fontSize: 14),
              ),
            ],

            // Bio
            if (bio.isNotEmpty) ...[
              const Divider(height: 24),
              const Text('Bio', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text(!_showFullBio && bio.length > 160
                  ? '${bio.substring(0, 160)}…'
                  : bio),
              if (bio.length > 160)
                TextButton(
                  onPressed: () => setState(() => _showFullBio = !_showFullBio),
                  child: Text(_showFullBio ? 'Show less' : 'Show more'),
                ),
            ],

            // Interests
            ..._buildInterests(_listStr(pi['interests'])),
          ],
        ),
      ),
    );
  }

  // ---------- Chip ----------
  Widget _chip(String label, {IconData? icon, Color? color}) {
    final fg = color ?? Colors.black87;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: (color ?? primary).withOpacity(.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: fg),
            const SizedBox(width: 6),
          ],
          Text(label, style: TextStyle(fontSize: 12, color: fg)),
        ],
      ),
    );
  }

  // ---------- Uploaded Media ----------
  Widget _mediaSection(String selfie, String front, String back) {
    final items = [
      _MediaItem(url: selfie, label: 'Selfie'),
      _MediaItem(url: front, label: 'ID – Front'),
      _MediaItem(url: back, label: 'ID – Back'),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader('Uploaded Media'),
        Card(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          surfaceTintColor: Colors.white,
          color: Colors.white,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
            child: GridView.builder(
              physics: const NeverScrollableScrollPhysics(),
              shrinkWrap: true,
              itemCount: items.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 3 / 4,
              ),
              itemBuilder: (_, i) =>
                  _MediaTile(item: items[i], all: items, initialIndex: i),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _showImageViewer(
      BuildContext context, String url, String label) {
    return showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(.85),
      builder: (_) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(12),
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                clipBehavior: Clip.none,
                minScale: .5,
                maxScale: 6,
                child: Image.network(
                  url,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Center(
                      child: Icon(Icons.broken_image,
                          color: Colors.white70, size: 42)),
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                style: IconButton.styleFrom(backgroundColor: Colors.white12),
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close, color: Colors.white),
              ),
            ),
            Positioned(
              left: 12,
              bottom: 12,
              child: Text(label, style: const TextStyle(color: Colors.white70)),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- Build ----------
  @override
  Widget build(BuildContext context) {
    final u = widget.user;
    final uid = _str(u['uid']);

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.chevron_left, color: primary, size: 30),
          onPressed: _working ? null : () => Navigator.pop(context),
        ),
        centerTitle: true,
        title: Text(
          'Verification Review',
          style: TextStyle(
              color: primary, fontWeight: FontWeight.bold, fontSize: 20),
        ),
      ),
      body: FutureBuilder<Map<String, String>>(
        future: AdminRepository.fetchVerificationMedia(uid),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final media = snap.data ?? const {};
          final selfie = _str(media['selfie_url']);
          final idFront = _str(media['front_id_url']);
          final idBack = _str(media['back_id_url']);

          return Stack(
            children: [
              ListView(
                padding: const EdgeInsets.fromLTRB(0, 0, 0, 92),
                children: [
                  _profileCard(media),
                  _mediaSection(selfie, idFront, idBack),
                ],
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: SafeArea(
                  minimum: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _working ? null : _approve,
                          icon: const Icon(Icons.check_circle),
                          label: const Text('Approve'),
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.green,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _working ? null : _reject,
                          icon: const Icon(Icons.cancel),
                          label: const Text('Reject'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.red.shade700,
                            side: BorderSide(color: Colors.red.shade400),
                            padding: const EdgeInsets.symmetric(vertical: 14),
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
    );
  }
}

// ---------- Media tiles + carousel ----------
class _MediaItem {
  final String url;
  final String label;
  const _MediaItem({required this.url, required this.label});
}

class _MediaTile extends StatelessWidget {
  final _MediaItem item;
  final List<_MediaItem> all;
  final int initialIndex;
  const _MediaTile(
      {required this.item, required this.all, required this.initialIndex});

  @override
  Widget build(BuildContext context) {
    final has = item.url.isNotEmpty;
    return GestureDetector(
      onTap: has ? () => _showCarousel(context, all, initialIndex) : null,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          children: [
            Positioned.fill(
              child: Container(
                color: Colors.white,
                child: has
                    ? Image.network(
                        item.url,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const Center(
                            child: Icon(Icons.broken_image, size: 28)),
                      )
                    : const Center(child: Text('No image')),
              ),
            ),
            Positioned(
              left: 8,
              bottom: 8,
              right: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(.45),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Future<void> _showCarousel(
      BuildContext context, List<_MediaItem> items, int startIndex) {
    final controller = PageController(initialPage: startIndex);
    return showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(.85),
      builder: (_) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(12),
        child: Stack(
          children: [
            Positioned.fill(
              child: PageView.builder(
                controller: controller,
                itemCount: items.length,
                itemBuilder: (_, i) {
                  final it = items[i];
                  return InteractiveViewer(
                    clipBehavior: Clip.none,
                    minScale: .5,
                    maxScale: 6,
                    child: it.url.isNotEmpty
                        ? Image.network(
                            it.url,
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) => const Center(
                              child: Icon(Icons.broken_image,
                                  color: Colors.white70, size: 42),
                            ),
                          )
                        : const Center(
                            child: Text('No image',
                                style: TextStyle(color: Colors.white70))),
                  );
                },
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                style: IconButton.styleFrom(backgroundColor: Colors.white12),
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close, color: Colors.white),
              ),
            ),
            _CarouselPagerLabel(items: items, controller: controller),
          ],
        ),
      ),
    );
  }
}

class _CarouselPagerLabel extends StatefulWidget {
  final List<_MediaItem> items;
  final PageController controller;
  const _CarouselPagerLabel({required this.items, required this.controller});

  @override
  State<_CarouselPagerLabel> createState() => _CarouselPagerLabelState();
}

class _CarouselPagerLabelState extends State<_CarouselPagerLabel> {
  int _idx = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onScroll);
  }

  void _onScroll() {
    final p = widget.controller.page;
    if (p == null) return;
    final i = p.round();
    if (i != _idx) setState(() => _idx = i);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onScroll);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.items[_idx].label;
    return Positioned(
      left: 12,
      bottom: 12,
      right: 12,
      child: Align(
        alignment: Alignment.bottomLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
              color: Colors.black54, borderRadius: BorderRadius.circular(8)),
          child: Text(label, style: const TextStyle(color: Colors.white70)),
        ),
      ),
    );
  }
}
