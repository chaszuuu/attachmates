// lib/utils/api_client.dart
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';
import 'api_config.dart';
import '../models/block_models.dart';

class ApiClient {
  ApiClient._();

  static const Duration _defaultTimeout = Duration(seconds: 20);
  // Refresh window: if token expires within this window, refresh preemptively.
  static const Duration _preemptiveRefreshWindow = Duration(minutes: 2);

  // ---------- internal ----------
  static Uri _u(String path, [Map<String, dynamic>? qp]) {
    final base = Uri.parse("${ApiConfig.baseUrl}$path");
    if (qp == null || qp.isEmpty) return base;
    return base.replace(queryParameters: {
      ...base.queryParameters,
      ...qp.map((k, v) => MapEntry(k, v?.toString() ?? "")),
    });
  }

  static Future<String> _freshIdToken() async {
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) throw Exception('User not authenticated');
    await u.reload();
    final token = await u.getIdToken(true);
    if (token == null || token.isEmpty) {
      throw Exception('Failed to fetch Firebase ID token');
    }
    return token;
  }

  /// Returns a token that is guaranteed to be valid for at least `_preemptiveRefreshWindow`.
  static Future<String> _ensureFreshToken({bool forceRefresh = false}) async {
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) throw Exception("User not authenticated");

    if (forceRefresh) {
      final t = await u.getIdToken(true);
      if (t != null && t.isNotEmpty) return t;
      return _freshIdToken();
    }

    // Try to use current token if not near expiry
    try {
      final res = await u.getIdTokenResult(false);
      final exp = res.expirationTime; // DateTime? in local tz
      if (exp != null) {
        final now = DateTime.now();
        // If token expires soon, force refresh
        if (exp.isBefore(now.add(_preemptiveRefreshWindow))) {
          final t = await u.getIdToken(true);
          if (t != null && t.isNotEmpty) return t;
          return _freshIdToken();
        }
        // Safe to reuse current token value
        final current = res.token;
        if (current != null && current.isNotEmpty) return current;
      }
    } catch (_) {
      // Fall through to force refresh
    }

    final t = await u.getIdToken(true);
    if (t != null && t.isNotEmpty) return t;
    return _freshIdToken();
  }

  static Future<Map<String, String>> _headersJson(
      {bool forceRefresh = false}) async {
    final token = await _ensureFreshToken(forceRefresh: forceRefresh);
    return {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
  }

  static bool _isAuthError(int code, [String? body]) {
    if (code == 401 || code == 403) return true;
    if (body == null) return false;
    final b = body.toLowerCase();
    return b.contains('expired') ||
        b.contains('invalid') ||
        b.contains('unauth') ||
        b.contains('token');
  }

  // ---------- HTTP helpers ----------
  static Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, dynamic>? query,
    Duration? timeout,
    bool forceRefreshFirst = false,
  }) async {
    // 1st attempt (optionally pre-refresh)
    var headers = await _headersJson(forceRefresh: forceRefreshFirst);
    var res = await http
        .get(_u(path, query), headers: headers)
        .timeout(timeout ?? _defaultTimeout);

    // Retry once on auth failure with a forced fresh token
    if (_isAuthError(res.statusCode, res.body)) {
      headers = await _headersJson(forceRefresh: true);
      res = await http
          .get(_u(path, query), headers: headers)
          .timeout(timeout ?? _defaultTimeout);
    }

    if (res.statusCode != 200) {
      throw Exception("GET $path failed: ${res.statusCode} ${res.body}");
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<http.Response> postJson(
    String path,
    Map<String, dynamic> body, {
    Duration? timeout,
    bool forceRefreshFirst = false,
  }) async {
    // 1st attempt (optionally pre-refresh)
    var headers = await _headersJson(forceRefresh: forceRefreshFirst);
    var res = await http
        .post(_u(path), headers: headers, body: jsonEncode(body))
        .timeout(timeout ?? _defaultTimeout);

    // Retry once on auth failure with a forced fresh token
    if (_isAuthError(res.statusCode, res.body)) {
      headers = await _headersJson(forceRefresh: true);
      res = await http
          .post(_u(path), headers: headers, body: jsonEncode(body))
          .timeout(timeout ?? _defaultTimeout);
    }
    return res;
  }

  static Future<Map<String, dynamic>> postJsonExpectOk(
    String path,
    Map<String, dynamic> body, {
    Duration? timeout,
    bool forceRefreshFirst = false,
  }) async {
    final res = await postJson(
      path,
      body,
      timeout: timeout,
      forceRefreshFirst: forceRefreshFirst,
    );
    if (res.statusCode != 200) {
      throw Exception("POST $path failed: ${res.statusCode} ${res.body}");
    }
    try {
      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  /// DELETE with JSON body + token refresh + single retry.
  static Future<http.Response> deleteJson(
    String path, {
    Map<String, dynamic>? body,
    Duration? timeout,
    bool forceRefreshFirst = false,
  }) async {
    // First attempt
    var headers = await _headersJson(forceRefresh: forceRefreshFirst);
    final req1 = http.Request('DELETE', _u(path))
      ..headers.addAll(headers)
      ..body = jsonEncode(body ?? const {});
    var res = await http.Client()
        .send(req1)
        .timeout(timeout ?? _defaultTimeout)
        .then(http.Response.fromStream);

    if (_isAuthError(res.statusCode, res.body)) {
      headers = await _headersJson(forceRefresh: true);
      final req2 = http.Request('DELETE', _u(path))
        ..headers.addAll(headers)
        ..body = jsonEncode(body ?? const {});
      res = await http.Client()
          .send(req2)
          .timeout(timeout ?? _defaultTimeout)
          .then(http.Response.fromStream);
    }
    return res;
  }

  static Future<Map<String, dynamic>> deleteJsonExpectOk(
    String path, {
    Map<String, dynamic>? body,
    Duration? timeout,
    bool forceRefreshFirst = false,
  }) async {
    final res = await deleteJson(
      path,
      body: body,
      timeout: timeout,
      forceRefreshFirst: forceRefreshFirst,
    );
    if (res.statusCode != 200) {
      throw Exception("DELETE $path failed: ${res.statusCode} ${res.body}");
    }
    try {
      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  /// Multipart with automatic token refresh + single retry on 401/403.
  static Future<http.StreamedResponse> postMultipart(
    String path,
    http.MultipartRequest req, {
    Duration? timeout,
  }) async {
    // ----- first attempt -----
    var token = await _ensureFreshToken(); // preemptive refresh-aware
    var first = http.MultipartRequest(req.method, _u(path))
      ..headers.addAll(req.headers)
      ..fields.addAll(req.fields)
      ..files.addAll(req.files)
      ..headers['Authorization'] = 'Bearer $token'
      ..headers['Accept'] = 'application/json';

    var res = await first.send().timeout(timeout ?? _defaultTimeout);

    // If not auth-related failure, return immediately
    if (res.statusCode != 401 && res.statusCode != 403) {
      return res;
    }

    // ----- retry once with a freshly refreshed token -----
    token = await _freshIdToken();
    var second = http.MultipartRequest(req.method, _u(path))
      ..headers.addAll(req.headers)
      ..fields.addAll(req.fields)
      ..files.addAll(req.files)
      ..headers['Authorization'] = 'Bearer $token'
      ..headers['Accept'] = 'application/json';

    return second.send().timeout(timeout ?? _defaultTimeout);
  }

  /// Build-and-send multipart from **file paths** so we can recreate the request on retry.
  static Future<http.StreamedResponse> postMultipartPaths(
    String path, {
    Map<String, String>? fields,
    Map<String, String>? filePaths, // key = field name, value = local file path
    Duration? timeout,
  }) async {
    Future<http.MultipartRequest> _build(String bearer) async {
      final req = http.MultipartRequest('POST', _u(path))
        ..headers['Authorization'] = 'Bearer $bearer'
        ..headers['Accept'] = 'application/json';

      if (fields != null && fields.isNotEmpty) {
        req.fields.addAll(fields);
      }
      if (filePaths != null && filePaths.isNotEmpty) {
        for (final entry in filePaths.entries) {
          req.files
              .add(await http.MultipartFile.fromPath(entry.key, entry.value));
        }
      }
      return req;
    }

    // 1st attempt with preemptive-fresh token
    var token = await _ensureFreshToken();
    var req = await _build(token);
    var res = await req.send().timeout(timeout ?? _defaultTimeout);

    if (res.statusCode != 401 && res.statusCode != 403) {
      return res;
    }

    // Retry once with a new token (rebuild request so files aren't "finalized")
    token = await _freshIdToken();
    req = await _build(token);
    return req.send().timeout(timeout ?? _defaultTimeout);
  }

  /// Build-and-send multipart from a **builder** that creates a fresh request each attempt.
  /// Use this for bodies built from BYTES (e.g., default asset profile image),
  /// so retries don't reuse finalized streams.
  static Future<http.StreamedResponse> postMultipartBuilder(
    String path,
    Future<http.MultipartRequest> Function(String bearer) build, {
    Duration? timeout,
  }) async {
    // 1st attempt (preemptive-fresh)
    var token = await _ensureFreshToken();
    var req = await build(token);
    var res = await req.send().timeout(timeout ?? _defaultTimeout);

    if (res.statusCode != 401 && res.statusCode != 403) {
      return res;
    }

    // Retry: force refresh and rebuild request
    token = await _freshIdToken();
    req = await build(token);
    return req.send().timeout(timeout ?? _defaultTimeout);
  }

  /// Convenience: throw with body if a streamed response isn't 200.
  static Future<void> expectOkStreamed(http.StreamedResponse res) async {
    if (res.statusCode == 200) return;
    final body = await res.stream.bytesToString();
    throw Exception("Multipart failed: ${res.statusCode} $body");
  }

  // ==========================================================================
  //                               USER GALLERY
  // ==========================================================================
  /// Ask backend for signed upload URLs. Matches backend: POST /signed-upload
  /// Response: { "slots": [ { "path", "token", "public_url", "signed_url" }, ... ] }
  static Future<List<SignedUploadItem>> galleryCreateSignedUpload(
    int count, {
    String mime = "image/jpeg",
  }) async {
    final data = await postJsonExpectOk(
      '/signed-upload',
      {'count': count, 'mime': mime},
    );

    final List<dynamic> raw = (data['slots'] as List?) ?? const [];

    return raw.map((e) {
      // Ensure a strongly typed map for fromJson
      final m = Map<String, dynamic>.from(e as Map);
      return SignedUploadItem.fromJson(m);
    }).toList();
  }

  /// Finalize after successful client uploads — matches backend: POST /finalize-upload
  static Future<void> galleryFinalize(
    List<String> urls,
    List<String?> keys,
  ) async {
    await postJsonExpectOk('/finalize-upload', {
      'urls': urls,
      'keys': keys,
    });
  }

  /// Delete a gallery photo — matches backend: POST /delete-photo
  static Future<void> galleryDelete({String? key, String? url}) async {
    await postJsonExpectOk('/delete-photo', {
      if (key != null && key.isNotEmpty) 'key': key,
      if (url != null && url.isNotEmpty) 'url': url,
    });
  }

  /// Save a new gallery order — NO-OP unless you expose a backend route.
  static Future<void> galleryReorder(
    List<String> urls,
    List<String?> keys,
  ) async {
    // TODO: implement on backend (e.g., POST /reorder-gallery) then call it here.
    return;
  }

  // ==========================================================================
  //                               NOTIFICATIONS
  // ==========================================================================
  static Future<void> updateNotifPrefs(Map<String, bool> prefs) async {
    final clean = <String, bool>{
      'messages': prefs['messages'] ?? true,
      'matches': prefs['matches'] ?? true,
      'likes': prefs['likes'] ?? true,
      'verification': prefs['verification'] ?? true,
    };
    await postJsonExpectOk('/user/notif-prefs', clean);
  }

  static Future<Map<String, bool>> getNotifPrefs() async {
    try {
      final data = await getJson('/user/notif-prefs');
      final prefs = (data['prefs'] as Map?) ?? const {};
      return {
        'messages': (prefs['messages'] ?? true) as bool,
        'matches': (prefs['matches'] ?? true) as bool,
        'likes': (prefs['likes'] ?? true) as bool,
        'verification': (prefs['verification'] ?? true) as bool,
      };
    } catch (_) {
      return const {
        'messages': true,
        'matches': true,
        'likes': true,
        'verification': true,
      };
    }
  }

  // ==========================================================================
  //                               QUIZ / REASSESS
  // ==========================================================================
  static Future<Map<String, dynamic>> getReassessEligibility() async {
    try {
      final data = await getJson("/reassess-eligibility");
      return {
        "eligible": data["eligible"] == true,
        "retry_in_days": (data["retry_in_days"] as num?)?.toInt() ?? 0,
      };
    } catch (e) {
      return {
        "eligible": false,
        "retry_in_days": 0,
        "error": e.toString(),
      };
    }
  }

  static Future<http.Response> submitQuiz(Map<String, dynamic> payload) async {
    return postJson("/submit", payload);
  }

  // ==========================================================================
  //                               MATCHING API
  // ==========================================================================
  static Future<List<Map<String, dynamic>>> fetchMatches(
      {int topN = 20}) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw Exception("User not authenticated");

    final res = await postJson("/match", {"userId": uid, "topN": topN});
    if (res.statusCode != 200) {
      throw Exception("Match failed: ${res.statusCode} ${res.body}");
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final results =
        (data["candidates"] as List? ?? []).cast<Map<String, dynamic>>();
    return results;
  }

  static Future<List<Map<String, dynamic>>> listPairs({
    int limit = 50,
    String? cursor,
  }) async {
    final data = await getJson(
      "/matches",
      query: {
        "limit": limit,
        if (cursor != null && cursor.isNotEmpty) "cursor": cursor,
      },
    );
    final items = (data["matches"] as List? ?? []);
    return items.cast<Map<String, dynamic>>();
  }

  static Future<Map<String, dynamic>> likeUser(String otherUid) async {
    return await postJsonExpectOk("/matches/like", {"other_uid": otherUid});
  }

  static Future<Map<String, dynamic>> acceptUser(String otherUid) async {
    return await postJsonExpectOk("/matches/respond", {
      "other_uid": otherUid,
      "action": "accept",
    });
  }

  static Future<Map<String, dynamic>> declineUser(String otherUid) async {
    return await postJsonExpectOk("/matches/respond", {
      "other_uid": otherUid,
      "action": "decline",
    });
  }

  static Future<Map<String, dynamic>> passUser(String otherUid,
      {String? reason}) async {
    return await postJsonExpectOk("/matches/pass", {
      "other_uid": otherUid,
      if (reason != null && reason.isNotEmpty) "reason": reason,
    });
  }

  // ==========================================================================
  //                                 BLOCKS
  // ==========================================================================
  static Future<UserBlocksResponse> getUserBlocks() async {
    final data = await getJson('/user_blocks');
    return UserBlocksResponse.fromJson(data);
  }

  static Future<void> postBlock(String targetUid) async {
    await postJsonExpectOk('/block', {'target_uid': targetUid});
  }

  static Future<void> postUnblock(String targetUid) async {
    await postJsonExpectOk('/unblock', {'target_uid': targetUid});
  }

  // ==========================================================================
  //                                 ADMIN
  // ==========================================================================
  static Future<Map<String, dynamic>> adminFetchPending({
    int limit = 20,
    String? cursor,
  }) async {
    return await getJson(
      '/admin/verification-pending',
      query: {
        'limit': '$limit',
        if (cursor != null) 'cursor': cursor,
      },
    );
  }

  static Future<int> adminFetchPendingCount() async {
    final data = await getJson('/admin/verification-pending/count');
    return (data['count'] as num?)?.toInt() ?? 0;
  }

  static Future<void> adminApprove(String targetUid) async {
    await postJsonExpectOk(
        '/admin/verification/approve', {'target_uid': targetUid});
  }

  static Future<void> adminReject(String targetUid, String reason) async {
    await postJsonExpectOk('/admin/verification/reject', {
      'target_uid': targetUid,
      'reason': reason,
    });
  }

  static Future<List<dynamic>> adminListAdmins() async {
    final data = await getJson('/admin/roles/list');
    final list = (data['admins'] as List?) ?? const [];
    return list.cast<dynamic>();
  }

  static Future<Map<String, dynamic>> adminGrantRole(
      String targetUid, String role) async {
    return await postJsonExpectOk('/admin/roles/grant', {
      'target_uid': targetUid,
      'role': role,
    });
  }

  static Future<Map<String, dynamic>> adminRevokeRole(
      String targetUid, String role) async {
    return await postJsonExpectOk('/admin/roles/revoke', {
      'target_uid': targetUid,
      'role': role,
    });
  }

  // NEW: fetch short-lived signed URLs for verification media (selfie/front/back)
  static Future<Map<String, String>> adminGetVerificationMedia(
    String uid, {
    int expires = 3600, // seconds
  }) async {
    final data = await getJson(
      '/admin/verification-media',
      query: {'uid': uid, 'expires': '$expires'},
    );
    return <String, String>{
      'selfie_url': (data['selfie_url'] ?? '').toString(),
      'front_id_url': (data['front_id_url'] ?? '').toString(),
      'back_id_url': (data['back_id_url'] ?? '').toString(),
    };
  }

  // ==========================================================================
  //                               OTHER UTILITIES
  // ==========================================================================
  static Future<void> embedBio({required String bio}) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw Exception("User not authenticated");

    final res = await postJson("/embed-bio", {"uid": uid, "bio": bio});
    if (res.statusCode != 200) {
      throw Exception("Embed bio failed: ${res.statusCode} ${res.body}");
    }
  }
}

// ---------- Tiny models ----------
class SignedUploadItem {
  final String path; // e.g., "uid/1730389-1.jpg" (bucket-relative path)
  final String token; // uploadToSignedUrl token
  final String publicUrl; // public URL for display
  final String?
      signedUrl; // full signed PUT URL (includes bucket & token) — NEW

  SignedUploadItem({
    required this.path,
    required this.token,
    required this.publicUrl,
    this.signedUrl,
  });

  factory SignedUploadItem.fromJson(Map<String, dynamic> j) => SignedUploadItem(
        path: (j['path'] ?? '').toString(),
        token: (j['token'] ?? '').toString(),
        publicUrl: (j['public_url'] ?? '').toString(),
        signedUrl: (j['signed_url'] ?? '').toString().trim().isEmpty
            ? null
            : (j['signed_url'] as String),
      );

  /// Optional helper if you want to compute the PUT URI on the client.
  /// Prefer using `signedUrl` when present.
  Uri buildSignedUploadUri(String supabaseUrl, {String? bucket}) {
    if (signedUrl != null && signedUrl!.isNotEmpty) {
      return Uri.parse(signedUrl!);
    }
    if (bucket == null || bucket.isEmpty) {
      throw ArgumentError(
          'bucket is required when signedUrl is not provided by the server');
    }
    final base = supabaseUrl.endsWith('/')
        ? supabaseUrl.substring(0, supabaseUrl.length - 1)
        : supabaseUrl;
    return Uri.parse(
        "$base/storage/v1/object/upload/sign/$bucket/$path?token=$token");
  }
}
