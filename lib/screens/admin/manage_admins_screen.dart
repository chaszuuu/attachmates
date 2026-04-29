// lib/screens/admin/manage_admins_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:firebase_auth/firebase_auth.dart';

import '../../repositories/admin_repository.dart';
import '../../utils/role_guard.dart';
import '../../utils/constants.dart'; // AppColors.primaryColor

class ManageAdminsScreen extends StatefulWidget {
  const ManageAdminsScreen({super.key});

  @override
  State<ManageAdminsScreen> createState() => _ManageAdminsScreenState();
}

class _ManageAdminsScreenState extends State<ManageAdminsScreen> {
  // ---------- Auth gate ----------
  bool _authChecked = false;
  bool _authorized = false;
  String? _selfUid;

  // ---------- Data ----------
  bool _loading = true;
  List<Map<String, dynamic>> _rows = [];

  // ---------- UI state ----------
  final TextEditingController _uidCtrl = TextEditingController();
  final TextEditingController _searchCtl = TextEditingController();
  String _grantRole = 'reviewer';
  String _roleFilter = 'all';

  Color get primary => AppColors.primaryColor;

  // ---------- Lifecycle ----------
  @override
  void initState() {
    super.initState();
    _checkAuthThenLoad();
  }

  Future<void> _checkAuthThenLoad() async {
    // Ensure we start with a fresh token to avoid first-hit 401s
    final u = FirebaseAuth.instance.currentUser;
    if (u != null) {
      await u.getIdToken(true);
    }

    final ok = await RoleGuard.isSuperadmin(); // superadmin only
    final self = FirebaseAuth.instance.currentUser?.uid;
    if (!mounted) return;
    setState(() {
      _authChecked = true;
      _authorized = ok;
      _selfUid = self;
    });
    if (ok) {
      await _load();
    } else {
      // not authorized; stop loading so body can show message
      setState(() => _loading = false);
    }
  }

