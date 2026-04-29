import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PersonalInformationPage extends StatefulWidget {
  final Function(Map<String, dynamic>) onInfoChanged;
  final GlobalKey<FormState> formKey;
  final Map<String, dynamic> initialData;

  const PersonalInformationPage({
    super.key,
    required this.onInfoChanged,
    required this.formKey,
    required this.initialData,
  });

  @override
  State<PersonalInformationPage> createState() =>
      _PersonalInformationPageState();
}

class _PersonalInformationPageState extends State<PersonalInformationPage> {
  final TextEditingController _firstNameController = TextEditingController();
  final TextEditingController _lastNameController = TextEditingController();
  final TextEditingController _bioController = TextEditingController();

  String? _dobDisplay;
  String? _dobIso;
  String? _selectedGender; // UI TitleCase: Male/Female/Non-binary/Other
  File? _profileImage;

  bool _prefsLoaded = false; // <-- guard to avoid early overwrites

  // ---- UI list (Title Case) ----
  static const List<String> _uiGenderOptions = [
    'Male',
    'Female',
    'Non-binary',
    'Other',
  ];

  // ---- Helpers to map UI <-> stored lowercase values ----
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
        return '';
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

  @override
  void initState() {
    super.initState();
    _loadFromPrefs();
    _firstNameController.addListener(_notifyParent);
    _lastNameController.addListener(_notifyParent);
    _bioController.addListener(_notifyParent);

    // Removed post-frame notify to avoid saving empty fields before prefs load.
    // WidgetsBinding.instance.addPostFrameCallback((_) => _notifyParent());
  }

  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();

    setState(() {
      _firstNameController.text = prefs.getString('first_name') ?? '';
      _lastNameController.text = prefs.getString('last_name') ?? '';
      _bioController.text = prefs.getString('bio') ?? '';

      // Normalize stored lowercase -> UI TitleCase
      final storedGender = prefs.getString('gender'); // expected lowercase
      final uiGender = _uiGenderFromStored(storedGender);
      _selectedGender = uiGender.isNotEmpty ? uiGender : null;

      _dobDisplay = prefs.getString('dob_display');
      _dobIso = prefs.getString('dob_iso');

      final profileImagePath = prefs.getString('profile_image_path');
      if (profileImagePath != null && profileImagePath != 'default') {
        final file = File(profileImagePath);
        if (file.existsSync()) {
          _profileImage = file;
        }
      }

      _prefsLoaded = true; // mark as ready
    });

