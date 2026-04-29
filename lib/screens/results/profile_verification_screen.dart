import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../quiz/quiz_screen.dart';
import '../profile_setup/profile_setup_screen.dart';
import '../discover/discover_screen.dart';

class ProfileVerificationScreen extends StatefulWidget {
  final String status; // hint only; live Firestore listener will update

  const ProfileVerificationScreen({super.key, required this.status});

  @override
  State<ProfileVerificationScreen> createState() =>
      _ProfileVerificationScreenState();
}

class _ProfileVerificationScreenState extends State<ProfileVerificationScreen> {
  final Color magenta = const Color(0xFFB5276A);

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sub;
  String _status = 'pending';
  String? _reason;
  bool _quizCompleted = false;
  bool _navigating = false;

  @override
  void initState() {
    super.initState();
    _status = _normalize(widget.status);
    _listenForChanges();
  }

  String _normalize(String? s) {
    final v = (s ?? '').toLowerCase().trim();
    if (v.isEmpty || v == 'not_started' || v == 'unknown') return 'pending';
    return v;
  }

  void _listenForChanges() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    _sub = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .snapshots()
        .listen((snap) {
      final data = snap.data();
      if (data == null) return;

      // Read ONLY from identity_verification object
      final ivObj = data['identity_verification'];
      String status = 'pending';
      String? reason;

      if (ivObj is Map<String, dynamic>) {
        final s = ivObj['status'];
        if (s is String && s.isNotEmpty) status = s;

        // NEW: read both keys — prefer rejected_reason but fall back to reason
        final r1 = ivObj['rejected_reason'];
        final r2 = ivObj['reason'];
        if (r1 is String && r1.trim().isNotEmpty) {
          reason = r1.trim();
        } else if (r2 is String && r2.trim().isNotEmpty) {
          reason = r2.trim();
        }
      }

      final quizCompleted = data['quiz']?['completed'] == true;

      if (!mounted) return;
      setState(() {
        _status = _normalize(status);
        _reason = reason;
        _quizCompleted = quizCompleted;
      });

      if (_status == 'approved' && _quizCompleted && !_navigating && mounted) {
        _navigating = true;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const DiscoverScreen()),
        );
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  AppBar _buildAppBar() {
    const section = 'Profile Verification';

    return AppBar(
      automaticallyImplyLeading: false,
      backgroundColor: magenta, // ⬅️ inverted brand color
      foregroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 8, // ⬅️ stronger, visible shadow
      shadowColor: Colors.black.withOpacity(0.3),
      titleSpacing: 0,
      title: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16), // match spacing
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Text(
                  'AttachMates',
                  style: GoogleFonts.indieFlower(
                    textStyle: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                const Text(
                  section,
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
            const SizedBox(
                width: 1), // placeholder to keep space-between layout
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isApproved = _status == 'approved';
    final isRejected = _status == 'rejected';
    final isPending = !isApproved && !isRejected;

    final iconData = isApproved
        ? Icons.check_circle
        : isRejected
            ? Icons.cancel
            : Icons.verified_user_rounded;

    final iconColor = isApproved
        ? Colors.green
        : isRejected
            ? Colors.red
            : magenta;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: _buildAppBar(),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (isPending)
                const SizedBox(
                  height: 90,
                  child: Center(
                    child: SlidingDots(
                      count: 5,
                      size: 30,
                      dotSpacing: 10,
                      color: Color(0xFFB5276A),
                      duration: Duration(milliseconds: 1800),
                      minOpacity: 0.25,
                    ),
                  ),
                )
              else
                Icon(iconData, size: 90, color: iconColor),
              const SizedBox(height: 1),
              Text(
                isApproved
                    ? "You're Verified! 🎉"
                    : isRejected
                        ? "Verification Failed"
                        : "Verification in Progress",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: magenta,
                ),
              ),
              const SizedBox(height: 1),
              if (isPending)
                const Text(
                  "We’re reviewing your ID and selfie to keep AttachMates safe. "
                  "You’ll be notified once verification is complete.",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.black54,
                    height: 1.4,
                  ),
                )
              else if (isApproved)
                const Text(
                  "Your profile has been successfully verified. You can proceed to take the quiz.",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.black54,
                    height: 1.4,
                  ),
                )
              else
                Column(
                  children: [
                    const Text(
                      "We couldn't verify your profile.\nPlease review your details and try again.",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 16,
                        color: Colors.black54,
                        height: 1.4,
                      ),
                    ),
                    if (_reason != null && _reason!.trim().isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        "Reason: ${_reason!}",
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 14,
                          color: Colors.black54,
                        ),
                      ),
                    ],
                  ],
                ),
              const SizedBox(height: 36),
              if (!isPending)
                SizedBox(
                  width: 240,
                  height: 48,
                  child: ElevatedButton(
                    onPressed: () {
                      if (_navigating) return;

                      if (isApproved) {
                        _navigating = true;
                        if (_quizCompleted) {
                          Navigator.pushReplacement(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const DiscoverScreen()),
                          );
                        } else {
                          Navigator.pushReplacement(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const QuizSetupScreen()),
                          );
                        }
                      } else if (isRejected) {
                        _navigating = true;
                        Navigator.pushReplacement(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const ProfileSetupScreen()),
                        );
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: magenta,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                      elevation: 0,
                    ),
                    child: Text(
                      isApproved
                          ? (_quizCompleted
                              ? "Go to Discover"
                              : "Proceed to Quiz")
                          : "Fix & Resubmit",
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Stationary dots with a moving highlight (no bouncing)
class SlidingDots extends StatefulWidget {
  final int count;
  final double size;
  final double dotSpacing;
  final Duration duration;
  final Color color;
  final double minOpacity;

  const SlidingDots({
    super.key,
    this.count = 5,
    this.size = 24,
    this.dotSpacing = 10,
    this.duration = const Duration(milliseconds: 1800),
    required this.color,
    this.minOpacity = 0.25,
  });

  @override
  State<SlidingDots> createState() => _SlidingDotsState();
}

class _SlidingDotsState extends State<SlidingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: widget.duration)
      ..repeat();
  }

  @override
  void didUpdateWidget(covariant SlidingDots oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration) {
      _ctrl.duration = widget.duration;
      _ctrl.reset();
      _ctrl.repeat();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        final head = _ctrl.value * widget.count;
        const sigma = 0.45;

        double gaussianWeight(double x) =>
            math.exp(-(x * x) / (2 * sigma * sigma));

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(widget.count, (i) {
            double dist = i - head;
            if (dist > widget.count / 2) dist -= widget.count;
            if (dist < -widget.count / 2) dist += widget.count;

            final w = gaussianWeight(dist);
            final opacity = widget.minOpacity + (1 - widget.minOpacity) * w;

            return Padding(
              padding: EdgeInsets.symmetric(horizontal: widget.dotSpacing / 2),
              child: Opacity(
                opacity: opacity,
                child: Container(
                  width: widget.size,
                  height: widget.size,
                  decoration: BoxDecoration(
                    color: widget.color,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}
