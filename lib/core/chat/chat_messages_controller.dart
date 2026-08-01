import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../firebase/firestore_service.dart';
import '../../firebase/models.dart';
import '../store/local_message_store.dart';

// Combined state this controller exposes — messages is the single, already
// merged and ordered list LocalMessageStore.watchChat(chatId) provides
// (pending sends and confirmed history alike, one row per message — see
// that store's own doc comment for why there's nothing left to merge/dedup
// here the way there used to be).
class ChatMessagesState {
  final List<Message> messages;
  final bool isInitialLoad;
  // Message ids that are genuinely NEW to `messages` since the previous
  // emission — computed by diffing LocalMessageStore's own before/after
  // snapshots (see build()'s _storeSub), not derived from Firestore's raw
  // docChanges the way this used to work. That distinction matters: a
  // message THIS device just sent reports as freshly `added` on Firestore's
  // side too, the same as one from someone else, even though it was
  // already visible here as a pending row before the server ever confirmed
  // it — diffing the store's actual rendered output instead of Firestore's
  // own bookkeeping is what correctly excludes that case without needing a
  // senderId special-case anywhere (chat_screen.dart's auto-scroll ref.listen
  // still filters to `senderId != currentUid`, but only to avoid scrolling
  // for other-device reads/edits of your own already-visible message, a
  // narrower and now purely optional refinement — not compensating for a
  // wrong "added" signal the way it originally had to).
  final List<String> addedMessageIds;
  final bool isLoadingOlder;
  // False once a fetchOlderMessages page comes back shorter than requested
  // — there's nothing older left in this chat. Starts true (unknown) until
  // the first page load actually confirms it one way or the other.
  final bool hasMoreOlder;
  // True once the local store has delivered at least one snapshot —
  // including an empty one (a genuinely empty chat). This is what
  // chat_screen.dart uses to decide whether it's still safe to show a
  // loading spinner instead of the (possibly empty) real list.
  final bool hasLoadedOnce;

  const ChatMessagesState({
    required this.messages,
    required this.isInitialLoad,
    required this.addedMessageIds,
    required this.isLoadingOlder,
    required this.hasMoreOlder,
    required this.hasLoadedOnce,
  });

  ChatMessagesState copyWith({
    List<Message>? messages,
    bool? isInitialLoad,
    List<String>? addedMessageIds,
    bool? isLoadingOlder,
    bool? hasMoreOlder,
    bool? hasLoadedOnce,
  }) {
    return ChatMessagesState(
      messages: messages ?? this.messages,
      isInitialLoad: isInitialLoad ?? this.isInitialLoad,
      addedMessageIds: addedMessageIds ?? this.addedMessageIds,
      isLoadingOlder: isLoadingOlder ?? this.isLoadingOlder,
      hasMoreOlder: hasMoreOlder ?? this.hasMoreOlder,
      hasLoadedOnce: hasLoadedOnce ?? this.hasLoadedOnce,
    );
  }
}

// Per-chat screen-scoped controller (autoDispose — start/stops with the
// chat screen's own lifetime, no refcounting needed since only one chat
// screen is ever open at a time in this app). Two responsibilities:
//
// 1. Own `state`, sourced ENTIRELY from LocalMessageStore.watchChat(chatId)
//    — the store is the single source of truth (see its own doc comment).
//    This is also where addedMessageIds/isInitialLoad get computed, by
//    diffing each new store snapshot against the previous one (see
//    ChatMessagesState's own doc comment for why that's the correct place
//    for that signal now, not Firestore's raw docChanges).
// 2. Act as this chat's sync writer while the screen is mounted: subscribe
//    to the live Firestore tail (FirestoreService.watchMessages) and
//    whatever older range has been paginated in (watchOlderMessagesInRange),
//    and upsert every doc either delivers into the store. Firestore is
//    never read directly by the UI — everything flows through the store.
//    This half never touches `state` directly at all anymore.
//
// Finding #4 (unchanged from before this store existed): watchMessages()
// itself only covers the live tail (messageTailWindowSize most recent
// messages, see firestore_service.dart) instead of a chat's entire
// history — loadOlderMessages() below is what pages further back on
// demand, keeping whatever's been paginated in live too (reactions/read-
// receipts on older messages keep updating) via the second, separately-
// scoped older-range listener, exactly as before.
//
// chatId is threaded through the constructor (Riverpod's classic
// NotifierProvider.family passes the family argument to the create
// function, not to build()) rather than build(String) — build() itself
// stays the plain no-arg override the base Notifier<ChatMessagesState>
// expects.
class ChatMessagesController extends Notifier<ChatMessagesState> {
  ChatMessagesController(this.chatId);

