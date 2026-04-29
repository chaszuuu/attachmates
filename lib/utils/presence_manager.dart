// utils/presence_manager.dart
import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';

const String _kRtdbUrl =
    'https://attachmates-default-rtdb.asia-southeast1.firebasedatabase.app';

bool _presenceStarted = false;
StreamSubscription<DatabaseEvent>? _connSub;
DatabaseReference? _statusRef;

/// Region-correct RTDB instance
FirebaseDatabase _rtdb() => FirebaseDatabase.instanceFor(
      app: Firebase.app(),
      databaseURL: _kRtdbUrl,
    );

/// Call at app start (if already signed in) or right after login.
Future<void> startPresenceTracking() async {
  if (_presenceStarted) return;
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return;

  _presenceStarted = true;

  final db = _rtdb();
  _statusRef = db.ref('status/${user.uid}');
  final connectedRef = db.ref('.info/connected');

  // Optimistically set an initial value (best-effort)
  try {
    await _statusRef!.set({
      'state': 'offline',
      'last_active': ServerValue.timestamp,
    });
  } catch (_) {}

  _connSub = connectedRef.onValue.listen((event) async {
    final connected = event.snapshot.value == true;
    if (!connected) return;

    try {
      // Schedule automatic offline on disconnect
      await _statusRef!.onDisconnect().set({
        'state': 'offline',
        'last_active': ServerValue.timestamp,
      });

      // Mark online now
      await _statusRef!.set({
        'state': 'online',
        'last_active': ServerValue.timestamp,
      });
    } catch (_) {}
  });
}

/// Cleanly stop presence tracking (e.g., during logout or app close).
Future<void> stopPresenceTracking() async {
  try {
    await _connSub?.cancel();
  } catch (_) {}
  _connSub = null;

  try {
    await _statusRef?.onDisconnect().cancel();
  } catch (_) {}
  _statusRef = null;

  _presenceStarted = false;
}

/// Best-effort immediate offline mark (use before signOut).
Future<void> markOfflineNow(String uid) async {
  try {
    final ref = _rtdb().ref('status/$uid');
    await ref.set({
      'state': 'offline',
      'last_active': ServerValue.timestamp,
    });
  } catch (_) {}
}
