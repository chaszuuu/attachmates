import 'package:supabase_flutter/supabase_flutter.dart';

class _CachedUrl {
  final String url;
  final DateTime expiresAt;
  _CachedUrl(this.url, this.expiresAt);
}

/// Caches Supabase signed URLs so we don't re-mint on every build.
class ImageUrlCache {
  static final Map<String, _CachedUrl> _cache = {};

  /// Returns a signed URL for a private storage path. Caches until ~expiry.
  static Future<String> signedUrl({
    required String bucket,
    required String path,
    Duration ttl = const Duration(hours: 6),
  }) async {
    final now = DateTime.now();
    final hit = _cache[path];
    if (hit != null && now.isBefore(hit.expiresAt)) {
      return hit.url;
    }

    final client = Supabase.instance.client;
    final seconds = ttl.inSeconds;
    final url =
        await client.storage.from(bucket).createSignedUrl(path, seconds);

    // keep a small safety margin before expiry
    final expiresAt = now.add(ttl).subtract(const Duration(minutes: 1));
    _cache[path] = _CachedUrl(url, expiresAt);
    return url;
  }

  static void invalidate(String path) => _cache.remove(path);
}
