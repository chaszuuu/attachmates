import 'package:flutter/material.dart';
import '../../widgets/onboarding_page.dart';
import '../../models/onboarding_content.dart';
import '../auth/auth_screen.dart';
import '../../utils/constants.dart';
import '../../utils/policies_gate.dart'; // ⬅️ NEW

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with SingleTickerProviderStateMixin {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  final List<OnboardingContent> _contents = [
    OnboardingContent(
      title: 'Where Compatibility\nMeets Connection',
      description:
          'Our AI-powered matching algorithm uses\nunique attachment style & love language data not just about singles, but about\nrelationships.',
      image: 'assets/images/attachmates_logo.png',
    ),
    OnboardingContent(
      title: 'Know Yourself,\nFind Your Match',
      description:
          'Our personality assessment helps you\nuncover your relationship style. Get matched with people who truly get you.',
      image: 'assets/logo.png',
    ),
    OnboardingContent(
      title: 'Ready for Real\nConnections?',
      description:
          'Skip the small talk & dive into meaningful\ntopics to foster relationships. Let them hear your story — the meaningful parts that matter.',
      image: 'assets/logo.png',
    ),
  ];

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: Curves.easeIn,
      ),
    );
    _animationController.forward();
  }

  @override
  void dispose() {
    _pageController.dispose();
    _animationController.dispose();
    super.dispose();
  }

  // ⬇️ make async so we can await the policies gate
  void _navigateToNextPage() async {
    if (_currentPage == _contents.length - 1) {
      // Show Terms → Privacy (first-time only; no-op afterwards)
      await ensurePoliciesAccepted(context);

      // Navigate to auth screen using the same horizontal slide animation
      if (!mounted) return;
      Navigator.of(context).push(
        PageRouteBuilder(
          pageBuilder: (context, animation, secondaryAnimation) => AuthScreen(
            isLogin: false,
            onBack: () {
              Navigator.of(context).pop();
            },
          ),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            const begin = Offset(1.0, 0.0);
            const end = Offset.zero;
            const curve = Curves.easeInOut;

            var tween =
                Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
            var offsetAnimation = animation.drive(tween);

            return SlideTransition(
              position: offsetAnimation,
              child: child,
            );
          },
          transitionDuration:
              const Duration(milliseconds: 500), // Same duration as PageView
        ),
      );
    } else {
      // Animate to next page in the PageView
      _pageController.nextPage(
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.white,
                  AppColors.primaryColor,
            ],
          ),
        ),
        child: SafeArea(
          child: FadeTransition(
            opacity: _fadeAnimation,
            child: Column(
              children: [
                Expanded(
                  child: PageView.builder(
                    controller: _pageController,
                    onPageChanged: (int page) {
                      setState(() {
                        _currentPage = page;
                      });
                    },
                    itemCount: _contents.length,
                    itemBuilder: (context, index) {
                      return OnboardingPage(
                        content: _contents[index],
                        onNextPressed: _navigateToNextPage,
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 30.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(
                      _contents.length,
                      (index) => buildDot(index),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget buildDot(int index) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      height: 8,
      width: _currentPage == index ? 24 : 8,
      margin: const EdgeInsets.only(right: 5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        color: _currentPage == index
            ? Colors.white
            : Colors.white.withOpacity(0.5),
      ),
    );
  }
}
