import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../firebase/models.dart';
import '../queue/pending_file_storage.dart';

// The single local source of truth for chat messages — replaces the old
// MessageCacheService (a passive, non-authoritative cold-start fallback)
// and the pending-send queue's own separate JSON blob
// (PendingMessageQueueService/PendingMediaMessage). See the 2026-07-31
// session notes for why: reconciling two independently-timed sources (a
// synthetic pending object merged with a live Firestore listener at render
// time) caused a real, confirmed bug class — messages briefly vanishing,
// bubbles visibly jumping — whenever the two sources' timing didn't line
// up. This store fixes the CLASS of bug, not just the symptom: exactly one
// row per message, keyed by messageId end to end (the same id generated
// client-side before the first send attempt — see
// FirestoreService.generateMessageId), updated in place as it moves
// through queued -> uploading -> confirmed. The UI never reconciles two
// different objects representing the same logical message.
//
// Every row is either SYNCED (came from Firestore: text, media, replies,
// reactions, deletion state, seq, timestamp, isSystem, forwardCount) or
// LOCAL (owned only by the send/retry path on this device: localSendStatus,
// localFilePath, localUploadProgress, localPreviewBytes, attemptCount,
// uploadedUrl, videoHd) — see Message.withConfirmedSeq/withLocalStatus/
// reconciledWithFirestore, the only three sanctioned ways a row changes,
// each explicit about which group it touches so it's structurally
// impossible for one to accidentally clobber the other.
//
// Two-tier persistence, matching (and literally reusing the on-disk key
// format of) the two services this class replaces — nothing to migrate:
//  - Confirmed history, per chat, lazily loaded only once that chat is
//    actually opened (same SharedPreferences key MessageCacheService used).
//  - Pending sends (localSendStatus != null), ALL chats in one small blob,
//    loaded eagerly by init() — same key PendingMessageQueueService used —
//    because the retry loop needs to find every in-flight send across the
//    whole app without opening every chat's full history first.
//
// A plain Dart class, no Riverpod dependency in the core logic — the
// WorkManager/BGTaskScheduler background isolate (background_queue_processor.dart)
// has no ProviderScope and constructs one of these directly, same as it
// already does for FirestoreService/SharedPreferences today.
class LocalMessageStore {
  LocalMessageStore(this._prefs);

  final SharedPreferences _prefs;

  static const int maxMessagesPerChat = 200;
  static const int maxCachedChats = 30;
  static const String _historyKeyPrefix = 'mugam_msg_cache_v1_';
  static const String _historyIndexKey = 'mugam_msg_cache_index_v1';
  static const String _pendingKey = 'mugam_pending_queue_v1';
  // One small blob for ALL chats (chatId -> ISO string, or explicit null for
  // "known: this chat was never cleared") rather than a key per chat: it has
  // to be readable synchronously for every chat before the first frame (see
  // clearedAtFor below), and one map read beats N key lookups. Deliberately
  // NOT evicted alongside history — a cutoff is a few dozen bytes and is
  // still correct for a chat whose messages have been evicted, whereas
  // losing it is exactly the "history without a cutoff" state this whole
  // mechanism exists to prevent.
  static const String _clearedKey = 'mugam_msg_cleared_v1';
  static const _debounceDuration = Duration(milliseconds: 400);

  // chatId -> (messageId -> Message). Confirmed history merged with
  // whatever's pending for that chat — every read serves from this map.
  final Map<String, Map<String, Message>> _byChat = {};
  final Set<String> _historyLoaded = {};
  final List<String> _accessOrder = [];
  final Map<String, StreamController<List<Message>>> _controllers = {};
  final Map<String, Timer> _historyDebounce = {};
  Timer? _pendingDebounce;
  bool _pendingLoaded = false;
  // Lazily read once, then kept in memory — clearedAtFor is on the path to
  // the first frame of every chat open and must never do disk work there.
  Map<String, dynamic>? _clearedCache;

