import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../firebase/firestore_service.dart';
import '../../firebase/models.dart';
import '../store/local_message_store.dart';
import 'message_visibility.dart';

// Combined state this controller exposes — messages is the single, already
// merged and ordered list LocalMessageStore.watchChat(chatId) provides
// (pending sends and confirmed history alike, one row per message — see
// that store's own doc comment for why there's nothing left to merge/dedup
// here the way there used to be).
class ChatMessagesState {
  final List<Message> messages;
  // What this device KNOWS about, before any per-user visibility filter —
  // the same raw list `messages` is derived from. Strictly for bookkeeping
  // that is about the conversation rather than about the view: read
  // receipts (lastReadMsgId must name a message the sender can resolve, and
  // a message you deleted for yourself, or cleared away, is still a message
  // you received) and the stale-preview seq comparison. NEVER render this —
  // rendering is what `messages` is for, and mixing the two up is the exact
  // mistake that made pagination and the message list disagree (B7/B8).
  final List<Message> rawMessages;
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
  // Whether older messages still EXIST on the server past what's loaded —
  // strictly a question about documents, never about how many of them the
  // user can see (see message_visibility.dart's own doc comment for why
  // conflating the two was B7/B8). False once a fetchOlderMessages page
  // comes back shorter than requested, or once the cutoff proves nothing
  // older could ever be visible. Starts true (unknown) until the first page
  // load actually confirms it one way or the other.
  final bool hasMoreOlder;
  // True once this controller can render a truthful list: the local store
  // has delivered at least one snapshot (including an empty one — a
  // genuinely empty chat) AND the "Çatı təmizlə" cutoff is known, so what's
  // about to be painted can't contain messages the user already cleared.
  // chat_screen.dart shows its loading spinner until this flips.
  final bool hasLoadedOnce;
  // The cutoff couldn't be established: no local record of it and Firestore
  // neither answered in time nor at all (offline on a chat this device has
  // never opened, or the listener errored). Distinct from hasLoadedOnce
  // being false on its own, which just means "still waiting".
  //
  // There is deliberately no third option where the list renders anyway.
  // An unknown cutoff means we cannot tell a cleared message from a kept
  // one, and the entire point of Этапы 3-4 was that cleared content never
  // reaches the screen in any frame — so the screen says so and offers a
  // retry (see retryClearedAt) instead of guessing. Self-healing: it clears
  // itself the moment the live listener delivers a value, with or without
  // the user pressing anything.
  final bool clearedAtUnavailable;

  const ChatMessagesState({
    required this.messages,
    required this.rawMessages,
    required this.isInitialLoad,
    required this.addedMessageIds,
    required this.isLoadingOlder,
    required this.hasMoreOlder,
    required this.hasLoadedOnce,
    required this.clearedAtUnavailable,
  });

