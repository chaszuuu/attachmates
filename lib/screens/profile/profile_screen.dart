// lib/screens/profile/profile_screen.dart
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart' hide Config;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart'
    as dotenv; // ✅ env-based URL

import '../../utils/constants.dart';
import '../../utils/api_client.dart';
import '../discover/discover_screen.dart';
import '../matches/matches_screen.dart';
import '../messages/messages_screen.dart';
import 'edit_profile_screen.dart';
import '../settings/settings_screen.dart';

// 🔔 notifications
import '../../repositories/notifications_repository.dart';
import '../notifications/notifications_screen.dart';

// ✅ single source of truth for interest categories
import '../../utils/interest_categories.dart';

// Pair helper (url + storage key)
class _PhotoPair {
  final String url;
  final String? key;
  const _PhotoPair({required this.url, required this.key});
}

// ---- shared image cache (same approach as Discover) ----
final CacheManager kImageCacheManager = CacheManager(
  Config(
    'attachmates_images_v1',
    stalePeriod: const Duration(days: 14),
    maxNrOfCacheObjects: 300,
  ),
);

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  // track what we've already prefetched
  final Set<String> _prefetched = {};

  // 🔔 notifications repo + auth-aware unread stream
  final _notifsRepo = NotificationsRepository();
  late final Stream<int> _unreadStream;

  // Local optimistic state for gallery (no flicker)
  List<String> _localUrls = const [];
  List<String?> _localKeys = const [];

  // picking guard
  bool _uploading = false;

  // animate only the newly added tiles
  final Set<String> _recentlyAdded = {};

  @override
  void initState() {
    super.initState();
    _unreadStream =
        FirebaseAuth.instance.authStateChanges().asyncExpand((user) async* {
      if (user == null) {
        yield 0;
      } else {
        yield* _notifsRepo.unreadCountStream(uid: user.uid);
      }
    });
  }

  // Helpers to navigate
  void _navigateToDiscover(BuildContext context) {
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            const DiscoverScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(-1.0, 0.0);
          const end = Offset.zero;
          const curve = Curves.easeInOut;
          var tween =
              Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
          return SlideTransition(
              position: animation.drive(tween), child: child);
        },
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );
  }

  void _navigateToMatches(BuildContext context) {
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            const MatchesScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(-1.0, 0.0);
          const end = Offset.zero;
          const curve = Curves.easeInOut;
          var tween =
              Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
          return SlideTransition(
              position: animation.drive(tween), child: child);
        },
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );
  }

  void _navigateToMessages(BuildContext context) {
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            const MessagesScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(-1.0, 0.0);
          const end = Offset.zero;
          const curve = Curves.easeInOut;
          var tween =
              Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
          return SlideTransition(
              position: animation.drive(tween), child: child);
        },
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );
  }

  void _navigateToEditProfile(BuildContext context) {
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            const EditProfileScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(1.0, 0.0);
          const end = Offset.zero;
          const curve = Curves.easeInOut;
          var tween =
              Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
          return SlideTransition(
              position: animation.drive(tween), child: child);
        },
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );
  }

  // 🔔 NEW: navigate to notifications
  void _navigateToNotifications() {
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const NotificationsScreen(),
        transitionsBuilder: (_, a, __, child) => SlideTransition(
          position: a.drive(
            Tween(begin: const Offset(1, 0), end: Offset.zero)
                .chain(CurveTween(curve: Curves.easeInOut)),
          ),
          child: child,
        ),
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );
  }

  // ====== Firestore stream for the current user's profile ======
  Stream<DocumentSnapshot<Map<String, dynamic>>>? _userStream() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return null;
    // includeMetadataChanges → updates faster from cache/local writes
    return FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .snapshots(includeMetadataChanges: true);
  }

  // ---- prefetch helper ----
  void _prefetchImages(BuildContext context, List<String> urls) {
    for (final url in urls) {
      if (url.isEmpty || _prefetched.contains(url)) continue;
      _prefetched.add(url);
      kImageCacheManager.getSingleFile(url).ignore(); // disk cache
      precacheImage(
        CachedNetworkImageProvider(url, cacheManager: kImageCacheManager),
        context,
      ).ignore();
    }
  }

  // ---- gender helpers (icon + color + normalized string) ----
  IconData? _iconForGender(String? raw) {
    if (raw == null) return null;
    final g = raw.trim().toLowerCase();
    if (g.isEmpty) return null;
    if (g == 'male' || g == 'man' || g == 'm') return Icons.male;
    if (g == 'female' || g == 'woman' || g == 'f') return Icons.female;
    if (g.startsWith('trans')) return Icons.transgender;
    if (g.contains('non') && g.contains('binary')) return Icons.transgender;
    if (g == 'nb' || g == 'enby' || g.contains('genderqueer')) {
      return Icons.transgender;
    }
    if (g.contains('agender') || g.contains('gender fluid')) {
      return Icons.transgender;
    }
    if (g == 'other' ||
        g == 'others' ||
        g.contains('prefer') && g.contains('not')) {
      return Icons.person_outline;
    }
    return null;
  }

  // Match Discover’s palette exactly
  Color _colorForGender(String? raw) {
    if (raw == null) return Colors.white70;
    final g = raw.trim().toLowerCase();
    if (g == 'male' || g == 'man' || g == 'm') {
      return const Color.fromARGB(255, 37, 149, 247);
    }
    if (g == 'female' || g == 'woman' || g == 'f') {
      return AppColors.primaryColor;
    }
    if (g.startsWith('trans') ||
        (g.contains('non') && g.contains('binary')) ||
        g == 'nb' ||
        g == 'enby' ||
        g.contains('genderqueer') ||
        g.contains('agender') ||
        g.contains('gender fluid')) {
      return const Color(0xFF7E57C2);
    }
    if (g == 'other' ||
        g == 'others' ||
        (g.contains('prefer') && g.contains('not'))) {
      return Colors.teal;
    }
    return Colors.white70;
  }

  String? _readGender(Map<String, dynamic> data, Map<String, dynamic> pinfo) {
    final cand = [
      pinfo['gender'],
      pinfo['gender_identity'],
      data['gender'],
      data['gender_identity'],
    ].firstWhere(
      (e) => (e is String && e.trim().isNotEmpty),
      orElse: () => null,
    );
    return (cand is String) ? cand : null;
  }

  // ---------- label helpers ----------
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

  String _formatAttachmentLabel(String s) => _titleize(s);

  String _formatLoveLabel(String s) {
    final t = _titleize(s);
    return t.replaceAllMapped(
      RegExp(r'\b(Of|And|For|To|In|On|With|A|An)\b'),
      (m) => m.group(0)!.toLowerCase(),
    );
  }

  // ---------- pastel color helpers from constants ----------
  Color _attachmentPastel(String label) {
    return attachmentColors[label] ?? AppColors.lightPink;
  }

  Color _lovePastel(String label) {
    return loveLanguageColors[label] ?? AppColors.lightPink;
  }

  // ---------- Merge Firestore and local optimistic gallery (no flicker) ----------
  _MergedGalleryResult _mergeGallery(
    List<String> docUrls,
    List<String?> docKeys,
    List<String> localUrls,
    List<String?> localKeys,
  ) {
    final outUrls = <String>[];
    final outKeys = <String?>[];
    final seen = <String>{};

    void add(String u, String? k) {
      if (u.isEmpty) return;
      if (seen.add(u)) {
        outUrls.add(u);
        outKeys.add(k);
      }
    }

    // Doc (authoritative) first, then local optimistic
    for (var i = 0; i < docUrls.length; i++) {
      final u = docUrls[i];
      final k = (i < docKeys.length) ? docKeys[i] : null;
      add(u, k);
      if (outUrls.length == 9) break;
    }
    for (var i = 0; i < localUrls.length && outUrls.length < 9; i++) {
      final u = localUrls[i];
      final k = (i < localKeys.length) ? localKeys[i] : null;
      add(u, k);
    }
    return _MergedGalleryResult(outUrls, outKeys);
  }

  // ✅ helper to read Supabase base URL dynamically from .env or --dart-define
  String _supabaseBaseUrl() {
    const fromDefine = String.fromEnvironment('SUPABASE_URL');
    if (fromDefine.isNotEmpty) return fromDefine;
    try {
      final v = dotenv.dotenv.env['SUPABASE_URL'];
      if (v != null && v.isNotEmpty) return v;
    } catch (_) {}
    throw Exception('SUPABASE_URL not set in .env or via --dart-define');
  }

  // ✅ helper for bucket name (defaults to user-gallery)
  String _supabaseGalleryBucket() {
    const fromDefine = String.fromEnvironment('SUPABASE_GALLERY_BUCKET');
    if (fromDefine.isNotEmpty) return fromDefine;
    try {
      final v = dotenv.dotenv.env['SUPABASE_GALLERY_BUCKET'];
      if (v != null && v.isNotEmpty) return v;
    } catch (_) {}
    return 'user-gallery';
  }

  // ---------- Upload flow (SIGNED UPLOAD via Supabase token) ----------
  Future<void> _pickAndUploadPhotos({int? maxToPick}) async {
    if (_uploading) return;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    try {
      setState(() => _uploading = true);

      final picker = ImagePicker();
      final picked = await picker.pickMultiImage(imageQuality: 90);

      // Nothing picked → bail early
      if (picked.isEmpty) {
        setState(() => _uploading = false);
        return;
      }

      // Respect remaining slots
      final remaining = ((maxToPick ?? 9)).clamp(0, 9);
      if (remaining == 0) {
        if (mounted) {
          _snack("Your gallery is already full (9/9).", success: false);
        }
        setState(() => _uploading = false);
        return;
      }

      final selection = picked.take(remaining).toList();

      // Ask backend for signed upload slots
      final slots = await ApiClient.galleryCreateSignedUpload(selection.length,
          mime: 'image/jpeg');
      if (slots.isEmpty) {
        throw Exception('No signed upload slots returned');
      }

      final List<String> uploadedPublicUrls = [];
      final List<String?> uploadedKeys = [];

      final supabaseUrl = _supabaseBaseUrl();
      final bucket = _supabaseGalleryBucket();

      for (int i = 0; i < selection.length && i < slots.length; i++) {
        final x = selection[i];
        final bytes = await x.readAsBytes();
        if (bytes.isEmpty) continue;

        final slot = slots[i];

        // Prefer server-provided full signed URL; fallback to local construction.
        final Uri uploadUrl = (() {
          if (slot.signedUrl != null && slot.signedUrl!.isNotEmpty) {
            return Uri.parse(slot.signedUrl!);
          }
          try {
            return slot.buildSignedUploadUri(supabaseUrl, bucket: bucket);
          } catch (_) {
            // Last-resort construction (kept for backward-compat)
            return Uri.parse(
              "$supabaseUrl/storage/v1/object/upload/sign/$bucket/${slot.path}"
              "?token=${Uri.encodeQueryComponent(slot.token)}",
            );
          }
        })();

        // Signed upload is a raw HTTP PUT to Supabase
        final putRes = await http.put(
          uploadUrl,
          headers: {
            'x-upsert': 'false',
            'content-type': _guessMime(x.path),
          },
          body: bytes,
        );

        if (putRes.statusCode == 200) {
          uploadedPublicUrls.add(slot.publicUrl);
          uploadedKeys.add(slot.path);
        } else {
          debugPrint('Signed PUT failed ${putRes.statusCode}: ${putRes.body}');
        }
      }

      if (uploadedPublicUrls.isEmpty) {
        if (mounted) _snack("No valid images to upload.", success: false);
        return;
      }

      // Finalize after successful uploads — server merges & writes Firestore
      await ApiClient.galleryFinalize(uploadedPublicUrls, uploadedKeys);

      // Instant local merge (no flicker)
      setState(() {
        final merged = _mergeGallery(
          /* docUrls   */ const [], // stream will soon update; we just add local
          /* docKeys   */ const [],
          /* localUrls */ [..._localUrls, ...uploadedPublicUrls],
          /* localKeys */ [..._localKeys, ...uploadedKeys],
        );
        _localUrls =
            merged.urls.length > 9 ? merged.urls.take(9).toList() : merged.urls;
        _localKeys =
            merged.keys.length > 9 ? merged.keys.take(9).toList() : merged.keys;

        // mark the new ones for animation
        _recentlyAdded.addAll(uploadedPublicUrls);
      });

      // optional — clear markers after the animation completes
      Future.delayed(const Duration(milliseconds: 450), () {
        if (!mounted) return;
        setState(() {
          for (final u in uploadedPublicUrls) {
            _recentlyAdded.remove(u);
          }
        });
      });

      if (mounted) {
        _snack(
          "Uploaded ${uploadedPublicUrls.length} photo${uploadedPublicUrls.length == 1 ? '' : 's'}",
          success: true,
        );
      }
    } catch (e) {
      if (mounted) _snack("Upload failed — ${e.toString()}", success: false);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  // ---------- Delete flow (backend + optimistic UI + rollback on error) ----------
  Future<void> _deletePhoto(String url, {String? storageKey}) async {
    final prevUrls = List<String>.from(_localUrls);
    final prevKeys = List<String?>.from(_localKeys);

    // Optimistic remove
    setState(() {
      final i = _localUrls.indexOf(url);
      if (i >= 0) {
        _localUrls.removeAt(i);
        if (i < _localKeys.length) _localKeys.removeAt(i);
      }
    });

    try {
      await ApiClient.galleryDelete(key: storageKey, url: url);

      // Also persist to Firestore so Stream reflects removal
      await _persistGalleryOrder(_localUrls, _localKeys);

      if (mounted) {
        _snack("Photo removed", success: true);
      }
    } catch (e) {
      // Rollback on failure
      setState(() {
        _localUrls = prevUrls;
        _localKeys = prevKeys;
      });
      if (mounted) {
        _snack("Remove failed — ${e.toString()}", success: false);
      }
    }
  }

  // ---------- Reorder UI ----------
  Future<void> _openReorderSheet({
    required List<String> urls,
    required List<String?> keys,
  }) async {
    final List<String> workingUrls = List.of(urls);
    final List<String?> workingKeys = List.of(keys);

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: SizedBox(
              height: MediaQuery.of(ctx).size.height * 0.7,
              child: Column(
                children: [
                  const SizedBox(height: 12),
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    "Reorder Photos",
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16.0),
                    child: Text(
                      "Drag to reorder. The first photo shows first in your gallery.",
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, color: Colors.grey),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // White tiles, smaller thumbs
                  Expanded(
                    child: ReorderableListView.builder(
                      itemBuilder: (context, index) {
                        final url = workingUrls[index];
                        return Container(
                          key: ValueKey(url),
                          color: Colors.white, // pure white container
                          child: ListTile(
                            tileColor: Colors.white, // pure white tile
                            contentPadding:
                                const EdgeInsets.symmetric(horizontal: 16),
                            leading: ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: SizedBox(
                                width: 44, // smaller thumb
                                height: 44,
                                child: CachedNetworkImage(
                                  imageUrl: url,
                                  cacheManager: kImageCacheManager,
                                  fit: BoxFit.cover,
                                  useOldImageOnUrlChange: true,
                                  fadeInDuration: Duration.zero,
                                  placeholderFadeInDuration: Duration.zero,
                                  fadeOutDuration: Duration.zero,
                                  placeholder: (_, __) =>
                                      const SizedBox.shrink(),
                                ),
                              ),
                            ),
                            title: const Text(
                              "Image",
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                            trailing: const Icon(Icons.drag_handle),
                          ),
                        );
                      },
                      itemCount: workingUrls.length,
                      onReorder: (oldIndex, newIndex) {
                        if (newIndex > workingUrls.length) {
                          newIndex = workingUrls.length;
                        }
                        if (oldIndex < newIndex) newIndex -= 1;
                        final u = workingUrls.removeAt(oldIndex);
                        final k = (oldIndex < workingKeys.length)
                            ? workingKeys.removeAt(oldIndex)
                            : null;
                        workingUrls.insert(newIndex, u);
                        workingKeys.insert(newIndex, k);
                        setState(() {}); // minor repaint only
                      },
                    ),
                  ),

                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text("Cancel"),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.primaryColor,
                                foregroundColor: Colors.white),
                            onPressed: () async {
                              await _applyNewOrder(workingUrls, workingKeys);
                              if (mounted) Navigator.pop(ctx);
                            },
                            child: const Text("Confirm & Save"),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _applyNewOrder(List<String> urls, List<String?> keys) async {
    final prevUrls = List<String>.from(_localUrls);
    final prevKeys = List<String?>.from(_localKeys);

    // Optimistic update
    setState(() {
      _localUrls = urls;
      _localKeys = keys;
    });

    try {
      // Optional backend route (no-op for now)
      await ApiClient.galleryReorder(urls, keys);

      // Persist to Firestore so the stream becomes authoritative with new order
      await _persistGalleryOrder(urls, keys);

      if (mounted) {
        _snack("Order updated", success: true);
      }
    } catch (e) {
      // Rollback on error
      setState(() {
        _localUrls = prevUrls;
        _localKeys = prevKeys;
      });
      if (mounted) {
        _snack("Failed to save order — ${e.toString()}", success: false);
      }
    }
  }

  Future<void> _persistGalleryOrder(
      List<String> urls, List<String?> keys) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final doc = FirebaseFirestore.instance.collection('users').doc(uid);
    await doc.update({
      'photos': urls.take(9).toList(),
      'photos_keys': keys.take(9).toList(),
    });
  }

// Read-only fullscreen viewer for the profile avatar (no delete, no menu)
  void _openViewerReadOnly(String url) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return Dialog(
          backgroundColor: Colors.black,
          insetPadding: const EdgeInsets.all(0),
          child: Stack(
            children: [
              Positioned.fill(
                child: InteractiveViewer(
                  minScale: 0.8,
                  maxScale: 4.0,
                  child: Center(
                    child: CachedNetworkImage(
                      imageUrl: url,
                      cacheManager: kImageCacheManager,
                      fit: BoxFit.contain,
                      useOldImageOnUrlChange: true,
                      fadeInDuration: Duration.zero,
                      placeholderFadeInDuration: Duration.zero,
                      fadeOutDuration: Duration.zero,
                      placeholder: (_, __) => const SizedBox.shrink(),
                      errorWidget: (_, __, ___) => const Icon(
                        Icons.broken_image,
                        color: Colors.white70,
                        size: 48,
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 16,
                left: 8,
                child: IconButton(
                  onPressed: () => Navigator.pop(ctx),
                  icon: const Icon(Icons.close, color: Colors.white),
                  tooltip: 'Close',
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ---------- Fullscreen viewer with actions ----------
  void _openViewer(String url, {String? key}) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return Dialog(
          backgroundColor: Colors.black,
          insetPadding: const EdgeInsets.all(0),
          child: Stack(
            children: [
              Positioned.fill(
                child: InteractiveViewer(
                  minScale: 0.8,
                  maxScale: 4.0,
                  child: Center(
                    child: CachedNetworkImage(
                      imageUrl: url,
                      cacheManager: kImageCacheManager,
                      fit: BoxFit.contain,
                      useOldImageOnUrlChange: true,
                      fadeInDuration: Duration.zero,
                      placeholderFadeInDuration: Duration.zero,
                      fadeOutDuration: Duration.zero,
                      placeholder: (_, __) => const SizedBox.shrink(),
                      errorWidget: (_, __, ___) => const Icon(
                        Icons.broken_image,
                        color: Colors.white70,
                        size: 48,
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 16,
                left: 8,
                child: IconButton(
                  onPressed: () => Navigator.pop(ctx),
                  icon: const Icon(Icons.close, color: Colors.white),
                ),
              ),
              Positioned(
                top: 16,
                right: 8,
                child: PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert, color: Colors.white),
                  color: Colors.white,
                  onSelected: (v) async {
                    if (v == 'delete') {
                      Navigator.pop(ctx);
                      final confirm = await _confirmBottomSheet(
                        title: "Remove this photo?",
                        message:
                            "It will be removed from your profile gallery.",
                        helperText: "This action cannot be undone.",
                        confirmLabel: "Remove",
                      );

                      if (confirm == true) {
                        await _deletePhoto(url, storageKey: key);
                      }
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(Icons.delete_outline),
                          SizedBox(width: 8),
                          Text('Delete'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ---- bottom-sheet confirm helper (replaces AlertDialog) ----
  Future<bool?> _confirmBottomSheet({
    required String title,
    required String message,
    String? helperText, // ✅ NEW
    String cancelLabel = "Cancel",
    String confirmLabel = "Confirm",
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 12),
                Text(title,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text(
                  message,
                  style: const TextStyle(fontSize: 14, color: Colors.black87),
                  textAlign: TextAlign.center,
                ),
                if (helperText != null && helperText.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    helperText,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.redAccent,
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: Text(cancelLabel),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primaryColor,
                          foregroundColor: Colors.white,
                        ),
                        onPressed: () => Navigator.pop(context, true),
                        child: Text(confirmLabel),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final stream = _userStream();
    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      appBar: _buildAppBar(),
      body: Column(
        children: [
          Expanded(
            child: stream == null
                ? _emptyState(
                    context,
                    title: "Not signed in",
                    subtitle:
                        "Please sign in to see and edit your profile details.",
                  )
                : StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                    stream: stream,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting &&
                          snapshot.hasData == false) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      if (snapshot.hasError) {
                        return _emptyState(
                          context,
                          title: "Error loading profile",
                          subtitle: snapshot.error.toString(),
                          showRetry: true,
                        );
                      }
                      final data = snapshot.data?.data() ?? {};

                      // personal_info block
                      final pinfo = (data['personal_info'] is Map)
                          ? Map<String, dynamic>.from(
                              data['personal_info'] as Map)
                          : <String, dynamic>{};

                      // Fullname (first + last)
                      final first =
                          (pinfo['first_name'] ?? data['first_name'] ?? '')
                              .toString()
                              .trim();
                      final last =
                          (pinfo['last_name'] ?? data['last_name'] ?? '')
                              .toString()
                              .trim();
                      final fullName = [first, last]
                          .where((s) => s.isNotEmpty)
                          .join(' ')
                          .trim();
                      final displayName =
                          fullName.isNotEmpty ? fullName : "User";

                      // Age (optional)
                      final age = _intFromAny(pinfo['age']);

                      // Gender (icon + color)
                      final genderStr = _readGender(data, pinfo);
                      final genderIcon = _iconForGender(genderStr);
                      final genderColor = _colorForGender(genderStr);

                      // Bio
                      final bio =
                          (pinfo['bio'] ?? data['bio'] ?? '').toString();

                      // Profile image (top avatar only)
                      final imageUrl = (data['profile_image_url'] ??
                              data['profileImageUrl'] ??
                              data['profile_image_local_url'])
                          ?.toString();
                      final hasNetworkImage = imageUrl != null &&
                          imageUrl.isNotEmpty &&
                          imageUrl.startsWith('http');

                      // ---------- Photos (MERGED across all sources) ----------
                      final List<String> photosFromDoc = (() {
                        final sources = [
                          data['photos'],
                          pinfo['photos'],
                          data['gallery'],
                          pinfo['gallery'],
                          data['images'],
                          pinfo['images'],
                        ].whereType<List>();

                        final out = <String>[];
                        final seen = <String>{};
                        for (final src in sources) {
                          for (final e in src) {
                            final s = (e ?? '').toString();
                            if (!s.startsWith('http')) continue;
                            if (seen.add(s)) out.add(s);
                            if (out.length == 9) break;
                          }
                          if (out.length == 9) break;
                        }
                        return out;
                      })();

                      final List<String?> photoKeysFromDoc = (() {
                        final keys = (data['photos_keys'] is List)
                            ? List<String?>.from((data['photos_keys'] as List)
                                .map((e) => e == null ? null : e.toString()))
                            : <String?>[];
                        return keys;
                      })();

                      // Merge stream data and local optimistic state (no flicker)
                      final merged = _mergeGallery(
                        photosFromDoc,
                        photoKeysFromDoc,
                        _localUrls,
                        _localKeys,
                      );
                      final photos = merged.urls;
                      final photoKeys = merged.keys;

                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        _prefetchImages(context, photos.take(9).toList());
                        if (hasNetworkImage) {
                          _prefetchImages(context, [imageUrl!]);
                        }
                      });

                      // ---------- read + normalize tags ----------
                      final rawAttachment = (data['attachment_style'] ??
                                  pinfo['attachment_style'])
                              ?.toString() ??
                          '';
                      final rawLovePrimary =
                          (data['love_primary'] ?? pinfo['love_primary'])
                                  ?.toString() ??
                              '';
                      final rawLoveSecondary =
                          (data['love_secondary'] ?? pinfo['love_secondary'])
                                  ?.toString() ??
                              '';

                      final attachment =
                          _formatAttachmentLabel(rawAttachment.trim());
                      final loveLangPrimary =
                          _formatLoveLabel(rawLovePrimary.trim());
                      final loveLangSecondary =
                          _formatLoveLabel(rawLoveSecondary.trim());

                      // ---------- Interests (MERGED across all sources) ----------
                      final List<String> interests = (() {
                        final sources = [
                          data['interests'],
                          pinfo['interests'],
                          data['tags'],
                          pinfo['tags'],
                          data['hobbies'],
                          pinfo['hobbies'],
                        ].whereType<List>();

                        final out = <String>[];
                        final seen = <String>{}; // case-insensitive dedupe
                        for (final src in sources) {
                          for (final item in src) {
                            final s = (item ?? '').toString().trim();
                            if (s.isEmpty) continue;
                            if (seen.add(s.toLowerCase())) out.add(s);
                          }
                        }
                        return out;
                      })();

                      // FIX: clamp num→int
                      final remainingSlots =
                          (9 - photos.length).clamp(0, 9).toInt();

                      return SingleChildScrollView(
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              // Profile picture (uses cache) — tappable to view full screen (read-only)
                              GestureDetector(
                                onTap: hasNetworkImage
                                    ? () => _openViewerReadOnly(imageUrl!)
                                    : null,
                                child: Container(
                                  width: 120,
                                  height: 120,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: AppColors.primaryColor,
                                      width: 3,
                                    ),
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(60),
                                    child: hasNetworkImage
                                        ? CachedNetworkImage(
                                            imageUrl: imageUrl!,
                                            cacheManager: kImageCacheManager,
                                            fit: BoxFit.cover,
                                            useOldImageOnUrlChange: true,
                                            fadeInDuration: Duration.zero,
                                            placeholderFadeInDuration:
                                                Duration.zero,
                                            fadeOutDuration: Duration.zero,
                                            placeholder: (_, __) =>
                                                const SizedBox.shrink(),
                                            errorWidget: (_, __, ___) =>
                                                Image.asset(
                                              'assets/default_pfp.png',
                                              fit: BoxFit.cover,
                                            ),
                                          )
                                        : Image.asset(
                                            'assets/default_pfp.png',
                                            fit: BoxFit.cover,
                                          ),
                                  ),
                                ),
                              ),

                              const SizedBox(height: 16),

                              // Name + age + gender icon (tight, inline)
                              _NameAgeWithGender(
                                name: displayName,
                                age: age,
                                genderIcon: genderIcon,
                                genderColor: genderColor,
                              ),

                              const SizedBox(height: 16),

                              // Edit profile button
                              GestureDetector(
                                onTap: () => _navigateToEditProfile(context),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 24, vertical: 8),
                                  decoration: BoxDecoration(
                                    border:
                                        Border.all(color: Colors.grey.shade400),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: const Text(
                                    "Edit Profile",
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 24),

                              // About me section
                              Container(
                                width: double.infinity,
                                alignment: Alignment.centerLeft,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      "About Me",
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      bio.isNotEmpty
                                          ? bio
                                          : "Tell people about yourself. Edit your profile to add a short bio.",
                                      style: const TextStyle(
                                        fontSize: 14,
                                        height: 1.5,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 24),

                              // ---------- Attachment Style ----------
                              if (attachment.isNotEmpty) ...[
                                Container(
                                  width: double.infinity,
                                  alignment: Alignment.centerLeft,
                                  child: const Text(
                                    "Attachment Style",
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      _buildTag(
                                        attachment,
                                        _attachmentPastel(attachment),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 24),
                              ],

                              // ---------- Love Languages ----------
                              if (loveLangPrimary.isNotEmpty ||
                                  loveLangSecondary.isNotEmpty) ...[
                                Container(
                                  width: double.infinity,
                                  alignment: Alignment.centerLeft,
                                  child: const Text(
                                    "Love Languages",
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      if (loveLangPrimary.isNotEmpty)
                                        _buildTag(
                                          loveLangPrimary,
                                          _lovePastel(loveLangPrimary),
                                        ),
                                      if (loveLangSecondary.isNotEmpty)
                                        _buildTag(
                                          loveLangSecondary,
                                          _lovePastel(loveLangSecondary),
                                        ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 24),
                              ],

                              // ---------- Interests ----------
                              if (interests.isNotEmpty) ...[
                                Container(
                                  width: double.infinity,
                                  alignment: Alignment.centerLeft,
                                  child: const Text(
                                    "Interests",
                                    style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      for (final it in interests)
                                        (() {
                                          final display = _titleize(it);
                                          final cat = categoryForInterest(
                                              it); // ← normalized
                                          final fill = interestColorForLabel(
                                              it); // ← normalized color

                                          if (cat == null) {
                                            // Unknown label → fallback pastel
                                            return _buildTag(
                                              display,
                                              AppColors.lightPink,
                                              textColor: onPastelText(
                                                  AppColors.lightPink),
                                              borderColor:
                                                  AppColors.primaryColor,
                                            );
                                          }

// Known category → use your category palette
                                          final border =
                                              interestBorderColor(cat);
                                          return _buildTag(display, fill,
                                              textColor: Colors.black,
                                              borderColor: border);
                                        })(),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 24),
                              ],

                              // Photos header with actions
                              Container(
                                width: double.infinity,
                                alignment: Alignment.centerLeft,
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    const Text(
                                      "Photos",
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    Row(
                                      children: [
                                        // Reorder button
                                        TextButton.icon(
                                          onPressed: photos.isEmpty
                                              ? null
                                              : () => _openReorderSheet(
                                                    urls: photos,
                                                    keys: photoKeys,
                                                  ),
                                          style: TextButton.styleFrom(
                                            foregroundColor:
                                                AppColors.primaryColor,
                                          ),
                                          icon: const Icon(Icons.reorder),
                                          label: const Text("Reorder"),
                                        ),
                                        const SizedBox(width: 4),
                                        // Add button
                                        GestureDetector(
                                          onTap: () => _pickAndUploadPhotos(
                                              maxToPick: remainingSlots == 0
                                                  ? 0
                                                  : remainingSlots),
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 12, vertical: 6),
                                            decoration: BoxDecoration(
                                              color: AppColors.primaryColor
                                                  .withOpacity(0.1),
                                              borderRadius:
                                                  BorderRadius.circular(20),
                                              border: Border.all(
                                                color: AppColors.primaryColor,
                                                width: 1,
                                              ),
                                            ),
                                            child: Row(
                                              children: [
                                                if (_uploading)
                                                  const SizedBox(
                                                    width: 16,
                                                    height: 16,
                                                    child:
                                                        CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                    ),
                                                  )
                                                else
                                                  Icon(
                                                    Icons.add_photo_alternate,
                                                    color:
                                                        AppColors.primaryColor,
                                                    size: 16,
                                                  ),
                                                const SizedBox(width: 6),
                                                Text(
                                                  _uploading
                                                      ? "Uploading..."
                                                      : (remainingSlots == 0
                                                          ? "Full (9/9)"
                                                          : "Add"),
                                                  style: TextStyle(
                                                    color:
                                                        AppColors.primaryColor,
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w500,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 8),

                              // Photos area — no placeholders if empty, and no grid key churn (prevents flicker)
                              if (photos.isEmpty)
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 28, horizontal: 16),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    border:
                                        Border.all(color: Colors.grey.shade200),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Column(
                                    children: [
                                      Icon(Icons.photo_library_outlined,
                                          size: 36,
                                          color: Colors.grey.shade500),
                                      const SizedBox(height: 8),
                                      Text(
                                        "No photos yet",
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          color: Colors.grey.shade800,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        "Tap Add to upload up to 9 photos",
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey.shade600,
                                        ),
                                      ),
                                    ],
                                  ),
                                )
                              else
                                GridView.builder(
                                  // NOTE: no ValueKey dependent on count -> avoids whole-grid rebuild flicker
                                  itemCount: photos.length.clamp(0, 9),
                                  gridDelegate:
                                      const SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: 3,
                                    crossAxisSpacing: 8,
                                    mainAxisSpacing: 8,
                                  ),
                                  shrinkWrap: true,
                                  physics: const NeverScrollableScrollPhysics(),
                                  itemBuilder: (context, index) {
                                    final url = photos[index];
                                    final key = index < photoKeys.length
                                        ? photoKeys[index]
                                        : null;

                                    final bool animatePopIn =
                                        _recentlyAdded.contains(url);

                                    return _AnimatedPhotoTile(
                                      url: url,
                                      storageKey: key,
                                      cacheManager: kImageCacheManager,
                                      onTap: () => _openViewer(url, key: key),
                                      onDeleteRequested: () async {
                                        final confirm =
                                            await _confirmBottomSheet(
                                          title: "Remove this photo?",
                                          message:
                                              "It will be removed from your profile gallery.",
                                          confirmLabel: "Remove",
                                        );
                                        if (confirm == true) {
                                          await _deletePhoto(url,
                                              storageKey: key);
                                        }
                                      },
                                      popIn: animatePopIn,
                                    );
                                  },
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      bottomNavigationBar: _buildBottomNavBar(context),
    );
  }

  // Reusable empty/error state
  Widget _emptyState(BuildContext context,
      {required String title,
      required String subtitle,
      bool showRetry = false}) {
    return Column(
      children: [
        const SizedBox(height: 32),
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.person_outline,
                      size: 80, color: Colors.grey.shade400),
                  const SizedBox(height: 16),
                  Text(title,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text(
                    subtitle,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 14, color: Colors.grey),
                  ),
                  if (showRetry) ...[
                    const SizedBox(height: 16),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primaryColor),
                      onPressed: () => setState(() {}),
                      child: const Text("Retry"),
                    ),
                  ]
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // Messages-style AppBar (copied & adapted)
  AppBar _buildAppBar() {
    return AppBar(
      automaticallyImplyLeading: false,
      backgroundColor: Colors.white,
      foregroundColor: Colors.black,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      systemOverlayStyle: const SystemUiOverlayStyle(
        statusBarColor: Colors.white,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
      ),
      elevation: 4,
      shadowColor: Colors.black.withOpacity(0.1),
      titleSpacing: 0,
      title: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // Left-aligned title
            Row(
              children: [
                Text(
                  "AttachMates",
                  style: GoogleFonts.indieFlower(
                    textStyle: TextStyle(
                      color: AppColors.primaryColor,
                      fontSize: 26,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  "Profile",
                  style: TextStyle(
                    color: Colors.grey.shade600,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
            // Right-aligned icons
            Row(
              children: [
                // 🔔 Notifications with numeric badge + 99+ cap (unified)
                StreamBuilder<int>(
                  stream: _unreadStream,
                  builder: (context, snapshot) {
                    final count = (snapshot.data ?? 0);
                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        IconButton(
                          onPressed: _navigateToNotifications,
                          icon: Icon(Icons.notifications_none,
                              color: AppColors.primaryColor),
                          tooltip: 'Notifications',
                        ),
                        if (count > 0)
                          Positioned(
                            right: 6,
                            top: 6,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.redAccent,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              constraints: const BoxConstraints(minWidth: 20),
                              child: Text(
                                count > 99 ? '99+' : '$count',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
                IconButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      PageRouteBuilder(
                        pageBuilder: (context, a, b) => const SettingsScreen(),
                        transitionsBuilder: (context, a, b, child) {
                          const begin = Offset(1.0, 0.0);
                          const end = Offset.zero;
                          const curve = Curves.easeInOut;
                          var tween = Tween(begin: begin, end: end)
                              .chain(CurveTween(curve: curve));
                          return SlideTransition(
                              position: a.drive(tween), child: child);
                        },
                        transitionDuration: const Duration(milliseconds: 300),
                      ),
                    );
                  },
                  icon: Icon(Icons.settings, color: AppColors.primaryColor),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ---------- pastel tag chip with ripple ----------
  Widget _buildTag(String text, Color bg,
      {Color? textColor, Color? borderColor}) {
    final Color _text = textColor ?? AppColors.black; // readable on pastel
    final Color _border = borderColor ?? darkenPastel(bg);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {},
        borderRadius: BorderRadius.circular(20),
        splashColor: Colors.black12,
        highlightColor: Colors.black.withOpacity(0.06),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
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
        ),
      ),
    );
  }

  // Unified BottomNavigationBar (same as other screens)
  Widget _buildBottomNavBar(BuildContext context) {
    return SafeArea(
      top: false,
      child: BottomNavigationBar(
        currentIndex: 3, // Profile tab active
        backgroundColor: Colors.white,
        elevation: 0,
        type: BottomNavigationBarType.fixed,
        selectedItemColor: AppColors.primaryColor,
        unselectedItemColor: Colors.grey,
        onTap: (i) {
          if (i == 0) _navigateToDiscover(context);
          if (i == 1) _navigateToMatches(context);
          if (i == 2) _navigateToMessages(context);
          // i == 3 -> already on Profile
        },
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.search), label: "Discover"),
          BottomNavigationBarItem(
              icon: Icon(Icons.favorite_border), label: "Matches"),
          BottomNavigationBarItem(
              icon: Icon(Icons.chat_bubble_outline), label: "Messages"),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: "Profile"),
        ],
      ),
    );
  }

  // Small util
  int? _intFromAny(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is String) return int.tryParse(v);
    return null;
  }

  String _guessMime(String path) {
    final ext = p.extension(path).toLowerCase();
    if (ext == '.png') return 'image/png';
    if (ext == '.webp') return 'image/webp';
    if (ext == '.heic' || ext == '.heif') return 'image/heic';
    return 'image/jpeg';
  }

  // Snackbar helper (green success, red fail)
  void _snack(String msg, {required bool success}) {
    final bg = success ? const Color(0xFF2E7D32) : const Color(0xFFC62828);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: bg,
        behavior: SnackBarBehavior.fixed, // full width
        content: Text(
          msg,
          style: const TextStyle(color: Colors.white),
        ),
      ),
    );
  }
}

// Helper: merged gallery result
class _MergedGalleryResult {
  final List<String> urls;
  final List<String?> keys;
  _MergedGalleryResult(this.urls, this.keys);
}

// ========= Small inline name/age/gender widget =========
class _NameAgeWithGender extends StatelessWidget {
  final String name;
  final int? age;
  final IconData? genderIcon;
  final Color genderColor;

  const _NameAgeWithGender({
    required this.name,
    required this.age,
    required this.genderIcon,
    required this.genderColor,
  });

  @override
  Widget build(BuildContext context) {
    final baseStyle = const TextStyle(
      fontSize: 22,
      fontWeight: FontWeight.bold,
      height: 1.1,
    );

    final text = (age != null) ? "$name, $age" : name;

    return RichText(
      text: TextSpan(
        style: baseStyle.copyWith(color: Colors.black),
        children: [
          TextSpan(text: text),
          if (genderIcon != null)
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Icon(
                  genderIcon,
                  size: 18,
                  color: genderColor,
                ),
              ),
            ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

// ========= Animated grid tile for photos (no flicker for existing tiles) =========
class _AnimatedPhotoTile extends StatelessWidget {
  final String url;
  final String? storageKey;
  final CacheManager cacheManager;
  final VoidCallback onTap;
  final Future<void> Function() onDeleteRequested;
  final bool popIn;

  const _AnimatedPhotoTile({
    required this.url,
    required this.storageKey,
    required this.cacheManager,
    required this.onTap,
    required this.onDeleteRequested,
    this.popIn = false,
  });

  @override
  Widget build(BuildContext context) {
    // For existing tiles (popIn == false), return a stable, non-animating child to avoid flicker.
    final child = GestureDetector(
      onTap: onTap,
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: CachedNetworkImage(
                imageUrl: url,
                cacheManager: cacheManager,
                fit: BoxFit.cover,
                // ---- anti-flicker settings ----
                useOldImageOnUrlChange: true,
                fadeInDuration:
                    popIn ? const Duration(milliseconds: 100) : Duration.zero,
                placeholderFadeInDuration: Duration.zero,
                fadeOutDuration: Duration.zero,
                placeholder: (_, __) => const SizedBox.shrink(),
                errorWidget: (_, __, ___) => Container(
                  color: Colors.grey.shade300,
                  alignment: Alignment.center,
                  child: const Icon(Icons.broken_image),
                ),
              ),
            ),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: Material(
              color: Colors.black45,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: onDeleteRequested,
                child: const Padding(
                  padding: EdgeInsets.all(4.0),
                  child: Icon(Icons.close, size: 16, color: Colors.white),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    if (!popIn) {
      // No animation at all for existing images → prevents micro-flicker.
      return child;
    }

    // New tiles: gentle scale-in only (no opacity crossfade to avoid shimmer/flicker)
    return TweenAnimationBuilder<double>(
      key: ValueKey(url),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      tween: Tween<double>(begin: 0.92, end: 1.0),
      builder: (context, scale, _) =>
          Transform.scale(scale: scale, child: child),
    );
  }
}
