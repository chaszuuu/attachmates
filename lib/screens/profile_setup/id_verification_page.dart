import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../utils/api_client.dart'; // ✅ use resilient client
import '../../utils/api_config.dart'; // (ok to keep if needed elsewhere)

class IdVerificationPage extends StatefulWidget {
  // Existing callbacks (kept for backward-compat)
  final Function(File) onFrontImagePicked;
  final Function(File) onBackImagePicked;
  final Function(String) onIdTypeSelected;

  // Optional URL callbacks (preserved but not used in this private-bucket flow)
  final void Function(String url)? onFrontUrlUploaded;
  final void Function(String url)? onBackUrlUploaded;

  // ✅ NEW: parent uses this to lock/unlock "Next"
  final ValueChanged<bool>? onSubmittedChanged;

  const IdVerificationPage({
    super.key,
    required this.onFrontImagePicked,
    required this.onBackImagePicked,
    required this.onIdTypeSelected,
    this.onFrontUrlUploaded,
    this.onBackUrlUploaded,
    this.onSubmittedChanged,
  });

  @override
  State<IdVerificationPage> createState() => _IdVerificationPageState();
}

class _IdVerificationPageState extends State<IdVerificationPage> {
  String? selectedIdType;
  File? frontImage;
  File? backImage;

  final ImagePicker _picker = ImagePicker();
  bool _submitting = false;

  /// After a successful upload, lock the button until something changes.
  bool _isIdSaved = false;

  // (Kept for reference; we’ll route through ApiClient instead)
  Uri get verifyIdEndpoint => Uri.parse('${ApiConfig.baseUrl}/verify-id');

  bool get _canSubmit =>
      selectedIdType != null &&
      selectedIdType!.isNotEmpty &&
      frontImage != null &&
      backImage != null &&
      !_submitting &&
      !_isIdSaved;

  @override
  void initState() {
    super.initState();
    _loadFromPrefs();
  }

  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();

    selectedIdType = prefs.getString('id_type');
    final frontPath = prefs.getString('id_front_image_path');
    final backPath = prefs.getString('id_back_image_path');

    // If you previously marked a successful upload, respect that state on reopen
    _isIdSaved = prefs.getBool('id_preuploaded') ?? false;

    if (frontPath != null &&
        frontPath.isNotEmpty &&
        File(frontPath).existsSync()) {
      frontImage = File(frontPath);
    }
    if (backPath != null &&
        backPath.isNotEmpty &&
        File(backPath).existsSync()) {
      backImage = File(backPath);
    }

    setState(() {});

    // Notify parent so state is restored outside
    if (selectedIdType != null && selectedIdType!.isNotEmpty) {
      widget.onIdTypeSelected(selectedIdType!);
    }
    if (frontImage != null) widget.onFrontImagePicked(frontImage!);
    if (backImage != null) widget.onBackImagePicked(backImage!);

