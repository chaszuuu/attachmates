import 'package:flutter/material.dart';

/// Slim banner shown above the composer when replying to a message.
/// Use inside ConversationScreen when `_replying != null`.
class ReplyBanner extends StatelessWidget {
  final String title; // e.g., "Replying to Alex"
  final String? textPreview; // 1-line preview of the original
  final Widget? mediaThumb; // optional tiny media preview (e.g., Image.network)
  final VoidCallback onCancel; // clear reply state

  const ReplyBanner({
    super.key,
    required this.title,
    this.textPreview,
    this.mediaThumb,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Material(
      color: Colors.transparent, // transparent so BoxDecoration shows
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.08), // very light shadow
              offset: const Offset(0, -1), // tiny shadow on top edge
              blurRadius: 3,
              spreadRadius: 0,
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          bottom: false,
          child: Padding(
            // match the composer’s horizontal padding (8, not 12)
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // left vertical bar aligned with '+' icon area
                SizedBox(
                  width: 40, // same as icon button width
                  height: 40,
                  child: Center(
                    child: Container(
                      width: 3,
                      height: 40,
                      decoration: BoxDecoration(
                        color: scheme.primary.withOpacity(0.65),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),

                // media thumbnail – optional (40×40 for alignment)
                if (mediaThumb != null) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 40,
                      height: 40,
                      child: mediaThumb!,
                    ),
                  ),
                  const SizedBox(width: 10),
                ],

                // texts
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: Colors.black87,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if ((textPreview ?? '').isNotEmpty)
                        Text(
                          textPreview!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.black54,
                          ),
                        ),
                    ],
                  ),
                ),

                const SizedBox(width: 8), // match convo bar spacing

                // cancel button — match message bar icon sizing, add extra right spacing
                Padding(
                  padding: const EdgeInsets.only(right: 1), // 👈 extra space
                  child: IconButton(
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints.tightFor(width: 40, height: 40),
                    iconSize: 24,
                    icon: const Icon(Icons.close),
                    color: Colors.black54,
                    onPressed: onCancel,
                    tooltip: 'Cancel reply',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
