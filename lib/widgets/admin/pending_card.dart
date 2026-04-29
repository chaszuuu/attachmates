import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;
import '../../utils/constants.dart'; // AppColors.primaryColor

class PendingCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final VoidCallback onTap;

  const PendingCard({
    super.key,
    required this.item,
    required this.onTap,
  });

  // ---------- utils ----------
  String _asString(dynamic v) => v == null ? '' : v.toString();

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

  // ===== Gender helpers (match admin_detail_screen.dart) =====
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

  // ---------- field builders ----------
  String _buildName(Map<String, dynamic> m) {
    final pi =
        (m['personal_info'] as Map?)?.cast<String, dynamic>() ?? const {};
    final first = _asString(pi['first_name']).trim();
    final last = _asString(pi['last_name']).trim();

    if (first.isNotEmpty || last.isNotEmpty) {
      return [first, last].where((s) => s.isNotEmpty).join(' ');
    }
    final dn = _asString(m['displayName']).trim();
    final dns = _asString(m['display_name']).trim();
    if (dn.isNotEmpty) return dn;
    if (dns.isNotEmpty) return dns;
    return _asString(m['uid']);
  }

  String _gender(Map<String, dynamic> m) {
    final pi =
        (m['personal_info'] as Map?)?.cast<String, dynamic>() ?? const {};
    final g = _asString(pi['gender']).trim();
    return g.isNotEmpty ? g : _asString(m['gender']).trim();
  }

  String _profileImageUrl(Map<String, dynamic> m) {
    final pi =
        (m['personal_info'] as Map?)?.cast<String, dynamic>() ?? const {};
    final root = _asString(pi['profile_image_url']);
    if (root.isNotEmpty) return root;
    return _asString(m['profile_image_url']);
  }

  String _formatSubmittedAt(Map<String, dynamic> m) {
    final iv = (m['identity_verification'] as Map?)?.cast<String, dynamic>() ??
        const {};
    final raw = iv['submitted_at'] ?? m['verificationSubmittedAt'];
    if (raw == null) return '';
    if (raw is Timestamp) {
      final dt = raw.toDate();
      return '${_two(dt.month)}/${_two(dt.day)}/${dt.year}';
    }
    final s = _asString(raw).trim();
    if (s.isEmpty) return '';
    final dt = DateTime.tryParse(s);
    if (dt != null) return '${_two(dt.month)}/${_two(dt.day)}/${dt.year}';
    return s;
  }

  static String _two(int n) => n < 10 ? '0$n' : '$n';

  // ---------- build ----------
  @override
  Widget build(BuildContext context) {
    final name = _buildName(item);
    final genderRaw = _gender(item);
    final genderLabel = _formatGenderLabel(genderRaw);
    final genderColor = _genderColor(genderLabel);
    final genderIc = _genderIcon(genderLabel);

    final age = _asString(item['age']).trim();
    final submittedAt = _formatSubmittedAt(item);
    final avatarUrl = _profileImageUrl(item);

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Material(
        color: Colors.white,
        child: InkWell(
          onTap: onTap,
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: Colors.grey.shade300, width: 1),
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            child: Row(
              children: [
                // Avatar
                ClipRRect(
                  borderRadius: BorderRadius.circular(40),
                  child: Container(
                    width: 60,
                    height: 60,
                    color: Colors.grey.shade200,
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
                const SizedBox(width: 14),

                // Info column
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name.isEmpty ? _asString(item['uid']) : name,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: Colors.black87,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          if (genderLabel.isNotEmpty)
                            _filledBadge(
                              genderLabel,
                              icon: genderIc,
                              color: genderColor,
                            ),
                          if (age.isNotEmpty)
                            _filledBadge(
                              '$age yrs',
                              icon: Icons.cake_outlined,
                              color: Colors.grey.shade700,
                            ),
                          if (submittedAt.isNotEmpty)
                            _filledBadge(
                              'Submitted $submittedAt',
                              icon: Icons.schedule,
                              color: Colors.grey.shade700,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),

                const SizedBox(width: 8),
                Icon(Icons.chevron_right, color: Colors.grey.shade500),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ===== Filled color badge (white text) =====
  Widget _filledBadge(String text, {IconData? icon, required Color color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: Colors.white),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: const TextStyle(fontSize: 12, color: Colors.white),
          ),
        ],
      ),
    );
  }
}
