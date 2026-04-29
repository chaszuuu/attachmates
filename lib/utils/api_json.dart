// lib/utils/api_json.dart
import 'dart:convert';
import 'package:http/http.dart' as http;

/// Decode any of:
/// - Map / Map<String, dynamic>
/// - http.Response (JSON body)
/// - String (JSON)
/// into a Map<String, dynamic>. Returns {} on empty bodies.
Map<String, dynamic> asJson(dynamic res) {
  if (res == null) return const {};

  if (res is Map<String, dynamic>) return res;

  if (res is Map) {
    return res.map((k, v) => MapEntry(k.toString(), v));
  }

  if (res is http.Response) {
    if (res.bodyBytes.isEmpty) return const {};
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
    throw const FormatException('Expected JSON object in http.Response');
  }

  if (res is String) {
    if (res.trim().isEmpty) return const {};
    final decoded = jsonDecode(res);
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
    throw const FormatException('Expected JSON object string');
  }

  throw ArgumentError('Unsupported response type: ${res.runtimeType}');
}

/// Get HTTP status code if this is an http.Response; otherwise null.
int? httpStatus(dynamic res) => (res is http.Response) ? res.statusCode : null;

/// Throw if this is an http.Response with 4xx/5xx.
void ensureOk(dynamic res) {
  if (res is http.Response && res.statusCode >= 400) {
    throw Exception('HTTP ${res.statusCode}: ${res.body}');
  }
}
