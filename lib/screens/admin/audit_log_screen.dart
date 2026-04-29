// lib/screens/admin/audit_log_screen.dart
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../utils/constants.dart'; // AppColors.primaryColor
import '../../utils/role_guard.dart';

/// Audit Log screen styled in the same spirit as PendingDetailScreen:
/// - Clean white cards, brand accents, chips, copy-to-clipboard, modal details
/// - Admin-only (admin | superadmin) gate
/// - Filters: quick range, action type, search (actor/target/action/payload text)
/// - Tap row -> bottom sheet with pretty JSON payload + quick copy actions
class AuditLogScreen extends StatefulWidget {
  const AuditLogScreen({super.key});

  @override
  State<AuditLogScreen> createState() => _AuditLogScreenState();
}

class _AuditLogScreenState extends State<AuditLogScreen> {
  bool _authChecked = false;
  bool _authorized = false;

  // UI state
  final TextEditingController _searchCtl = TextEditingController();
  String _actionFilter = 'All';
  _Range _range = _Range.last7d;

  Color get primary => AppColors.primaryColor;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    // Ensure fresh token (avoid first-hit 401s after role changes)
    final u = FirebaseAuth.instance.currentUser;
    if (u != null) {
      await u.getIdToken(true);
    }

    final ok = await RoleGuard.isAdminOrAbove();
    if (!mounted) return;
    setState(() {
      _authChecked = true;
      _authorized = ok;
    });
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  // ===== Query builder =====
  Query<Map<String, dynamic>> _baseQuery() {
    final col = FirebaseFirestore.instance.collection('admin_audit');
    final now = DateTime.now();
    final from = _range.start(now);

    Query<Map<String, dynamic>> q = col
        .where('ts', isGreaterThanOrEqualTo: Timestamp.fromDate(from))
        .orderBy('ts', descending: true)
        .limit(200);

    if (_actionFilter != 'All') {
      q = q.where('action', isEqualTo: _actionFilter);
    }

    return q;
  }

  // Local in-memory text filter (client side) for search box
  bool _matchesSearch(Map<String, dynamic> m) {
    final q = _searchCtl.text.trim().toLowerCase();
    if (q.isEmpty) return true;

    bool match(String s) => s.toLowerCase().contains(q);

    final fields = <String>[
      (m['action'] ?? '').toString(),
      (m['actor_uid'] ?? '').toString(),
      (m['actor_email'] ?? '').toString(),
      (m['actor_display_name'] ?? '').toString(),
      (m['target_uid'] ?? '').toString(),
      (m['target'] ?? '').toString(),
      (m['note'] ?? '').toString(),
      (m['ip'] ?? '').toString(),
    ];

    if (fields.any((s) => s.isNotEmpty && match(s))) return true;

    // payload (JSON) text search
    final payload = m['payload'];
    if (payload != null) {
      try {
        final text = const JsonEncoder.withIndent('  ').convert(payload);
        if (match(text)) return true;
      } catch (_) {}
    }
    return false;
  }

  // ===== UI helpers =====
  String _fmtTs(dynamic ts) {
    if (ts is Timestamp) {
      final dt = ts.toDate().toLocal();
      return DateFormat('yyyy-MM-dd HH:mm').format(dt);
    }
    return ts?.toString() ?? '';
  }