  Future<void> _load() async {
    if (!_authorized) return;
    setState(() => _loading = true);
    try {
      final rows = await AdminRepository.listAdmins();
      // Normalize as Map<String, dynamic>
      final parsed = rows
          .map<Map<String, dynamic>>((e) =>
              (e is Map) ? Map<String, dynamic>.from(e) : <String, dynamic>{})
          .toList();
      if (!mounted) return;
      setState(() => _rows = parsed);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Load failed: $e')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ---------- Helpers ----------
  String _s(dynamic v) => v == null ? '' : v.toString();

  List<String> _rolesOf(Map<String, dynamic> m) {
    final r = m['roles'];
    if (r is List) {
      return r.map((e) => _s(e).trim()).where((s) => s.isNotEmpty).toList();
    }
    if (r is String && r.trim().isNotEmpty) return [r.trim()];
    return const [];
  }

  Future<void> _copy(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Copied to clipboard')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Copy failed: $e')));
    }
  }

  // ---------- Grant / Revoke ----------
  Future<void> _grant() async {
    if (!_authorized) return;
    final uid = _uidCtrl.text.trim();
    if (uid.isEmpty) return;

    final confirmed = await _confirmGrant(uid, _grantRole);
    if (confirmed != true) return;

    try {
      await AdminRepository.grantRole(uid, _grantRole);
      _uidCtrl.clear();
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Granted $_grantRole to $uid')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Grant failed: $e')));
    }
  }

  Future<void> _revoke(String uid, String role) async {
    if (!_authorized) return;
    if (uid == _selfUid && role == 'superadmin') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("You can't revoke your own superadmin role."),
        ),
      );
      return;
    }

    final confirmed = await _confirmRevoke(uid, role);
    if (confirmed != true) return;

    try {
      await AdminRepository.revokeRole(uid, role);
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Revoked $role from $uid')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Revoke failed: $e')));
    }
  }

  // ---------- Confirm Sheets ----------
  Future<bool?> _confirmGrant(String uid, String role) async {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return _ConfirmSheet(
          icon: Icons.person_add_alt_1,
          iconColor: primary,
          title: 'Grant Role',
          message:
              'Are you sure you want to grant the role "$role" to this UID?',
          detail: uid,
          confirmText: 'Grant',
          confirmColor: primary,
        );
      },
    );
  }

  Future<bool?> _confirmRevoke(String uid, String role) async {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return _ConfirmSheet(
          icon: Icons.remove_circle,
          iconColor: Colors.red.shade700,
          title: 'Revoke Role',
          message:
              'Are you sure you want to revoke the role "$role" from this UID?',
          detail: uid,
          confirmText: 'Revoke',
          confirmColor: Colors.red.shade700,
        );
      },
    );
  }

  // ---------- Role tag colors ----------
  final Map<String, Color> _roleColors = const {
    'viewer': Color(0xFF90A4AE),
    'reviewer': Color(0xFF42A5F5),
    'admin': Color(0xFFAB47BC),
    'superadmin': Color(0xFFEF5350),
  };

  Widget _roleChip(String role, {VoidCallback? onDelete, bool locked = false}) {
    final base = _roleColors[role] ?? Colors.black87;
    final bg = base.withOpacity(.08);
    final border = base.withOpacity(.25);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.verified_user, size: 14, color: base),
          const SizedBox(width: 6),
          Text(
            role,
            style: TextStyle(
                fontSize: 12, color: base, fontWeight: FontWeight.w600),
          ),
          if (onDelete != null && !locked) ...[
            const SizedBox(width: 4),
            InkWell(
              onTap: onDelete,
              borderRadius: BorderRadius.circular(999),
              child: Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Icon(Icons.close, size: 14, color: base),
              ),
            )
          ],
          if (locked) ...[
            const SizedBox(width: 4),
            Icon(Icons.lock, size: 14, color: base),
          ],
        ],
      ),
    );
  }

  // ---------- Small input card ----------
  Widget _grantCard() {
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      surfaceTintColor: Colors.white,
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: primary.withOpacity(.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.admin_panel_settings, color: primary),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Grant Role',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _uidCtrl,
              decoration: InputDecoration(
                hintText: 'Enter user UID',
                isDense: true,
                filled: true,
                fillColor: Colors.grey.shade50,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: primary, width: 1.5),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _grantRole,
                    decoration: InputDecoration(
                      isDense: true,
                      filled: true,
                      fillColor: Colors.grey.shade50,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.grey.shade300),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: primary, width: 1.5),
                      ),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'viewer', child: Text('viewer')),
                      DropdownMenuItem(
                          value: 'reviewer', child: Text('reviewer')),
                      DropdownMenuItem(value: 'admin', child: Text('admin')),
                      DropdownMenuItem(
                          value: 'superadmin', child: Text('superadmin')),
                    ],
                    onChanged: (v) =>
                        setState(() => _grantRole = v ?? 'reviewer'),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton.icon(
                  onPressed: _grant,
                  style: FilledButton.styleFrom(
                    backgroundColor: primary,
                    padding: const EdgeInsets.symmetric(
                        vertical: 12, horizontal: 16),
                  ),
                  icon: const Icon(Icons.add),
                  label: const Text('Grant'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchAndFilter() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        children: [
          TextField(
            controller: _searchCtl,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'Search UID…',
              prefixIcon: const Icon(Icons.search),
              isDense: true,
              filled: true,
              fillColor: Colors.grey.shade50,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.grey.shade300),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: primary, width: 1.5),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Text('Filter by role  ',
                  style: TextStyle(fontSize: 12, color: Colors.black87)),
              const SizedBox(width: 8),
              DropdownButton<String>(
                value: _roleFilter,
                items: const [
                  DropdownMenuItem(value: 'all', child: Text('All')),
                  DropdownMenuItem(value: 'viewer', child: Text('viewer')),
                  DropdownMenuItem(value: 'reviewer', child: Text('reviewer')),
                  DropdownMenuItem(value: 'admin', child: Text('admin')),
                  DropdownMenuItem(
                      value: 'superadmin', child: Text('superadmin')),
                ],
                onChanged: (v) => setState(() => _roleFilter = v ?? 'all'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------- Rows list ----------
  List<Map<String, dynamic>> get _filteredRows {
    final q = _searchCtl.text.trim().toLowerCase();
    final rf = _roleFilter;
    return _rows.where((m) {
      final uid = _s(m['uid']).toLowerCase();
      final roles = _rolesOf(m).map((e) => e.toLowerCase()).toList();

      final matchesQ = q.isEmpty || uid.contains(q);
      final matchesR = (rf == 'all') || roles.contains(rf);
      return matchesQ && matchesR;
    }).toList();
  }

  Widget _adminRowCard(Map<String, dynamic> m) {
    final uid = _s(m['uid']);
    final roles = _rolesOf(m);
    final isSelf = uid == _selfUid;

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      surfaceTintColor: Colors.white,
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('UID',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Text(
                    uid.isEmpty ? '—' : uid,
                    style: const TextStyle(
                        fontWeight: FontWeight.w400, fontSize: 14),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                InkWell(
                  onTap: uid.isEmpty ? null : () => _copy(uid),
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child:
                        Icon(Icons.copy, size: 16, color: Colors.grey.shade700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text('Roles',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(height: 8),
            roles.isEmpty
                ? const Text('—', style: TextStyle(fontSize: 14))
                : Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: roles
                        .map((r) => _roleChip(
                              r,
                              onDelete: () => _revoke(uid, r),
                              locked: isSelf && r == 'superadmin',
                            ))
                        .toList(),
                  ),
          ],
        ),
      ),
    );
  }

  // ---------- Build ----------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.chevron_left, color: primary, size: 30),
          onPressed: () => Navigator.pop(context),
        ),
        centerTitle: true,
        title: Text(
          'Manage Admins',
          style: TextStyle(
            color: primary,
            fontWeight: FontWeight.bold,
            fontSize: 20,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _authorized ? _load : null,
            icon: Icon(Icons.refresh, color: primary),
          ),
        ],
      ),
      body: Builder(
        builder: (_) {
          // Show a single consistent loading state in the body
          if (!_authChecked || _loading) {
            return const Center(child: CircularProgressIndicator());
          }

          if (!_authorized) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24.0),
                child: Text(
                  'Access denied\nSuperadmin role required',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          return RefreshIndicator(
            onRefresh: _load,
            color: primary,
            child: ListView(
              padding: const EdgeInsets.only(bottom: 16),
              children: [
                _grantCard(),
                _searchAndFilter(),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Text('Administrators',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ),
                if (_filteredRows.isEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 16, 16, 24),
                    child: Text('No results'),
                  )
                else
                  ..._filteredRows.map(_adminRowCard),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _uidCtrl.dispose();
    _searchCtl.dispose();
    super.dispose();
  }
}

// ---------- Reusable confirm sheet ----------
class _ConfirmSheet extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String message;
  final String? detail;
  final String confirmText;
  final Color confirmColor;

  const _ConfirmSheet({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.message,
    this.detail,
    required this.confirmText,
    required this.confirmColor,
  });

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      heightFactor: 0.42,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.12),
              blurRadius: 24,
              offset: const Offset(0, -8),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 44,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: iconColor.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      alignment: Alignment.center,
                      child: Icon(icon, color: iconColor, size: 22),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: Colors.black87,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  message,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Colors.black87,
                    height: 1.35,
                  ),
                ),
                if (detail != null && detail!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(detail!,
                      style:
                          const TextStyle(fontSize: 12, color: Colors.black54)),
                ],
                const Spacer(),
                SafeArea(
                  top: false,
                  bottom: true,
                  minimum: const EdgeInsets.only(bottom: 24),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: Colors.grey.shade400),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () => Navigator.of(context).pop(true),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: confirmColor,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Text(confirmText),
                        ),
                      ),
                    ],
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
