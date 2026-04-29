import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import '../../utils/image_url_cache.dart';

class ChatImageItem {
  final String messageId;
  final String? directUrl;
  final String? storagePath;
  const ChatImageItem({
    required this.messageId,
    this.directUrl,
    this.storagePath,
  });
}

class ImageViewerScreen extends StatefulWidget {
  final List<ChatImageItem> items;
  final int initialIndex;

  const ImageViewerScreen({
    super.key,
    required this.items,
    this.initialIndex = 0,
  });

  @override
  State<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends State<ImageViewerScreen> {
  late final PageController _controller =
      PageController(initialPage: widget.initialIndex);

  Future<String> _resolveUrl(ChatImageItem item) async {
    if (item.directUrl != null && item.directUrl!.isNotEmpty) {
      return item.directUrl!;
    }
    if (item.storagePath != null && item.storagePath!.isNotEmpty) {
      return ImageUrlCache.signedUrl(bucket: 'chats', path: item.storagePath!);
    }
    throw Exception('No image URL available');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Close',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: PhotoViewGallery.builder(
        pageController: _controller,
        itemCount: widget.items.length,
        builder: (ctx, index) {
          final item = widget.items[index];
          return PhotoViewGalleryPageOptions.customChild(
            child: FutureBuilder<String>(
              future: _resolveUrl(item),
              builder: (ctx, snap) {
                if (!snap.hasData) {
                  return const Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  );
                }
                // NO Hero here
                return Image.network(
                  snap.data!,
                  fit: BoxFit.contain,
                );
              },
            ),
            // NO heroAttributes here
            minScale: PhotoViewComputedScale.contained,
            maxScale: PhotoViewComputedScale.covered * 3.0,
          );
        },
        backgroundDecoration: const BoxDecoration(color: Colors.black),
        loadingBuilder: (_, __) =>
            const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      ),
    );
  }
}
