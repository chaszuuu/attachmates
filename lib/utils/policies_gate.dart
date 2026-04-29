// lib/utils/policies_gate.dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../widgets/terms_modal.dart';

const _kPoliciesAcceptedKey = 'policiesAccepted_v2'; // bump if you change content

Future<void> ensurePoliciesAccepted(BuildContext context) async {
  final prefs = await SharedPreferences.getInstance();
  final accepted = prefs.getBool(_kPoliciesAcceptedKey) ?? false;
  if (accepted) return;

  // Show Terms first
  await showTermsModal(context);

  // Then Privacy
  await showPrivacyModal(context);

  // Save preference
  await prefs.setBool(_kPoliciesAcceptedKey, true);
}
