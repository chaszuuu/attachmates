import 'package:flutter/material.dart';
import '../models/onboarding_content.dart';
import '../utils/animations.dart';

class OnboardingPage extends StatefulWidget {
  final OnboardingContent content;
  final VoidCallback onNextPressed;

  const OnboardingPage({
    super.key,
    required this.content,
    required this.onNextPressed,
  });

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );

    // Update slide animation to come from the left
    _slideAnimation = Tween<Offset>(
      begin: const Offset(-0.5, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutCubic,
    ));

    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeIn,
    ));

    _animationController.forward();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start, // Changed to align children to the left
        children: [
          const SizedBox(height: 20),
          const Spacer(),
          // Headline text with slide and fade animation - now left aligned
          SlideTransition(
            position: _slideAnimation,
            child: FadeTransition(
              opacity: _fadeAnimation,
              child: Container(
                width: MediaQuery.of(context).size.width * 0.8,
                alignment: Alignment.centerLeft, // Changed to left align
                child: Text(
                  widget.content.title,
                  textAlign: TextAlign.left, // Changed to left align text
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    height: 1.2,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          // Description text with slide and fade animation - now left aligned
          SlideTransition(
            position: _slideAnimation,
            child: FadeTransition(
              opacity: _fadeAnimation,
              child: Container(
                width: MediaQuery.of(context).size.width * 0.8,
                alignment: Alignment.centerLeft, // Changed to left align
                child: Text(
                  widget.content.description,
                  textAlign: TextAlign.left, // Changed to left align text
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.9),
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
              ),
            ),
          ),
          const Spacer(),
          // Next button with animation
          Center(
            child: AnimatedPressable(
              onPressed: widget.onNextPressed,
              child: Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
                child: const Icon(
                  Icons.arrow_forward,
                  color: Colors.white,
                ),
              ),
            ),
          ),
          const Spacer(),
        ],
      ),
    );
  }
}
