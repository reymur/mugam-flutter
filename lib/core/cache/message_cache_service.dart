import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../firebase/models.dart';

// Local, database-independent cache of the last N messages per chat, used
// only to paint something before the live Firestore stream delivers its
// first snapshot (or while offline). It never overrides live data — once
// the stream responds, its data always wins. The on-disk JSON format only
// ever stores plain types (millis ints, strings, maps), so this survives a
// future backend swap unchanged.
class MessageCacheService {
  MessageCacheService(this._prefs);

  final SharedPreferences _prefs;

  static const int maxMessagesPerChat = 50;
  static const int maxCachedChats = 30;
  static const String _keyPrefix = 'mugam_msg_cache_v1_';
  static const String _indexKey = 'mugam_msg_cache_index_v1';

  final Map<String, Timer> _debounceTimers = {};
  static const _debounceDuration = Duration(milliseconds: 500);

  List<Message>? read(String chatId) {
    final raw = _tryRead(_keyPrefix + chatId);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw) as List;
      return decoded
          .map((e) => _messageFromCacheJson(e as Map<String, dynamic>))
          .toList();
    } catch (e, st) {
      debugPrint('MessageCacheService: corrupted cache for $chatId, clearing ($e)');
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'MessageCacheService: corrupted cache for $chatId',
      );
      _tryRemove(_keyPrefix + chatId);
      _removeFromIndex(chatId);
      return null;
    }
  }

  // Debounced: rapid-fire snapshot updates (reactions, delivery receipts)
  // collapse into a single write per quiet period instead of hitting disk
  // on every event.
  void writeDebounced(String chatId, List<Message> messages) {
    _debounceTimers[chatId]?.cancel();
    _debounceTimers[chatId] = Timer(_debounceDuration, () {
      _debounceTimers.remove(chatId);
      _write(chatId, messages);
    });
  }

  // Bypasses the debounce so the very last update isn't lost if the screen
  // is disposed mid-debounce.
  void flush(String chatId, List<Message> messages) {
    _debounceTimers.remove(chatId)?.cancel();
    _write(chatId, messages);
  }

  Future<void> evict(String chatId) async {
    _debounceTimers.remove(chatId)?.cancel();
    await _tryRemove(_keyPrefix + chatId);
    await _removeFromIndex(chatId);
  }

  Future<void> clearAll() async {
    for (final timer in _debounceTimers.values) {
      timer.cancel();
    }
    _debounceTimers.clear();
    final index = _readIndex();
    for (final chatId in index.keys) {
      await _tryRemove(_keyPrefix + chatId);
    }
    await _tryRemove(_indexKey);
  }

  void _write(String chatId, List<Message> messages) {
    final trimmed = messages.length > maxMessagesPerChat
        ? messages.sublist(messages.length - maxMessagesPerChat)
        : messages;
    try {
      final encoded = jsonEncode(trimmed.map(_messageToCacheJson).toList());
      _prefs.setString(_keyPrefix + chatId, encoded);
      _touchIndex(chatId);
    } catch (e, st) {
      debugPrint('MessageCacheService: failed to write cache for $chatId ($e)');
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'MessageCacheService: failed to write cache for $chatId',
      );
    }
  }

  Map<String, int> _readIndex() {
    final raw = _tryRead(_indexKey);
    if (raw == null) return {};
    try {
      return Map<String, int>.from(jsonDecode(raw) as Map);
    } catch (e, st) {
      debugPrint('MessageCacheService: corrupted cache index, clearing ($e)');
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'MessageCacheService: corrupted cache index',
      );
      _tryRemove(_indexKey);
      return {};
    }
  }

  void _touchIndex(String chatId) {
    final index = _readIndex();
    index[chatId] = DateTime.now().millisecondsSinceEpoch;
    while (index.length > maxCachedChats) {
      final oldestChatId = index.entries
          .reduce((a, b) => a.value <= b.value ? a : b)
          .key;
      index.remove(oldestChatId);
      _tryRemove(_keyPrefix + oldestChatId);
    }
    try {
      _prefs.setString(_indexKey, jsonEncode(index));
    } catch (e, st) {
      debugPrint('MessageCacheService: failed to write cache index ($e)');
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'MessageCacheService: failed to write cache index',
      );
    }
  }

  Future<void> _removeFromIndex(String chatId) async {
    final index = _readIndex();
    if (index.remove(chatId) != null) {
      try {
        await _prefs.setString(_indexKey, jsonEncode(index));
      } catch (e, st) {
        debugPrint('MessageCacheService: failed to update cache index ($e)');
        FirebaseCrashlytics.instance.recordError(
          e,
          st,
          reason: 'MessageCacheService: failed to update cache index',
        );
      }
    }
  }

  String? _tryRead(String key) {
    try {
      return _prefs.getString(key);
    } catch (e, st) {
      debugPrint('MessageCacheService: failed to read "$key" ($e)');
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'MessageCacheService: failed to read "$key"',
      );
      return null;
    }
  }

  Future<void> _tryRemove(String key) async {
    try {
      await _prefs.remove(key);
    } catch (e, st) {
      debugPrint('MessageCacheService: failed to remove "$key" ($e)');
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'MessageCacheService: failed to remove "$key"',
      );
    }
  }

  Map<String, dynamic> _messageToCacheJson(Message m) => {
    'id': m.id,
    'senderId': m.senderId,
    'text': m.text,
    'imageURL': m.imageURL,
    'audioURL': m.audioURL,
    'videoURL': m.videoURL,
    'videoDurationMs': m.videoDurationMs,
    'videoWidth': m.videoWidth,
    'videoHeight': m.videoHeight,
    'imageWidth': m.imageWidth,
    'imageHeight': m.imageHeight,
    'mediaOriginChatId': m.mediaOriginChatId,
    'mediaFileName': m.mediaFileName,
    'fileURL': m.fileURL,
    'fileName': m.fileName,
    'fileSizeBytes': m.fileSizeBytes,
    'locationImageURL': m.locationImageURL,
    'latitude': m.latitude,
    'longitude': m.longitude,
    'waveform': m.waveform,
    'listenedBy': m.listenedBy,
    'timestampMillis': m.timestamp?.millisecondsSinceEpoch,
    'type': m.type,
    'replyToId': m.replyToId,
    'replyToText': m.replyToText,
    'replyToSenderName': m.replyToSenderName,
    'replyToImageURL': m.replyToImageURL,
    'replyToVideoURL': m.replyToVideoURL,
    'deletedForAll': m.deletedForAll,
    'deletedFor': m.deletedFor,
    'deletedAt': m.deletedAt,
    'reactions': m.reactions,
  };

  Message _messageFromCacheJson(Map<String, dynamic> json) => Message(
    id: json['id'] as String,
    senderId: json['senderId'] as String,
    text: json['text'] as String,
    imageURL: json['imageURL'] as String?,
    audioURL: json['audioURL'] as String?,
    videoURL: json['videoURL'] as String?,
    videoDurationMs: json['videoDurationMs'] as int?,
    videoWidth: json['videoWidth'] as int?,
    videoHeight: json['videoHeight'] as int?,
    imageWidth: json['imageWidth'] as int?,
    imageHeight: json['imageHeight'] as int?,
    mediaOriginChatId: json['mediaOriginChatId'] as String?,
    mediaFileName: json['mediaFileName'] as String?,
    fileURL: json['fileURL'] as String?,
    fileName: json['fileName'] as String?,
    fileSizeBytes: json['fileSizeBytes'] as int?,
    locationImageURL: json['locationImageURL'] as String?,
    latitude: (json['latitude'] as num?)?.toDouble(),
    longitude: (json['longitude'] as num?)?.toDouble(),
    waveform: (json['waveform'] as List?)?.cast<int>(),
    listenedBy: List<String>.from(json['listenedBy'] as List? ?? const []),
    timestamp: json['timestampMillis'] != null
        ? Timestamp.fromMillisecondsSinceEpoch(json['timestampMillis'] as int)
        : null,
    type: json['type'] as String,
    replyToId: json['replyToId'] as String?,
    replyToText: json['replyToText'] as String?,
    replyToSenderName: json['replyToSenderName'] as String?,
    replyToImageURL: json['replyToImageURL'] as String?,
    replyToVideoURL: json['replyToVideoURL'] as String?,
    deletedForAll: json['deletedForAll'] as bool? ?? false,
    deletedFor: List<String>.from(json['deletedFor'] as List? ?? const []),
    deletedAt: json['deletedAt'] as String?,
    reactions: {
      for (final entry in (json['reactions'] as Map<String, dynamic>? ?? const {}).entries)
        entry.key: List<String>.from(entry.value as List? ?? const []),
    },
  );
}

final messageCacheServiceProvider = Provider<MessageCacheService>((ref) {
  throw UnimplementedError(
    'messageCacheServiceProvider must be overridden with a SharedPreferences instance at app startup',
  );
});

final cachedMessagesProvider = Provider.autoDispose.family<List<Message>?, String>(
  (ref, chatId) {
    return ref.watch(messageCacheServiceProvider).read(chatId);
  },
);
