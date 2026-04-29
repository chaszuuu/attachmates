// lib/widgets/themed_refresh.dart
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Reusable sliver pull-to-refresh with a simple themed **circle** indicator.
/// - Determinate ring while dragging (fills with pull progress)
/// - Indeterminate ring while refreshing
/// - Smooth fade-in/out as the header expands/collapses
///
/// Drop it at the top of a CustomScrollView.slivers.
class ThemedSliverRefreshControl extends StatelessWidget {
  final Future<void> Function() onRefresh;

  /// Ring color (e.g., AppColors.primaryColor).
  final Color color;

  /// Desired height of the indicator when fully revealed.
  final double indicatorExtent;

  /// If true, the ring fades out as content snaps back.
  final bool fadeOutWhenCollapsed;

  /// Visuals for the ring.
  final double size;
  final double strokeWidth;

  const ThemedSliverRefreshControl({
    super.key,
    required this.onRefresh,
    required this.color,
    this.indicatorExtent = 60.0,
    this.fadeOutWhenCollapsed = true,
    this.size = 26.0,
    this.strokeWidth = 2.8,
  });

  @override
  Widget build(BuildContext context) {
    return CupertinoSliverRefreshControl(
      onRefresh: onRefresh,
      builder: (context, refreshState, pulledExtent, triggerPullDistance,
          effectiveIndicatorExtent) {
        final double extent = pulledExtent.clamp(0.0, double.infinity);
        final double target = (effectiveIndicatorExtent == 0
            ? indicatorExtent
            : effectiveIndicatorExtent);
        final double progress =
            (target <= 0 ? 0.0 : (pulledExtent / target)).clamp(0.0, 1.0);

        double opacity;
        switch (refreshState) {
          case RefreshIndicatorMode.drag:
            opacity = progress; // fade in with pull
            break;
          case RefreshIndicatorMode.armed:
          case RefreshIndicatorMode.refresh:
            opacity = 1.0; // solid while refreshing
            break;
          case RefreshIndicatorMode.done:
            opacity =
                fadeOutWhenCollapsed ? progress : 1.0; // fade on snap-back
            break;
          case RefreshIndicatorMode.inactive:
          default:
            opacity = 0.0;
            break;
        }

        // Fully collapse the space when hidden.
        if (fadeOutWhenCollapsed && (opacity <= 0.01 || extent <= 4.0)) {
          return SizedBox(height: extent);
        }

        final bool isRefreshing = refreshState == RefreshIndicatorMode.refresh;

        return SizedBox(
          height: extent,
          child: Center(
            child: AnimatedOpacity(
              opacity: opacity,
              duration: const Duration(milliseconds: 120),
              child: _CircleRefreshRing(
                color: color,
                size: size,
                strokeWidth: strokeWidth,
                // Determinate while dragging, indeterminate while refreshing
                progress: isRefreshing ? null : progress,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CircleRefreshRing extends StatelessWidget {
  final Color color;
  final double size;
  final double strokeWidth;

  /// null => indeterminate spinner; 0..1 => determinate progress ring.
  final double? progress;

  const _CircleRefreshRing({
    required this.color,
    required this.size,
    required this.strokeWidth,
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    // Give a tiny minimum so it doesn't “blink” at very low pulls.
    final double? clamped =
        (progress == null) ? null : progress!.clamp(0.06, 1.0);

    return SizedBox(
      width: size,
      height: size,
      child: CircularProgressIndicator(
        value: clamped, // null => indeterminate
        strokeWidth: strokeWidth,
        valueColor: AlwaysStoppedAnimation<Color>(color),
        backgroundColor: color.withOpacity(0.16),
      ),
    );
  }
}
