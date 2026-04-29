// lib/repositories/blocks_repository.dart
import 'package:flutter/foundation.dart';
import '../utils/api_client.dart';

class BlocksRepository with ChangeNotifier {
  Set<String> _blocked = {};
  Set<String> _blockedBy = {};
  bool _loaded = false;
  bool _refreshing = false;

  BlocksRepository();

  bool get isLoaded => _loaded;
  List<String> get blocked => _blocked.toList(growable: false);
  List<String> get blockedBy => _blockedBy.toList(growable: false);

  /// True if either you blocked them OR they blocked you.
  bool isBlockedWith(String uid) =>
      _blocked.contains(uid) || _blockedBy.contains(uid);

  /// Optional convenience (directional)
  bool isBlockedByMe(String uid) => _blocked.contains(uid);
  bool hasBlockedMe(String uid) => _blockedBy.contains(uid);

  Future<void> refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final res =
          await ApiClient.getUserBlocks(); // { blockedUids, blockedByUids }
      final newBlocked = res.blockedUids.toSet();
      final newBlockedBy = res.blockedByUids.toSet();

      final changed = !(setEquals(_blocked, newBlocked) &&
          setEquals(_blockedBy, newBlockedBy));

      _blocked = newBlocked;
      _blockedBy = newBlockedBy;
      _loaded = true;

      if (changed) notifyListeners();
    } catch (e) {
      // Bubble up if caller wants to show a toast; otherwise just keep last known state
      debugPrint('BlocksRepository.refresh error: $e');
      rethrow;
    } finally {
      _refreshing = false;
    }
  }

  Future<void> block(String uid) async {
    await ApiClient.postBlock(uid); // sends { target_uid: uid }
    if (_blocked.add(uid)) notifyListeners();
  }

  Future<void> unblock(String uid) async {
    await ApiClient.postUnblock(
        uid); // sends { target_uid: uid, unblock: true } or similar
    if (_blocked.remove(uid)) notifyListeners();
  }

  void clear() {
    _blocked.clear();
    _blockedBy.clear();
    _loaded = false;
    notifyListeners();
  }
}
