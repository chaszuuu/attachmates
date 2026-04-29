import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
// ⬇️ NEW: Supabase
import 'package:supabase_flutter/supabase_flutter.dart';

// ⬇️ provider + repos
import 'package:provider/provider.dart';
import 'repositories/blocks_repository.dart';

import 'screens/onboarding/onboarding_screen.dart';
import 'screens/auth/auth_screen.dart';
import 'screens/profile_setup/profile_setup_screen.dart';
import 'screens/discover/discover_screen.dart';
import 'screens/results/profile_verification_screen.dart';
import 'services/firebase_options.dart';
import 'screens/quiz/quiz_screen.dart';

import 'utils/presence_service.dart';
import 'services/fcm_token_service.dart';
import 'services/push_service.dart';

// ✅ respect Settings toggle
import 'utils/shared_pref.dart';

// ⬇️ NEW: roles provider (cached custom-claim roles to prevent flicker)
import 'utils/role_manager.dart';

// for deep links to a chat from notifications
import 'screens/messages/conversation_screen.dart';
import 'screens/messages/messages_screen.dart';
import 'screens/matches/matches_screen.dart';
import 'screens/profile/profile_screen.dart';
import 'screens/settings/settings_screen.dart';
// 🔔 open the in-app notifications list on certain taps
import 'screens/notifications/notifications_screen.dart';

// Global navigator key so we can route from notification taps
final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();

