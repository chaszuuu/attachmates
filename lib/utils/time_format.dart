import 'package:intl/intl.dart';

/// Centralized time & date formatting for chat UI.
class TimeFormat {
  // ---------- Basics ----------

  /// Exact clock time – e.g., "3:24 PM"
  static String exactTime(DateTime dt) {
    final local = dt.toLocal();
    return DateFormat('h:mm a').format(local); // already uppercase AM/PM
  }

  /// Compact clock time – e.g., "3:24 PM" (space, uppercase AM/PM)
  static String exactTimeCompact(DateTime dt, {String? locale}) {
    final local = dt.toLocal();
    return DateFormat('h:mm a', locale).format(local);
  }

  /// Short "time ago" – e.g., "Just now", "5m", "2h", "3d", "Sep 10"
  static String timeAgoShort(DateTime dt, {DateTime? now}) {
    final n = (now ?? DateTime.now()).toLocal();
    final t = dt.toLocal();
    final diff = n.difference(t);

    if (diff.inSeconds < 45) return 'Just now';
    if (diff.inMinutes < 1) return '${diff.inSeconds}s';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';

    // Fallback → "Sep 10" (or include year if different)
    if (n.year == t.year) return DateFormat('MMM d').format(t);
    return DateFormat('MMM d, y').format(t);
  }

  /// Day label – "Today", "Yesterday", "Sep 10[, 2025]"
  static String dayLabel(DateTime dt, {DateTime? now, String? locale}) {
    final n = (now ?? DateTime.now()).toLocal();
    final t = dt.toLocal();

    final today = DateTime(n.year, n.month, n.day);
    final thatDay = DateTime(t.year, t.month, t.day);
    final diffDays = today.difference(thatDay).inDays;

    if (diffDays == 0) return 'Today';
    if (diffDays == 1) return 'Yesterday';
    if (n.year == t.year) return DateFormat('MMM d', locale).format(t);
    return DateFormat('MMM d, y', locale).format(t);
  }

  /// Detect if there’s a big gap (default ≥ 8h) between two timestamps.
  static bool isSignificantGap(DateTime a, DateTime b,
      {Duration gap = const Duration(hours: 8)}) {
    final earlier = a.isBefore(b) ? a : b;
    final later = a.isBefore(b) ? b : a;
    return later.difference(earlier) >= gap;
  }

  // ---------- Conversation divider label per your rules ----------

  /// Conversation date divider label:
  /// - Today → "Today 4:50 PM"
  /// - Yesterday → "Yesterday 4:50 PM"
  /// - ≤ 7 days ago → "Mon 4:50 PM"
  /// - Older this year → "Sep 3, 4:50 PM"
  /// - Previous years → "Jan 1, 2023" (no time)
  static String dividerLabel(DateTime dt, {DateTime? now, String? locale}) {
    final DateTime n = (now ?? DateTime.now()).toLocal();
    final DateTime t = dt.toLocal();

    final DateTime startOfToday = DateTime(n.year, n.month, n.day);
    final DateTime startOfYesterday =
        startOfToday.subtract(const Duration(days: 1));
    final DateTime oneWeekAgo = startOfToday.subtract(const Duration(days: 7));

    // Today
    if (_isSameDay(t, n)) {
      return 'Today ${exactTimeCompact(t, locale: locale)}';
    }

    // Yesterday
    if (_isSameDay(t, startOfYesterday)) {
      return 'Yesterday ${exactTimeCompact(t, locale: locale)}';
    }

    // Within the last 7 days (not including today/yesterday)
    if (t.isAfter(oneWeekAgo)) {
      final dow = DateFormat('E', locale).format(t); // Mon, Tue, ...
      return '$dow ${exactTimeCompact(t, locale: locale)}';
    }

    // Same calendar year → "Sep 3, 4:50 PM"
    if (t.year == n.year) {
      final date = DateFormat('MMM d', locale).format(t);
      return '$date, ${exactTimeCompact(t, locale: locale)}';
    }

    // Previous years → "Jan 1, 2023" (no time)
    return DateFormat('MMM d, y', locale).format(t);
  }

  // ---------- Private helpers ----------

  static bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}
