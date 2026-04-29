import 'dart:async';

/// Shared interface so the parent can call `scrollToFirstMissing(...)`
/// on any quiz page State via GlobalKey.currentState.
abstract class ValidationTarget {
  Future<bool> scrollToFirstMissing(Set<int> invalidIndices);
}
