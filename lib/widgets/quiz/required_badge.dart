import 'package:flutter/material.dart';

/// A tiny “Required” badge used to flag unanswered items.
/// Keeps styling consistent across quiz pages.
class RequiredBadge extends StatelessWidget {
  const RequiredBadge({
    super.key,
    this.label = 'Required',
    this.compact = false,
    this.showIcon = true,
  });

  final String label;
  final bool compact;
  final bool showIcon;

  @override
  Widget build(BuildContext context) {
    final bg = const Color(0xFFFFEBEE); // light red
    final bd = const Color(0xFFFFCDD2); // border red
    final fg = const Color(0xFFD32F2F); // text/icon red

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : 8,
        vertical: compact ? 2 : 4,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: bd),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showIcon)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child:
                  Icon(Icons.error_outline, size: compact ? 12 : 14, color: fg),
            ),
          Text(
            label,
            style: TextStyle(
              fontSize: compact ? 11 : 12,
              fontWeight: FontWeight.w600,
              color: fg,
              height: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}
