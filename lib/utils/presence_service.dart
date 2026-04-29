// lib/utils/presence_service.dart
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

/// Use the SAME regional RTDB instance app-wide
const _kRtdbUrl =
    'https://attachmates-default-rtdb.asia-southeast1.firebasedatabase.app';

FirebaseDatabase _rtdb() => FirebaseDatabase.instanceFor(
      app: Firebase.app(),
      databaseURL: _kRtdbUrl,
    );

class PresenceService with WidgetsBindingObserver {
  static final PresenceService _i = PresenceService._internal();
  factory PresenceService() => _i;
  PresenceService._internal();

  DatabaseReference? _statusRef; // points to status/{uid}  ← single node
  StreamSubscription<DatabaseEvent>? _connSub;
  bool _started = false;
  int _lastWriteMs = 0;

  String get _platform => Platform.isAndroid
      ? 'android'
      : Platform.isIOS
          ? 'ios'
          : Platform.isMacOS
              ? 'macos'
              : Platform.isWindows
                  ? 'windows'
                  : Platform.isLinux
                      ? 'linux'
                      : 'other';

  // ===== Public API =====
  Future<void> start() async {
    if (_started) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    _started = true;
    WidgetsBinding.instance.addObserver(this);

    final db = _rtdb();
    _statusRef = db.ref('status/${user.uid}'); // ✅ single root node

    final info = db.ref('.info/connected');
    _connSub = info.onValue.listen((ev) async {
      final connected = (ev.snapshot.value == true);
      if (!connected || _statusRef == null) return;

      // server-side auto-offline
      await _statusRef!.onDisconnect().set({
        'state': 'offline',
        'last_active': ServerValue.timestamp,
        'platform': _platform,
      });

      // mark online now
      await _setState('online');
    });
  }

  Future<void> stop() async {
    try {
      if (_statusRef != null) {
        await _statusRef!.set({
          'state': 'offline',
          'last_active': ServerValue.timestamp,
          'platform': _platform,
        });
      }
    } catch (_) {}
    await _connSub?.cancel();
    _connSub = null;
    _statusRef = null;
    _started = false;
    WidgetsBinding.instance.removeObserver(this);
  }

  Future<void> setOnline() => _setState('online');
  Future<void> setAway() => _setState('away');
  Future<void> setOffline() => _setState('offline');

  /// Watch single-node presence at status/{uid}
  static Stream<Map<String, dynamic>> watch(String uid) {
    final ref = _rtdb().ref('status/$uid');
    return ref.onValue.map((event) {
      final v = event.snapshot.value;
      if (v is Map) {
        final m = Map<Object?, Object?>.from(v);
        final state = (m['state'] ?? 'offline').toString();
        final la = m['last_active'];
        final last = (la is num) ? la.toInt() : 0; // handle int/double
        final platform = (m['platform'] ?? 'other').toString();
        return {'state': state, 'last_active': last, 'platform': platform};
      }
      return {'state': 'offline', 'last_active': 0, 'platform': 'other'};
    });
  }

  static Stream<Map<String, dynamic>> watchAggregate(String uid) => watch(uid);

  static bool isActiveNow(Map<String, dynamic> presence,
      {int graceMs = 120000}) {
    final state = (presence['state'] ?? 'offline') as String;
    final la = presence['last_active'];
    final last = (la is num) ? la.toInt() : 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    return state == 'online' && (now - last) < graceMs;
  }

  // ===== Lifecycle → presence =====
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final ref = _statusRef;
    if (ref == null) return;
    final to = switch (state) {
      AppLifecycleState.resumed => 'online',
      AppLifecycleState.inactive => 'away',
      AppLifecycleState.paused => 'away',
      AppLifecycleState.detached => 'offline',
      _ => 'away',
    };
    ref.set({
      'state': to,
      'last_active': ServerValue.timestamp,
      'platform': _platform,
    });
  }

  // ===== Internals =====
  Future<void> _setState(String state) async {
    final ref = _statusRef;
    if (ref == null) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastWriteMs < 1000) return; // debounce

    try {
      String? prev;
      final snap = await ref.get();
      final val = snap.value;
      if (val is Map && val['state'] is String) {
        prev = val['state'] as String;
      }
      if (prev == state) return;

      _lastWriteMs = now;
      await ref.set({
        'state': state,
        'last_active': ServerValue.timestamp,
        'platform': _platform,
      });
    } catch (_) {}
  }
}
