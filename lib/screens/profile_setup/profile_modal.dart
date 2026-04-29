// front_end/lib/screens/profile_setup/profile_modal.dart
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ✅ Needed to read bundled asset bytes for default profile image
import 'package:flutter/services.dart' show rootBundle;
import 'package:http_parser/http_parser.dart'; // for MediaType

import '../../utils/shared_pref.dart';
import '../../utils/api_client.dart';
import '../../utils/api_config.dart';

// Firebase + Firestore
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../results/profile_verification_screen.dart';

Future<void> showVerificationConfirmationModal({
  required BuildContext context,
  required Map<String, dynamic> personalInfo,
  required File? livenessImage,
  required File? idFrontImage,
  required File? idBackImage,
  required String? selectedIdType,
  required VoidCallback onSubmitComplete,

  // Kept for backward compatibility; optional in private-bucket flow
  String? selfieUrl,
  String? idFrontUrl,
  String? idBackUrl,
}) async {
  int _calculateAgeFromIso(String iso) {
    final dob = DateFormat('yyyy-MM-dd').parse(iso);
    final now = DateTime.now();
    int age = now.year - dob.year;
    final hasHadBirthdayThisYear = (now.month > dob.month) ||
        (now.month == dob.month && now.day >= dob.day);
    if (!hasHadBirthdayThisYear) age--;
    return age;
  }

  String _safeError(Object e, [String fallback = "Something went wrong"]) {
    try {
      final m = e.toString();
      final start = m.indexOf('{');
      if (start != -1) {
        final jsonStr = m.substring(start);
        final obj = json.decode(jsonStr);
        if (obj is Map && obj['detail'] is String) return obj['detail'];
        if (obj is Map && obj['message'] is String) return obj['message'];
      }
    } catch (_) {}
    return fallback;
  }

  // Flags from pre-upload pages
  bool _selfiePreuploaded = false;
  bool _idPreuploaded = false;

  // Hydrate any missing info from SharedPreferences
  Future<void> _hydrateFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();

    // URLs are optional; read them if present (legacy support)
    selfieUrl ??= prefs.getString('liveness_selfie_url');
    idFrontUrl ??= prefs.getString('id_front_url');
    idBackUrl ??= prefs.getString('id_back_url');

    // Flags are authoritative in private-bucket flow
    _selfiePreuploaded = prefs.getBool('selfie_preuploaded') ?? false;
    _idPreuploaded = prefs.getBool('id_preuploaded') ?? false;
  }

  final primary = const Color(0xFFB5276A);

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) {
      final h = MediaQuery.of(context).size.height;
      final sheetFactor = h < 700 ? 0.45 : 0.40; // align with settings design

      return FractionallySizedBox(
        heightFactor: sheetFactor,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
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

                  // header (icon tile + title)
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
                        child:
                            Icon(Icons.verified_user_outlined, color: primary),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text(
                          'Confirm submission',
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
                    "You're about to submit your personal details, interests, selfie, and ID for verification. Do you want to proceed?",
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
                              child: const Text('Cancel'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton(
                              onPressed: () async {
                                // Close the sheet before showing loader
                                Navigator.of(context).pop();

                                // Loader overlay
                                showDialog(
                                  context: context,
                                  barrierDismissible: false,
                                  builder: (_) => const Center(
                                      child: CircularProgressIndicator()),
                                );

                                try {
                                  // ✅ Extra safety: refresh the ID token right before the sequence
                                  await FirebaseAuth.instance.currentUser
                                      ?.getIdToken(true);

                                  await _hydrateFromPrefs();

                                  // ---- Prep payload ----
                                  final Map<String, dynamic> infoToSend =
                                      Map.from(personalInfo);

                                  // Extract and remove local-only fields
                                  final File? profileImage =
                                      infoToSend['profile_image'] as File?;
                                  infoToSend.remove('profile_image');

                                  // Normalize DOB
                                  if (infoToSend['dob'] is String &&
                                      (infoToSend['dob'] as String)
                                          .isNotEmpty) {
                                    // already ISO
                                  } else if (infoToSend['dob_display']
                                          is String &&
                                      (infoToSend['dob_display'] as String)
                                          .isNotEmpty) {
                                    final parsed = DateFormat('MM/dd/yyyy')
                                        .parse(infoToSend['dob_display']
                                            as String);
                                    infoToSend['dob'] =
                                        DateFormat('yyyy-MM-dd').format(parsed);
                                  }
                                  infoToSend.remove('dob_display');

                                  // Ensure age
                                  if ((infoToSend['age'] == null ||
                                          (infoToSend['age'] is! int)) &&
                                      infoToSend['dob'] is String &&
                                      (infoToSend['dob'] as String)
                                          .isNotEmpty) {
                                    try {
                                      infoToSend['age'] = _calculateAgeFromIso(
                                          infoToSend['dob'] as String);
                                    } catch (_) {}
                                  }

                                  // BIO (optional): make sure string & trimmed
                                  final bio = infoToSend['bio'];
                                  if (bio != null)
                                    infoToSend['bio'] = bio.toString().trim();

                                  // INTERESTS: ensure List<String>, default []
                                  final interestsRaw = infoToSend['interests'];
                                  List<String> interests = [];
                                  if (interestsRaw is List) {
                                    interests = interestsRaw
                                        .whereType<String>()
                                        .map((e) => e.trim())
                                        .where((e) => e.isNotEmpty)
                                        .toList();
                                  }
                                  infoToSend['interests'] = interests;

                                  // Client-side guard (UX) — align with UI: 3–10
                                  if (interests.isNotEmpty &&
                                      interests.length < 3) {
                                    throw Exception(
                                        "Pick at least 3 interests before submitting.");
                                  }
                                  if (interests.length > 10) {
                                    throw Exception(
                                        "Select up to 10 interests only.");
                                  }

                                  // ---- 1) Personal info (JSON) ----
                                  final currentUser =
                                      FirebaseAuth.instance.currentUser;
                                  final currentUid = currentUser?.uid;
                                  infoToSend['email'] =
                                      currentUser?.email ?? '';

                                  final personalInfoRes =
                                      await ApiClient.postJson(
                                    "/profile-info",
                                    infoToSend,
                                    forceRefreshFirst: true,
                                  );
                                  if (personalInfoRes.statusCode != 200) {
                                    throw Exception(
                                        "Personal info failed: ${personalInfoRes.body}");
                                  }

                                  // ---- 1.1) Embed bio (non-fatal) ----
                                  final userBio =
                                      (infoToSend['bio'] as String?)?.trim() ??
                                          "";
                                  if (currentUid != null &&
                                      userBio.isNotEmpty) {
                                    try {
                                      final embedRes = await ApiClient.postJson(
                                        "/embed-bio",
                                        {
                                          "uid": currentUid,
                                          "bio": userBio,
                                        },
                                        forceRefreshFirst: true,
                                      );
                                      if (embedRes.statusCode != 200) {
                                        debugPrint(
                                            "Bio embedding failed: ${embedRes.body}");
                                      }
                                    } catch (e) {
                                      debugPrint("Bio embedding error: $e");
                                    }
                                  }

                                  // ---- 2) Profile image (retry-safe) ----
                                  if (profileImage != null &&
                                      profileImage.existsSync()) {
                                    final streamed =
                                        await ApiClient.postMultipartPaths(
                                      "/upload-profile",
                                      fields: {"image_uploaded": "true"},
                                      filePaths: {
                                        "profile_image": profileImage.path
                                      },
                                      timeout: const Duration(seconds: 150),
                                    );
                                    await ApiClient.expectOkStreamed(streamed);
                                  } else {
                                    // Asset default
                                    final data = await rootBundle
                                        .load('assets/default_pfp.png');
                                    final bytes = data.buffer.asUint8List();

                                    final streamed =
                                        await ApiClient.postMultipartBuilder(
                                      "/upload-profile",
                                      (bearer) async {
                                        final req = http.MultipartRequest(
                                          'POST',
                                          Uri.parse(
                                              "${ApiConfig.baseUrl}/upload-profile"),
                                        )
                                          ..headers['Authorization'] =
                                              'Bearer $bearer'
                                          ..headers['Accept'] =
                                              'application/json'
                                          ..fields['image_uploaded'] = 'true'
                                          ..files
                                              .add(http.MultipartFile.fromBytes(
                                            'profile_image',
                                            bytes,
                                            filename: 'default_pfp.png',
                                            contentType:
                                                MediaType('image', 'png'),
                                          ));
                                        return req;
                                      },
                                      timeout: const Duration(seconds: 150),
                                    );
                                    await ApiClient.expectOkStreamed(streamed);
                                  }

                                  // ---- 3) Selfie (skip if preuploaded OR url present) ----
                                  final hasSelfieUrl = selfieUrl != null &&
                                      selfieUrl!.isNotEmpty;
                                  if (!hasSelfieUrl && !_selfiePreuploaded) {
                                    if (livenessImage != null &&
                                        livenessImage.existsSync()) {
                                      final streamedSelfie =
                                          await ApiClient.postMultipartPaths(
                                        "/upload-selfie",
                                        filePaths: {
                                          'selfie': livenessImage.path
                                        },
                                        timeout: const Duration(seconds: 150),
                                      );
                                      await ApiClient.expectOkStreamed(
                                          streamedSelfie);
                                    }
                                  }

                                  // ---- 4) ID images (skip if preuploaded OR both urls present) ----
                                  final haveFrontUrl = idFrontUrl != null &&
                                      idFrontUrl!.isNotEmpty;
                                  final haveBackUrl = idBackUrl != null &&
                                      idBackUrl!.isNotEmpty;

                                  if ((!haveFrontUrl || !haveBackUrl) &&
                                      !_idPreuploaded) {
                                    if (idFrontImage != null &&
                                        idBackImage != null &&
                                        selectedIdType != null) {
                                      final streamedId =
                                          await ApiClient.postMultipartPaths(
                                        "/verify-id",
                                        fields: {'id_type': selectedIdType},
                                        filePaths: {
                                          'front_id': idFrontImage.path,
                                          'back_id': idBackImage.path,
                                        },
                                        timeout: const Duration(seconds: 150),
                                      );
                                      await ApiClient.expectOkStreamed(
                                          streamedId);
                                    }
                                  }

                                  // ---- Close loader ----
                                  if (context.mounted) {
                                    Navigator.of(context, rootNavigator: true)
                                        .pop();
                                  }

                                  // ---- Update Firestore: flags + (optional) media URLs ----
                                  if (currentUid != null) {
                                    final prefs =
                                        await SharedPreferences.getInstance();
                                    selfieUrl ??=
                                        prefs.getString('liveness_selfie_url');
                                    idFrontUrl ??=
                                        prefs.getString('id_front_url');
                                    idBackUrl ??=
                                        prefs.getString('id_back_url');

                                    final mediaUpdate = <String, dynamic>{};
                                    if (selfieUrl != null &&
                                        selfieUrl!.isNotEmpty) {
                                      mediaUpdate['selfie_url'] = selfieUrl;
                                    }
                                    if (idFrontUrl != null &&
                                        idFrontUrl!.isNotEmpty) {
                                      mediaUpdate['id_front_url'] = idFrontUrl;
                                    }
                                    if (idBackUrl != null &&
                                        idBackUrl!.isNotEmpty) {
                                      mediaUpdate['id_back_url'] = idBackUrl;
                                    }

                                    final update = <String, dynamic>{
                                      'profile_setup_complete': true,
                                      'identity_verification': {
                                        'status': 'pending',
                                        'updated_at':
                                            FieldValue.serverTimestamp(),
                                        'reason': FieldValue.delete(),
                                      },
                                      'quiz': {'completed': false},
                                    };

                                    if (mediaUpdate.isNotEmpty) {
                                      update['media'] =
                                          mediaUpdate; // optional URLs
                                    }

                                    await FirebaseFirestore.instance
                                        .collection('users')
                                        .doc(currentUid)
                                        .set(update, SetOptions(merge: true));
                                  }

                                  // ---- Cleanup & navigate ----
                                  onSubmitComplete();
                                  await clearProfilePrefs();

                                  if (context.mounted) {
                                    Navigator.of(context, rootNavigator: true)
                                        .pushAndRemoveUntil(
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            const ProfileVerificationScreen(
                                                status: 'pending'),
                                      ),
                                      (_) => false,
                                    );
                                  }
                                } catch (e) {
                                  if (context.mounted) {
                                    Navigator.of(context, rootNavigator: true)
                                        .pop(); // close loader
                                    showDialog(
                                      context: context,
                                      builder: (_) => AlertDialog(
                                        title: const Text("Submission Failed"),
                                        content: Text(
                                          _safeError(e,
                                              "Please try again or check your connection."),
                                        ),
                                        actions: [
                                          TextButton(
                                            child: const Text("OK"),
                                            onPressed: () {
                                              if (context.mounted) {
                                                Navigator.of(context).pop();
                                              }
                                            },
                                          ),
                                        ],
                                      ),
                                    );
                                  }
                                }
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: primary,
                                foregroundColor: Colors.white,
                                elevation: 0,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 14),
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
}