// ─────────────────────────────────────────────────────────────────────────────
// FCM BACKGROUND HANDLER (must be a top-level or static function)
// ─────────────────────────────────────────────────────────────────────────────
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // Lightweight work only
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  try {
    await dotenv.load(fileName: ".env");
  } catch (_) {}

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // ⬇️ NEW: Initialize Supabase from .env (must be before any Supabase.instance.client usage)
  final supabaseUrl = dotenv.env['SUPABASE_URL'];
  final supabaseAnonKey = dotenv.env['SUPABASE_ANON_KEY'];
  if (supabaseUrl == null || supabaseAnonKey == null) {
    // You said you'll add these in .env; this guard avoids cryptic crashes if missing.
    debugPrint("⚠️ Missing SUPABASE_URL / SUPABASE_ANON_KEY in .env");
  } else {
    await Supabase.initialize(
      url: supabaseUrl,
      anonKey: supabaseAnonKey,
    );
  }

  // Register FCM background handler once after Firebase init
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  // Foreground push handling + local notifications + token auto-refresh (idempotent)
  await PushService.init();

  // Hook up a global tap router for notification clicks
  PushService.onNotificationTap = _handleNotifTap;

  // If the app was launched by tapping a notif while terminated, route now
  final initialMsg = await FirebaseMessaging.instance.getInitialMessage();
  if (initialMsg?.data.isNotEmpty == true) {
    _handleNotifTap(initialMsg!.data);
  }

  // Optional but recommended: explicit local caches
  FirebaseFirestore.instance.settings =
      const Settings(persistenceEnabled: true);
  FirebaseDatabase.instance.setPersistenceEnabled(true);

  // Presence + Push — keep status and device token correct across sign-in/sign-out
  FirebaseAuth.instance.authStateChanges().listen((user) async {
    if (user != null) {
      await PushService.init(); // idempotent safety
      await PresenceService().start();

      // ✅ Respect stored toggle
      final enabled = await SharedPref.getBool('notif_enabled') ?? true;
      if (enabled) {
        await PushService.enable(); // asks permission if needed + saves token
      } else {
        await PushService.disable(); // marks device disabled for this user
      }

      // (Optional) If you want to keep these lines, they’re harmless,
      // but PushService.enable() already saves & binds the token.
      // await FcmTokenService.saveForCurrentUser();
      // FcmTokenService.bindAutoRefresh();
    } else {
      await PresenceService().stop();
      // Sign-out flow already handles token cleanup/disable.
    }
  });

  // If already signed in on cold start, kick off presence & ensure push per toggle
  final current = FirebaseAuth.instance.currentUser;
  if (current != null) {
    // 🔑 Warm a fresh ID token at startup to avoid early 401/expired blips
    try {
      await current.getIdToken(true);
    } catch (_) {}

    // ignore: unawaited_futures
    PresenceService().start();

    final enabled = await SharedPref.getBool('notif_enabled') ?? true;
    if (enabled) {
      // ignore: unawaited_futures
      PushService.enable();
    } else {
      // ignore: unawaited_futures
      PushService.disable();
    }
  }

  // Optional now (RoleManager will refresh claims post-mount)
  // await FirebaseAuth.instance.currentUser?.getIdToken(true);

  // ⬇️ Provide repositories to the widget tree
  runApp(
    MultiProvider(
      providers: [
        // ⬇️ NEW: roles provider — instant cache hydrate, no network
        ChangeNotifierProvider<RoleManager>(
          create: (_) => RoleManager()..hydrateFromCache(),
        ),
        // NOTE: don't eager-refresh here; auth may not be ready yet.
        ChangeNotifierProvider<BlocksRepository>(
          create: (_) => BlocksRepository(),
        ),
      ],
      child: const MyApp(),
    ),
  );

  // ⬇️ Keep providers in sync with auth state after the app mounts
  FirebaseAuth.instance.authStateChanges().listen((user) {
    // Ensure the widget tree is ready
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final ctx = _navKey.currentContext;
      if (ctx == null) return; // app not mounted yet

      // ⬇️ NEW: RoleManager sync (prevents Settings admin flicker)
      final roles = ctx.read<RoleManager>();
      if (user == null) {
        await roles.clear();
      } else {
        // Quick refresh (no force) so UI is instant from current token/claims
        await roles.refresh(force: false);
        // Then a single forced refresh in background to pick up any recent role changes
        // ignore: unawaited_futures
        roles.refresh(force: true);
        // ⬅️ NEW: also preload the pending badge (no flicker, auto-appears)
        // ignore: unawaited_futures
        roles.refreshPendingCount();
      }

      // Existing BlocksRepository sync
      final blocks = ctx.read<BlocksRepository>();
      if (user == null) {
        blocks.clear(); // 🧹 drop cached lists on sign-out
      } else {
        // ignore: unawaited_futures
        blocks.refresh().catchError((_) {});
        // 🔄 refresh lists on sign-in
      }
    });
  });
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});
  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late final Future<Widget> _initialFuture;

  @override
  void initState() {
    super.initState();
    _initialFuture = _getInitialScreen();
    _printFirebaseToken();
  }

  Future<void> _printFirebaseToken() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      print("⚠️ No user signed in");
      return;
    }

    final token =
        await user.getIdToken(); // or getIdToken(true) for a forced refresh
    print("🔑 Firebase ID Token:\n$token");
  }

  String _normalizeStatus(String? s) {
    final v = (s ?? '').toLowerCase().trim();
    if (v.isEmpty || v == 'not_started' || v == 'unknown') return 'pending';
    return v;
  }

  Future<Widget> _getInitialScreen() async {
    try {
      // 1) Onboarding (local-only)
      final prefs = await SharedPreferences.getInstance();
      final hasSeen = prefs.getBool('hasSeenOnboarding') ?? false;
      if (!hasSeen) {
        await prefs.setBool('hasSeenOnboarding', true);
        return const OnboardingScreen();
      }

      // 2) Auth
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return const AuthScreen(isLogin: true);
      await user.reload();
      final uid = FirebaseAuth.instance.currentUser!.uid;

      // 3) User doc — try SERVER first (short timeout), then fall back to CACHE
      final users = FirebaseFirestore.instance.collection('users').doc(uid);

      DocumentSnapshot<Map<String, dynamic>> snap;
      try {
        snap = await users
            .get(const GetOptions(source: Source.server))
            .timeout(const Duration(seconds: 3));
      } on Exception {
        snap = await users.get(const GetOptions(source: Source.cache));
      }

      if (!snap.exists) {
        return const ProfileSetupScreen();
      }

      final data = (snap.data() ?? <String, dynamic>{});
      final fromServer = !snap.metadata.isFromCache;

      // 4) Require setup completion
      final setupDone = (data['profile_setup_complete'] == true) ||
          (data['profileSetupComplete'] == true); // legacy support
      if (!setupDone) {
        return const ProfileSetupScreen();
      }

      // 5) Identity status — support camelCase & snake_case, nested or flat
      String status = 'pending';
      final ivCamel = data['identityVerification'];
      final ivSnake = data['identity_verification'];

      if (ivCamel is Map && ivCamel['status'] is String) {
        status = ivCamel['status'];
      } else if (data['identityVerificationStatus'] is String) {
        status = data['identityVerificationStatus'];
      } else if (ivSnake is Map && ivSnake['status'] is String) {
        status = ivSnake['status'];
      } else if (data['identity_verification_status'] is String) {
        status = data['identity_verification_status'];
      }
      status = _normalizeStatus(status);

      // 6) Quiz completed — default missing/null to false
      bool quizCompleted = false;
      final quiz = data['quiz'];
      if (quiz is Map<String, dynamic>) {
        final c = quiz['completed'];
        if (c is bool) quizCompleted = c;
      }

      // 7) Final routing
      if (status == 'rejected') {
        return const ProfileVerificationScreen(status: 'rejected');
      }
      if (!fromServer && status != 'approved') {
        // If we only have cache and user isn't approved, wait for server truth
        return const _CheckingScreen();
      }
      if (status != 'approved') {
        return const ProfileVerificationScreen(status: 'pending');
      }
      if (!quizCompleted) {
        return const QuizSetupScreen();
      }
      return const DiscoverScreen();
    } catch (e) {
      debugPrint('Error during startup: $e');
      return const AuthScreen(isLogin: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navKey, // ← enables routing from notif taps
      title: 'AttachMates',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFB5276A),
          primary: const Color(0xFFB5276A),
        ),
        textTheme: GoogleFonts.poppinsTextTheme(),
        useMaterial3: true,
      ),
      home: FutureBuilder<Widget>(
        future: _initialFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          return snapshot.data ?? const AuthScreen(isLogin: true);
        },
      ),
    );
  }
}