  // Must be awaited once at app startup (see main.dart), before anything
  // reads/writes a pending send — hydrates every in-flight send across
  // every chat so the retry loop can find them immediately, same as
  // PendingMessageQueueController.build() reading the whole queue once
  // today.
  Future<void> init() async {
    if (_pendingLoaded) return;
    _pendingLoaded = true;
    for (final message in _readPending()) {
      final chatId = message.chatId;
      if (chatId == null) continue;
      _byChat.putIfAbsent(chatId, () => {})[message.id] = message;
    }
  }

  // Sign-out: wipes EVERY piece of account-scoped local state this class
  // owns — confirmed-history caches, the pending-send blob, and the durable
  // upload files that blob references — so the next account signed in on
  // this device inherits nothing from the previous one.
  //
  // The pending blob used to be deliberately excluded here ("an in-flight
  // send surviving a logout is a pre-existing edge case"). That turned out
  // to be a real cross-account data leak, confirmed on-device 2026-08-01:
  // a device signed in as user A left a stuck 'uploading' row in the blob,
  // signed in as user B, and init() loaded A's row — carrying A's senderId
  // — straight into B's session. It surfaced as a phantom incoming bubble
  // in B's chat, and worse, B's client picked that row as "the newest
  // message from the other party" and wrote its client-generated id into
  // the shared chats/{chatId}.lastReadMsgId, which no other device could
  // resolve (the id has no server document), permanently breaking read
  // receipts in that direction. An in-flight send belongs to the account
  // that created it; carrying it across a sign-out can only ever be wrong,
  // and the rules would reject it anyway (senderId must equal auth.uid).
  Future<void> clearAllForSignOut() async {
    for (final timer in _historyDebounce.values) {
      timer.cancel();
    }
    _historyDebounce.clear();
    _pendingDebounce?.cancel();
    _pendingDebounce = null;
    final index = _readHistoryIndex();
    for (final chatId in index.keys) {
      await _prefs.remove(_historyKeyPrefix + chatId);
    }
    await _prefs.remove(_historyIndexKey);
    await _prefs.remove(_pendingKey);
    await _prefs.remove(_clearedKey);
    _clearedCache = null;
    _byChat.clear();
    _historyLoaded.clear();
    _accessOrder.clear();
    for (final controller in _controllers.values) {
      if (!controller.isClosed) controller.add(const []);
    }
    await deleteAllPendingFiles();
  }

  // Drops any pending row that doesn't belong to `uid`, plus any row whose
  // chat history it can't be reconciled against. Runs at startup once the
  // signed-in uid is known (see main.dart) as the second half of the
  // cross-account leak fix above: clearAllForSignOut covers every sign-out
  // that goes through the app's own Çıxış flow, and this covers every path
  // that doesn't — a session invalidated server-side, a token that expired
  // while the app was killed, a reinstall restoring a backup, or any future
  // sign-out call site that forgets to run the cleanup.
  //
  // A foreign-uid row is unsendable by definition: firestore.rules requires
  // a message's senderId to equal the writer's own uid, so retrying it can
  // only ever fail. Dropping it is strictly better than leaving it to
  // consume retry attempts and pollute the chat view.
  //
  // Returns how many rows were dropped, for the caller to log — silently
  // discarding user-visible content is exactly how this class of bug stays
  // invisible for weeks.
  Future<int> dropForeignPendingMessages(String uid) async {
    final foreign = <Message>[];
    for (final chatMessages in _byChat.values) {
      for (final m in chatMessages.values) {
        if (m.localSendStatus != null && m.senderId != uid) foreign.add(m);
      }
    }
    if (foreign.isEmpty) return 0;
    final touchedChats = <String>{};
    for (final m in foreign) {
      final chatId = m.chatId;
      if (chatId == null) continue;
      _byChat[chatId]?.remove(m.id);
      touchedChats.add(chatId);
      unawaited(deletePendingFile(m.localFilePath));
    }
    for (final chatId in touchedChats) {
      _emit(chatId);
    }
    await flushPending();
    return foreign.length;
  }

  // ---- Reading ----

