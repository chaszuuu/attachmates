import 'dart:io';

import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../utils/api_client.dart'; // ✅ resilient client

class LivenessTestPage extends StatefulWidget {
  final Function(File?) onImageCaptured;

  // ✅ parent uses this to lock/unlock "Next"
  final ValueChanged<bool>? onSubmittedChanged;

  const LivenessTestPage({
    super.key,
    required this.onImageCaptured,
    this.onSubmittedChanged,
  });

  @override
  State<LivenessTestPage> createState() => _LivenessTestPageState();
}

class _LivenessTestPageState extends State<LivenessTestPage>
    with TickerProviderStateMixin {
  late AnimationController _countdownController;
  late Animation<double> _progressAnimation;

  CameraController? _cameraController;
  bool _isCameraInitialized = false;

  bool _isCountingDown = false;
  bool _isCompleted = false;
  int _countdown = 3;

  File? _capturedSelfie;

  // Retake & Upload flow flags (no URLs)
  bool _isUploading = false;
  bool _selfieUploaded = false;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _loadFromPrefs();

    _countdownController = AnimationController(
      duration: const Duration(seconds: 3),
      vsync: this,
    );

    _progressAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _countdownController, curve: Curves.linear),
    );
  }

  Future<void> _initializeCamera() async {
    final cameras = await availableCameras();
    final frontCamera = cameras.firstWhere(
      (cam) => cam.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );
    _cameraController = CameraController(frontCamera, ResolutionPreset.medium);
    await _cameraController!.initialize();
    if (mounted) {
      setState(() => _isCameraInitialized = true);
    }
  }

  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final pathStr = prefs.getString('liveness_selfie_path');
    final preFlag = prefs.getBool('selfie_preuploaded') ?? false;

    if (pathStr != null && pathStr.isNotEmpty) {
      final file = File(pathStr);
      if (file.existsSync()) {
        setState(() {
          _capturedSelfie = file;
          _isCompleted = true;
          _selfieUploaded = preFlag;
        });
        widget.onImageCaptured(file);

        // ✅ If previously submitted & uploaded, unlock Next on load
        widget.onSubmittedChanged?.call(preFlag);
        return;
      }
    }
    // No saved selfie — ensure parent is locked
    widget.onSubmittedChanged?.call(false);
  }

  Future<void> _savePathToPrefs(File file) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('liveness_selfie_path', file.path);
  }

  Future<void> _clearPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('liveness_selfie_path');
    await prefs.remove('selfie_preuploaded');
  }

  @override
  void dispose() {
    _countdownController.dispose();
    _cameraController?.dispose();
    super.dispose();
  }

  void _startLivenessTest() {
    if (_isCountingDown || _isCompleted || !_isCameraInitialized) return;
    setState(() {
      _isCountingDown = true;
      _countdown = 3;
    });
    _countdownController.forward(from: 0);
    _runCountdown();
  }

  void _retryTest() async {
    setState(() {
      _isCompleted = false;
      _isCountingDown = false;
      _capturedSelfie = null;
      _selfieUploaded = false;
      _isUploading = false;
      _countdown = 3;
    });
    _countdownController.reset();
    await _clearPrefs();
    widget.onImageCaptured(null);

    // ✅ Changed/cleared selfie → must re-submit, lock Next
    widget.onSubmittedChanged?.call(false);
  }

  void _runCountdown() async {
    for (int i = 3; i > 0; i--) {
      setState(() => _countdown = i);
      await Future.delayed(const Duration(seconds: 1));
    }
    await _captureSelfie();
  }

  Future<void> _captureSelfie() async {
    try {
      final rawImage = await _cameraController!.takePicture();
      final tempDir = await getTemporaryDirectory();
      final filePath = path.join(
          tempDir.path, 'selfie_${DateTime.now().millisecondsSinceEpoch}.jpg');
      final selfieFile = File(filePath);
      await selfieFile.writeAsBytes(await rawImage.readAsBytes());

      setState(() {
        _capturedSelfie = selfieFile;
        _isCountingDown = false;
        _isCompleted = true; // preview ready
        _selfieUploaded = false; // not uploaded yet
      });

      widget.onImageCaptured(selfieFile);
      await _savePathToPrefs(selfieFile);

      // ✅ New/changed selfie → requires a fresh submit
      widget.onSubmittedChanged?.call(false);
    } catch (e) {
      if (!mounted) return;
      _showSnack('Selfie capture failed: $e', error: true);
      setState(() {
        _isCountingDown = false;
        _isCompleted = false;
      });
      widget.onSubmittedChanged?.call(false);
    }
  }

  Future<void> _markPreuploaded() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('selfie_preuploaded', true);
  }

  Future<void> _confirmAndUpload() async {
    if (_capturedSelfie == null || _isUploading || _selfieUploaded) return;

    setState(() => _isUploading = true);
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('Not authenticated');

      // ✅ pre-warm a fresh ID token to avoid intermittent 401s on retake
      await user.getIdToken(true);

      final streamed = await ApiClient.postMultipartPaths(
        "/upload-selfie",
        fields: {'uid': user.uid}, // optional, if backend uses it
        filePaths: {'selfie': _capturedSelfie!.path},
        timeout: const Duration(seconds: 150),
      );
      await ApiClient.expectOkStreamed(streamed);

      if (!mounted) return;
      setState(() => _selfieUploaded = true);
      await _markPreuploaded();
      _showSnack('Selfie uploaded');
      widget.onSubmittedChanged?.call(true);
    } catch (e) {
      if (!mounted) return;
      _showSnack('Selfie upload failed: $e', error: true);
      widget.onSubmittedChanged?.call(false);
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  void _showSnack(String message, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? Colors.red : Colors.green,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return !_isCameraInitialized
        ? const Center(child: CircularProgressIndicator())
        : SingleChildScrollView(
            padding: const EdgeInsets.all(20.0),
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
                  "Answer a few questions to help us match you better (3 / 9)",
                  style: TextStyle(
                    color: Color(0xFFB5276A),
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  "Liveness Verification",
                  style: TextStyle(
                    color: Color(0xFFB5276A),
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 20),

                // Preview + countdown
                Center(
                  child: AnimatedBuilder(
                    animation: _progressAnimation,
                    builder: (_, __) => Stack(
                      alignment: Alignment.center,
                      children: [
                        SizedBox(
                          width: 260,
                          height: 260,
                          child: CircularProgressIndicator(
                            value: _isCountingDown
                                ? _progressAnimation.value
                                : 0.0,
                            strokeWidth: 6,
                            valueColor:
                                const AlwaysStoppedAnimation(Color(0xFFB5276A)),
                            backgroundColor:
                                const Color(0xFFB5276A).withOpacity(0.1),
                          ),
                        ),
                        ClipOval(
                          child: SizedBox(
                            width: 250,
                            height: 250,
                            child: _capturedSelfie != null
                                ? Image.file(_capturedSelfie!,
                                    fit: BoxFit.cover)
                                : CameraPreview(_cameraController!),
                          ),
                        ),
                        if (_isCountingDown)
                          Text(
                            '$_countdown',
                            style: const TextStyle(
                              fontSize: 48,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 30),

                // Buttons
                if (!_isCountingDown)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (_isCompleted) ...[
                        ElevatedButton(
                          onPressed: (_isUploading || _selfieUploaded)
                              ? null
                              : _confirmAndUpload,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFB5276A),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 30,
                              vertical: 12,
                            ),
                          ),
                          child: _isUploading
                              ? const SizedBox(
                                  height: 22,
                                  width: 22,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Text("Choose this photo"),
                        ),
                        const SizedBox(width: 12),
                        ElevatedButton(
                          onPressed: _isUploading ? null : _retryTest,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.grey,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 30,
                              vertical: 12,
                            ),
                          ),
                          child: const Text("Retake"),
                        ),
                      ],
                      if (!_isCompleted)
                        ElevatedButton(
                          onPressed: _startLivenessTest,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFB5276A),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 30,
                              vertical: 12,
                            ),
                          ),
                          child: const Text("Start Test"),
                        ),
                    ],
                  ),
                const SizedBox(height: 20),

                // Tip box
                Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFB5276A).withOpacity(0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: const [
                      Icon(Icons.lightbulb_outline, color: Color(0xFFB5276A)),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          "Please stay in a well-lit area and keep your face within the circle for accurate verification.",
                          style: TextStyle(
                            fontSize: 13,
                            color: Color(0xFFB5276A),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
  }
}
