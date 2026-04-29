// lib/utils/constants.dart
import 'package:flutter/material.dart';

class AppColors {
  static const Color primaryColor = Color(0xFFB5276A);
  static const Color lightPink = Color(0xFFFAE3F0);
  static const Color softRose = Color(0xFFF06292);
  static const Color white = Colors.white;
  static const Color black = Colors.black87;
  static const Color grey = Colors.grey;

  // Material grey shades
  static const Color grey300 = Color(0xFFE0E0E0); // light grey
  static const Color grey400 = Color(0xFFBDBDBD); // medium-light grey
}

class AppGradients {
  static const LinearGradient primaryGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      AppColors.lightPink,
      AppColors.primaryColor,
    ],
  );
}

// ───────────────────────────────────────────────
// text helpers (shared normalizers)
// ───────────────────────────────────────────────
String _titleize(String s) {
  final clean = s.replaceAll(RegExp(r'[_\-]+'), ' ').trim();
  if (clean.isEmpty) return "";
  final small = {'of','and','for','to','in','on','with','a','an'};
  return clean
      .split(RegExp(r'\s+'))
      .asMap()
      .entries
      .map((e) {
        final w = e.value.toLowerCase();
        final firstOrLast = e.key == 0 || e.key == clean.split(RegExp(r'\s+')).length - 1;
        if (!firstOrLast && small.contains(w)) return w; // keep small words lowercase
        return "${w[0].toUpperCase()}${w.substring(1)}";
      })
      .join(" ");
}

// ───────────────────────────────────────────────
// 🩷 Attachment Styles
// ───────────────────────────────────────────────
const List<String> kAttachmentStyles = [
  'Secure',
  'Anxious',
  'Avoidant',
  'Disorganized',
];

const Map<String, Color> attachmentColors = {
  'Secure': Color(0xFFB2E2B2),      // Pastel Green – stability, calm
  'Anxious': Color(0xFFF7B2B2),     // Soft Rose Red – warmth, vulnerability
  'Avoidant': Color(0xFFB2D7F7),    // Light Blue – distance, composure
  'Disorganized': Color(0xFFD3B2F7),// Lavender – complexity, introspection
};

String normalizeAttachment(String? raw) {
  final s = (raw ?? "").trim();
  if (s.isEmpty) return "";
  final t = _titleize(s);
  // handle common synonyms/typos if any arise later
  switch (t.toLowerCase()) {
    case 'fearful-avoidant': // alias
      return 'Disorganized';
    default:
      return kAttachmentStyles.contains(t) ? t : t; // fall back to titleized
  }
}

Color attachmentColorFor(String? label) =>
    attachmentColors[normalizeAttachment(label)] ?? AppColors.lightPink;

// ───────────────────────────────────────────────
// 💞 Love Languages
// ───────────────────────────────────────────────
const List<String> kLoveLanguages = [
  'Words of Affirmation',
  'Acts of Service',
  'Receiving Gifts',
  'Quality Time',
  'Physical Touch',
];

const Map<String, Color> loveLanguageColors = {
  'Words of Affirmation': Color(0xFFFFD59E), // Soft Amber – expressive warmth
  'Acts of Service': Color(0xFFB2EBF2),      // Pastel Cyan – helpful, supportive
  'Receiving Gifts': Color(0xFFF7B2D9),      // Light Magenta – generosity
  'Quality Time': Color(0xFFCBC2F2),         // Gentle Indigo – presence
  'Physical Touch': Color(0xFFFFB2B2),       // Soft Coral – intimacy
};

String normalizeLoveLanguage(String? raw) {
  final s = (raw ?? "").trim();
  if (s.isEmpty) return "";
  // titleize but keep small words lower to match keys
  final t = _titleize(s)
      .replaceAllMapped(RegExp(r'\b(Of|And|For|To|In|On|With|A|An)\b'),
          (m) => m.group(0)!.toLowerCase());

  // map common variants → canonical keys
  final lower = t.toLowerCase();
  if (lower.contains('words') && lower.contains('affirm')) {
    return 'Words of Affirmation';
  }
  if (lower.contains('act') && lower.contains('service')) {
    return 'Acts of Service';
  }
  if (lower.contains('gift')) {
    return 'Receiving Gifts';
  }
  if (lower.contains('quality') && lower.contains('time')) {
    return 'Quality Time';
  }
  if (lower.contains('touch')) {
    return 'Physical Touch';
  }
  // if already canonical or very close, return t
  return kLoveLanguages.contains(t) ? t : t;
}

Color loveLanguageColorFor(String? label) =>
    loveLanguageColors[normalizeLoveLanguage(label)] ?? AppColors.lightPink;

// ───────────────────────────────────────────────
// 🎨 Interest Categories – Pastel base + helpers
// ───────────────────────────────────────────────
const Map<String, Color> interestCategoryColors = {
  "Outdoors & Adventure": Color(0xFFC6E5B1), // mint green
  "Sports & Wellness": Color(0xFFBEE3F8),    // sky blue
  "Arts & Creativity": Color(0xFFFBCFE8),    // soft pink
  "Music & Performance": Color(0xFFFDE68A),  // warm yellow
  "Film, TV & Fandoms": Color(0xFFDDD6FE),   // lavender
  "Games & Esports": Color(0xFFFCA5A5),      // peach red
  "Food & Drink": Color(0xFFFEF3C7),         // cream
  "Travel & Culture": Color(0xFFBAE6FD),     // sky teal
  "Tech & Learning": Color(0xFFC7D2FE),      // periwinkle
  "Lifestyle & Home": Color(0xFFFDE68A),     // light gold
  "Community & Values": Color(0xFFBBF7D0),   // mint
  "Pets & Animals": Color(0xFFFBCFE8),       // soft pink
  "Wheels & Machines": Color(0xFFE5E7EB),    // neutral gray
};

const Color kInterestCategoryFallback = AppColors.grey300;
const double kInterestPillBorderWidth = 1.5;

Color interestBaseColor(String category) =>
    interestCategoryColors[category] ?? kInterestCategoryFallback;

Color darkenPastel(Color pastel, [double factor = 0.8]) {
  final h = HSLColor.fromColor(pastel);
  return h.withLightness((h.lightness * factor).clamp(0.0, 1.0)).toColor();
}

Color interestBorderColor(String category) =>
    darkenPastel(interestBaseColor(category), 0.70);

Color onPastelText(Color bg) =>
    bg.computeLuminance() > 0.75 ? AppColors.black : Colors.white;

// ───────────────────────────────────────────────
// 💬 Reactions (used by picker + chips)
// ───────────────────────────────────────────────
const List<String> kSupportedReactions = [
  "❤️", "😂", "😢", "😮", "😡", "👍",
];

const double kReactionChipFontSize = 12;
const double kReactionTrayEmojiSize = 28;
const Duration kReactionTrayAutoDismiss = Duration(seconds: 5);
const double kReactionChipRadius = 12;
const double kReactionBubbleRadius = 18;

const Color kMyBubbleColor = AppColors.primaryColor; // me
const Color kOtherBubbleColor = AppColors.grey300;   // other
const Color kReactionChipFill = AppColors.white;     // chip bg
const Color kReactionChipBorder = AppColors.grey400; // chip border