  Future<void> _showDetails(Map<String, dynamic> m) async {
    final payload = m['payload'];
    final pretty = _prettyJson(payload);

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.4,
          maxChildSize: 0.9,
          builder: (context, controller) {
            return Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(24)),
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
                bottom: true,
                minimum: const EdgeInsets.only(bottom: 6),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: ListView(
                    controller: controller,
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
                              color: primary.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            alignment: Alignment.center,
                            child: Icon(Icons.history, color: primary),
                          ),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Text(
                              'Audit Entry',
                              style: TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.w700),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _kv('Action', (m['action'] ?? '').toString()),
                      _kv('Actor UID', (m['actor_uid'] ?? '').toString(),
                          copy: true),
                      if ((m['actor_email'] ?? '').toString().isNotEmpty)
                        _kv('Actor Email', (m['actor_email'] ?? '').toString(),
                            copy: true),
                      if ((m['actor_display_name'] ?? '').toString().isNotEmpty)
                        _kv('Actor Name',
                            (m['actor_display_name'] ?? '').toString()),
                      if ((m['target_uid'] ?? '').toString().isNotEmpty)
                        _kv('Target UID', (m['target_uid'] ?? '').toString(),
                            copy: true),
                      if ((m['ip'] ?? '').toString().isNotEmpty)
                        _kv('IP', (m['ip'] ?? '').toString(), copy: true),
                      _kv('Time', _fmtTs(m['ts'])),
                      const SizedBox(height: 12),
                      const Text('Payload',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade50,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.grey.shade300),
                        ),
                        child: SelectableText(
                          pretty.isEmpty ? '—' : pretty,
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 12),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () =>
                                  _copy(pretty.isEmpty ? '{}' : pretty),
                              icon: const Icon(Icons.copy),
                              label: const Text('Copy JSON'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: () => Navigator.of(context).maybePop(),
                              icon: const Icon(Icons.check),
                              label: const Text('Close'),
                              style: FilledButton.styleFrom(
                                  backgroundColor: primary),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  String _prettyJson(dynamic v) {
    if (v == null) return '';
    try {
      return const JsonEncoder.withIndent('  ').convert(v);
    } catch (_) {
      try {
        return const JsonEncoder.withIndent('  ')
            .convert(jsonDecode(v.toString()));
      } catch (_) {
        return v.toString();
      }
    }
  }

  Future<void> _copy(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Copied')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Copy failed: $e')));
    }
  }

  // ===== Widgets =====
  Widget _filters() {
    final ranges = {
      _Range.last24h: '24h',
      _Range.last7d: '7d',
      _Range.last30d: '30d',
      _Range.all: 'All',
    };

    final actions = const <String>[
      'All',
      'approve_verification',
      'reject_verification',
      'update_profile',
      'system',
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          // --- Search box (full-width, its own line) ---
          final searchBox = TextField(
            controller: _searchCtl,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'Search (action, actor, target, payload…)',
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
          );

          // --- Time dropdown ---
          final timeDd = DropdownButtonFormField<_Range>(
            value: _range,
            isDense: true,
            isExpanded: true,
            onChanged: (v) => setState(() => _range = v ?? _range),
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(12)),
              ),
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            ),
            icon: const Icon(Icons.arrow_drop_down, size: 18),
            items: ranges.entries
                .map((e) => DropdownMenuItem<_Range>(
                    value: e.key, child: Text(e.value)))
                .toList(),
          );

          // --- Action dropdown ---
          final actionDd = DropdownButtonFormField<String>(
            value: _actionFilter,
            isDense: true,
            isExpanded: true,
            onChanged: (v) => setState(() => _actionFilter = v ?? 'All'),
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(12)),
              ),
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            ),
            icon: const Icon(Icons.arrow_drop_down, size: 18),
            selectedItemBuilder: (context) => actions
                .map((a) => Text(a, overflow: TextOverflow.ellipsis))
                .toList(),
            items: actions
                .map((a) => DropdownMenuItem<String>(
                      value: a,
                      child: Text(a, overflow: TextOverflow.ellipsis),
                    ))
                .toList(),
          );

          // --- Layout: search on top, dropdowns side-by-side ---
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              searchBox,
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: timeDd),
                  const SizedBox(width: 8),
                  Expanded(child: actionDd),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _tile(Map<String, dynamic> m) {
    final action = (m['action'] ?? '').toString();
    final actor = (m['actor_uid'] ?? '').toString();
    final actorEmail = (m['actor_email'] ?? '').toString();
    final target = (m['target_uid'] ?? '').toString();
    final ts = m['ts'];

    final time = _fmtTs(ts);

    final icon = _actionIcon(action);
    final chipColor = _actionColor(action);

    return InkWell(
      onTap: () => _showDetails(m),
      child: Card(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        color: Colors.white,
        surfaceTintColor: Colors.white,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: chipColor.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: Icon(icon, color: chipColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            action.isEmpty ? '—' : action,
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w700),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Flexible(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerRight,
                            child: _chip(time,
                                icon: Icons.schedule, color: Colors.black87),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (actor.isNotEmpty)
                          _chip('actor: $actor',
                              icon: Icons.person,
                              color: Colors.black87,
                              copyValue: actor),
                        if (actorEmail.isNotEmpty)
                          _chip(actorEmail,
                              icon: Icons.alternate_email,
                              color: Colors.black87,
                              copyValue: actorEmail),
                        if (target.isNotEmpty)
                          _chip('target: $target',
                              icon: Icons.flag,
                              color: Colors.black87,
                              copyValue: target),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _actionIcon(String action) {
    switch (action) {
      case 'approve_verification':
        return Icons.verified;
      case 'reject_verification':
        return Icons.cancel;
      case 'update_profile':
        return Icons.manage_accounts;
      case 'system':
        return Icons.settings;
      default:
        return Icons.history;
    }
  }

  Color _actionColor(String action) {
    switch (action) {
      case 'approve_verification':
        return Colors.green;
      case 'reject_verification':
        return Colors.red.shade700;
      case 'update_profile':
        return primary;
      case 'system':
        return Colors.indigo;
      default:
        return Colors.grey.shade700;
    }
  }

  Widget _chip(String label,
      {IconData? icon, Color? color, String? copyValue}) {
    final fg = color ?? Colors.black87;
    return LayoutBuilder(
      builder: (context, constraints) {
        final cap = (constraints.maxWidth * 0.5).clamp(120.0, 220.0);
        return InkWell(
          onLongPress: (copyValue ?? label).isEmpty
              ? null
              : () => _copy(copyValue ?? label),
          borderRadius: BorderRadius.circular(999),
          child: Container(
            constraints: BoxConstraints(maxWidth: cap),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: (color ?? primary).withOpacity(.25)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 14, color: fg),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: fg),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _kv(String label, String value, {bool copy = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(label,
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 8),
          Expanded(child: SelectableText(value.isEmpty ? '—' : value)),
          if (copy && value.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () => _copy(value),
              tooltip: 'Copy',
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final q = _baseQuery();

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
          'Audit Log',
          style: TextStyle(
              color: primary, fontWeight: FontWeight.bold, fontSize: 20),
        ),
      ),
      body: Builder(
        builder: (_) {
          // Single consistent loading state in the body (AppBar always visible)
          if (!_authChecked) {
            return const Center(child: CircularProgressIndicator());
          }

          if (!_authorized) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24.0),
                child: Text(
                  'Access denied.\nAdmin or Superadmin role required.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          return Column(
            children: [
              _filters(),
              Expanded(
                child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: q.snapshots(),
                  builder: (_, snap) {
                    if (snap.hasError) {
                      return Center(child: Text('Error: ${snap.error}'));
                    }
                    if (!snap.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final all = snap.data!.docs.map((d) => d.data()).toList();
                    final docs = all.where(_matchesSearch).toList();
                    if (docs.isEmpty) {
                      return const Center(child: Text('No audit records'));
                    }
                    return ListView.builder(
                      itemCount: docs.length,
                      itemBuilder: (_, i) => _tile(docs[i]),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ===== Quick ranges =====
enum _Range { last24h, last7d, last30d, all }

extension on _Range {
  DateTime start(DateTime now) {
    switch (this) {
      case _Range.last24h:
        return now.subtract(const Duration(hours: 24));
      case _Range.last7d:
        return now.subtract(const Duration(days: 7));
      case _Range.last30d:
        return now.subtract(const Duration(days: 30));
      case _Range.all:
        return DateTime(1970);
    }
  }
}