    // Now safely notify once after prefs are loaded.
    _notifyParent();
  }

  int _calculateAge(DateTime dob) {
    final now = DateTime.now();
    int age = now.year - dob.year;
    final hasHadBirthdayThisYear = (now.month > dob.month) ||
        (now.month == dob.month && now.day >= dob.day);
    if (!hasHadBirthdayThisYear) age--;
    return age;
  }

  Future<void> _notifyParent() async {
    if (!_prefsLoaded) return; // avoid early overwrites

    int? age;
    if (_dobIso != null && _dobIso!.isNotEmpty) {
      try {
        final dob = DateFormat('yyyy-MM-dd').parse(_dobIso!);
        age = _calculateAge(dob);
      } catch (_) {}
    }

    // Normalize to lowercase for backend/Firestore
    final normalizedGender = _storedGenderFromUi(_selectedGender);

    widget.onInfoChanged({
      'first_name': _firstNameController.text.trim(),
      'last_name': _lastNameController.text.trim(),
      'dob_display': _dobDisplay,
      'dob': _dobIso,
      'age': age,
      'gender': normalizedGender, // lowercase out to parent/backend
      'bio': _bioController.text.trim(),
      'profile_image': _profileImage,
    });

    // Persist locally (keep gender in lowercase as the single source of truth)
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('first_name', _firstNameController.text.trim());
    await prefs.setString('last_name', _lastNameController.text.trim());
    await prefs.setString('dob_display', _dobDisplay ?? '');
    await prefs.setString('dob_iso', _dobIso ?? '');
    await prefs.setString('bio', _bioController.text.trim());
    if (age != null) await prefs.setInt('age', age);

    // Only persist gender if a valid value is selected; don't overwrite with ''.
    if (normalizedGender.isNotEmpty) {
      await prefs.setString('gender', normalizedGender);
    }

    if (_profileImage != null) {
      await prefs.setString('profile_image_path', _profileImage!.path);
    } else {
      await prefs.setString('profile_image_path', 'default');
    }
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  Future<void> _pickProfileImage() async {
    showModalBottomSheet(
      context: context,
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
                  final picked =
                      await ImagePicker().pickImage(source: ImageSource.camera);
                  if (picked != null) {
                    setState(() => _profileImage = File(picked.path));
                    _notifyParent();
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_library),
                title: const Text('Choose from Gallery'),
                onTap: () async {
                  Navigator.pop(context);
                  final picked = await ImagePicker()
                      .pickImage(source: ImageSource.gallery);
                  if (picked != null) {
                    setState(() => _profileImage = File(picked.path));
                    _notifyParent();
                  }
                },
              ),
              if (_profileImage != null)
                ListTile(
                  leading: const Icon(Icons.delete),
                  title: const Text('Remove Photo'),
                  onTap: () async {
                    Navigator.pop(context);
                    setState(() => _profileImage = null);
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setString('profile_image_path', 'default');
                    _notifyParent();
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20.0),
      child: Form(
        key: widget.formKey,
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
              "Answer a few questions to help us match you better (1 / 9)",
              style: TextStyle(
                color: Color(0xFFB5276A),
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              "Personal Information",
              style: TextStyle(
                color: Color(0xFFB5276A),
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 20),
            Center(
              child: GestureDetector(
                onTap: _pickProfileImage,
                child: CircleAvatar(
                  radius: 50,
                  backgroundImage: _profileImage != null
                      ? FileImage(_profileImage!)
                      : const AssetImage('assets/default_pfp.png')
                          as ImageProvider,
                  child: Align(
                    alignment: Alignment.bottomRight,
                    child: Container(
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white,
                      ),
                      padding: const EdgeInsets.all(4),
                      child: const Icon(Icons.camera_alt, size: 18),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 32),

            // Bio right after profile image
            _buildBioField(),
            const SizedBox(height: 20),

            _buildInputField(
              label: "First Name",
              controller: _firstNameController,
              hint: "Enter your first name",
            ),
            const SizedBox(height: 16),
            _buildInputField(
              label: "Last Name",
              controller: _lastNameController,
              hint: "Enter your last name",
            ),
            const SizedBox(height: 16),
            _buildDobField(),
            const SizedBox(height: 16),

            // Title Case in UI, lowercase in storage
            _buildGenderDropdown(),

            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }

  Widget _buildInputField({
    required String label,
    required TextEditingController controller,
    required String hint,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
              color: Color(0xFFB5276A),
              fontWeight: FontWeight.bold,
            )),
        const SizedBox(height: 8),
        FormField<String>(
          validator: (value) =>
              controller.text.trim().isEmpty ? '*Required' : null,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          builder: (fieldState) {
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color:
                      fieldState.hasError ? Colors.red : Colors.grey.shade300,
                ),
              ),
              child: Stack(
                alignment: Alignment.centerLeft,
                children: [
                  TextField(
                    controller: controller,
                    onChanged: (value) => fieldState.didChange(value),
                    decoration: InputDecoration(
                      hintText: hint,
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 0, vertical: 16),
                    ),
                  ),
                  if (fieldState.hasError)
                    Positioned(
                      right: 0,
                      child: Text(
                        fieldState.errorText!,
                        style: const TextStyle(color: Colors.red, fontSize: 12),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildBioField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text("Short Bio (optional)",
            style: TextStyle(
              color: Color(0xFFB5276A),
              fontWeight: FontWeight.bold,
            )),
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
          ),
        ),
        const SizedBox(height: 4),
        Text(
          "${_bioController.text.length}/200",
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
      ],
    );
  }

  Widget _buildDobField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text("Date of Birth",
            style: TextStyle(
              color: Color(0xFFB5276A),
              fontWeight: FontWeight.bold,
            )),
        const SizedBox(height: 8),
        FormField<String>(
          validator: (value) =>
              _dobDisplay == null || _dobDisplay!.isEmpty ? '*Required' : null,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          builder: (fieldState) {
            return GestureDetector(
              onTap: () => _pickDate(context),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color:
                        fieldState.hasError ? Colors.red : Colors.grey.shade300,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _dobDisplay ?? "MM/DD/YYYY",
                      style: TextStyle(
                        color: _dobDisplay == null ? Colors.grey : Colors.black,
                      ),
                    ),
                    const Icon(Icons.calendar_today, color: Colors.grey),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildGenderDropdown() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text("Gender",
            style: TextStyle(
              color: Color(0xFFB5276A),
              fontWeight: FontWeight.bold,
            )),
        const SizedBox(height: 8),
        FormField<String>(
          validator: (value) =>
              _selectedGender == null || _selectedGender!.isEmpty
                  ? '*Required'
                  : null,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          builder: (fieldState) {
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color:
                      fieldState.hasError ? Colors.red : Colors.grey.shade300,
                ),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: _uiGenderOptions.contains(_selectedGender)
                      ? _selectedGender
                      : null,
                  hint: const Text("Select gender"),
                  onChanged: (value) {
                    setState(() {
                      _selectedGender = value; // Title Case in UI
                    });
                    fieldState.didChange(value);
                    _notifyParent(); // emits lowercase to parent + saves lowercase (guarded)
                  },
                  items: _uiGenderOptions
                      .map((g) => DropdownMenuItem(
                            value: g,
                            child: Text(g),
                          ))
                      .toList(),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Future<void> _pickDate(BuildContext context) async {
    final now = DateTime.now();
    final maxDate = DateTime(now.year - 18, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: maxDate,
      firstDate: DateTime(1900),
      lastDate: maxDate,
    );

    if (picked != null) {
      setState(() {
        _dobDisplay = DateFormat('MM/dd/yyyy').format(picked);
        _dobIso = DateFormat('yyyy-MM-dd').format(picked);
      });
      _notifyParent();
    }
  }
}
