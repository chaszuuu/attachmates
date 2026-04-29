// lib/screens/settings/manage_signin_screen.dart

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter_facebook_auth/flutter_facebook_auth.dart';

// Optional: only used by conflict sheet
import '../auth/auth_screen.dart';

class ManageSignInScreen extends StatefulWidget {
  const ManageSignInScreen({super.key});

  @override
  State<ManageSignInScreen> createState() => _ManageSignInScreenState();
}

class _ManageSignInScreenState extends State<ManageSignInScreen> {
  final _auth = FirebaseAuth.instance;
  final _users = FirebaseFirestore.instance.collection('users');
  bool _busy = false;

  User? get _user => _auth.currentUser;
  Set<String> _currentProviderIds = {};

  @override
  void initState() {
    super.initState();
    _refreshProviders();
  }

  void _refreshProviders() {
    final list = _user?.providerData.map((p) => p.providerId).toList() ?? [];
    setState(() => _currentProviderIds = Set<String>.from(list));
  }

  // ───────────────── Firestore helpers ─────────────────

  // Merge nested maps (no dotted keys here)
  Future<void> _mergeUser(Map<String, dynamic> data) async {
    final uid = _user?.uid;
    if (uid == null) return;
    await _users.doc(uid).set(data, SetOptions(merge: true));
  }

  // Update dotted paths (needed for deletes of nested fields)
  Future<void> _updatePaths(Map<String, dynamic> paths) async {
    final uid = _user?.uid;
    if (uid == null) return;
    await _users.doc(uid).update(paths);
  }

  // After link/unlink → reload token, refresh providers, mirror to Firestore
  Future<void> _postLinkCleanup({Map<String, dynamic>? fields}) async {
    await _user?.reload();
    await _user?.getIdToken(true);
    _refreshProviders();
    await _mergeUser({
      'linked_providers': _currentProviderIds.toList(),
      if (fields != null) ...fields,
      'updated_at': FieldValue.serverTimestamp(),
    });
  }

  // Remove provider-specific metadata on unlink
  Future<void> _removeProviderMetadata(String providerId) async {
    final deletes = <String, dynamic>{};
    if (providerId == 'google.com') {
      deletes['auth_emails.google'] = FieldValue.delete();
      deletes['auth_ids.google'] = FieldValue.delete();
      deletes['auth_names.google'] = FieldValue.delete();
    } else if (providerId == 'facebook.com') {
      deletes['auth_emails.facebook'] = FieldValue.delete();
      deletes['auth_ids.facebook'] = FieldValue.delete();
      deletes['auth_names.facebook'] = FieldValue.delete();
    } else if (providerId == 'phone') {
      deletes['auth_phone.e164'] = FieldValue.delete();
      deletes['phone_number'] = FieldValue.delete();
    }
    if (deletes.isNotEmpty) {
      await _updatePaths(deletes); // use update(...) for dotted deletes
    }
  }

  // Safe read: try nested map first, then legacy dotted field
  T? _readNested<T>(
    Map<String, dynamic> data,
    String parent,
    String child, {
    String? legacyKey,
  }) {
    final m = (data[parent] as Map?)?.cast<String, dynamic>();
    final v = m?[child];
    if (v != null) return v as T;
    final legacy = data[legacyKey ?? '$parent.$child'];
    return legacy as T?;
  }

  // ───────────────── LINK FLOWS ─────────────────

