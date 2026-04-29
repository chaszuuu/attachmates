import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../utils/api_client.dart';
import '../../utils/shared_pref.dart' show clearQuizPrefs;

Future<Map<String, dynamic>?> showQuizSubmissionModal({
  required BuildContext context,
  required List<int?> attachmentResponses, // length 60, 1..6
  required Map<int, String?> loveLanguageResponses, // length 30, A–E
  required String? preferredGender,
  required VoidCallback onSubmitComplete,
  bool cooldownAware = false, // ⬅️ NEW: only true for Profile re-assess
  String?
      intent, // ⬅️ NEW: optional hint for backend ("profile_reassess" | "mixed_retake" | "normal")
}) {
  return showModalBottomSheet<Map<String, dynamic>?>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) {
      bool submitting = false;

      Future<void> _submit(StateSetter setState) async {
        if (submitting) return;
        setState(() => submitting = true);

        void _closeSpinnerIfAny() {
          if (context.mounted) {
            Navigator.of(context, rootNavigator: true).maybePop();
          }
        }

        try {
          // --- Validate defensively ---
          if (attachmentResponses.length != 60 ||
              attachmentResponses.any((e) => e == null || e! < 1 || e! > 6)) {
            throw Exception("Please answer all attachment-style questions.");
          }
          final llList =
              List<String?>.generate(30, (i) => loveLanguageResponses[i]);
          if (llList.length != 30 ||
              llList.any((e) => e == null || e!.isEmpty)) {
            throw Exception("Please answer all love-language questions.");
          }

          // --- Spinner ---
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (_) => const Center(child: CircularProgressIndicator()),
          );

          // --- Build payload ---
final normalizedPref = (() {
  final val = (preferredGender ?? '').trim().toLowerCase();
  if (val.isEmpty) return 'no preference';
  if (val == 'any') return 'no preference';
  return val;
})();


          final payload = <String, dynamic>{
            "attachment_responses": attachmentResponses.map((e) => e!).toList(),
            "love_language_responses":
                llList.map((e) => e!.toUpperCase()).toList(),
            "preferred_gender": normalizedPref,
          };
          if (intent != null && intent.isNotEmpty) {
            payload["intent"] = intent; // e.g., "profile_reassess"
          }

          // ✅ Ensure a fresh token on the first hop (avoids rare "used too early")
          await FirebaseAuth.instance.currentUser?.getIdToken(true);

          // --- POST ---
          final resp = await ApiClient.postJson(
            "/submit",
            payload,
            forceRefreshFirst: true, // ✅ belt & suspenders on initial call
          );

          // Show cooldown only when this modal is used for Profile re-assess
          if (resp.statusCode == 403 && cooldownAware) {
            _closeSpinnerIfAny();
            String message =
                "Re-assessment is currently locked. Please try again later.";
            try {
              final body = jsonDecode(resp.body) as Map<String, dynamic>;
              final detail =
                  (body['detail'] is Map) ? body['detail'] as Map : {};
              final days = (detail['retry_in_days'] as num?)?.toInt();
              if (days != null) {
                message =
                    "You can re-assess in $days day${days == 1 ? '' : 's'}.";
              }
            } catch (_) {}
            if (Navigator.of(sheetContext).canPop()) {
              Navigator.of(sheetContext).pop(null); // cancel result
            }
            if (context.mounted) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text(message)));
            }
            return;
          }

          if (resp.statusCode != 200) {
            _closeSpinnerIfAny();
            throw Exception(
                "Failed to submit quiz (${resp.statusCode}): ${resp.body}");
          }

          final Map<String, dynamic> body =
              jsonDecode(resp.body) as Map<String, dynamic>;

          // --- Mark completion in Firestore ---
          final uid = FirebaseAuth.instance.currentUser?.uid;
          if (uid == null) {
            _closeSpinnerIfAny();
            throw Exception("Not authenticated — cannot mark quiz completion.");
          }
          await FirebaseFirestore.instance.collection('users').doc(uid).set({
            "quiz": {
              "completed": true,
              "submitted_at": FieldValue.serverTimestamp(),
            }
          }, SetOptions(merge: true));

          // --- Cleanup + notify + return result ---
          _closeSpinnerIfAny();
          await clearQuizPrefs();
          onSubmitComplete();

          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("Quiz submitted successfully!")),
            );
          }

          if (Navigator.of(sheetContext).canPop()) {
            Navigator.of(sheetContext).pop(body); // return backend JSON
          }
        } catch (e) {
          _closeSpinnerIfAny();
          setState(() => submitting = false);

          if (context.mounted) {
            showDialog(
              context: context,
              builder: (_) => AlertDialog(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                title: const Text("Submission Failed"),
                content: Text("Error: $e"),
                actions: [
                  TextButton(
                    child: const Text("OK"),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            );
          }
        }
      }

      final primary = const Color(0xFFB5276A);
      final h = MediaQuery.of(sheetContext).size.height;
      final sheetFactor = h < 700 ? 0.45 : 0.40; // match Settings styling

      return StatefulBuilder(
        builder: (ctx, setState) {
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
                            child: Icon(
                              Icons.assignment_turned_in_outlined,
                              color: primary,
                            ),
                          ),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Text(
                              "Submit Quiz Answers",
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
                        "You're about to submit your quiz answers. Do you want to proceed?",
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
                                  onPressed: submitting
                                      ? null
                                      : () =>
                                          Navigator.of(sheetContext).pop(null),
                                  style: OutlinedButton.styleFrom(
                                    side:
                                        BorderSide(color: Colors.grey.shade400),
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 14),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                  child: const Text('Cancel'),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: ElevatedButton(
                                  onPressed: submitting
                                      ? null
                                      : () => _submit(setState),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: submitting
                                        ? Colors.grey.shade400
                                        : primary,
                                    foregroundColor: Colors.white,
                                    elevation: 0,
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 14),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                  child: const Text('Confirm'),
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
    },
  );
}
