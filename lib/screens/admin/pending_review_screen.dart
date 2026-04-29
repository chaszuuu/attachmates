import 'package:flutter/material.dart';
import '../../repositories/admin_repository.dart';
import '../../widgets/admin/pending_card.dart';
import 'pending_detail_screen.dart';
import '../../utils/role_guard.dart';
import '../../utils/constants.dart'; // AppColors.primaryColor

class ReviewRequestScreen extends StatefulWidget {
  const ReviewRequestScreen({super.key});

  @override
  State<ReviewRequestScreen> createState() => _ReviewRequestScreenState();
}

class _ReviewRequestScreenState extends State<ReviewRequestScreen> {
  bool _authChecked = false;
  bool _authorized = false;
  String _query = '';

  Color get primary => AppColors.primaryColor;

  @override
  void initState() {
    super.initState();
    _checkAuthThenLoad();
  }

  Future<void> _checkAuthThenLoad() async {
    final ok = await RoleGuard.isReviewerOrAbove();
    if (!mounted) return;
    setState(() {
      _authChecked = true;
      _authorized = ok;
    });
  }

  String _str(dynamic v) => v == null ? '' : v.toString();

  Widget _chip(String label, {IconData? icon, Color? color}) {
    final fg = color ?? Colors.black87;
    return Container(
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
          Text(label, style: TextStyle(fontSize: 12, color: fg)),
        ],
      ),
    );
  }

  List<Map<String, dynamic>> _applyFilter(List<Map<String, dynamic>> items) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return items;

    return items.where((m) {
      final uid = _str(m['uid']).toLowerCase();
      final dn = _str(m['displayName']).toLowerCase();
      final dns = _str(m['display_name']).toLowerCase();
      final pi =
          (m['personal_info'] as Map?)?.cast<String, dynamic>() ?? const {};
      final first = _str(pi['first_name']).toLowerCase();
      final last = _str(pi['last_name']).toLowerCase();
      final full =
          [first, last].where((s) => s.isNotEmpty).join(' ').toLowerCase();

      return uid.contains(q) ||
          dn.contains(q) ||
          dns.contains(q) ||
          first.contains(q) ||
          last.contains(q) ||
          full.contains(q);
    }).toList();
  }

  List<Map<String, dynamic>> _sortBySubmittedAt(
      List<Map<String, dynamic>> items) {
    DateTime _parse(dynamic v) {
      if (v == null) return DateTime.fromMillisecondsSinceEpoch(0);
      try {
        if (v is dynamic && v.toString().contains('Timestamp')) {
          final dt = v.toDate();
          if (dt is DateTime) return dt;
        }
      } catch (_) {}
      if (v is DateTime) return v;
      return DateTime.tryParse(v.toString()) ??
          DateTime.fromMillisecondsSinceEpoch(0);
    }

    DateTime _getDt(Map m) {
      final iv =
          (m['identity_verification'] as Map?)?.cast<String, dynamic>() ??
              const {};
      final raw = iv['submitted_at'] ?? m['verificationSubmittedAt'];
      return _parse(raw);
    }

    final copy = [...items];
    copy.sort((a, b) => _getDt(b).compareTo(_getDt(a)));
    return copy;
  }

  @override
  Widget build(BuildContext context) {
    if (!_authChecked) {
      return _loadingScaffold();
    }

    if (!_authorized) {
      return _deniedScaffold();
    }

    final stream = AdminRepository.pendingStream(limit: 100);

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
          'Verification Review',
          style: TextStyle(
              color: primary, fontWeight: FontWeight.bold, fontSize: 20),
        ),
      ),
      body: Column(
        children: [
          // Pending count on top-right above search
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Align(
              alignment: Alignment.centerRight,
              child: StreamBuilder<List<Map<String, dynamic>>>(
                stream: stream,
                builder: (ctx, snap) {
                  final count = (snap.data ?? const []).length;
                  return _chip('Pending: $count',
                      icon: Icons.hourglass_bottom, color: Colors.black87);
                },
              ),
            ),
          ),

          // Search bar below the chip
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: TextField(
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: 'Search by name or UID',
                isDense: true,
                filled: true,
                fillColor: Colors.white,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: Colors.grey.shade300, // soft grey outline
                    width: 1,
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: Colors.grey.shade300,
                    width: 1,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: Colors.grey.shade400,
                    width: 1.2,
                  ),
                ),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),

          const SizedBox(height: 8),

          // List
          Expanded(
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: stream,
              builder: (ctx, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Text('Load failed — ${snap.error}'),
                    ),
                  );
                }

                final items = snap.data ?? const <Map<String, dynamic>>[];
                final filtered = _applyFilter(items);
                final sorted = _sortBySubmittedAt(filtered);

                if (sorted.isEmpty) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24.0),
                      child: Text('No pending users found.'),
                    ),
                  );
                }

                return RefreshIndicator(
                  onRefresh: () async {
                    // no-op; stream auto-refreshes
                  },
                  child: ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    // ⬇️ EXACT same horizontal as the search bar (16)
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    itemCount: sorted.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (ctx, i) {
                      final item = sorted[i];

                      return PendingCard(
                        item: item,
                        onTap: () async {
                          final changed = await Navigator.push<bool>(
                            context,
                            MaterialPageRoute(
                              builder: (_) => PendingDetailScreen(user: item),
                            ),
                          );
                          if (changed == true && mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Updated — live data refreshed'),
                              ),
                            );
                          }
                        },
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ---------- small helpers ----------
  Scaffold _loadingScaffold() => Scaffold(
        backgroundColor: Colors.white,
        appBar: _basicAppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );

  Scaffold _deniedScaffold() => Scaffold(
        backgroundColor: Colors.white,
        appBar: _basicAppBar(),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24.0),
            child: Text(
              'Access denied.\nReviewer, Admin, or Superadmin role required.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );

  AppBar _basicAppBar() => AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.chevron_left, color: primary, size: 30),
          onPressed: () => Navigator.pop(context),
        ),
        centerTitle: true,
        title: Text(
          'Verification Review',
          style: TextStyle(
              color: primary, fontWeight: FontWeight.bold, fontSize: 20),
        ),
      );
}