  Future<void> _linkGoogle() async {
    setState(() => _busy = true);
    String? attemptedEmail;
    String? attemptedId;
    String? attemptedName;
    try {
      // Force account chooser
      final googleSignIn = GoogleSignIn(scopes: ['email']);
      await googleSignIn.signOut();
      await googleSignIn.disconnect();

      final googleUser = await googleSignIn.signIn();
      if (googleUser == null) throw Exception('Sign-in cancelled');
      attemptedEmail = googleUser.email;
      attemptedId = googleUser.id;
      attemptedName = googleUser.displayName;

      final googleAuth = await googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      await _user!.linkWithCredential(credential);

      // Write nested maps (no dotted keys)
      final fields = <String, dynamic>{
        'auth_emails': {'google': attemptedEmail},
        'auth_ids': {'google': attemptedId},
        if (attemptedName != null && attemptedName.isNotEmpty)
          'auth_names': {'google': attemptedName},
        if ((_user?.email == null || (_user?.email?.isEmpty ?? true)) &&
            attemptedEmail != null)
          'email': attemptedEmail,
      };

      await _postLinkCleanup(fields: fields);
      _snack('Linked Google: $attemptedEmail');
    } on FirebaseAuthException catch (e) {
      if (_isConflict(e.code)) {
        await _handleProviderConflict(
          email: attemptedEmail,
          onRetry: _linkGoogle,
        );
      } else {
        _handleAuthError(e, fallback: 'Failed to link Google');
      }
    } catch (e) {
      _snack(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _linkFacebook() async {
    setState(() => _busy = true);
    String? attemptedEmail;
    String? attemptedId;
    String? attemptedName;
    try {
      final res = await FacebookAuth.instance.login(permissions: ['email']);
      if (res.accessToken == null) throw Exception('Login cancelled');

      final credential = FacebookAuthProvider.credential(res.accessToken!.token);

      final profile = await FacebookAuth.instance.getUserData();
      attemptedEmail = profile['email'];
      attemptedId = profile['id']?.toString();
      attemptedName = profile['name'];

      await _user!.linkWithCredential(credential);

      final fields = <String, dynamic>{
        if (attemptedEmail != null) 'auth_emails': {'facebook': attemptedEmail},
        if (attemptedId != null) 'auth_ids': {'facebook': attemptedId},
        if (attemptedName != null && attemptedName.isNotEmpty)
          'auth_names': {'facebook': attemptedName},
        if ((_user?.email == null || (_user?.email?.isEmpty ?? true)) &&
            attemptedEmail != null)
          'email': attemptedEmail,
      };

      await _postLinkCleanup(fields: fields);
      _snack('Linked Facebook${attemptedEmail != null ? ': $attemptedEmail' : ''}');
    } on FirebaseAuthException catch (e) {
      if (_isConflict(e.code)) {
        await _handleProviderConflict(
          email: attemptedEmail,
          onRetry: _linkFacebook,
        );
      } else {
        _handleAuthError(e, fallback: 'Failed to link Facebook');
      }
    } catch (e) {
      _snack(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _linkPhone() async {
    final credential = await Navigator.push<PhoneAuthCredential?>(
      context,
      MaterialPageRoute(builder: (_) => const _PhoneLinkFlow()),
    );
    if (credential == null) return;

    setState(() => _busy = true);
    try {
      await _user!.linkWithCredential(credential);

      await _user?.reload();
      final e164 = _auth.currentUser?.phoneNumber;

      final fields = <String, dynamic>{
        if (e164 != null && e164.isNotEmpty) ...{
          'auth_phone': {'e164': e164},
          'phone_number': e164, // convenience top-level
        },
      };

      await _postLinkCleanup(fields: fields);
      _snack('Linked phone number${e164 != null ? ' ($e164)' : ''}.');
    } on FirebaseAuthException catch (e) {
      if (_isConflict(e.code)) {
        await _handleProviderConflict(
          email: null,
          onRetry: _linkPhone,
        );
      } else {
        _handleAuthError(e, fallback: 'Failed to link phone');
      }
    } catch (e) {
      _snack(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ───────────────── UNLINK ─────────────────

  Future<void> _unlink(String providerId) async {
    if (_currentProviderIds.length <= 1) {
      _snack('You cannot remove your last sign-in method.');
      return;
    }

    setState(() => _busy = true);
    try {
      await _user!.unlink(providerId);
      await _removeProviderMetadata(providerId);
      await _postLinkCleanup();
      _snack('Unlinked ${_label(providerId)}');
    } on FirebaseAuthException catch (e) {
      _handleAuthError(e, fallback: 'Failed to unlink');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ───────────────── UI ─────────────────

  @override
  Widget build(BuildContext context) {
    final uid = _user?.uid;
    if (uid == null) {
      return const Scaffold(body: Center(child: Text('Sign in required')));
    }

    // Live-read the user's doc to display saved emails / phone
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _users.doc(uid).snapshots(),
      builder: (context, snap) {
        final data = snap.data?.data() ?? const <String, dynamic>{};

// Read nested with legacy fallbacks
final googleEmail = _readNested<String>(data, 'auth_emails', 'google');
final fbName      = _readNested<String>(data, 'auth_names',  'facebook');
final phoneE164   = _readNested<String>(data, 'auth_phone',  'e164');

// Legacy dotted fallbacks (if you have old docs)
final googleEmailLegacy = data['auth_emails.google'] as String?;
final fbNameLegacy      = data['auth_names.facebook'] as String?;
final phoneLegacy       = data['auth_phone.e164'] as String?;

// Final labels per your rule:
// - Google → email
// - Facebook → name
final _googleLabel = googleEmail ?? googleEmailLegacy;
final _fbLabel     = fbName ?? fbNameLegacy;
final _phoneLabel  = phoneE164 ?? phoneLegacy;

String _subtitleFor(String providerId) {
  if (!_currentProviderIds.contains(providerId)) return 'Not linked';
  switch (providerId) {
    case 'google.com':
      return 'Linked • ${_googleLabel ?? '—'}';
    case 'facebook.com':
      return 'Linked • ${_fbLabel ?? '—'}';
    case 'phone':
      return 'Linked • ${_phoneLabel ?? 'No number saved'}';
    default:
      return 'Linked';
  }
}


        final items = <_ProviderItem>[
          _ProviderItem(
            id: 'google.com',
            title: 'Google',
            icon: Icons.g_mobiledata_rounded,
            isLinked: _currentProviderIds.contains('google.com'),
            onLink: _linkGoogle,
            onUnlink: () => _unlink('google.com'),
            subtitleText: _subtitleFor('google.com'),
          ),
          _ProviderItem(
            id: 'facebook.com',
            title: 'Facebook',
            icon: Icons.facebook_outlined,
            isLinked: _currentProviderIds.contains('facebook.com'),
            onLink: _linkFacebook,
            onUnlink: () => _unlink('facebook.com'),
            subtitleText: _subtitleFor('facebook.com'),
          ),
          _ProviderItem(
            id: 'phone',
            title: 'Phone Number',
            icon: Icons.phone_iphone_outlined,
            isLinked: _currentProviderIds.contains('phone'),
            onLink: _linkPhone,
            onUnlink: () => _unlink('phone'),
            subtitleText: _subtitleFor('phone'),
          ),
        ];

        return Scaffold(
          appBar: AppBar(
            title: const Text('Manage Sign-In Methods'),
            surfaceTintColor: Colors.transparent,
          ),
          body: ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (_, i) {
              final it = items[i];
              return _CardRow(
                leading: Icon(it.icon, size: 24),
                title: it.title,
                trailing: _busy
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : it.isLinked
                        ? OutlinedButton(
                            onPressed: it.onUnlink,
                            child: const Text('Unlink'),
                          )
                        : ElevatedButton(
                            onPressed: it.onLink,
                            child: const Text('Link'),
                          ),
                subtitle: Text(
                  it.subtitleText ?? (it.isLinked ? 'Linked' : 'Not linked'),
                  style: TextStyle(
                    color: it.isLinked ? Colors.green.shade700 : Colors.grey.shade600,
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  bool _isConflict(String code) {
    return code == 'credential-already-in-use' ||
        code == 'email-already-in-use' ||
        code == 'account-exists-with-different-credential';
  }

  void _handleAuthError(FirebaseAuthException e, {required String fallback}) {
    String msg = fallback;
    switch (e.code) {
      case 'provider-already-linked':
        msg = 'This provider is already linked.';
        break;
      case 'credential-already-in-use':
        msg = 'That credential is already used by another account.';
        break;
      case 'requires-recent-login':
        msg = 'Please reauthenticate and try again.';
        break;
      default:
        msg = '$fallback (${e.code})';
    }
    _snack(msg);
  }

  Future<void> _handleProviderConflict({
    required String? email,
    required Future<void> Function() onRetry,
  }) async {
    if (!mounted) return;

    List<String> methods = [];
    try {
      if (email != null && email.isNotEmpty) {
        methods = await FirebaseAuth.instance.fetchSignInMethodsForEmail(email);
      }
    } catch (_) {}

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) {
        return SafeArea(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 16)],
            ),
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('This account is already linked',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Text(
                  email == null || email.isEmpty
                      ? 'That credential belongs to another user.'
                      : 'The account $email belongs to another user.',
                  style: const TextStyle(fontSize: 14),
                ),
                if (methods.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Sign-in methods on that account: ${methods.join(", ")}',
                    style: const TextStyle(fontSize: 13, color: Colors.black54),
                  ),
                ],
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Close'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () async {
                          Navigator.of(context).pop();
                          await FirebaseAuth.instance.signOut();
                          if (!mounted) return;
                          Navigator.of(context).pushReplacement(
                            MaterialPageRoute(builder: (_) => const AuthScreen(isLogin: true)),
                          );
                        },
                        child: const Text('Switch account'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ElevatedButton(
                  onPressed: () async {
                    Navigator.of(context).pop();
                    await onRetry();
                  },
                  child: const Text('I unlinked it already — Retry link'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _label(String providerId) {
    switch (providerId) {
      case 'google.com':
        return 'Google';
      case 'facebook.com':
        return 'Facebook';
      case 'phone':
        return 'Phone';
      default:
        return providerId;
    }
  }
}

// ───────────────── Helper classes ─────────────────

class _ProviderItem {
  final String id;
  final String title;
  final IconData icon;
  final bool isLinked;
  final VoidCallback onLink;
  final VoidCallback onUnlink;
  final String? subtitleText;

  _ProviderItem({
    required this.id,
    required this.title,
    required this.icon,
    required this.isLinked,
    required this.onLink,
    required this.onUnlink,
    this.subtitleText,
  });
}

class _CardRow extends StatelessWidget {
  final Widget leading;
  final String title;
  final Widget trailing;
  final Widget? subtitle;

  const _CardRow({
    required this.leading,
    required this.title,
    required this.trailing,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 4, offset: Offset(0,2))],
      ),
      child: Row(
        children: [
          leading,
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                if (subtitle != null) const SizedBox(height: 4),
                if (subtitle != null) subtitle!,
              ],
            ),
          ),
          const SizedBox(width: 12),
          trailing,
        ],
      ),
    );
  }
}

// ───────────────── Minimal phone linking flow ─────────────────

class _PhoneLinkFlow extends StatefulWidget {
  const _PhoneLinkFlow({super.key});
  @override
  State<_PhoneLinkFlow> createState() => _PhoneLinkFlowState();
}

class _PhoneLinkFlowState extends State<_PhoneLinkFlow> {
  final _phoneCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  String? _verificationId;
  bool _sending = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Link Phone')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _phoneCtrl,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Phone number (+63xxxxxxxxxx)'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _sending ? null : _sendCode,
              child: const Text('Send code'),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _codeCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'SMS code'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: (_verificationId == null) ? null : _confirmCode,
              child: const Text('Confirm & Link'),
            )
          ],
        ),
      ),
    );
  }

  Future<void> _sendCode() async {
    setState(() => _sending = true);

    await FirebaseAuth.instance.verifyPhoneNumber(
      phoneNumber: _phoneCtrl.text.trim(),
      verificationCompleted: (PhoneAuthCredential credential) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Auto-verification completed')),
        );
      },
      verificationFailed: (FirebaseAuthException e) {
        setState(() => _sending = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: ${e.message}')));
      },
      codeSent: (String verificationId, int? resendToken) {
        setState(() {
          _verificationId = verificationId;
          _sending = false;
        });
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Code sent')));
      },
      codeAutoRetrievalTimeout: (String verificationId) {
        _verificationId = verificationId;
      },
      timeout: const Duration(seconds: 60),
    );
  }

  void _confirmCode() {
    if (_verificationId == null) return;
    final cred = PhoneAuthProvider.credential(
      verificationId: _verificationId!,
      smsCode: _codeCtrl.text.trim(),
    );
    Navigator.of(context).pop<PhoneAuthCredential>(cred);
  }
}
