// lib/utils/upload_service.dart
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

/// Network class for adaptive behavior.
enum NetClass { wifi, cellular, none }

/// Per-network upload tuning.
class UploadPreset {
  final int maxSide; // resize longest side (px)
  final int quality; // JPEG/WebP quality (0..100)
  final int concurrency; // how many parallel uploads
  final Duration timeout; // per-file timeout

  const UploadPreset({
    required this.maxSide,
    required this.quality,
    required this.concurrency,
    required this.timeout,
  });
}

/// Centralized, frontend-only helper:
/// - Detects Wi-Fi vs Cellular
/// - Compresses/resizes images
/// - Uploads to your EXISTING FastAPI endpoints (multipart/form-data)
/// - Returns the Supabase URL from backend JSON
class UploadService {
  UploadService._();

  // ------------ Public API ------------

  /// Prepare (compress+resize) an image locally WITHOUT uploading.
  /// Use this if you want to keep the same final-modal UX but faster uploads.
  static Future<File> prepareImage(File input,
      {int? overrideMaxSide, int? overrideQuality}) async {
    final p = await _preset();
    return _compress(
      input,
      maxSide: overrideMaxSide ?? p.maxSide,
      quality: overrideQuality ?? p.quality,
    );
  }

  /// Upload ONE file to your backend multipart endpoint.
  /// The backend should upload to Supabase and respond with { url: "..." } or equivalent.
  static Future<String> uploadSingleToBackend({
    required Uri
        endpoint, // e.g. Uri.parse('${ApiConfig.baseUrl}/upload-selfie')
    required String fieldName, // e.g. 'selfie' | 'id_front' | 'id_back'
    required File file,
    Map<String, String>? extraFields, // any other form fields your API expects
    Duration? timeoutOverride, // override per-file timeout if desired
  }) async {
    final p = await _preset();

    // compress locally (adaptive to network)
    final compressed =
        await _compress(file, maxSide: p.maxSide, quality: p.quality);

    // auth header from Firebase
    final headers = await _authHeadersJson();

    return _retry(() async {
      final req = http.MultipartRequest('POST', endpoint);
      req.headers.addAll(headers);
      if (extraFields != null && extraFields.isNotEmpty) {
        req.fields.addAll(extraFields);
      }
      req.files.add(
        await http.MultipartFile.fromPath(fieldName, compressed.path),
      );

      final streamed = await req.send().timeout(timeoutOverride ?? p.timeout);
      final res = await http.Response.fromStream(streamed);

      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw HttpException('Upload failed: ${res.statusCode} ${res.body}');
      }

      final body = _safeJson(res.body);
      final url = _extractUrl(body);
      if (url == null || url.isEmpty) {
        throw StateError('Upload succeeded but no URL returned by backend.');
      }
      return url;
    });
  }

  /// Upload ALL THREE with adaptive concurrency (Wi-Fi: parallel, Cellular: sequential).
  /// Provide your existing endpoints; this does NOT change your backend.
  static Future<Map<String, String>> uploadAllViaBackend({
    required Uri selfieEndpoint,
    required Uri idFrontEndpoint,
    required Uri idBackEndpoint,
    required File selfie,
    required File idFront,
    required File idBack,
    Map<String, String>? extraSelfieFields,
    Map<String, String>? extraFrontFields,
    Map<String, String>? extraBackFields,
    Duration? timeoutOverride,
  }) async {
    final p = await _preset();

    // Prepare (compress) first to avoid double work in parallel paths
    final prepared = await Future.wait([
      _compress(selfie, maxSide: p.maxSide, quality: p.quality),
      _compress(idFront, maxSide: p.maxSide, quality: p.quality),
      _compress(idBack, maxSide: p.maxSide, quality: p.quality),
    ]);
    final cSelfie = prepared[0];
    final cFront = prepared[1];
    final cBack = prepared[2];

    Future<String> upSelfie() => uploadSingleToBackend(
          endpoint: selfieEndpoint,
          fieldName: 'selfie',
          file: cSelfie,
          extraFields: extraSelfieFields,
          timeoutOverride: timeoutOverride ?? p.timeout,
        );

    Future<String> upFront() => uploadSingleToBackend(
          endpoint: idFrontEndpoint,
          fieldName: 'id_front',
          file: cFront,
          extraFields: extraFrontFields,
          timeoutOverride: timeoutOverride ?? p.timeout,
        );

    Future<String> upBack() => uploadSingleToBackend(
          endpoint: idBackEndpoint,
          fieldName: 'id_back',
          file: cBack,
          extraFields: extraBackFields,
          timeoutOverride: timeoutOverride ?? p.timeout,
        );

    final urls = <String, String>{};

    if (p.concurrency == 1) {
      // Cellular: safer sequential uploads
      urls['id_front_url'] = await upFront();
      urls['id_back_url'] = await upBack();
      urls['selfie_url'] = await upSelfie();
    } else {
      // Wi-Fi: parallel uploads
      final res = await Future.wait([upFront(), upBack(), upSelfie()]);
      urls['id_front_url'] = res[0];
      urls['id_back_url'] = res[1];
      urls['selfie_url'] = res[2];
    }

    return urls;
  }

  // ------------ Internals ------------

  static Future<NetClass> _net() async {
    final results = await Connectivity().checkConnectivity();
    if (results.contains(ConnectivityResult.wifi)) return NetClass.wifi;
    if (results.contains(ConnectivityResult.mobile)) return NetClass.cellular;
    return NetClass.none;
  }

  static Future<UploadPreset> _preset() async {
    switch (await _net()) {
      case NetClass.wifi:
        return const UploadPreset(
          maxSide: 1440,
          quality: 80,
          concurrency: 3,
          timeout: Duration(seconds: 90),
        );
      case NetClass.cellular:
        return const UploadPreset(
          maxSide: 960,
          quality: 68,
          concurrency: 1,
          timeout: Duration(seconds: 150),
        );
      case NetClass.none:
        return const UploadPreset(
          maxSide: 960,
          quality: 65,
          concurrency: 1,
          timeout: Duration(seconds: 150),
        );
    }
  }

  static Future<File> _compress(File input,
      {required int maxSide, required int quality}) async {
    // For non-JPEG inputs, flutter_image_compress will still re-encode.
    final outPath = '${input.path}.cmp.jpg';
    final bytes = await FlutterImageCompress.compressWithFile(
      input.path,
      minWidth: maxSide,
      minHeight: maxSide,
      quality: quality,
      keepExif: false,
      format: CompressFormat.jpeg,
    );

    if (bytes == null) throw StateError('Image compression failed.');
    final out = File(outPath);
    await out.writeAsBytes(bytes, flush: true);
    return out;
    // TIP: If you ever need WebP: use format: CompressFormat.webp
  }

  static Future<Map<String, String>> _authHeadersJson() async {
    final token = await FirebaseAuth.instance.currentUser?.getIdToken();
    if (token == null) {
      throw StateError('User not authenticated');
    }
    return {
      'Authorization': 'Bearer $token',
      'Accept': 'application/json',
    };
  }

  static Future<T> _retry<T>(Future<T> Function() run,
      {int attempts = 3}) async {
    int i = 0;
    while (true) {
      try {
        return await run();
      } catch (e) {
        i += 1;
        if (i >= attempts) rethrow;
        await Future.delayed(
            Duration(milliseconds: 500 * i * i)); // 0.5s, 2s, 4.5s
      }
    }
  }

  static Map<String, dynamic> _safeJson(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic>
          ? decoded
          : <String, dynamic>{'raw': decoded};
    } catch (_) {
      return <String, dynamic>{'raw': body};
    }
  }

  /// Extract a URL from common server responses.
  /// Supports: {url}, {selfie_url}, {id_front_url}, {id_back_url}
  static String? _extractUrl(Map<String, dynamic> m) {
    final candidates = [
      m['url'],
      m['selfie_url'],
      m['id_front_url'],
      m['id_back_url'],
    ];
    for (final c in candidates) {
      if (c is String && c.isNotEmpty) return c;
    }
    return null;
  }
}