  ChatMessagesState copyWith({
    List<Message>? messages,
    List<Message>? rawMessages,
    bool? isInitialLoad,
    List<String>? addedMessageIds,
    bool? isLoadingOlder,
    bool? hasMoreOlder,
    bool? hasLoadedOnce,
    bool? clearedAtUnavailable,
  }) {
    return ChatMessagesState(
      messages: messages ?? this.messages,
      rawMessages: rawMessages ?? this.rawMessages,
      isInitialLoad: isInitialLoad ?? this.isInitialLoad,
      addedMessageIds: addedMessageIds ?? this.addedMessageIds,
      isLoadingOlder: isLoadingOlder ?? this.isLoadingOlder,
      hasMoreOlder: hasMoreOlder ?? this.hasMoreOlder,
      hasLoadedOnce: hasLoadedOnce ?? this.hasLoadedOnce,
      clearedAtUnavailable:
          clearedAtUnavailable ?? this.clearedAtUnavailable,
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

  late final FirestoreService _firestoreService;
  late final LocalMessageStore _store;
  StreamSubscription<List<Message>>? _storeSub;
  StreamSubscription<List<Message>>? _tailSub;
  StreamSubscription<List<Message>>? _olderSub;
  StreamSubscription<ChatClearedAt>? _clearedSub;

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
  // this are dropped from the output. Kept live by its own narrow
  // watchChatClearedAt stream, never folded into a ref.watch on the
  // general chat-meta stream: that stream also carries the job-offer
  // typing indicator, which writes every few seconds while an offer is
  // pending — routing that through build() would tear down and recreate
  // _tailSub/_olderSub/_storeSub on every one of those writes.
  //
  // The stream is NOT how this value first becomes available, though — see
  // _clearedAtKnown and LocalMessageStore.clearedAtFor.
  DateTime? _clearedAt;
  // Whether _clearedAt above means anything yet. Null used to serve double
  // duty as both "no cutoff" and "haven't heard yet", and since the store
  // reads off local disk while the cutoff came over the network, "haven't
  // heard yet" was the state the FIRST FRAME of every cleared chat was
  // painted in — one frame of the entire pre-clear history, then a collapse
  // to empty (N1, confirmed on-device). Seeded synchronously from the local
  // store before anything subscribes, so in practice this is already true
  // by the time the first frame is built; while it isn't, nothing is
  // emitted at all (hasLoadedOnce stays false and the screen shows its
  // spinner) rather than emitting an unfiltered list.
  bool _clearedAtKnown = false;
  bool _clearedAtUnavailable = false;
  Timer? _clearedUnknownWait;
  String _uid = '';

  // How long to sit in the loading state before telling the user the chat
  // couldn't be loaded, when the cutoff is genuinely unknown — no local
  // record AND no answer from Firestore yet. Only reachable for a chat this
  // account has never opened on this device (which therefore has no local
  // history to show anyway) or, exactly once, for history that predates the
  // local cutoff record.
  //
  // What expiry does NOT do is render the list unfiltered. There is no
  // amount of waiting that turns "we don't know where the cutoff is" into
  // "it's safe to show everything" — the honest answer is that the chat
  // couldn't be loaded, which is also the one the user can act on. Short
  // (4s) precisely because it costs nothing to be wrong: the live listener
  // stays subscribed and clears this state by itself as soon as it
  // delivers, so an over-eager message on a slow connection resolves into
  // the real chat without any interaction.
  static const Duration _clearedUnknownTimeout = Duration(seconds: 4);

  // Bounds one loadOlderMessages call when pages keep coming back with
  // nothing the user can see (a long stretch of "delete for me" messages).
  // Same rationale as chat_screen's _maxOlderPagesToSearch, smaller number:
  // this runs on a scroll gesture, not on an explicit "find that message".
  static const int _maxOlderPagesPerLoad = 5;

  @override
  ChatMessagesState build() {
    _firestoreService = ref.watch(firestoreServiceProvider);
    _store = ref.watch(localMessageStoreProvider);
    ref.onDispose(() {
      _storeSub?.cancel();
      _tailSub?.cancel();
      _olderSub?.cancel();
      _clearedSub?.cancel();
      _clearedUnknownWait?.cancel();
    });
    final uid = FirebaseAuth.instance.currentUser?.uid;
    _uid = uid ?? '';
    // Step one, before ANY subscription exists: take the cutoff off local
    // disk, synchronously. This is what makes the ordering question moot
    // instead of merely unlikely — there is no window in which the store
    // could emit while the cutoff is still unknown, because the cutoff is
    // already resolved on the line above the subscription. See
    // LocalMessageStore.clearedAtFor for the three states and why a chat
    // with local history always has a local cutoff to go with it.
    if (_store.isClearedAtKnown(chatId)) {
      _clearedAtKnown = true;
      _clearedAt = _store.clearedAtFor(chatId);
    }
    if (uid != null) {
      _subscribeClearedAt(uid);
    } else {
      // Signed out mid-teardown: there is no per-user cutoff to wait for.
      _clearedAtKnown = true;
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
      state = _filtered(isInitialLoad: isInitial, addedMessageIds: addedIds);
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
      rawMessages: [],
      isInitialLoad: true,
      addedMessageIds: [],
      isLoadingOlder: false,
      hasMoreOlder: true,
      hasLoadedOnce: false,
      clearedAtUnavailable: false,
    );
  }

  // The live cutoff listener, plus the bounded wait that only exists while
  // the cutoff has never been established. Kept as its own method so
  // retryClearedAt can run exactly the same setup again.
  void _subscribeClearedAt(String uid) {
    _clearedSub?.cancel();
    _clearedUnknownWait?.cancel();
    _clearedUnknownWait = null;
    if (!_clearedAtKnown) {
      _clearedUnknownWait = Timer(_clearedUnknownTimeout, () {
        if (_clearedAtKnown) return;
        _clearedAtUnavailable = true;
        state = _filtered(
          isInitialLoad: state.isInitialLoad,
          addedMessageIds: const [],
        );
      });
    }
    _clearedSub = _firestoreService.watchChatClearedAt(chatId, uid).listen(
      (answer) {
        // Silence, not an answer: the chat document isn't in the local
        // cache and the server hasn't spoken. Keep waiting — and in
        // particular do NOT persist it, which is exactly what turned this
        // case into a false "never cleared" that survived reconnecting
        // (N13). Also never downgrades an already-known cutoff back to
        // unknown: once we've had a real answer it stays the truth until a
        // newer real answer replaces it.
        if (!answer.isKnown) return;
        _clearedUnknownWait?.cancel();
        _clearedUnknownWait = null;
        final wasKnown = _clearedAtKnown;
        final previous = _clearedAt;
        _clearedAtKnown = true;
        _clearedAtUnavailable = false;
        _clearedAt = answer.at;
        // Persist for the next cold open — including a null, which here IS
        // a real answer ("this chat has never been cleared"), because the
        // stream only reports known when it actually saw the document.
        unawaited(_store.setClearedAt(chatId, answer.at));
        // Nothing to repaint when the answer merely repeats itself —
        // includeMetadataChanges means this stream also fires on
        // cache/server and pending-write transitions that carry no change
        // to the cutoff at all.
        if (wasKnown && previous == answer.at) return;
        // Nothing new arrived — only the filter changed — so this never
        // reports any added ids, regardless of what the diff below would
        // otherwise say.
        state = _filtered(
          isInitialLoad: state.isInitialLoad,
          addedMessageIds: const [],
        );
      },
      onError: (Object e, StackTrace st) {
        FirebaseCrashlytics.instance.recordError(
          e,
          st,
          reason: 'ChatMessagesController: clearedAt listener error for $chatId',
        );
        // An error while the cutoff is already known changes nothing —
        // the known value stays authoritative and the screen keeps
        // rendering. Only a failure to ever establish it is user-visible.
        if (_clearedAtKnown) return;
        _clearedUnknownWait?.cancel();
        _clearedUnknownWait = null;
        _clearedAtUnavailable = true;
        state = _filtered(
          isInitialLoad: state.isInitialLoad,
          addedMessageIds: const [],
        );
      },
    );
  }

  // "Yenidən cəhd et" on the couldn't-load state. Resubscribing is what
  // actually retries — the previous listener may be sitting on a dead
  // connection — and it re-arms the wait so the user gets a spinner rather
  // than a button that appears to do nothing. No-op once the cutoff is
  // known, since there is then nothing left to retry.
  void retryClearedAt() {
    if (_clearedAtKnown || _uid.isEmpty) return;
    _clearedAtUnavailable = false;
    state = _filtered(
      isInitialLoad: state.isInitialLoad,
      addedMessageIds: const [],
    );
    _subscribeClearedAt(_uid);
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

  // The one visibility test, shared with pagination below so the two can't
  // disagree about what a page is worth — see message_visibility.dart.
  bool _isVisible(Message m) =>
      isMessageVisible(m, uid: _uid, clearedAt: _clearedAt);

  // hasLoadedOnce/clearedAtUnavailable are derived here rather than passed
  // in: they're a pure function of this controller's own two waits (the
  // store's first emission and the cutoff), and every call site was
  // computing the same expression anyway — one of them from a slightly
  // different angle, which is how these flags drift apart.
  ChatMessagesState _filtered({
    required bool isInitialLoad,
    required List<String> addedMessageIds,
  }) {
    // While the cutoff is unknown this hands back an empty list, not the raw
    // one — the guarantee is that an unfiltered message never leaves this
    // controller at all, not merely that the widget tree happens to be
    // showing a spinner over it (chat_screen is not the only reader of
    // state.messages: the auto-scroll ref.listen and _lastMessages read it
    // too, and "safe as long as every consumer remembers to check a flag"
    // is precisely the kind of contract that decays).
    final visible = _clearedAtKnown
        ? _rawMessages.where(_isVisible).toList()
        : const <Message>[];
    return state.copyWith(
      messages: visible,
      rawMessages: _rawMessages,
      isInitialLoad: isInitialLoad,
      addedMessageIds: addedMessageIds,
      hasLoadedOnce: _storeHasEmittedOnce && _clearedAtKnown,
      clearedAtUnavailable: _clearedAtUnavailable,
    );
  }

  // Called when the user scrolls near the top of the currently-loaded
  // history. No-ops (rather than erroring) if a load is already in flight
  // or a previous page already confirmed there's nothing older.
  //
  // Keeps fetching until the user actually GAINS something, which is a
  // different question from whether the fetch returned documents (B7/B8).
  // A page of 50 messages that are all "delete for me" or all past the
  // clear-chat cutoff renders as zero new rows: the list doesn't grow, so
  // the scroll position doesn't move, so nothing ever asks for the next
  // page — the rest of the history became unreachable without a single
  // error anywhere. The old code made exactly that mistake twice over: it
  // ended pagination on page length (a raw document count, taken before any
  // filtering) and left "nothing appeared" entirely unhandled.
  Future<void> loadOlderMessages() async {
    if (state.isLoadingOlder || !state.hasMoreOlder) return;
    var boundary = _oldestEverLoaded ?? _tailOldest;
    if (boundary == null) return; // no messages loaded at all yet
    state = state.copyWith(isLoadingOlder: true);
    try {
      var gained = 0;
      var pages = 0;
      var moreOlder = true;
      while (gained == 0 && moreOlder && pages < _maxOlderPagesPerLoad) {
        final page = await _firestoreService.fetchOlderMessages(
          chatId: chatId,
          beforeSeq: boundary!,
        );
        pages++;
        if (page.isEmpty) {
          moreOlder = false;
          break;
        }
        // Short page = the query hit the start of the collection. This is
        // the ONLY thing page length is allowed to decide.
        moreOlder = page.length >= messageTailWindowSize;
        await _store.upsertManyFromFirestore(chatId: chatId, reals: page);
        // Every document this query can return is confirmed and therefore
        // has a seq; a null would mean the next iteration has no boundary to
        // page from, so stop rather than loop on the same page forever.
        final oldest = page.first.seq;
        if (oldest == null) {
          moreOlder = false;
          break;
        }
        _oldestEverLoaded = oldest;
        boundary = oldest;
        gained += page.where(_isVisible).length;
        // Explicit yield between pages, same rationale (and the same real
        // ANR) as chat_screen's own paging loop: a page served from
        // Firestore's local cache resolves near-instantly, so the await
        // above alone doesn't guarantee the frame scheduler a turn between
        // this page's store upsert and the next fetch.
        await Future<void>.delayed(Duration.zero);
        // The cutoff makes pagination terminable instead of merely
        // filtered: if even the NEWEST message on this page is at or before
        // it, everything older is too, so there is nothing left to find. A
        // cleared chat now stops after one page instead of scanning its
        // entire history to display nothing.
        final clearedAt = _clearedAt;
        if (clearedAt != null && gained == 0) {
          final newest = page.last.timestamp?.toDate();
          if (newest != null && !newest.isAfter(clearedAt)) {
            moreOlder = false;
            break;
          }
        }
      }
      // Once per call rather than once per page — the listener only needs to
      // end up covering the final range.
      //
      // First page load: nothing was subscribed yet (no _oldestEverLoaded
      // existed before this call), so this starts the older listener. Later
      // page loads just prepend more history to the range the existing
      // listener's lower bound needs to grow to cover too.
      _resubscribeOlderListener();
      state = state.copyWith(isLoadingOlder: false, hasMoreOlder: moreOlder);
    } catch (_) {
      state = state.copyWith(isLoadingOlder: false);
    }
  }
}

final chatMessagesControllerProvider = NotifierProvider.autoDispose
    .family<ChatMessagesController, ChatMessagesState, String>(
      ChatMessagesController.new,
    );
