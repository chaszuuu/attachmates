import 'package:flutter/material.dart';

class SoftErrorScreen extends StatelessWidget {
  final String? message;
  final VoidCallback? onRetry;

  const SoftErrorScreen({super.key, this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Something went wrong.',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  textAlign: TextAlign.center),
              if (message != null) ...[
                const SizedBox(height: 8),
                Text(message!, textAlign: TextAlign.center),
              ],
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: onRetry ?? () => Navigator.of(context).maybePop(),
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