  final String chatId;

  // TEMP DIAGNOSTIC (2026-08-01) — static so the counts survive across
  // instance recreation, to measure directly whether Riverpod's
  // autoDispose is tearing this controller down and rebuilding it far more
  // often than the enclosing chat screen widget (which separate evidence —
  // the activeUsers field on chats/{chatId} never changing across a live
  // Firestore diff — already showed stays mounted throughout). Purely
  // in-memory, no network I/O: read by chat_screen.dart's debug-SnackBar
  // timer. Remove once the root cause of the chats/{chatId} write storm is
  // confirmed/fixed.
  static int debugBuildCount = 0;
  static int debugDisposeCount = 0;
  static final List<DateTime> _debugRecentBuilds = [];

  static String debugSnapshot() {
    final now = DateTime.now();
    _debugRecentBuilds.removeWhere(
      (t) => now.difference(t) > const Duration(seconds: 10),
    );
    return 'build=$debugBuildCount dispose=$debugDisposeCount '
        'builds/10s=${_debugRecentBuilds.length}';
  }

  late final FirestoreService _firestoreService;
  late final LocalMessageStore _store;
  StreamSubscription<List<Message>>? _storeSub;
  StreamSubscription<List<Message>>? _tailSub;
  StreamSubscription<List<Message>>? _olderSub;
  StreamSubscription<DateTime?>? _clearedSub;

  // Null until loadOlderMessages() has been called at least once — that's
  // also exactly the condition for whether the older-range listener exists
  // at all yet.
  int? _oldestEverLoaded;
  int? _tailOldest;
  // Un-cleared-filtered store output, so the diff below and the
  // clear-chat filter both work off the exact same raw list.
  List<Message> _rawMessages = const [];
  Set<String> _previousIds = const {};
  bool _storeHasEmittedOnce = false;
  // "Çatı təmizlə" cutoff for the CURRENT uid only — messages at or before
  // this are dropped from the output. Fed by its own narrow
  // watchChatClearedAt stream, never folded into a ref.watch on the
  // general chat-meta stream: that stream also carries the job-offer
  // typing indicator, which writes every few seconds while an offer is
  // pending — routing that through build() would tear down and recreate
  // _tailSub/_olderSub/_storeSub on every one of those writes.
  DateTime? _clearedAt;

