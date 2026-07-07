import 'dart:collection';
import 'dart:typed_data';

// Shared LRU-eviction core behind both media byte caches below. Keyed by
// Message.stableMediaKey rather than the technical source (local file path
// vs. uploaded URL) a widget happens to be reading from at a given moment,
// so the same logical message's already-decoded bytes survive that source
// swap instead of being dropped and regenerated (which previously showed a
// brief loading spinner/placeholder on an already-delivered message).
class _LruByteCache {
  _LruByteCache(this._maxEntries);

  final int _maxEntries;

  // Insertion/access order doubles as LRU order: get() re-inserts the hit
  // key at the end, put() evicts from the front once over the cap.
  final LinkedHashMap<String, Uint8List> _cache = LinkedHashMap();

  Uint8List? get(String key) {
    final value = _cache.remove(key);
    if (value == null) return null;
    _cache[key] = value;
    return value;
  }

  void put(String key, Uint8List bytes) {
    _cache.remove(key);
    _cache[key] = bytes;
    while (_cache.length > _maxEntries) {
      _cache.remove(_cache.keys.first);
    }
  }

  void evict(String key) {
    _cache.remove(key);
  }
}

// Generated video-thumbnail JPEGs (maxWidth 400, quality 60) — a few tens
// of KB each, used by VideoThumbnailImage (see video_message_widgets.dart).
// This cap keeps total memory in the low single-digit MB range even for a
// very actively scrolled chat.
class MediaThumbnailCacheManager {
  MediaThumbnailCacheManager._();
  static final MediaThumbnailCacheManager instance =
      MediaThumbnailCacheManager._();

  final _cache = _LruByteCache(60);

  Uint8List? get(String key) => _cache.get(key);
  void put(String key, Uint8List bytes) => _cache.put(key, bytes);
  void evict(String key) => _cache.evict(key);
}

// Full picked-photo bytes (already downsized to maxWidth 1200 / quality 70
// by image_picker, but still much larger per-entry than a video thumbnail —
// up to a few hundred KB) — used by ImageMessageBubble to feed
// CachedNetworkImage a seamless placeholder the moment a just-sent photo's
// local file swaps to its uploaded URL, instead of CachedNetworkImage's own
// spinner while it fetches a URL nothing has cached yet. Kept as a separate
// instance from MediaThumbnailCacheManager (same underlying LRU shape, but
// deliberately not sharing one cache/cap) so a handful of large photos
// can't prematurely evict a chat's worth of tiny video thumbnails, or vice
// versa.
class ImagePreviewCacheManager {
  ImagePreviewCacheManager._();
  static final ImagePreviewCacheManager instance =
      ImagePreviewCacheManager._();

  final _cache = _LruByteCache(20);

  Uint8List? get(String key) => _cache.get(key);
  void put(String key, Uint8List bytes) => _cache.put(key, bytes);
  void evict(String key) => _cache.evict(key);
}