class _CheckingScreen extends StatefulWidget {
  const _CheckingScreen();
  @override
  State<_CheckingScreen> createState() => _CheckingScreenState();
}

class _CheckingScreenState extends State<_CheckingScreen> {
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sub;

  @override
  void initState() {
    super.initState();

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      _go(const AuthScreen(isLogin: true));
      return;
    }

    _sub = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .snapshots(includeMetadataChanges: true)
        .listen((snap) {
      // Only act on server updates to avoid stale cache flicker
      if (snap.metadata.isFromCache) return;

      final d = snap.data() ?? {};
      String status = 'pending';

      // Support all schema variants
      final ivCamel = d['identityVerification'];
      final ivSnake = d['identity_verification'];

      if (ivCamel is Map && ivCamel['status'] is String) {
        status = (ivCamel['status'] as String);
      } else if (d['identityVerificationStatus'] is String) {
        status = (d['identityVerificationStatus'] as String);
      } else if (ivSnake is Map && ivSnake['status'] is String) {
        status = (ivSnake['status'] as String);
      } else if (d['identity_verification_status'] is String) {
        status = (d['identity_verification_status'] as String);
      }
      status = status.toLowerCase().trim();

      final quizDone = (d['quiz'] is Map) && (d['quiz']['completed'] == true);

      if (status == 'rejected') {
        _go(const ProfileVerificationScreen(status: 'rejected'));
      } else if (status != 'approved') {
        _go(const ProfileVerificationScreen(status: 'pending'));
      } else if (!quizDone) {
        _go(const QuizSetupScreen());
      } else {
        _go(const DiscoverScreen());
      }
    });
  }

  void _go(Widget page) {
    if (!mounted) return;
    _sub?.cancel();
    _sub = null;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => page,
        transitionsBuilder: (_, a, __, child) =>
            FadeTransition(opacity: a, child: child),
        transitionDuration: const Duration(milliseconds: 200),
      ),
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Helpers for verification deep link
// ─────────────────────────────────────────────────────────────
String _readIdentityStatus(Map<String, dynamic> data) {
  String? s;
  final ivCamel = data['identityVerification'];
  final ivSnake = data['identity_verification'];

  if (ivCamel is Map && ivCamel['status'] is String)
    s = ivCamel['status'];
  else if (data['identityVerificationStatus'] is String)
    s = data['identityVerificationStatus'];
  else if (ivSnake is Map && ivSnake['status'] is String)
    s = ivSnake['status'];
  else if (data['identity_verification_status'] is String)
    s = data['identity_verification_status'];

  final v = (s ?? '').toLowerCase().trim();
  if (v.isEmpty || v == 'not_started' || v == 'unknown') return 'pending';
  return v;
}

