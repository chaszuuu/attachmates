import 'package:flutter/material.dart';

/// Provides smooth scrolling utilities to make a specific widget visible.
mixin ValidationScroller<T extends StatefulWidget> on State<T> {
  /// Smoothly ensures the widget for [key] is visible.
  Future<void> ensureVisibleKey(
    GlobalKey key, {
    Duration duration = const Duration(milliseconds: 280),
    Curve curve = Curves.easeOut,
    double alignment = 0.1,
  }) async {
    final ctx = key.currentContext;
    if (ctx == null) return;
    await Scrollable.ensureVisible(
      ctx,
      duration: duration,
      curve: curve,
      alignment: alignment,
    );
  }

  /// Scrolls to the first invalid item key from a list.
  /// Returns `true` if something was scrolled to.
  Future<bool> scrollToFirstInvalid({
    required List<GlobalKey> itemKeys,
    required Set<int> invalidIndices,
    Duration duration = const Duration(milliseconds: 280),
    Curve curve = Curves.easeOut,
    double alignment = 0.1,
  }) async {
    if (invalidIndices.isEmpty || itemKeys.isEmpty) return false;

    final sorted = invalidIndices.toList()..sort();
    for (final idx in sorted) {
      if (idx >= 0 && idx < itemKeys.length) {
        final key = itemKeys[idx];
        final ctx = key.currentContext;
        if (ctx != null) {
          await ensureVisibleKey(
            key,
            duration: duration,
            curve: curve,
            alignment: alignment,
          );
          return true;
        }
      }
    }
    return false;
  }
}
