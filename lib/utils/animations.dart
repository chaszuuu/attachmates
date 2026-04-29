import 'package:flutter/material.dart';

/// =======================
/// Page transition routes
/// =======================

class FadePageRoute<T> extends PageRouteBuilder<T> {
  FadePageRoute({
    required Widget child,
    Duration duration = const Duration(milliseconds: 500),
  }) : super(
          transitionDuration: duration,
          reverseTransitionDuration: duration,
          pageBuilder: (_, __, ___) => child,
          transitionsBuilder: (_, animation, __, child) =>
              FadeTransition(opacity: animation, child: child),
        );
}

enum SlideDirection { right, left, up, down }

class SlidePageRoute<T> extends PageRouteBuilder<T> {
  SlidePageRoute({
    required Widget child,
    SlideDirection direction = SlideDirection.right,
    Duration duration = const Duration(milliseconds: 400),
    Curve curve = Curves.easeOutCubic,
  }) : super(
          transitionDuration: duration,
          reverseTransitionDuration: duration,
          pageBuilder: (_, __, ___) => child,
          transitionsBuilder: (_, animation, __, child) {
            final begin = _beginOffsetFor(direction);
            final tween = Tween<Offset>(begin: begin, end: Offset.zero)
                .chain(CurveTween(curve: curve));
            return SlideTransition(position: animation.drive(tween), child: child);
          },
        );

  static Offset _beginOffsetFor(SlideDirection d) {
    switch (d) {
      case SlideDirection.right:
        return const Offset(1.0, 0.0);
      case SlideDirection.left:
        return const Offset(-1.0, 0.0);
      case SlideDirection.up:
        return const Offset(0.0, 1.0);
      case SlideDirection.down:
        return const Offset(0.0, -1.0);
    }
  }
}

/// =======================
/// Press animations, links
/// =======================

class AnimatedPressable extends StatefulWidget {
  final Widget child;
  final VoidCallback onPressed;
  final VoidCallback? onLongPress;
  final Duration duration;
  final double pressedScale;
  final bool enabled;

  const AnimatedPressable({
    super.key,
    required this.child,
    required this.onPressed,
    this.onLongPress,
    this.duration = const Duration(milliseconds: 120),
    this.pressedScale = 0.96,
    this.enabled = true,
  });

  @override
  State<AnimatedPressable> createState() => _AnimatedPressableState();
}

class _AnimatedPressableState extends State<AnimatedPressable> {
  bool _pressed = false;

  void _setPressed(bool v) {
    if (_pressed != v && widget.enabled) {
      setState(() => _pressed = v);
    }
  }

  @override
  Widget build(BuildContext context) {
    final child = AnimatedScale(
      scale: _pressed && widget.enabled ? widget.pressedScale : 1.0,
      duration: widget.duration,
      curve: Curves.easeOut,
      child: widget.child,
    );

    return GestureDetector(
      onTapDown: widget.enabled ? (_) => _setPressed(true) : null,
      onTapUp: widget.enabled
          ? (_) {
              _setPressed(false);
              widget.onPressed();
            }
          : null,
      onTapCancel: widget.enabled ? () => _setPressed(false) : null,
      onLongPress: widget.enabled ? widget.onLongPress : null,
      behavior: HitTestBehavior.translucent,
      child: child,
    );
  }
}

class AnimatedTextLink extends StatefulWidget {
  final String text;
  final VoidCallback onTap;
  final TextStyle? style;
  final TextStyle? hoverStyle;
  final Duration duration;

  const AnimatedTextLink({
    super.key,
    required this.text,
    required this.onTap,
    this.style,
    this.hoverStyle,
    this.duration = const Duration(milliseconds: 200),
  });

  @override
  State<AnimatedTextLink> createState() => _AnimatedTextLinkState();
}

class _AnimatedTextLinkState extends State<AnimatedTextLink> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final base = widget.style ?? const TextStyle(color: Colors.white, fontSize: 14);
    final hover = widget.hoverStyle ??
        base.copyWith(
          decoration: TextDecoration.underline,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        );
    final styleNow = (_hover || _pressed) ? hover : base;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) {
          setState(() => _pressed = false);
          widget.onTap();
        },
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedDefaultTextStyle(
          style: styleNow,
          duration: widget.duration,
          child: Text(widget.text),
        ),
      ),
    );
  }
}
