// lib/screens/settings/settings_screen.dart
import 'dart:async'; // for unawaited
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

// Provider + role manager (for instant, no-flicker admin gating)
import 'package:provider/provider.dart';
import '../../utils/role_manager.dart';

import '../../utils/constants.dart';
import '../../utils/shared_pref.dart';
import '../../services/auth_signout.dart';

// Navigation targets
import '../discover/discover_screen.dart';
import '../matches/matches_screen.dart';
import '../messages/messages_screen.dart';
import '../profile/profile_screen.dart';
import '../profile/edit_profile_screen.dart';
import '../auth/auth_screen.dart';

// Reassess modal deps
import '../../utils/eligibility_cache.dart';
import '../quiz/quiz_screen.dart';

// Notifications settings
import '../notifications/notification_settings.dart';

// Blocked users screen
import 'blocked_users_screen.dart';

//import 'manage_signin_screen.dart';


// ---- Admin deps ----
import '../../repositories/admin_repository.dart';
import '../admin/pending_review_screen.dart';
import '../admin/manage_admins_screen.dart';
import '../admin/audit_log_screen.dart';

// ⬇️ NEW: Terms modal
import '../../widgets/terms_modal.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _darkModeEnabled = false;
  bool _signingOut = false;

  // Reassess eligibility (seeded from cache)
  bool _eligLoading = true;
  bool _eligible = false;
  int _retryDays = 0;
  String? _eligError;

  @override
  void initState() {
    super.initState();

    // Warm the cache and seed local snapshot
    ReassessEligibilityCache.instance.get().then((data) {
      if (!mounted) return;
      setState(() {
        _eligLoading = false;
        _eligible = data.eligible;
        _retryDays = data.retryInDays;
        _eligError = null;
      });
    }).catchError((e) {
      if (!mounted) return;
      setState(() {
        _eligLoading = false;
        _eligError = e.toString();
      });
    });
  }

  // Kick a fetch for pending count the first time roles show reviewer+
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final rm = context.watch<RoleManager>();
    if (rm.isLoaded && rm.isReviewerOrAbove && rm.pendingCount == null) {
      // ignore: unawaited_futures
      rm.refreshPendingCount(); // RoleManager notifies listeners on update
    }
  }

  // ---------- Helpers ----------
  void _showFeatureComingSoonMessage() {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("This feature will be available soon!"),
        duration: Duration(seconds: 2),
      ),
    );
  }

  /// Instant-logout UX: navigate first, then clean up in the background.
  Future<void> _performLogout() async {
    if (_signingOut) return;
    setState(() => _signingOut = true);

    if (!mounted) return;

    // Navigate away immediately (wipe stack)
    Navigator.of(context).pushAndRemoveUntil(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const AuthScreen(isLogin: true),
        transitionsBuilder: (_, animation, __, child) {
          const begin = Offset(-1.0, 0.0);
          const end = Offset.zero;
          const curve = Curves.easeInOut;
          var tween =
              Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
          return SlideTransition(
              position: animation.drive(tween), child: child);
        },
        transitionDuration: const Duration(milliseconds: 400),
      ),
      (route) => false,
    );

    // Do the heavy work off-thread
    unawaited(() async {
      try {
        await clearAllPrefs();
      } catch (_) {}
      try {
        await AuthSignOut.signOutAll()
            .timeout(const Duration(seconds: 5), onTimeout: () {});
      } catch (_) {}
    }());
  }

  // ---------- Navigation helpers ----------
  void _navigateToDiscover() {
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const DiscoverScreen(),
        transitionsBuilder: (_, animation, __, child) {
          const begin = Offset(-1.0, 0.0);
          const end = Offset.zero;
          const curve = Curves.easeInOut;
          var tween =
              Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
          return SlideTransition(
              position: animation.drive(tween), child: child);
        },
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );
  }

  void _navigateToMatches() {
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const MatchesScreen(),
        transitionsBuilder: (_, animation, __, child) {
          const begin = Offset(-1.0, 0.0);
          const end = Offset.zero;
          const curve = Curves.easeInOut;
          var tween =
              Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
          return SlideTransition(
              position: animation.drive(tween), child: child);
        },
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );
  }

  void _navigateToMessages() {
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const MessagesScreen(),
        transitionsBuilder: (_, animation, __, child) {
          const begin = Offset(-1.0, 0.0);
          const end = Offset.zero;
          const curve = Curves.easeInOut;
          var tween =
              Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
          return SlideTransition(
              position: animation.drive(tween), child: child);
        },
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );
  }

  void _navigateToProfile() {
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const ProfileScreen(),
        transitionsBuilder: (_, animation, __, child) {
          const begin = Offset(-1.0, 0.0);
          const end = Offset.zero;
          const curve = Curves.easeInOut;
          var tween =
              Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
          return SlideTransition(
              position: animation.drive(tween), child: child);
        },
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );
  }

  void _navigateToEditProfile() {
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const EditProfileScreen(),
        transitionsBuilder: (_, animation, __, child) {
          const begin = Offset(1.0, 0.0);
          const end = Offset.zero;
          const curve = Curves.easeInOut;
          var tween =
              Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
          return SlideTransition(
              position: animation.drive(tween), child: child);
        },
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );
  }

  // ---------- New: Logout bottom sheet ----------
  Future<void> _showLogoutSheet() async {
    final primary = AppColors.primaryColor;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) {
        final h = MediaQuery.of(context).size.height;
        final sheetFactor = h < 700 ? 0.35 : 0.30;

        return FractionallySizedBox(
          heightFactor: sheetFactor,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(24)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.12),
                  blurRadius: 24,
                  offset: const Offset(0, -8),
                )
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
                    // drag handle
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

                    // header
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
                          child: Icon(Icons.logout_rounded, color: primary),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            'Log out',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: Colors.black87,
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 12),

                    const Text(
                      'Are you sure you want to log out? You can sign in again anytime.',
                      textAlign: TextAlign.justify,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.black87,
                        height: 1.35,
                      ),
                    ),

                    const Spacer(),

                    // Buttons + safe bottom space
                    SafeArea(
                      top: false,
                      bottom: true,
                      minimum: const EdgeInsets.only(bottom: 28),
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () => Navigator.of(context).pop(),
                                style: OutlinedButton.styleFrom(
                                  side: BorderSide(color: Colors.grey.shade400),
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 14),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                child: const Text('Close'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: ElevatedButton(
                                onPressed: _signingOut
                                    ? null
                                    : () async {
                                        Navigator.of(context).pop();
                                        await _performLogout();
                                      },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: _signingOut
                                      ? Colors.grey.shade400
                                      : primary,
                                  foregroundColor: Colors.white,
                                  elevation: 0,
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 14),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                child: const Text('Log out'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // ---------- Re-assess bottom sheet ----------
  Future<void> _showReassessSheet() async {
    bool locLoading = _eligLoading;
    bool locEligible = _eligible;
    int locRetry = _retryDays;
    String? locErr = _eligError;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            Future<void> refresh() async {
              setModalState(() {
                locLoading = true;
                locErr = null;
              });
              try {
                final data = await ReassessEligibilityCache.instance
                    .get(forceRefresh: true);
                setModalState(() {
                  locEligible = data.eligible;
                  locRetry = data.retryInDays;
                  locLoading = false;
                  locErr = null;
                });
              } catch (e) {
                setModalState(() {
                  locLoading = false;
                  locErr = e.toString();
                });
              }
            }

            final primary = AppColors.primaryColor;
            final h = MediaQuery.of(ctx).size.height;
            final sheetFactor =
                h < 700 ? 0.45 : 0.40; // taller on small screens

            return AnimatedPadding(
              duration: const Duration(milliseconds: 200),
              padding:
                  EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
              child: FractionallySizedBox(
                heightFactor: sheetFactor,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(24)),
                    boxShadow: [
                      BoxShadow(
                          color: Colors.black.withOpacity(0.12),
                          blurRadius: 24,
                          offset: const Offset(0, -8))
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
                          // drag handle
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

                          // header
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
                                child: Icon(Icons.restart_alt, color: primary),
                              ),
                              const SizedBox(width: 12),
                              const Expanded(
                                child: Text(
                                  'Re-assess quiz',
                                  style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.black87),
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 12),

                          const Text(
                            'Update your Attachment Style, Love Language, and Preferences. '
                            'This will overwrite your previous results.',
                            textAlign: TextAlign.justify,
                            style: TextStyle(
                                fontSize: 14,
                                color: Colors.black87,
                                height: 1.35),
                          ),

                          const SizedBox(height: 18),

                          // Status area
                          SizedBox(
                            height: 54,
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 200),
                              child: () {
                                if (locLoading) {
                                  return Row(
                                    key: const ValueKey('loading'),
                                    children: const [
                                      SizedBox(
                                        height: 20,
                                        width: 20,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2),
                                      ),
                                      SizedBox(width: 10),
                                      Text("Checking eligibility..."),
                                    ],
                                  );
                                } else if (locErr != null) {
                                  return Row(
                                    key: const ValueKey('error'),
                                    children: [
                                      Expanded(
                                        child: Text(
                                          "Couldn’t check eligibility. Please try again.",
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                              color: Colors.redAccent),
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: "Refresh",
                                        onPressed: refresh,
                                        icon: const Icon(Icons.refresh),
                                        visualDensity: VisualDensity.compact,
                                      ),
                                    ],
                                  );
                                } else {
                                  return Row(
                                    key: const ValueKey('result'),
                                    crossAxisAlignment:
                                        CrossAxisAlignment.center,
                                    children: [
                                      Expanded(
                                        child: Text(
                                          locEligible
                                              ? "You’re eligible to re-assess now."
                                              : "Locked – $locRetry day${locRetry == 1 ? '' : 's'} remaining.",
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: locEligible
                                                ? Colors.green.shade700
                                                : Colors.grey.shade700,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: "Refresh",
                                        onPressed: refresh,
                                        icon: const Icon(Icons.refresh),
                                        visualDensity: VisualDensity.compact,
                                      ),
                                    ],
                                  );
                                }
                              }(),
                            ),
                          ),

                          const Spacer(),

                          // Buttons + safe bottom space
                          SafeArea(
                            top: false,
                            bottom: true,
                            minimum: const EdgeInsets.only(bottom: 28),
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton(
                                      onPressed: () => Navigator.of(ctx).pop(),
                                      style: OutlinedButton.styleFrom(
                                        side: BorderSide(
                                            color: Colors.grey.shade400),
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 14),
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(12),
                                        ),
                                      ),
                                      child: const Text('Close'),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: ElevatedButton(
                                      onPressed: locEligible
                                          ? () async {
                                              Navigator.of(ctx).pop();
                                              if (!mounted) return;
                                              await Navigator.push(
                                                context,
                                                MaterialPageRoute(
                                                  builder: (_) =>
                                                      const QuizSetupScreen(),
                                                  settings: const RouteSettings(
                                                      arguments: {
                                                        'reassess': true
                                                      }),
                                                ),
                                              );
                                            }
                                          : null,
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: locEligible
                                            ? primary
                                            : Colors.grey.shade400,
                                        foregroundColor: Colors.white,
                                        elevation: 0,
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 14),
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(12),
                                        ),
                                      ),
                                      child: const Text('Start'),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      appBar: _buildAppBar(),
      body: _buildSettingsContent(),
      bottomNavigationBar: _buildBottomNavBar(), // Same style as Profile
    );
  }

  AppBar _buildAppBar() {
    return AppBar(
      automaticallyImplyLeading: false,
      backgroundColor: Colors.white,
      foregroundColor: Colors.black,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 4,
      shadowColor: Colors.black.withOpacity(0.1),
      titleSpacing: 0,
      title: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // Left-aligned back
            IconButton(
              onPressed: () => Navigator.of(context).pop(),
              icon: Icon(Icons.chevron_left,
                  color: AppColors.primaryColor, size: 28),
            ),
            // Title
            Row(
              children: [
                Text(
                  "AttachMates",
                  style: GoogleFonts.indieFlower(
                    textStyle: TextStyle(
                      color: AppColors.primaryColor,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Text("Settings",
                    style:
                        TextStyle(color: Colors.grey.shade600, fontSize: 14)),
              ],
            ),
            const SizedBox(width: 40), // spacer for symmetry
          ],
        ),
      ),
    );
  }

  Widget _buildSettingsContent() {
    final rm = context.watch<RoleManager>(); // roles & flags from provider

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // ACCOUNT
        _buildSectionHeader("ACCOUNT"),
        _buildSettingsCard([
          _buildSettingsItem(
            title: "Edit Profile",
            icon: Icons.edit_outlined,
            onTap: _navigateToEditProfile,
            showArrow: true,
          ),
          _buildDivider(),
          // Re-assess Quiz in Settings → Account
          _buildSettingsItem(
            title: "Re-assess Quiz",
            icon: Icons.restart_alt,
            onTap: _showReassessSheet,
            showArrow: true,
          ),
          _buildDivider(),
          _buildSettingsItem(
            title: "Manage Sign-In Methods",
            icon: Icons.login_outlined,
            onTap: _showFeatureComingSoonMessage,
            showArrow: true,
          ),
        ]),
        const SizedBox(height: 24),

        // PRIVACY & SAFETY
        _buildSectionHeader("PRIVACY & SAFETY"),
        _buildSettingsCard([
          _buildSettingsItem(
            title: "Blocked Users",
            icon: Icons.block_outlined,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const BlockedUsersScreen()),
              );
            },
            showArrow: true,
          ),
          // ⬇️ Removed "Safe Match Verification"
        ]),
        const SizedBox(height: 24),

        // ---- ADMIN (conditional) ----
        if (rm.isLoaded && rm.isReviewerOrAbove) ...[
          _buildSectionHeader("ADMIN"),
          _buildSettingsCard([
            _buildSettingsItem(
              title: "Review Requests",
              icon: Icons.pending_actions,
              onTap: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const ReviewRequestScreen()),
                );
                // Refresh count on return (update RoleManager globally)
                // ignore: use_build_context_synchronously
                context.read<RoleManager>().refreshPendingCount();
              },
              showArrow: true,
              trailing: _buildPendingBadge(rm.pendingCount), // ← from provider
            ),
            // Audit Log visible to admin & superadmin
            if (rm.isAdminOrAbove) ...[
              _buildDivider(),
              _buildSettingsItem(
                title: "Audit Log",
                icon: Icons.history,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AuditLogScreen()),
                ),
                showArrow: true,
              ),
            ],
            // Manage Admins → superadmin only
            if (rm.isSuperadmin) ...[
              _buildDivider(),
              _buildSettingsItem(
                title: "Manage Admins",
                icon: Icons.manage_accounts_outlined,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ManageAdminsScreen()),
                ),
                showArrow: true,
              ),
            ],
          ]),
          const SizedBox(height: 24),
        ],

        // APP PREFERENCES
        _buildSectionHeader("APP PREFERENCES"),
        _buildSettingsCard([
          _buildSettingsItem(
            title: "Dark Mode",
            icon: Icons.dark_mode_outlined,
            trailing: Switch(
              value: _darkModeEnabled,
              onChanged: (value) {
                setState(() => _darkModeEnabled = value);
                _showFeatureComingSoonMessage();
              },
              activeColor: AppColors.primaryColor,
            ),
          ),
          _buildDivider(),
          // Tap to open dedicated notifications screen
          _buildSettingsItem(
            title: "Notifications",
            icon: Icons.notifications_outlined,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const NotificationsSettingsScreen()),
              );
            },
            showArrow: true,
          ),
        ]),

        const SizedBox(height: 24),

        // ABOUT
        _buildSectionHeader("ABOUT"),
        _buildSettingsCard([
          _buildSettingsItem(
            title: "Help & Support",
            icon: Icons.help_outline,
            onTap: _showFeatureComingSoonMessage,
            showArrow: true,
          ),
          _buildDivider(),
          // ⬇️ Split into two separate items, both using showTermsModal
          _buildSettingsItem(
            title: "Terms of Use",
            icon: Icons.article_outlined,
            onTap: () => showTermsModal(context),
            showArrow: true,
          ),
          _buildDivider(),
          _buildSettingsItem(
            title: "Privacy Policy",
            icon: Icons.privacy_tip_outlined,
            onTap: () => showTermsModal(context),
            showArrow: true,
          ),
          _buildDivider(),
          _buildSettingsItem(
            title: "App Version",
            icon: Icons.info_outline,
            trailing: Text("v1.0.0",
                style: TextStyle(color: Colors.grey.shade600, fontSize: 14)),
          ),
        ]),
        const SizedBox(height: 24),

        // SESSION
        _buildSectionHeader("SESSION"),
        _buildSettingsCard([
          _buildSettingsItem(
            title: "Log Out",
            icon: Icons.logout_outlined,
            onTap: _showLogoutSheet, // ← switched from dialog to bottom sheet
            showArrow: true,
            titleColor: Colors.red,
          ),
        ]),
        const SizedBox(height: 24),
      ]),
    );
  }

  // ---- tiny badge helper (fixed-height red pill; no layout jump)
  Widget? _buildPendingBadge(int? count) {
    if (count == null || count <= 0) return null;
    final label = count > 99 ? '99+' : '$count';

    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
      child: Container(
        height: 22, // fixed height → no layout jump
        padding: const EdgeInsets.symmetric(horizontal: 6),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.redAccent, // red badge
          borderRadius: BorderRadius.circular(11), // circle @ h=22
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            height: 1.0,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title,
        style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: Colors.grey.shade600,
            letterSpacing: 0.5),
      ),
    );
  }

  Widget _buildSettingsCard(List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 4,
              offset: const Offset(0, 2))
        ],
      ),
      child: Column(children: children),
    );
  }

  Widget _buildSettingsItem({
    required String title,
    IconData? icon,
    VoidCallback? onTap,
    Widget? trailing,
    bool showArrow = false,
    Color? titleColor,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon,
                  size: 22,
                  color: titleColor ?? AppColors.primaryColor.withOpacity(0.8)),
              const SizedBox(width: 16),
            ],
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: titleColor ?? Colors.black87),
              ),
            ),
            if (trailing != null) trailing,
            if (showArrow)
              Icon(Icons.chevron_right, color: Colors.grey.shade400, size: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildDivider() {
    return Divider(
        height: 1,
        thickness: 1,
        color: Colors.grey.shade200,
        indent: 16,
        endIndent: 16);
  }

  // ---------- Bottom nav (same style/behavior as Profile screen) ----------
  Widget _buildBottomNavBar() {
    return SafeArea(
      top: false,
      child: BottomNavigationBar(
        currentIndex: 0, // choose Profile tab highlight (closest fit)
        backgroundColor: Colors.white,
        elevation: 0,
        type: BottomNavigationBarType.fixed,
        selectedItemColor: Colors.grey,
        unselectedItemColor: Colors.grey,
        onTap: (i) {
          if (i == 0) _navigateToDiscover();
          if (i == 1) _navigateToMatches();
          if (i == 2) _navigateToMessages();
          if (i == 3) _navigateToProfile();
        },
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.search), label: "Discover"),
          BottomNavigationBarItem(
              icon: Icon(Icons.favorite_border), label: "Matches"),
          BottomNavigationBarItem(
              icon: Icon(Icons.chat_bubble_outline), label: "Messages"),
          BottomNavigationBarItem(
              icon: Icon(Icons.person_outline), label: "Profile"),
        ],
      ),
    );
  }
}