  // The "Çatı təmizlə" cutoff for this chat, as last learned from Firestore.
  // SYNCHRONOUS by design: it lives in the same store, under the same
  // account-scoped lifetime, as the messages it filters, so a chat that has
  // any local history to render always has its cutoff available in the very
  // same turn — no await, no stream, nothing for the store's own disk read
  // to race against. That invariant is the whole fix for N1: the cutoff used
  // to arrive over the network (watchChatClearedAt) while the messages came
  // off local disk, so the disk always won and the first frame rendered the
  // pre-clear history before collapsing to empty.
  //
  // Three states, not two — this is what isClearedAtKnown separates:
  //   known, cleared at T  -> entry present, non-null
  //   known, never cleared -> entry present, null (written explicitly)
  //   not known yet        -> no entry at all
  // "Not known" is only reachable for a chat this account has never had open
  // on this device (so there is no local history to leak either) or, once,
  // for a chat whose history predates this mechanism shipping.
  DateTime? clearedAtFor(String chatId) {
    final raw = _readCleared()[chatId];
    if (raw is! String) return null;
    return DateTime.tryParse(raw);
  }

  bool isClearedAtKnown(String chatId) =>
      _readCleared().containsKey(chatId);

  // Records what watchChatClearedAt just reported, including a null (which
  // is a real, positive answer — "this chat has never been cleared" — and is
  // stored as such, see the three states above). Written straight through
  // rather than debounced: it's a single short string, and it is the thing
  // that decides whether the NEXT cold open of this chat can render its
  // history at all.
  Future<void> setClearedAt(String chatId, DateTime? value) async {
    final cleared = _readCleared();
    final encoded = value?.toIso8601String();
    if (cleared.containsKey(chatId) && cleared[chatId] == encoded) return;
    cleared[chatId] = encoded;
    try {
      await _prefs.setString(_clearedKey, jsonEncode(cleared));
    } catch (e, st) {
      debugPrint('LocalMessageStore: failed to write cleared blob ($e)');
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'LocalMessageStore: failed to write cleared blob',
      );
    }
  }

  Map<String, dynamic> _readCleared() {
    final cached = _clearedCache;
    if (cached != null) return cached;
    Map<String, dynamic> parsed;
    try {
      final raw = _prefs.getString(_clearedKey);
      parsed = raw == null
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (e, st) {
      // Corrupted blob: fall back to "nothing known", which degrades to the
      // network path for every chat rather than to a wrong cutoff.
      debugPrint('LocalMessageStore: corrupted cleared blob, clearing ($e)');
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'LocalMessageStore: corrupted cleared blob',
      );
      _prefs.remove(_clearedKey);
      parsed = <String, dynamic>{};
    }
    _clearedCache = parsed;
    return parsed;
  }

  // Ensures this chat's confirmed history is loaded, emits the current
  // snapshot immediately (async* generators replay the leading `yield` to
  // every new listener — this store never expects more than one live
  // listener per chat, since only one chat screen is ever open at a time),
  // then forwards every future mutation.
  Stream<List<Message>> watchChat(String chatId) async* {
    await _ensureHistoryLoaded(chatId);
    yield _sorted(chatId);
    yield* _controllerFor(chatId).stream;
  }

  // Every currently-pending send across every chat — what the global send
  // controller/retry loop iterates. Safe any time after init() (doesn't
  // need any individual chat's confirmed history loaded).
  List<Message> allPending() {
    final result = <Message>[];
    for (final chatMessages in _byChat.values) {
      for (final m in chatMessages.values) {
        if (m.localSendStatus != null) result.add(m);
      }
    }
    return result;
  }

  // ---- Mutating: send/retry path (LOCAL group) ----

  // Unlike every other mutation here, this flushes to disk immediately
  // rather than through the debounced write path — this is the ONLY
  // durable record that the user ever asked to send this message at all;
  // losing it to an app kill inside a 400ms debounce window (as the
  // old PendingMessageQueueController.enqueue's own synchronous
  // `_service.saveAll(state)` never did either) would silently drop a
  // queued send. Every later status transition (queued -> uploading ->
  // confirmed/failed) can safely debounce, since by then either the send
  // already succeeded (Firestore has it too) or it's just a retry-count
  // bump the next launch re-attempts anyway from this same durable copy.
  Future<void> insertPending(Message message) async {
    assert(message.chatId != null, 'insertPending requires Message.chatId');
    assert(
      message.localSendStatus != null,
      'insertPending requires a localSendStatus',
    );
    await _ensureHistoryLoaded(message.chatId!);
    await _put(message);
    await flushPending();
  }

  Future<void> updatePendingStatus({
    required String chatId,
    required String messageId,
    required String? status,
    int? attemptCount,
    String? uploadedUrl,
    String? localFilePath,
  }) async {
    final existing = _byChat[chatId]?[messageId];
    if (existing == null) return;
    await _put(
      existing.withLocalStatus(
        status: status,
        attemptCount: attemptCount,
        uploadedUrl: uploadedUrl,
        localFilePath: localFilePath,
      ),
    );
    _schedulePendingWrite();
  }

  // A pending send just got confirmed by FirestoreService._commitMessage —
  // update the SAME row in place (never delete+reinsert, that's the whole
  // point of this store) and move it out of the pending blob into this
  // chat's confirmed history.
  Future<void> markConfirmed({
    required String chatId,
    required String messageId,
    required int seq,
  }) async {
    final existing = _byChat[chatId]?[messageId];
    if (existing == null) return;
    await _put(existing.withConfirmedSeq(seq));
    // Same rationale as _upsertOne's own cleanup — whichever of the two
    // paths clears this row's pending state first is the one that owns
    // deleting its file (deletePendingFile is a no-op for an already-gone
    // path, so the other path running later is harmless).
    unawaited(deletePendingFile(existing.localFilePath));
    _schedulePendingWrite();
    _scheduleHistoryWrite(chatId);
  }

  // Manual delete of a queued/failed item ("Sil" in the pending-message
  // sheet) — the caller is responsible for cancelling any in-flight upload
  // task and deleting the local file first (see chat_screen.dart's
  // _cancelUploadCallback), this only removes the row itself.
  Future<void> removePending({
    required String chatId,
    required String messageId,
  }) async {
    final chatMessages = _byChat[chatId];
    if (chatMessages == null) return;
    if (chatMessages.remove(messageId) == null) return;
    _emit(chatId);
    _schedulePendingWrite();
  }

  // Deliberately does NOT schedule a disk write — see
  // Message.withUploadProgress's own doc comment for why. Purely updates
  // the in-memory row and notifies watchChat's live listeners (the WhatsApp-
  // style upload progress ring), same low cost as any other in-memory
  // Riverpod state change.
  void updateProgress({
    required String chatId,
    required String messageId,
    required double progress,
  }) {
    final existing = _byChat[chatId]?[messageId];
    if (existing == null) return;
    _byChat[chatId]![messageId] = existing.withUploadProgress(progress);
    _emit(chatId);
  }

  // ---- Mutating: Firestore live listener sync (SYNCED group) ----

  // `real` is a plain Message.fromFirestore result (chatId left unset by
  // that factory — see its own doc comment) for a doc the live tail/older
  // listener just delivered. If this chat already has a local row for the
  // same id (this device's own pending send, or just re-syncing an
  // already-confirmed row whose reactions/deletion-state changed), only the
  // synced fields move; any local-only fields on the existing row survive
  // untouched.
  Future<void> upsertFromFirestore({
    required String chatId,
    required Message real,
  }) async {
    await _ensureHistoryLoaded(chatId);
    final wasPending = _upsertOne(chatId, real);
    _emit(chatId);
    if (wasPending) _schedulePendingWrite();
    _scheduleHistoryWrite(chatId);
  }

  // Same as upsertFromFirestore, batched: one Firestore snapshot can carry
  // many docs at once (initial history load, or a burst of messages
  // arriving after reconnecting) — upserting each individually would emit
  // (and rebuild every watchChat listener) once per doc. This applies them
  // all to the in-memory map first and emits exactly once, so
  // ChatMessagesController's own added-id diff (see its doc comment) sees
  // one clean before/after pair instead of N rapid-fire intermediate
  // states.
  Future<void> upsertManyFromFirestore({
    required String chatId,
    required List<Message> reals,
  }) async {
    if (reals.isEmpty) return;
    await _ensureHistoryLoaded(chatId);
    var anyWasPending = false;
    for (final real in reals) {
      if (_upsertOne(chatId, real)) anyWasPending = true;
    }
    _emit(chatId);
    if (anyWasPending) _schedulePendingWrite();
    _scheduleHistoryWrite(chatId);
  }

  // Returns whether the existing row (if any) was pending — the two public
  // methods above use this to decide whether the pending blob needs
  // rewriting, without emitting/scheduling themselves (so the batch path
  // can do both exactly once, after every row in the batch is applied).
  bool _upsertOne(String chatId, Message real) {
    final existing = _byChat[chatId]?[real.id];
    final wasPending = existing?.localSendStatus != null;
    final merged = existing == null
        ? Message.fromFirestore(real.id, _reencode(real), chatId: chatId)
        : existing.reconciledWithFirestore(real);
    // This row just stopped being pending because the server confirmed it
    // (see Message.reconciledWithFirestore) — the durable copy of the
    // captured/recorded file the send path made (persistPendingFile) has
    // nothing left to retry from, so drop it rather than leaking it in the
    // app's documents directory forever. Only the foreground send path
    // needed this: processPendingQueueOnce already deletes the file on its
    // own success path, but MessageSendController._processChatQueue never
    // did, so every media message sent while the app was open left its
    // full-size copy behind permanently.
    if (wasPending && merged.localSendStatus == null) {
      unawaited(deletePendingFile(existing!.localFilePath));
    }
    final chatMessages = _byChat.putIfAbsent(chatId, () => {});
    chatMessages[merged.id] = merged;
    return wasPending;
  }

  // ---- Internals ----

  StreamController<List<Message>> _controllerFor(String chatId) =>
      _controllers.putIfAbsent(
        chatId,
        () => StreamController<List<Message>>.broadcast(),
      );

  Future<void> _ensureHistoryLoaded(String chatId) async {
    _touchAccess(chatId);
    if (_historyLoaded.contains(chatId)) return;
    _historyLoaded.add(chatId);
    final loaded = _readHistory(chatId);
    final chatMessages = _byChat.putIfAbsent(chatId, () => {});
    for (final m in loaded) {
      // A pending row for this id (already in memory from init()'s eager
      // pending-blob load) is always more current than confirmed history —
      // never let a stale disk read of history clobber it.
      chatMessages.putIfAbsent(m.id, () => m);
    }
  }

  void _touchAccess(String chatId) {
    _accessOrder.remove(chatId);
    _accessOrder.add(chatId);
    while (_accessOrder.length > maxCachedChats) {
      final evicted = _accessOrder.removeAt(0);
      // Never evict a chat with a still-pending send in flight — losing
      // track of it in memory would leave it stuck (the retry loop reads
      // allPending() straight from these in-memory maps).
      final hasPending =
          _byChat[evicted]?.values.any((m) => m.localSendStatus != null) ??
          false;
      if (hasPending) {
        _accessOrder.add(evicted);
        break;
      }
      _byChat.remove(evicted);
      _historyLoaded.remove(evicted);
      _controllers.remove(evicted)?.close();
    }
  }

  List<Message> _sorted(String chatId) {
    final all = _byChat[chatId]?.values.toList() ?? [];
    all.sort((a, b) {
      final aSeq = a.seq;
      final bSeq = b.seq;
      if (aSeq != null && bSeq != null) return aSeq.compareTo(bSeq);
      if (aSeq != null) return -1;
      if (bSeq != null) return 1;
      // Both still pending — order by local enqueue time (`timestamp`,
      // set once at insert and never touched again while pending).
      final aTime = a.timestamp?.millisecondsSinceEpoch ?? 0;
      final bTime = b.timestamp?.millisecondsSinceEpoch ?? 0;
      return aTime.compareTo(bTime);
    });
    return all;
  }

  Future<void> _put(Message message) async {
    final chatId = message.chatId;
    if (chatId == null) return;
    _byChat.putIfAbsent(chatId, () => {})[message.id] = message;
    _emit(chatId);
  }

  void _emit(String chatId) {
    final controller = _controllers[chatId];
    if (controller != null && !controller.isClosed) {
      controller.add(_sorted(chatId));
    }
  }

  void _schedulePendingWrite() {
    _pendingDebounce?.cancel();
    _pendingDebounce = Timer(_debounceDuration, _writePendingNow);
  }

  void _scheduleHistoryWrite(String chatId) {
    _historyDebounce[chatId]?.cancel();
    _historyDebounce[chatId] = Timer(_debounceDuration, () {
      _historyDebounce.remove(chatId);
      _writeHistoryNow(chatId);
    });
  }

  // Bypasses the debounce so the very last update isn't lost if the app is
  // backgrounded/killed mid-debounce (see main.dart's AppLifecycleState
  // wiring).
  Future<void> flushPending() async {
    _pendingDebounce?.cancel();
    _pendingDebounce = null;
    await _writePendingNow();
  }

  Future<void> _writePendingNow() async {
    try {
      final all = allPending();
      await _prefs.setString(
        _pendingKey,
        jsonEncode(all.map(_toJson).toList()),
      );
    } catch (e, st) {
      debugPrint('LocalMessageStore: failed to write pending blob ($e)');
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'LocalMessageStore: failed to write pending blob',
      );
    }
  }

  List<Message> _readPending() {
    try {
      final raw = _prefs.getString(_pendingKey);
      if (raw == null) return [];
      final decoded = jsonDecode(raw) as List;
      return decoded
          .map((e) => _fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e, st) {
      debugPrint('LocalMessageStore: corrupted pending blob, clearing ($e)');
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'LocalMessageStore: corrupted pending blob',
      );
      _prefs.remove(_pendingKey);
      return [];
    }
  }

  void _writeHistoryNow(String chatId) {
    final confirmed = (_byChat[chatId]?.values ?? const <Message>[])
        .where((m) => m.seq != null)
        .toList()
      ..sort((a, b) => a.seq!.compareTo(b.seq!));
    final trimmed = confirmed.length > maxMessagesPerChat
        ? confirmed.sublist(confirmed.length - maxMessagesPerChat)
        : confirmed;
    try {
      _prefs.setString(
        _historyKeyPrefix + chatId,
        jsonEncode(trimmed.map(_toJson).toList()),
      );
      _touchHistoryIndex(chatId);
    } catch (e, st) {
      debugPrint('LocalMessageStore: failed to write history for $chatId ($e)');
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'LocalMessageStore: failed to write history for $chatId',
      );
    }
  }

  List<Message> _readHistory(String chatId) {
    try {
      final raw = _prefs.getString(_historyKeyPrefix + chatId);
      if (raw == null) return [];
      final decoded = jsonDecode(raw) as List;
      return decoded
          .map((e) => _fromJson(e as Map<String, dynamic>, chatId: chatId))
          .toList();
    } catch (e, st) {
      debugPrint('LocalMessageStore: corrupted history for $chatId, clearing ($e)');
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'LocalMessageStore: corrupted history for $chatId',
      );
      _prefs.remove(_historyKeyPrefix + chatId);
      return [];
    }
  }

  void _touchHistoryIndex(String chatId) {
    final index = _readHistoryIndex();
    index[chatId] = DateTime.now().millisecondsSinceEpoch;
    while (index.length > maxCachedChats) {
      final oldest = index.entries.reduce((a, b) => a.value <= b.value ? a : b).key;
      index.remove(oldest);
      _prefs.remove(_historyKeyPrefix + oldest);
    }
    try {
      _prefs.setString(_historyIndexKey, jsonEncode(index));
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'LocalMessageStore: failed to write history index',
      );
    }
  }

  Map<String, int> _readHistoryIndex() {
    try {
      final raw = _prefs.getString(_historyIndexKey);
      if (raw == null) return {};
      return Map<String, int>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  // Re-encodes an already-built Message back into a Firestore-shaped map so
  // upsertFromFirestore can reuse Message.fromFirestore's own field
  // extraction for the "no existing local row" branch, instead of a fourth
  // near-duplicate constructor call listing every field again. Only ever
  // fed data Message.fromFirestore itself already parsed, so this round
  // trip is lossless for every field that factory reads.
  Map<String, dynamic> _reencode(Message m) => {
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
    'timestamp': m.timestamp,
    'seq': m.seq,
    'type': m.type,
    if (m.replyToId != null)
      'replyTo': {
        'id': m.replyToId,
        'text': m.replyToText,
        'senderName': m.replyToSenderName,
        'imageURL': m.replyToImageURL,
        'videoURL': m.replyToVideoURL,
      },
    if (m.replyToStatusId != null)
      'replyToStatus': {
        'id': m.replyToStatusId,
        'ownerUid': m.replyToStatusOwnerUid,
        'type': m.replyToStatusType,
        'text': m.replyToStatusText,
        'thumbnailURL': m.replyToStatusThumbnailURL,
      },
    'deletedForAll': m.deletedForAll,
    'deletedFor': m.deletedFor,
    'deletedAt': m.deletedAt,
    'reactions': m.reactions,
    'isSystem': m.isSystem,
    'forwardCount': m.forwardCount,
  };

  Map<String, dynamic> _toJson(Message m) => {
    'id': m.id,
    'chatId': m.chatId,
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
    'seq': m.seq,
    'type': m.type,
    'replyToId': m.replyToId,
    'replyToText': m.replyToText,
    'replyToSenderName': m.replyToSenderName,
    'replyToImageURL': m.replyToImageURL,
    'replyToVideoURL': m.replyToVideoURL,
    'replyToStatusId': m.replyToStatusId,
    'replyToStatusOwnerUid': m.replyToStatusOwnerUid,
    'replyToStatusType': m.replyToStatusType,
    'replyToStatusText': m.replyToStatusText,
    'replyToStatusThumbnailURL': m.replyToStatusThumbnailURL,
    'deletedForAll': m.deletedForAll,
    'deletedFor': m.deletedFor,
    'deletedAt': m.deletedAt,
    'reactions': m.reactions,
    'isSystem': m.isSystem,
    'forwardCount': m.forwardCount,
    // Local group — meaningless/wasteful to persist: localUploadProgress
    // and localPreviewBytes (same rationale PendingMediaMessage always
    // used — a resumed 'queued' item re-uploads from scratch, so these
    // correctly default back to 0.0/null rather than showing stale state).
    'localFilePath': m.localFilePath,
    'localSendStatus': m.localSendStatus,
    'attemptCount': m.attemptCount,
    'uploadedUrl': m.uploadedUrl,
    'videoHd': m.videoHd,
  };

  Message _fromJson(Map<String, dynamic> json, {String? chatId}) => Message(
    id: json['id'] as String,
    chatId: chatId ?? json['chatId'] as String?,
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
    seq: (json['seq'] as num?)?.toInt(),
    type: json['type'] as String,
    replyToId: json['replyToId'] as String?,
    replyToText: json['replyToText'] as String?,
    replyToSenderName: json['replyToSenderName'] as String?,
    replyToImageURL: json['replyToImageURL'] as String?,
    replyToVideoURL: json['replyToVideoURL'] as String?,
    replyToStatusId: json['replyToStatusId'] as String?,
    replyToStatusOwnerUid: json['replyToStatusOwnerUid'] as String?,
    replyToStatusType: json['replyToStatusType'] as String?,
    replyToStatusText: json['replyToStatusText'] as String?,
    replyToStatusThumbnailURL: json['replyToStatusThumbnailURL'] as String?,
    deletedForAll: json['deletedForAll'] as bool? ?? false,
    deletedFor: List<String>.from(json['deletedFor'] as List? ?? const []),
    deletedAt: json['deletedAt'] as String?,
    reactions: {
      for (final entry in (json['reactions'] as Map<String, dynamic>? ?? const {}).entries)
        entry.key: List<String>.from(entry.value as List? ?? const []),
    },
    isSystem: json['isSystem'] as bool? ?? false,
    forwardCount: (json['forwardCount'] as num?)?.toInt() ?? 0,
    localFilePath: json['localFilePath'] as String?,
    localSendStatus: json['localSendStatus'] as String?,
    attemptCount: json['attemptCount'] as int? ?? 0,
    uploadedUrl: json['uploadedUrl'] as String?,
    videoHd: json['videoHd'] as bool? ?? false,
  );
}

final localMessageStoreProvider = Provider<LocalMessageStore>((ref) {
  throw UnimplementedError(
    'localMessageStoreProvider must be overridden with an initialized '
    'LocalMessageStore at app startup',
  );
});