Future<void> _routeToVerification(
    {String? statusHint, bool? quizCompletedHint}) async {
  final nav = _navKey.currentState;
  if (nav == null) return;

  final user = FirebaseAuth.instance.currentUser;
  if (user == null) {
    nav.push(
        MaterialPageRoute(builder: (_) => const AuthScreen(isLogin: true)));
    return;
  }

  // Fast path if notif already told us the status (and optionally quiz_completed)
  String status = (statusHint ?? '').toLowerCase().trim();
  if (status.isNotEmpty) {
    final quizDone = quizCompletedHint ?? false; // default if not provided
    if (status == 'approved') {
      nav.push(MaterialPageRoute(
          builder: (_) =>
              quizDone ? const DiscoverScreen() : const QuizSetupScreen()));
    } else if (status == 'rejected') {
      nav.push(MaterialPageRoute(
          builder: (_) => const ProfileVerificationScreen(status: 'rejected')));
    } else {
      nav.push(MaterialPageRoute(
          builder: (_) => const ProfileVerificationScreen(status: 'pending')));
    }
    return;
  }

  // No status in payload → fetch latest from Firestore (server-first, cache fallback)
  try {
    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get(const GetOptions(source: Source.server))
        .timeout(const Duration(seconds: 3));

    final data = doc.data() ?? <String, dynamic>{};
    final statusNow = _readIdentityStatus(data);
    final quizMap = (data['quiz'] is Map)
        ? Map<String, dynamic>.from(data['quiz'])
        : const <String, dynamic>{};
    final quizDone = quizMap['completed'] == true;

    if (statusNow == 'approved') {
      nav.push(MaterialPageRoute(
          builder: (_) =>
              quizDone ? const DiscoverScreen() : const QuizSetupScreen()));
    } else if (statusNow == 'rejected') {
      nav.push(MaterialPageRoute(
          builder: (_) => const ProfileVerificationScreen(status: 'rejected')));
    } else {
      nav.push(MaterialPageRoute(
          builder: (_) => const ProfileVerificationScreen(status: 'pending')));
    }
  } catch (_) {
    // Safe fallback if offline/timeouts: open notifications list
    nav.push(MaterialPageRoute(builder: (_) => const NotificationsScreen()));
  }
}

// ─────────────────────────────────────────────────────────────
void _handleNotifTap(Map<String, dynamic> data) {
  final nav = _navKey.currentState;
  if (nav == null) return;

  if (data.isEmpty) return;

  final type = (data['type'] ?? '').toString().toLowerCase();

  // normalize id keys
  final dynamic chatIdRaw = data['chatId'] ?? data['chat_id'];
  final String? chatId = chatIdRaw == null ? null : chatIdRaw.toString();

  if ((type == 'message' || type == 'chat') && chatId != null) {
    nav.push(
        MaterialPageRoute(builder: (_) => ConversationScreen(chatId: chatId)));
    return;
  }

  switch (type) {
    case 'match':
      nav.push(MaterialPageRoute(
        builder: (_) => const MatchesScreen(initialTab: 0), // New tab
      ));
      break;
    case 'like':
    case 'likeback':
      nav.push(
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => const MatchesScreen(initialTab: 1),
          transitionsBuilder: (_, animation, __, child) => SlideTransition(
            position: animation.drive(
              Tween(begin: const Offset(1, 0), end: Offset.zero)
                  .chain(CurveTween(curve: Curves.easeInOut)),
            ),
            child: child,
          ),
          transitionDuration: const Duration(milliseconds: 300),
        ),
      );
      break;
    case 'messages':
      nav.push(MaterialPageRoute(builder: (_) => const MessagesScreen()));
      break;
    case 'profile':
      nav.push(MaterialPageRoute(builder: (_) => const ProfileScreen()));
      break;
    case 'settings':
      nav.push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
      break;
    case 'verification':
      {
        final raw = (data['status'] ?? data['verification_status'])?.toString();
        final statusHint = raw?.toLowerCase().trim();
        final qcRaw = data['quiz_completed'];
        final quizCompletedHint =
            (qcRaw == true) || (qcRaw?.toString().toLowerCase() == 'true');

        _routeToVerification(
            statusHint: statusHint, quizCompletedHint: quizCompletedHint);
        break;
      }
    case 'discover':
    default:
      nav.push(MaterialPageRoute(builder: (_) => const DiscoverScreen()));
  }
}