    // ✅ Tell parent whether "Save ID" had succeeded earlier
    widget.onSubmittedChanged?.call(_isIdSaved);
  }

  Future<void> _saveToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('id_type', selectedIdType ?? '');
    await prefs.setString('id_front_image_path', frontImage?.path ?? '');
    await prefs.setString('id_back_image_path', backImage?.path ?? '');
  }

  Future<void> _invalidateSavedState() async {
    if (!_isIdSaved) {
      // Even if not saved, still ensure parent is locked until next save
      widget.onSubmittedChanged?.call(false);
      return;
    }
    setState(() => _isIdSaved = false);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('id_preuploaded');

    // ✅ Something changed → must re-save
    widget.onSubmittedChanged?.call(false);
  }

  Future<void> _pickImage(bool isFront) async {
    final ImageSource? source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (BuildContext context) {
        return SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.camera_alt),
                title: const Text('Take Photo'),
                onTap: () => Navigator.pop(context, ImageSource.camera),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library),
                title: const Text('Choose from Gallery'),
                onTap: () => Navigator.pop(context, ImageSource.gallery),
              ),
            ],
          ),
        );
      },
    );

    if (source == null) return;

    final XFile? pickedFile = await _picker.pickImage(source: source);
    if (pickedFile == null) return;

    final file = File(pickedFile.path);

    // Changing either photo should unlock the button
    await _invalidateSavedState();

    setState(() {
      if (isFront) {
        frontImage = file;
        widget.onFrontImagePicked(file);
      } else {
        backImage = file;
        widget.onBackImagePicked(file);
      }
    });

    await _saveToPrefs();
  }

  Future<void> _removeImage(bool isFront) async {
    // Removing a photo definitely unlocks the button
    await _invalidateSavedState();

    setState(() {
      if (isFront) {
        frontImage = null;
      } else {
        backImage = null;
      }
    });
    await _saveToPrefs();
  }

  Future<void> _markPreuploaded() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('id_preuploaded', true);
  }

  Future<void> _uploadBothSides() async {
    if (!_canSubmit) return;

    try {
      setState(() => _submitting = true);

      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        throw Exception('Not authenticated');
      }

      // ✅ Route through ApiClient: handles 401/403 → force refresh → retry-once
      final streamed = await ApiClient.postMultipartPaths(
        "/verify-id",
        fields: {'id_type': selectedIdType!},
        filePaths: {
          'front_id': frontImage!.path,
          'back_id': backImage!.path,
        },
        timeout: const Duration(seconds: 150),
      );
      await ApiClient.expectOkStreamed(streamed);

      // Throw with body if not 200, for better debugging
      await ApiClient.expectOkStreamed(streamed);

      // Success: lock the button until something changes.
      if (!mounted) return;
      setState(() => _isIdSaved = true);
      await _markPreuploaded();

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('ID uploaded'),
          backgroundColor: Colors.green, // success = green
        ),
      );

      // ✅ Upload succeeded → unlock Next in parent
      widget.onSubmittedChanged?.call(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Upload failed — ${e.toString()}'),
          backgroundColor: Colors.red, // error = red
        ),
      );

      // keep locked
      widget.onSubmittedChanged?.call(false);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Widget _buildPhotoSection({
    required String title,
    required bool isFront,
    required File? imageFile,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: Color(0xFFB5276A),
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          height: 150,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFB5276A)),
          ),
          child: imageFile != null
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(imageFile, fit: BoxFit.cover),
                )
              : Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.credit_card,
                          size: 50, color: Color(0xFFB5276A)),
                      const SizedBox(height: 10),
                      Text(
                        "Please take a clear photo of the\n$title",
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFFB5276A),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
        const SizedBox(height: 10),
        Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ElevatedButton(
                onPressed: () => _pickImage(isFront),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFB5276A),
                  foregroundColor: Colors.white,
                ),
                child: const Text("Select Photo"),
              ),
              const SizedBox(width: 12),
              ElevatedButton(
                onPressed: () => _removeImage(isFront),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.grey,
                  foregroundColor: Colors.white,
                ),
                child: const Text("Remove"),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final canSubmitNow = _canSubmit;

    return Scaffold(
      backgroundColor: Colors.white,
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Let's Get to Know You",
              style: TextStyle(
                color: Color(0xFFB5276A),
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              "Answer a few questions to help us match you better (4 / 9)",
              style: TextStyle(
                color: Color(0xFFB5276A),
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              "Photo Verification",
              style: TextStyle(
                color: Color(0xFFB5276A),
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              "Type of ID",
              style: TextStyle(
                color: Color(0xFFB5276A),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: selectedIdType,
                  hint: const Text("Select ID type"),
                  onChanged: (value) async {
                    // Changing ID type unlocks the button
                    await _invalidateSavedState();

                    setState(() {
                      selectedIdType = value;
                      if (value != null) widget.onIdTypeSelected(value);
                    });
                    await _saveToPrefs();
                  },
                  items: const [
                    DropdownMenuItem(
                        value: "Passport", child: Text("Passport")),
                    DropdownMenuItem(
                        value: "Driver's License",
                        child: Text("Driver's License")),
                    DropdownMenuItem(
                        value: "National ID", child: Text("National ID")),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Color(0xFFB5276A).withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                "We ask for a valid ID to keep everyone safe. Your data is private and secure.",
                style: TextStyle(color: Color(0xFFB5276A)),
              ),
            ),
            const SizedBox(height: 30),
            _buildPhotoSection(
              title: "Front of ID",
              isFront: true,
              imageFile: frontImage,
            ),
            const SizedBox(height: 30),
            _buildPhotoSection(
              title: "Back of ID",
              isFront: false,
              imageFile: backImage,
            ),
            const SizedBox(height: 25),

            // One-time upload button — only enabled when complete and NOT saved
            Center(
              child: SizedBox(
                width: 220,
                height: 44,
                child: ElevatedButton(
                  onPressed: canSubmitNow ? _uploadBothSides : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFB5276A),
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: Colors.grey.shade300,
                    disabledForegroundColor: Colors.white,
                  ),
                  child: _submitting
                      ? const SizedBox(
                          height: 22,
                          width: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(_isIdSaved ? "Saved" : "Save ID"),
                ),
              ),
            ),
            const SizedBox(height: 12),

            if (!(selectedIdType != null &&
                selectedIdType!.isNotEmpty &&
                frontImage != null &&
                backImage != null))
              const Center(
                child: Text(
                  "Select ID type, Front, and Back to enable Save",
                  style: TextStyle(
                    color: Color(0xFFB5276A),
                    fontSize: 12,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
