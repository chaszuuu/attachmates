// lib/screens/notifications/notifications_settings_screen.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../utils/constants.dart';
import '../../utils/shared_pref.dart';
import '../../utils/api_client.dart';
import '../../services/push_service.dart';

class NotificationsSettingsScreen extends StatefulWidget {
  const NotificationsSettingsScreen({super.key});

  @override
  State<NotificationsSettingsScreen> createState() =>
      _NotificationsSettingsScreenState();
}

class _NotificationsSettingsScreenState
    extends State<NotificationsSettingsScreen> {
  bool _loading = true;

  bool _notificationsEnabled = true;
  bool _notifMessages = true;
  bool _notifMatches = true;
  bool _notifLikes = true;
  bool _notifVerification = true;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      final localGlobal = await SharedPref.getBool('notif_enabled');
      final status = await Permission.notification.status;
      final osAllowed = status.isGranted;
      final global = (localGlobal ?? true) && osAllowed;

      final msgs = await SharedPref.getBool('notif_messages') ?? true;
      final mats = await SharedPref.getBool('notif_matches') ?? true;
      final likes = await SharedPref.getBool('notif_likes') ?? true;
      final ver = await SharedPref.getBool('notif_verification') ?? true;

      setState(() {
        _notificationsEnabled = global;
        _notifMessages = msgs;
        _notifMatches = mats;
        _notifLikes = likes;
        _notifVerification = ver;
      });

      await _syncNotifPrefsFromServer();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _hideSnack() => ScaffoldMessenger.of(context).hideCurrentSnackBar();

  void _showSavedSnack([String msg = 'Saved']) {
    _hideSnack();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: Colors.green,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _showErrorSnack([String? msg]) {
    _hideSnack();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg ?? 'Failed to update preferences. Check connection.'),
        backgroundColor: Colors.red.shade600,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _syncNotifPrefsFromServer() async {
    try {
      final prefs = await ApiClient.getNotifPrefs();
      if (!mounted) return;
      setState(() {
        _notifMessages = prefs['messages'] ?? _notifMessages;
        _notifMatches = prefs['matches'] ?? _notifMatches;
        _notifLikes = prefs['likes'] ?? _notifLikes;
        _notifVerification = prefs['verification'] ?? _notifVerification;
      });
      await SharedPref.setBool('notif_messages', _notifMessages);
      await SharedPref.setBool('notif_matches', _notifMatches);
      await SharedPref.setBool('notif_likes', _notifLikes);
      await SharedPref.setBool('notif_verification', _notifVerification);
    } catch (_) {}
  }

  Future<void> _saveCategoryPrefs({
    bool? messages,
    bool? matches,
    bool? likes,
    bool? verification,
  }) async {
    if (_saving) return;
    setState(() => _saving = true);

    final next = <String, bool>{
      'messages': messages ?? _notifMessages,
      'matches': matches ?? _notifMatches,
      'likes': likes ?? _notifLikes,
      'verification': verification ?? _notifVerification,
    };

    try {
      await ApiClient.updateNotifPrefs(next);
      await SharedPref.setBool('notif_messages', next['messages']!);
      await SharedPref.setBool('notif_matches', next['matches']!);
      await SharedPref.setBool('notif_likes', next['likes']!);
      await SharedPref.setBool('notif_verification', next['verification']!);
      _showSavedSnack();
    } catch (_) {
      _showErrorSnack();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _toggleGlobal(bool value) async {
    setState(() => _notificationsEnabled = value);

    if (value) {
      final ok = await PushService.enable();
      if (!mounted) return;
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Enable notifications in system settings'),
            action: SnackBarAction(
              label: 'Open',
              onPressed: () async {
                await openAppSettings();
              },
            ),
            duration: const Duration(seconds: 3),
          ),
        );
        setState(() => _notificationsEnabled = false);
        await SharedPref.setBool('notif_enabled', false);
      } else {
        await SharedPref.setBool('notif_enabled', true);
        await _syncNotifPrefsFromServer();
        _showSavedSnack('Notifications turned on');
      }
    } else {
      await PushService.disable();
      await SharedPref.setBool('notif_enabled', false);
      _showSavedSnack('Notifications turned off');
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = AppColors.primaryColor;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.chevron_left, color: primary, size: 30),
          onPressed: () => Navigator.pop(context),
          splashRadius: 24,
        ),
        centerTitle: true,
        title: Text(
          "Notifications",
          style: TextStyle(
            color: primary,
            fontWeight: FontWeight.bold,
            fontSize: 20,
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                // ✨ Push notification section title
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                  child: Text(
                    "Push Notifications",
                    style: TextStyle(
                      color: Colors.grey.shade700,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),

                // Main/global toggle
                _buildToggleTile(
                  title: "Notifications",
                  subtitle: "Turn all push notifications on or off.",
                  value: _notificationsEnabled,
                  onChanged: _toggleGlobal,
                  activeColor: primary,
                ),
                const SizedBox(height: 6),

                // Sub-items (indented)
                Opacity(
                  opacity: _notificationsEnabled ? 1.0 : 0.45,
                  child: AbsorbPointer(
                    absorbing: !_notificationsEnabled,
                    child: Column(
                      children: [
                        _buildToggleTile(
                          title: "Messages",
                          value: _notifMessages,
                          onChanged: (v) async {
                            setState(() => _notifMessages = v);
                            await _saveCategoryPrefs(messages: v);
                          },
                          activeColor: primary,
                          indent: 24,
                        ),
                        _buildToggleTile(
                          title: "Matches",
                          value: _notifMatches,
                          onChanged: (v) async {
                            setState(() => _notifMatches = v);
                            await _saveCategoryPrefs(matches: v);
                          },
                          activeColor: primary,
                          indent: 24,
                        ),
                        _buildToggleTile(
                          title: "Likes",
                          value: _notifLikes,
                          onChanged: (v) async {
                            setState(() => _notifLikes = v);
                            await _saveCategoryPrefs(likes: v);
                          },
                          activeColor: primary,
                          indent: 24,
                        ),
                        _buildToggleTile(
                          title: "Verification",
                          value: _notifVerification,
                          onChanged: (v) async {
                            setState(() => _notifVerification = v);
                            await _saveCategoryPrefs(verification: v);
                          },
                          activeColor: primary,
                          indent: 24,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  /// Custom ListTile with ripple + optional indent for sub-items
  Widget _buildToggleTile({
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    Color? activeColor,
    double indent = 0,
  }) {
    return InkWell(
      onTap: () => onChanged(!value),
      splashColor: Colors.grey.withOpacity(0.2),
      highlightColor: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            if (indent > 0) SizedBox(width: indent),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: Colors.black,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: Colors.grey.shade600,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Switch(
              value: value,
              onChanged: onChanged,
              activeColor: activeColor ?? AppColors.primaryColor,
            ),
          ],
        ),
      ),
    );
  }
}