  @override
  ChatMessagesState build() {
    // TEMP DIAGNOSTIC — see debugBuildCount's own comment above.
    debugBuildCount++;
    _debugRecentBuilds.add(DateTime.now());
    _firestoreService = ref.watch(firestoreServiceProvider);
    _store = ref.watch(localMessageStoreProvider);
    ref.onDispose(() {
      // TEMP DIAGNOSTIC — see debugBuildCount's own comment above.
      debugDisposeCount++;
      _storeSub?.cancel();
      _tailSub?.cancel();
      _olderSub?.cancel();
      _clearedSub?.cancel();
    });
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      _clearedSub = _firestoreService.watchChatClearedAt(chatId, uid).listen((
        clearedAt,
      ) {
        _clearedAt = clearedAt;
        // Nothing new arrived — only the filter changed — so this never
        // reports any added ids, regardless of what the diff below would
        // otherwise say.
        state = _filtered(
          isInitialLoad: state.isInitialLoad,
          addedMessageIds: const [],
          hasLoadedOnce: state.hasLoadedOnce,
        );
      });
    }
    // The fast path: local disk, no network round trip — this is what lets
    // the chat screen paint real content (including this device's own
    // still-pending sends) essentially instantly, cold start or not,
    // without a separate passive fallback-cache layer the old design
    // needed (MessageCacheService, now folded into the store itself).
    //
    // Also the ONLY place addedMessageIds/isInitialLoad get computed now —
    // by diffing this snapshot's ids against the previous one. The very
    // first emission (_storeHasEmittedOnce still false) is history
    // loading in, not new messages arriving, so it's reported as
    // isInitialLoad with no added ids, same meaning as before.
    _storeSub = _store.watchChat(chatId).listen((messages) {
      final newIds = messages.map((m) => m.id).toSet();
      final isInitial = !_storeHasEmittedOnce;
      final addedIds = isInitial
          ? const <String>[]
          : newIds.difference(_previousIds).toList();
      _storeHasEmittedOnce = true;
      _previousIds = newIds;
      _rawMessages = messages;
      state = _filtered(
        isInitialLoad: isInitial,
        addedMessageIds: addedIds,
        hasLoadedOnce: true,
      );
    });
    _tailSub = _firestoreService.watchMessages(chatId).listen((messages) {
      unawaited(
        _store.upsertManyFromFirestore(chatId: chatId, reals: messages),
      );
      final newTailOldest = messages.isEmpty ? null : messages.first.seq;
      // Only re-point the older listener once we actually have a tail
      // boundary to bound it by, and only if pagination has ever happened
      // (_oldestEverLoaded set) — otherwise there's no older listener yet
      // to widen.
      if (newTailOldest != null &&
          _oldestEverLoaded != null &&
          newTailOldest != _tailOldest) {
        _tailOldest = newTailOldest;
        _resubscribeOlderListener();
      } else {
        _tailOldest = newTailOldest;
      }
    }, onError: (Object e, StackTrace st) {
      // This stream naturally dies with a permission-denied error the
      // instant the chat disappears out from under a still-mounted
      // ChatScreen — leave-group, delete-group, or being removed by an
      // admin (found via Phase G testing: firestore.rules' isMember()
      // starts rejecting reads the moment the write that causes any of
      // those lands, but this screen isn't unmounted until its own
      // Navigator.pop() finishes a beat later). The screen is already
      // navigating away in all of those cases, so silently stopping here
      // is correct — rethrowing/updating state would surface a scary raw
      // FirebaseException as Flutter's default red error overlay for
      // something that isn't really an error from the user's point of
      // view. A genuine, unexpected Firestore error on a still-valid chat
      // is a different, much rarer case; logging it (rather than
      // crashing) is still the safer default for that case too.
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'ChatMessagesController: tail listener error for $chatId',
      );
    });
    return const ChatMessagesState(
      messages: [],
      isInitialLoad: true,
      addedMessageIds: [],
      isLoadingOlder: false,
      hasMoreOlder: true,
      hasLoadedOnce: false,
    );
  }

  void _resubscribeOlderListener() {
    final from = _oldestEverLoaded;
    final to = _tailOldest;
    if (from == null || to == null) return;
    _olderSub?.cancel();
    _olderSub = _firestoreService
        .watchOlderMessagesInRange(chatId: chatId, fromSeq: from, toSeq: to)
        .listen((messages) {
          unawaited(
            _store.upsertManyFromFirestore(chatId: chatId, reals: messages),
          );
        }, onError: (Object e, StackTrace st) {
          // Same rationale as the tail listener's onError above — this
          // listener dies the same way, for the same reasons.
          FirebaseCrashlytics.instance.recordError(
            e,
            st,
            reason:
                'ChatMessagesController: older listener error for $chatId',
          );
        });
  }

  ChatMessagesState _filtered({
    required bool isInitialLoad,
    required List<String> addedMessageIds,
    required bool hasLoadedOnce,
  }) {
    final clearedAt = _clearedAt;
    final visible = clearedAt == null
        ? _rawMessages
        : _rawMessages
              .where((m) => m.timestamp?.toDate().isAfter(clearedAt) ?? true)
              .toList();
    return state.copyWith(
      messages: visible,
      isInitialLoad: isInitialLoad,
      addedMessageIds: addedMessageIds,
      hasLoadedOnce: hasLoadedOnce,
    );
  }

  // Called when the user scrolls near the top of the currently-loaded
  // history. No-ops (rather than erroring) if a load is already in flight
  // or a previous page already confirmed there's nothing older.
  Future<void> loadOlderMessages() async {
    if (state.isLoadingOlder || !state.hasMoreOlder) return;
    final boundary = _oldestEverLoaded ?? _tailOldest;
    if (boundary == null) return; // no messages loaded at all yet
    state = state.copyWith(isLoadingOlder: true);
    try {
      final page = await _firestoreService.fetchOlderMessages(
        chatId: chatId,
        beforeSeq: boundary,
      );
      if (page.isEmpty) {
        state = state.copyWith(isLoadingOlder: false, hasMoreOlder: false);
        return;
      }
      await _store.upsertManyFromFirestore(chatId: chatId, reals: page);
      _oldestEverLoaded = page.first.seq;
      // First page load: nothing was subscribed yet (no _oldestEverLoaded
      // existed before this call), so start the older listener now. Later
      // page loads just prepend more history to the range the existing
      // listener's lower bound needs to grow to cover too.
      _resubscribeOlderListener();
      state = state.copyWith(
        isLoadingOlder: false,
        hasMoreOlder: page.length >= messageTailWindowSize,
      );
    } catch (_) {
      state = state.copyWith(isLoadingOlder: false);
    }
  }
}

final chatMessagesControllerProvider = NotifierProvider.autoDispose
    .family<ChatMessagesController, ChatMessagesState, String>(
      ChatMessagesController.new,
    );
