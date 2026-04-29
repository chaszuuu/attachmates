// lib/screens/profile/edit_profile_screen.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../utils/constants.dart';
import '../../utils/api_client.dart'; // ✅ use centralized API client
// 🆕 shared interest categories & colors
import '../../utils/interest_categories.dart';
// 🆕 interests editor screen
import 'edit_interests_screen.dart';

class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  // ----- Controllers -----
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _bioController = TextEditingController();
  final _ageController = TextEditingController();

  // ----- Local state -----
  bool _loading = true;
  bool _saving = false;
  String? _error;

  // Profile image
  String? _profileImageUrl;
  File? _pickedImageFile;

  // DOB
  String? _dobIso; // yyyy-MM-dd
  String? _dobDisplay; // MM/dd/yyyy

  // Gender (UI Title Case; stored lowercase)
  String? _selectedGender;

  // Interests (editable in separate screen)
  List<String> _interests = [];

  final ImagePicker _picker = ImagePicker();

  static const List<String> _uiGenderOptions = [
    'Male',
    'Female',
    'Non-binary',
    'Other',
  ];

  @override
  void initState() {
    super.initState();
    _loadExistingProfile();
  }

  // ===== helpers reused across screens =====

  String _titleize(String s) {
    final clean = s.replaceAll(RegExp(r'[_\-]+'), ' ').trim();
    if (clean.isEmpty) return "";
    return clean
        .split(RegExp(r'\s+'))
        .map((w) => w.isEmpty
            ? ""
            : "${w[0].toUpperCase()}${w.substring(1).toLowerCase()}")
        .join(" ");
  }

  String _formatGenderLabel(String raw) {
    final s = raw.trim().toLowerCase();
    if (s.isEmpty) return "";
    if ({"m", "male", "man", "boy"}.contains(s)) return "Male";
    if ({"f", "female", "woman", "girl"}.contains(s)) return "Female";
    if ({"non-binary", "nonbinary", "nb", "enby"}.contains(s))
      return "Non-binary";
    if ({"others", "other", "prefer not to say", "prefer-not", "na", "n/a"}
        .contains(s)) {
      return "Other";
    }
    return _titleize(s);
  }

  // -------- Gender mappers (storage/UI) --------
  String _uiGenderFromStored(String? stored) {
    if (stored == null) return '';
    final s = stored.trim().toLowerCase();
    switch (s) {
      case 'male':
        return 'Male';
      case 'female':
        return 'Female';
      case 'non-binary':
      case 'nonbinary':
      case 'non binary':
        return 'Non-binary';
      case 'other':
        return 'Other';
      default:
        return _formatGenderLabel(s);
    }
  }

  String _storedGenderFromUi(String? ui) {
    switch (ui) {
      case 'Male':
        return 'male';
      case 'Female':
        return 'female';
      case 'Non-binary':
        return 'non-binary';
      case 'Other':
        return 'other';
      default:
        return '';
    }
  }

  // -------- DOB coercion (Timestamp / ISO / yyyy-MM-dd / epoch) --------
  DateTime? _coerceDob(dynamic raw) {
    if (raw == null) return null;
    if (raw is Timestamp) return raw.toDate();
    if (raw is int) {
      final isMs = raw > 2000000000;
      return DateTime.fromMillisecondsSinceEpoch(isMs ? raw : raw * 1000);
    }
    if (raw is Map && raw['seconds'] is int) {
      return DateTime.fromMillisecondsSinceEpoch(
          (raw['seconds'] as int) * 1000);
    }
    if (raw is String) {
      final s = raw.trim();
      if (s.isEmpty) return null;
      try {
        final dt = DateTime.parse(s);
        return DateTime(dt.year, dt.month, dt.day);
      } catch (_) {
        try {
          final parts = s.split("-");
          if (parts.length == 3) {
            final y = int.parse(parts[0]);
            final m = int.parse(parts[1]);
            final d = int.parse(parts[2]);
            return DateTime(y, m, d);
          }
        } catch (_) {}
      }
    }
    return null;
  }

  // -------- Load existing data from Firestore --------
  Future<void> _loadExistingProfile() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) throw Exception("Not signed in.");

      final snap =
          await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final data = snap.data() ?? {};

      final pinfo = (data['personal_info'] is Map)
          ? Map<String, dynamic>.from(data['personal_info'] as Map)
          : <String, dynamic>{};

      _firstNameController.text =
          (pinfo['first_name'] ?? data['first_name'] ?? '').toString();
      _lastNameController.text =
          (pinfo['last_name'] ?? data['last_name'] ?? '').toString();
      _bioController.text = (pinfo['bio'] ?? data['bio'] ?? '').toString();

      // DOB
      final dobRaw = pinfo['dob'] ?? data['dob'];
      final dt = _coerceDob(dobRaw);
      if (dt != null) {
        _dobIso = DateFormat('yyyy-MM-dd').format(dt);
        _dobDisplay = DateFormat('MM/dd/yyyy').format(dt);
        final savedAge = pinfo['age'];
        _ageController.text = (savedAge is int)
            ? savedAge.toString()
            : _calculateAge(dt).toString();
      } else {
        _dobIso = null;
        _dobDisplay = null;
        _ageController.text = "";
      }

      // Gender (stored lowercase)
      final storedGender = (pinfo['gender'] ?? data['gender'])?.toString();
      final uiGender = _uiGenderFromStored(storedGender);
      _selectedGender = uiGender.isNotEmpty ? uiGender : null;

      // Profile image (for preview)
      _profileImageUrl = (data['profile_image_url'] ??
              data['profileImageUrl'] ??
              data['profile_image_local_url'])
          ?.toString();

      // ✅ Interests — use ONLY personal_info.interests
      _interests = (() {
        final raw = pinfo['interests'];
        if (raw is List) {
          return raw
              .where((e) => e != null)
              .map((e) => e.toString().trim())
              .where((s) => s.isNotEmpty)
              .toList();
        }
        return <String>[];
      })();

      setState(() {
        _loading = false;
        _error = null;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  // -------- Save (upload image if picked, then write Firestore) --------
Future<void> _saveProfile() async {
  if (_saving) return;
  setState(() {
    _saving = true;
    _error = null;
  });

  try {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw Exception("Not signed in.");

    // Validate required (mirror PersonalInformationPage)
    if (_firstNameController.text.trim().isEmpty) {
      throw Exception("First name is required.");
    }
    if (_lastNameController.text.trim().isEmpty) {
      throw Exception("Last name is required.");
    }
    if (_dobIso == null || _dobIso!.isEmpty) {
      throw Exception("Date of birth is required.");
    }
    if (_selectedGender == null || _selectedGender!.isEmpty) {
      throw Exception("Gender is required.");
    }

    // Age calculation from DOB
    final age = _calculateAge(DateFormat('yyyy-MM-dd').parse(_dobIso!));
    if (age < 18) {
      throw Exception("You must be at least 18 years old.");
    }
    _ageController.text = age.toString();

    // If user picked a new photo, upload it now (via ApiClient)
    if (_pickedImageFile != null) {
      final url = await _uploadProfileImage(_pickedImageFile!);
      if (url != null && url.isNotEmpty) {
        setState(() => _profileImageUrl = url);
        // backend already wrote profile_image_url
      }
    }

    // Normalize gender for storage (lowercase)
    final genderStored = _storedGenderFromUi(_selectedGender);

    // 🔒 Do NOT write interests here — they’re managed by EditInterestsScreen
    final update = <String, dynamic>{
      "personal_info": {
        "first_name": _firstNameController.text.trim(),
        "last_name": _lastNameController.text.trim(),
        "bio": _bioController.text.trim(),
        "dob": _dobIso,         // yyyy-MM-dd
        "dob_display": _dobDisplay, // MM/dd/yyyy
        "age": age,             // derived
        "gender": genderStored, // lowercase
        // ⛔ removed: "interests"
      },
      // ⛔ removed: root "interests"
    };

    await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .set(update, SetOptions(merge: true));

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Profile updated successfully!"),
        backgroundColor: Colors.green,
      ),
    );
    Navigator.pop(context);
  } catch (e) {
    setState(() => _error = e.toString());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_error ?? "Failed to save profile."),
        backgroundColor: Colors.red,
      ),
    );
  } finally {
    if (mounted) setState(() => _saving = false);
  }
}


  // -------- Upload profile image via ApiClient.postMultipart --------
  Future<String?> _uploadProfileImage(File file) async {
    final req = http.MultipartRequest("POST", Uri());
    req.fields["image_uploaded"] = "true";
    req.files.add(await http.MultipartFile.fromPath(
      "profile_image",
      file.path,
      filename: file.path.split('/').last,
    ));

    final streamed = await ApiClient.postMultipart("/upload-profile", req);
    if (streamed.statusCode != 200) {
      final err = await streamed.stream.bytesToString();
      throw Exception("Upload failed (${streamed.statusCode}): $err");
    }
    final body = await streamed.stream.bytesToString();
    final jsonMap = jsonDecode(body) as Map<String, dynamic>;
    final url = (jsonMap["url"] ?? jsonMap["path"] ?? "").toString();
    if (url.isEmpty) {
      throw Exception("Upload succeeded but no URL returned.");
    }
    return url;
  }

  // -------- Pick/Remove photo (bottom sheet) --------
  Future<void> _pickProfileImageBottomSheet() async {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) {
        return SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.camera_alt),
                title: const Text('Take a Photo'),
                onTap: () async {
                  Navigator.pop(context);
                  final picked = await _picker.pickImage(
                    source: ImageSource.camera,
                    imageQuality: 90,
                  );
                  if (picked != null) {
                    setState(() => _pickedImageFile = File(picked.path));
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_library),
                title: const Text('Choose from Gallery'),
                onTap: () async {
                  Navigator.pop(context);
                  final picked = await _picker.pickImage(
                    source: ImageSource.gallery,
                    imageQuality: 90,
                  );
                  if (picked != null) {
                    setState(() => _pickedImageFile = File(picked.path));
                  }
                },
              ),
              if (_pickedImageFile != null)
                ListTile(
                  leading: const Icon(Icons.delete),
                  title: const Text('Remove Selected Photo'),
                  onTap: () {
                    Navigator.pop(context);
                    setState(() => _pickedImageFile = null);
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  // -------- Age helper --------
  int _calculateAge(DateTime dob) {
    final now = DateTime.now();
    int age = now.year - dob.year;
    final hadBirthday = (now.month > dob.month) ||
        (now.month == dob.month && now.day >= dob.day);
    if (!hadBirthday) age--;
    return age;
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _bioController.dispose();
    _ageController.dispose();
    super.dispose();
  }

  // -------- UI --------
  @override
  Widget build(BuildContext context) {
    final uploadingBadge = _saving
        ? Positioned(
            top: -6,
            right: -6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(14),
                boxShadow: const [
                  BoxShadow(
                      blurRadius: 4,
                      offset: Offset(0, 2),
                      color: Colors.black26)
                ],
              ),
              child: const Text(
                "Saving...",
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w600),
              ),
            ),
          )
        : const SizedBox.shrink();

    final primary = AppColors.primaryColor;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.chevron_left, color: primary, size: 30),
          onPressed: _saving ? null : () => Navigator.pop(context),
          splashRadius: 24,
        ),
        centerTitle: true,
        title: Text(
          "Edit Profile",
          style: TextStyle(
            color: primary,
            fontWeight: FontWeight.bold,
            fontSize: 20,
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : _saveProfile,
            child: _saving
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(
                    "Save",
                    style: TextStyle(
                      color: primary,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _errorView(_error!)
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Avatar — tappable + brand border
                      Center(
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            InkWell(
                              onTap:
                                  _saving ? null : _pickProfileImageBottomSheet,
                              borderRadius: BorderRadius.circular(60),
                              child: Container(
                                width: 120,
                                height: 120,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(color: primary, width: 3),
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(60),
                                  child: _pickedImageFile != null
                                      ? Image.file(_pickedImageFile!,
                                          fit: BoxFit.cover)
                                      : (_profileImageUrl != null &&
                                              _profileImageUrl!
                                                  .toLowerCase()
                                                  .startsWith('http'))
                                          ? Image.network(
                                              _profileImageUrl!,
                                              fit: BoxFit.cover,
                                              errorBuilder: (_, __, ___) =>
                                                  Image.asset(
                                                      'assets/default_pfp.png',
                                                      fit: BoxFit.cover),
                                            )
                                          : Image.asset(
                                              'assets/default_pfp.png',
                                              fit: BoxFit.cover),
                                ),
                              ),
                            ),
                            Positioned(
                              bottom: -4,
                              right: -4,
                              child: GestureDetector(
                                onTap: _saving
                                    ? null
                                    : _pickProfileImageBottomSheet,
                                child: Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    color: primary,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                        color: Colors.white, width: 2),
                                  ),
                                  child: const Icon(Icons.camera_alt,
                                      color: Colors.white, size: 20),
                                ),
                              ),
                            ),
                            uploadingBadge,
                          ],
                        ),
                      ),

                      const SizedBox(height: 24),

                      const Text(
                        "Basic Information",
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 16),

                      _buildTextField(
                        label: "First Name",
                        controller: _firstNameController,
                        hint: "Enter your first name",
                        required: true,
                      ),
                      const SizedBox(height: 16),
                      _buildTextField(
                        label: "Last Name",
                        controller: _lastNameController,
                        hint: "Enter your last name",
                        required: true,
                      ),
                      const SizedBox(height: 16),

                      _buildDobField(context),
                      const SizedBox(height: 16),

                      _buildTextField(
                        label: "Age",
                        controller: _ageController,
                        hint: "",
                        enabled: false,
                      ),
                      const SizedBox(height: 16),

                      _buildGenderDropdown(),
                      const SizedBox(height: 24),

                      const Text(
                        "About Me",
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 16),
                      _buildBioField(),

                      const SizedBox(height: 24),

                      // Interests section with inline edit icon
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              "Interests",
                              style: TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.bold),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.edit,
                                color: AppColors.primaryColor),
                            tooltip: "Edit Interests",
                            onPressed: _saving
                                ? null
                                : () async {
                                    final updated =
                                        await Navigator.push<List<String>>(
                                      context,
                                      PageRouteBuilder(
                                        pageBuilder: (_, a, __) =>
                                            EditInterestsScreen(
                                          initial: _interests,
                                        ),
                                        transitionsBuilder:
                                            (_, a, __, child) =>
                                                SlideTransition(
                                          position: a.drive(
                                            Tween(
                                                    begin: const Offset(1, 0),
                                                    end: Offset.zero)
                                                .chain(CurveTween(
                                                    curve:
                                                        Curves.easeInOut)),
                                          ),
                                          child: child,
                                        ),
                                        transitionDuration:
                                            const Duration(
                                                milliseconds: 300),
                                      ),
                                    );
                                    if (updated != null) {
                                      setState(() => _interests = updated);
                                    }
                                  },
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (_interests.isEmpty)
                        Text(
                          "No interests yet. Tap the ✎ icon to choose some.",
                          style: TextStyle(
                              fontSize: 14, color: Colors.grey[700]),
                        )
                      else
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _interests.map((it) {
  final display = _titleize(it);               // pretty label for UI
  final cat = categoryForInterest(it);         // normalized category
  final fill = interestColorForLabel(it);      // normalized fill color
  final border = (cat != null)
      ? interestBorderColor(cat)
      : AppColors.primaryColor;                // fallback border

  // optional debug (remove later)
  // print('interest "$it" -> cat=$cat');

  return _pill(display, fill, textColor: Colors.black, border: border);
}).toList(),


                        ),
                      const SizedBox(height: 40),

                      const SizedBox(height: 40),
                    ],
                  ),
                ),
    );
  }

  // ------------- UI Helpers -------------

  Widget _pill(String text, Color bg, {Color? textColor, Color? border}) {
    final Color _text = textColor ?? AppColors.black;
    final Color _border = border ?? darkenPastel(bg);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _border, width: 1.25),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: _text,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _errorView(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 36),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _loadExistingProfile,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primaryColor,
              ),
              child: const Text("Retry"),
            )
          ],
        ),
      ),
    );
  }

  Widget _buildTextField({
    required String label,
    required TextEditingController controller,
    required String hint,
    bool required = false,
    bool enabled = true,
    TextInputType keyboardType = TextInputType.text,
    int maxLines = 1,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: enabled ? Colors.grey.shade100 : Colors.grey.shade200,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey.shade300),
          ),
          child: TextField(
            controller: controller,
            enabled: enabled,
            keyboardType: keyboardType,
            maxLines: maxLines,
            decoration: InputDecoration(
              hintText: hint,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.all(12),
              errorText: required && controller.text.trim().isEmpty
                  ? '*Required'
                  : null,
            ),
            onChanged: (_) {
              setState(() {}); // refresh error text
            },
          ),
        ),
      ],
    );
  }

  Widget _buildDobField(BuildContext context) {
    // Keeping read-only display (same as before)
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          "Date of Birth",
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
          decoration: BoxDecoration(
            color: Colors.grey.shade200,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey.shade300),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _dobDisplay ?? "MM/DD/YYYY",
                style: const TextStyle(
                  color: Colors.grey,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildGenderDropdown() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text("Gender",
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: (_selectedGender == null || _selectedGender!.isEmpty)
                  ? Colors.red
                  : Colors.grey.shade300,
            ),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              isExpanded: true,
              value: _uiGenderOptions.contains(_selectedGender)
                  ? _selectedGender
                  : null,
              hint: const Text("Select gender"),
              onChanged: _saving
                  ? null
                  : (value) {
                      setState(() => _selectedGender = value);
                    },
              items: _uiGenderOptions
                  .map((g) => DropdownMenuItem(value: g, child: Text(g)))
                  .toList(),
            ),
          ),
        ),
        if (_selectedGender == null || _selectedGender!.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('*Required',
                style: TextStyle(color: Colors.red, fontSize: 12)),
          ),
      ],
    );
  }

  Widget _buildBioField() {
    final len = _bioController.text.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text("Short Bio (optional)",
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey.shade300),
          ),
          child: TextField(
            controller: _bioController,
            maxLength: 200,
            minLines: 3,
            maxLines: 3,
            decoration: const InputDecoration(
              hintText: "Tell us a little about yourself (e.g., hobbies, vibe)",
              counterText: "",
              border: InputBorder.none,
              contentPadding: EdgeInsets.symmetric(horizontal: 0, vertical: 12),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        const SizedBox(height: 4),
        Text("$len/200",
            style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }

  // (Date picker kept but not wired to tap since field is read-only here)
  Future<void> _pickDate(BuildContext context) async {
    final now = DateTime.now();
    final maxDate = DateTime(now.year - 18, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate:
          _dobIso != null ? DateFormat('yyyy-MM-dd').parse(_dobIso!) : maxDate,
      firstDate: DateTime(1900),
      lastDate: maxDate,
    );

    if (picked != null) {
      setState(() {
        _dobDisplay = DateFormat('MM/dd/yyyy').format(picked);
        _dobIso = DateFormat('yyyy-MM-dd').format(picked);
        _ageController.text = _calculateAge(picked).toString();
      });
    }
  }
}
