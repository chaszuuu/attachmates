import 'dart:typed_data';
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';

class ImageUpload {
  static final _picker = ImagePicker();

  /// One-shot: pick (camera/gallery) and return compressed WebP bytes.
  static Future<Uint8List?> pickAndCompress({
    bool fromCamera = false,
    int targetWidth = 1080,
    int targetHeight = 1440,
    int quality = 80,
  }) async {
    final picked = await _picker.pickImage(
      source: fromCamera ? ImageSource.camera : ImageSource.gallery,
      imageQuality: 100,
    );
    if (picked == null) return null;
    return compressFile(File(picked.path),
        targetWidth: targetWidth, targetHeight: targetHeight, quality: quality);
  }

  /// Compress an existing FILE (e.g., from Camera plugin) to WebP bytes.
  static Future<Uint8List?> compressFile(
    File file, {
    int targetWidth = 1080,
    int targetHeight = 1440,
    int quality = 80,
  }) async {
    final bytes = await file.readAsBytes();
    return compressBytes(bytes,
        targetWidth: targetWidth, targetHeight: targetHeight, quality: quality);
  }

  /// Compress raw BYTES to WebP bytes.
  static Future<Uint8List?> compressBytes(
    Uint8List bytes, {
    int targetWidth = 1080,
    int targetHeight = 1440,
    int quality = 80,
  }) async {
    return FlutterImageCompress.compressWithList(
      bytes,
      minWidth: targetWidth,
      minHeight: targetHeight,
      quality: quality,
      format: CompressFormat.webp,
      keepExif: false,
    );
  }
}
