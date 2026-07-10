import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../firebase/firestore_service.dart';
import '../../firebase/models.dart';

// Combined state this controller exposes — messages is the full merged,
// deduped, timestamp-sorted list (older-paginated-in history + the live
// tail), so consumers read it exactly like the old messagesProvider's
// MessagesSnapshot.messages. isInitialLoad/addedMessageIds are forwarded
// from the tail listener only, same meaning as before (new messages
// arriving at the bottom, not history loading in).
class ChatMessagesState {
  final List<Message> messages;
  final bool isInitialLoad;
  final List<String> addedMessageIds;
  final bool isLoadingOlder;
  // False once a fetchOlderMessages page comes back shorter than requested
  // — there's nothing older left in this chat. Starts true (unknown) until
  // the first page load actually confirms it one way or the other.
  final bool hasMoreOlder;
  // True once the live tail listener has delivered at least one snapshot —
  // including an empty one (a genuinely empty chat). Distinct from
  // isInitialLoad, which stays true for that first snapshot too (it means
  // something different — "history loading in, not a new message"); this
  // is what chat_screen.dart uses to decide whether it's still safe to show
  // stale cached messages instead (mirrors the old messagesProvider
  // AsyncValue's .hasValue check).
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

// Finding #4: watchMessages() itself only covers the live tail
// (messageTailWindowSize most recent messages, see firestore_service.dart)
// instead of a chat's entire history. This controller is what stitches
// that back together for the UI — merging the always-on tail listener with
// a second, separately-scoped listener covering whatever older history has
// been paginated in via loadOlderMessages(), so reactions/read-receipts on
// already-loaded older messages keep updating live rather than going stale
// until the chat is reopened (the tradeoff explicitly rejected in favor of
// the extra complexity here).
//
// The two listeners' ranges are kept adjacent and non-overlapping purely
// via timestamp boundaries — no per-message bookkeeping: the older
// listener's query is [oldestEverLoaded, tailOldest), recreated with a
// wider upper bound whenever the tail's own oldest message shifts forward
// (a new message arriving ages the previous oldest out of
// limitToLast(messageTailWindowSize), which Firestore reports as a
// `removed` docChange on the tail listener even though the document still
// exists — that's the signal this widens on).
//
// chatId is threaded through the constructor (Riverpod's classic
// NotifierProvider.family passes the family argument to the create
// function, not to build()) rather than build(String) — build() itself
// stays the plain no-arg override the base Notifier<ChatMessagesState>
// expects.
class ChatMessagesController extends Notifier<ChatMessagesState> {
  ChatMessagesController(this.chatId);

  final String chatId;

  late final FirestoreService _firestoreService;
  StreamSubscription<MessagesSnapshot>? _tailSub;
  StreamSubscription<List<Message>>? _olderSub;

  // Null until loadOlderMessages() has been called at least once — that's
  // also exactly the condition for whether the older-range listener exists
  // at all yet.
  Timestamp? _oldestEverLoaded;
  Timestamp? _tailOldest;
  List<Message> _tailMessages = const [];
  List<Message> _olderMessages = const [];

  @override
  ChatMessagesState build() {
    _firestoreService = ref.watch(firestoreServiceProvider);
    ref.onDispose(() {
      _tailSub?.cancel();
      _olderSub?.cancel();
    });
    _tailSub = _firestoreService.watchMessages(chatId).listen((snapshot) {
      _tailMessages = snapshot.messages;
      final newTailOldest = snapshot.messages.isEmpty
          ? null
          : snapshot.messages.first.timestamp;
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
      state = _mergedState(
        isInitialLoad: snapshot.isInitialLoad,
        addedMessageIds: snapshot.addedMessageIds,
        hasLoadedOnce: true,
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
        .watchOlderMessagesInRange(
          chatId: chatId,
          fromTimestamp: from,
          toTimestamp: to,
        )
        .listen((messages) {
          _olderMessages = messages;
          state = _mergedState(
            isInitialLoad: state.isInitialLoad,
            addedMessageIds: const [],
          );
        });
  }

  ChatMessagesState _mergedState({
    required bool isInitialLoad,
    required List<String> addedMessageIds,
    bool? hasLoadedOnce,
  }) {
    // Both lists are already ascending-ordered and, by construction (the
    // older listener's upper bound always tracks the tail's own oldest
    // message), non-overlapping except for a possible brief instant right
    // around a boundary update — the id-based dedup below covers that.
    final seen = <String>{};
    final combined = <Message>[];
    for (final m in [..._olderMessages, ..._tailMessages]) {
      if (seen.add(m.id)) combined.add(m);
    }
    return state.copyWith(
      messages: combined,
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
        beforeTimestamp: boundary,
      );
      if (page.isEmpty) {
        state = state.copyWith(isLoadingOlder: false, hasMoreOlder: false);
        return;
      }
      _oldestEverLoaded = page.first.timestamp;
      _olderMessages = [...page, ..._olderMessages];
      // First page load: nothing was subscribed yet (no _oldestEverLoaded
      // existed before this call), so start the older listener now. Later
      // page loads just prepend more history to the range the existing
      // listener's lower bound needs to grow to cover too.
      _resubscribeOlderListener();
      state = _mergedState(
        isInitialLoad: state.isInitialLoad,
        addedMessageIds: const [],
      ).copyWith(
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
