import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart' hide User;
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/agreements/event_answers.dart';
import '../core/chat/chat_departure.dart';
import '../core/chat/chat_existence.dart';
import '../core/models/activity_type.dart';
import '../core/time/instant_iso.dart';
import '../core/store/shared_stream.dart';
import 'models.dart';

// Live-tail window size for watchMessages (finding #4) — how many of the
// most recent messages stay covered by the always-on live listener. Older
// history is paginated in separately (see ChatMessagesController) rather
// than this growing per chat's total history size.
const int messageTailWindowSize = 50;

// Сколько самых свежих чатов держит живой список (B31). Замер по проду
// 02.08: 7 чатов во всём проекте, максимум 6 у одного пользователя, —
// то есть сегодня граница не задевает никого и заведена на вырост.
//
// Это отсечка, а не страница: чат за пределами сотни самых свежих в
// список не попадёт вовсе, и подгрузки по прокрутке здесь нет. Для
// нынешних чисел это неотличимо от «показываем всё», но настоящая
// постраничность списка чатов — отдельная работа, если счёт пойдёт на
// сотни.
const int chatListWindowSize = 100;

// Сколько самых свежих медиа чата держит живой слушатель галереи (B33).
// Замер по проду 02.08: 42 медиа-сообщения во всём проекте, самый
// большой чат — 278 сообщений любого типа. Граница сегодня недостижима.
//
// Последствие, которое нельзя оставлять молчаливым: медиа старше окна в
// галерею не попадает, поэтому открытие такого вложения из переписки
// показывает его одно, без ленты соседей (см.
// ChatAttachmentViewerScreen — там это обработано явно, а не приводит к
// показу чужой фотографии вместо запрошенной).
const int chatMediaWindowSize = 200;

// The answer to "where is this user's Çatı təmizlə cutoff in this chat" —
// a tri-state, because "we haven't been told" and "there is no cutoff" are
// different answers that a nullable DateTime cannot tell apart. See
// FirestoreService.watchChatClearedAt for how they're distinguished and why
// collapsing them was a real, durable bug (N13).
class ChatClearedAt {
  const ChatClearedAt.known(this.at) : isKnown = true;
  const ChatClearedAt.unknown() : isKnown = false, at = null;

  // False means literally nothing is known — not "known to be absent".
  // Callers must not persist or act on `at` while this is false.
  final bool isKnown;
  final DateTime? at;

  // Value equality exists specifically so watchChatClearedAt can end in
  // `.distinct()`: it now maps off a shared chats/{chatId} listener that
  // also fires for typing/preview writes, and without equality every
  // unrelated write to that document would look like a new cutoff and
  // re-run ChatMessagesController's subscription rebuild.
  @override
  bool operator ==(Object other) =>
      other is ChatClearedAt && other.isKnown == isKnown && other.at == at;

  @override
  int get hashCode => Object.hash(isKnown, at);
}

// Deep equality for the projected maps below. Written here rather than
// pulled from package:collection because that package isn't a declared
// dependency of this app, and the shapes involved are small and known:
// maps, lists and scalars, nested a couple of levels at most.
bool _deepEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !_deepEquals(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

// Один слушатель на chats/{chatId} вместо трёх (B17).
//
// Три проекции ниже — watchChatMeta, watchChatTyping,
// watchChatClearedAt — обязаны остаться раздельными ПОТОКАМИ: свести их
// в один было замерено как вредное (запись «печатает» раз в ~3 с
// перестраивала весь ~1000-строчный build() экрана чата, см. комментарий
// watchChatTyping). Но раздельные потоки никогда не требовали
// раздельных СЛУШАТЕЛЕЙ: Firestore тарифицирует чтение документа на
// каждого слушателя, то есть за одну запись в самый горячий документ
// приложения платилось трижды.
//
// Механику совместного слушателя — повтор последнего снимка новому
// подписчику, отсутствие щели между повтором и подключением, полное
// забывание состояния после ухода последнего — держит SharedStream
// (lib/core/store/shared_stream.dart), где она покрыта тестами. Здесь
// остаётся только проекция и `.distinct()` на каждой из них.

class FirestoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseFunctions _functions = FirebaseFunctions.instanceFor(
    region: 'europe-west3',
  );

  // Applied to the simple, single-purpose chat/presence write helpers below
  // (markChatAsDelivered through setTyping) — none of them previously had
  // any timeout at all, unlike the pending-message queue's own 20s bound.
  // Confirmed on-device as a real, severe gap: a single stuck local
  // Firestore write (setUserPresence, in this case — see its own comment)
  // hung forever with no error, silently freezing that one piece of state
  // (lastSeen) indefinitely instead of failing visibly and letting the
  // caller/Crashlytics know. 10s is generous for a single-document update
  // under normal conditions, short enough that a genuinely stuck write
  // doesn't block anything user-facing for long.
  static const Duration _writeTimeout = Duration(seconds: 10);

  // chatIds whose chats/{chatId}/meta/counters document is known to exist,
  // so _commitMessage can skip _resolveSeedFloor's probe read (see there).
  // Purely a per-session read-cost optimisation — never consulted for the
  // seq value itself, which always comes from the transaction's own read of
  // that document, so a stale entry here can't produce a wrong seq.
  final Set<String> _seededCounterChats = {};

  // Живые слушатели chats/{chatId}, по одному на чат (B17). Запись
  // исчезает сама, как только от неё отписался последний потребитель —
  // см. SharedStream.
  final Map<String, SharedStream<DocumentSnapshot<Map<String, dynamic>>>>
  _sharedChatDocs = {};

  // includeMetadataChanges нужен ровно одному потребителю —
  // watchChatClearedAt, которому без него не отличить «документа нет в
  // кэше» от «сервер подтвердил, что документа нет» (N13). Раз слушатель
  // теперь один на всех, флаг включён на нём; остальным проекциям лишние
  // события гасит `.distinct()`.
  Stream<DocumentSnapshot<Map<String, dynamic>>> _watchChatDoc(String chatId) {
    final shared = _sharedChatDocs.putIfAbsent(
      chatId,
      () => SharedStream<DocumentSnapshot<Map<String, dynamic>>>(
        () => _db
            .collection('chats')
            .doc(chatId)
            .snapshots(includeMetadataChanges: true),
        onIdle: () => _sharedChatDocs.remove(chatId),
      ),
    );
    return shared.stream;
  }

  Future<User?> fetchUserById(String uid) async {
    final doc = await _db.collection('users').doc(uid).get();
    if (!doc.exists) return null;
    return User.fromFirestore(doc.id, doc.data()!);
  }

  Stream<User?> watchUserById(String uid) {
    return _db
        .collection('users')
        .doc(uid)
        .snapshots()
        .map((doc) => doc.exists ? User.fromFirestore(doc.id, doc.data()!) : null)
        .handleError((Object e, StackTrace st) {
          // Same expected sign-out race as _watchUsers above — only log
          // while genuinely still signed in.
          if (FirebaseAuth.instance.currentUser != null) {
            debugPrint('❌ watchUserById($uid) stream error: $e\n$st');
          }
          throw e;
        });
  }

  Future<String> uploadAvatar({
    required String uid,
    required String filePath,
  }) async {
    final ref = FirebaseStorage.instance
        .ref()
        .child('avatars')
        .child('$uid.jpg');
    await ref.putFile(File(filePath));
    return await ref.getDownloadURL();
  }

  Future<void> updateUserProfile({
    required String uid,
    required String displayName,
    required String bio,
    required ActivityType? activityType,
    required String city,
    required bool available,
    String? photoURL,
  }) async {
    // instrument/specialty stay derived display strings — every screen that
    // reads them as plain text (search, profile chips, etc.) keeps working
    // unchanged. activityInstruments is the flat leaf list, kept separately
    // because Firestore can only array-contains-filter a flat array, not
    // reach into activityType's nested map.
    final instrumentLabel = activityType?.toDisplayLabel() ?? '';
    await _db.collection('users').doc(uid).update({
      'displayName': displayName,
      'bio': bio,
      'instrument': instrumentLabel,
      'specialty': instrumentLabel,
      'activityType': activityType?.toMap(),
      'activityInstruments': activityType?.toSearchableInstruments() ?? [],
      'city': city,
      'available': available,
      'updatedAt': FieldValue.serverTimestamp(),
      if (photoURL != null) 'photoURL': photoURL,
    });
  }

  Stream<List<User>> _watchUsers(Query<Map<String, dynamic>> query) {
    return query
        .snapshots()
        .map(
          (snap) => snap.docs
              .map((doc) => User.fromFirestore(doc.id, doc.data()))
              .toList(),
        )
        .handleError((Object e, StackTrace st) {
          // A permission-denied here the instant sign-out invalidates the
          // ID token is an expected race (this stream's listener was still
          // alive from whatever screen was mounted underneath Settings),
          // not a real failure — only worth logging while genuinely still
          // signed in.
          if (FirebaseAuth.instance.currentUser != null) {
            debugPrint('❌ _watchUsers stream error: $e\n$st');
          }
          throw e;
        });
  }

  // Every registered user, regardless of role — the home feed used to
  // filter to role == 'musician' here, which made every 'qonaq'-registered
  // user permanently invisible to everyone. Visibility no longer depends on
  // role; musiciansProvider/allUsersProvider are now equivalent aliases,
  // kept separate because call sites read as "musicians feed" vs. "any
  // user picker" (tagging event participants, etc.).
  Stream<List<User>> watchAllUsers() {
    return _watchUsers(_db.collection('users'));
  }

  // Skips the one snapshot that isn't an answer: empty AND merely from the
  // local cache. That is "we haven't reached the server and have nothing
  // stored", which the chat list used to render as the sentence "Hələ mesaj
  // yoxdur" — telling a user with a full inbox that they have no messages
  // (N14, seen on-device 02.08 on a cold install with no connection). Not
  // emitting it leaves chatsProvider in its loading state, which the screen
  // resolves into a real couldn't-load message.
  //
  // Deliberately narrow: an empty result WITH isFromCache false is the
  // server genuinely saying "no chats", and a non-empty cached result is
  // real data worth showing offline. Only the two together mean silence.
  // Same test as watchChatClearedAt, one level up (a query rather than a
  // document) — see its own comment for why this is exact rather than a
  // heuristic.
  Stream<List<Chat>> watchChats(String uid) {
    return _db
        .collection('chats')
        .where('members', arrayContains: uid)
        // Порядок и граница — на сервере, а не только в памяти (B31).
        // Раньше запрос тянул все чаты пользователя целиком и
        // пересортировывал их в клиенте на любое изменение любого из них.
        //
        // Сортировка именно по lastMessageTime, а не по lastMessageAt,
        // хотя второе поле пишут оба приложения: lastMessageAt после
        // создания чата обновляет только mugam-v2, а сообщения из этого
        // приложения его не двигают — порядок по нему был бы неверным.
        // lastMessageTime, наоборот, поддерживает onNewMessage для
        // сообщений обоих приложений.
        //
        // Плата за этот выбор — документы, у которых поля НЕТ вовсе,
        // Firestore из выдачи выбрасывает, а такие создаёт mugam-v2 (в
        // его коде этого имени нет). Поэтому запрос опирается на
        // серверную гарантию: onChatCreated (functions/src/index.ts)
        // проставляет поле при создании любого чата, кем бы он ни был
        // создан. Явный null полем считается и из выдачи не выпадает —
        // он штатно бывает у чата с полностью удалённой историей и
        // сортируется в конец, ровно как и в прежней сортировке в памяти.
        .orderBy('lastMessageTime', descending: true)
        .limit(chatListWindowSize)
        .snapshots()
        .where((snap) => !(snap.docs.isEmpty && snap.metadata.isFromCache))
        .map((snap) {
          // Отметка доставки ставится ЗДЕСЬ, а не на экране чата (B18):
          // список чатов — единственное место, где устройство узнаёт о
          // новом сообщении, не открывая переписку. Именно это и значит
          // «доставлено»: сообщение доехало до устройства получателя.
          _recordDeliveries(snap, uid);
          final chats = snap.docs
              .map((doc) => Chat.fromFirestore(doc.id, doc.data(), uid))
              .toList();
          // A single 1:1 pair can have more than one chat doc — real
          // pre-existing mugam-v2 legacy chats predating this app, plus
          // (now-defunct) duplicates from the old completed-chat-forking
          // design getOrCreateDirectChat used to have. Every one of them
          // is still a genuinely valid document (nothing here deletes or
          // merges their history), but showing every dormant duplicate as
          // its own row is confusing clutter — confirmed on-device as
          // literally the same contact appearing 2+ times in this list.
          // Collapsing to the single most-recently-active chat per
          // counterpart (by otherUid, group chats untouched) is what
          // getOrCreateDirectChat's own legacy-fallback lookup already
          // does when picking which chat to reuse — this just makes the
          // list agree with that choice instead of surfacing every dormant
          // thread it correctly ignores.
          final bestPerCounterpart = <String, Chat>{};
          final result = <Chat>[];
          for (final chat in chats) {
            if (chat.isGroup) {
              result.add(chat);
              continue;
            }
            final otherUid = chat.members.firstWhere(
              (m) => m != uid,
              orElse: () => chat.id,
            );
            final existing = bestPerCounterpart[otherUid];
            if (existing == null) {
              bestPerCounterpart[otherUid] = chat;
            } else {
              final existingTime = existing.lastMessageTime;
              final chatTime = chat.lastMessageTime;
              final chatIsNewer = existingTime == null
                  ? chatTime != null
                  : (chatTime != null && chatTime.isAfter(existingTime));
              if (chatIsNewer) bestPerCounterpart[otherUid] = chat;
            }
          }
          result.addAll(bestPerCounterpart.values);
          // Tiebreaker по id при равных ключах — тот же, что уже стоит в
          // getOrCreateDirectChat выше, и по той же причине (B32/B13).
          // Возврат 0 оставлял порядок на усмотрение сортировки, а она в
          // Dart не обещает стабильности: две карточки с одинаковым
          // lastMessageTime могли меняться местами на ровном месте, при
          // любой перерисовке списка.
          //
          // Совпадение ключей — не экзотика, а штатное состояние: сервер
          // пишет lastMessageTime: null каждому чату, у которого история
          // удалена целиком (recomputeChatPreviewAfterRemoval), так что
          // все такие чаты равны между собой. Плюс сообщения, отправленные
          // в одну миллисекунду.
          result.sort((a, b) {
            final aTime = a.lastMessageTime;
            final bTime = b.lastMessageTime;
            if (aTime == null && bTime == null) return a.id.compareTo(b.id);
            if (aTime == null) return 1;
            if (bTime == null) return -1;
            final byTime = bTime.compareTo(aTime);
            return byTime != 0 ? byTime : a.id.compareTo(b.id);
          });
          return result;
        });
  }

  // The feed's real-time source: every currently-active status (across all
  // owners) this uid is allowed to see. The where() clause here — field
  // name, operator, and using request.auth.uid (via arrayContains: uid))
  // — must exactly match firestore.rules' top-level
  // `match /{path=**}/statuses/{statusId} { allow read: if isSignedIn() &&
  // request.auth.uid in resource.data.visibleToUids; }` block. Firestore
  // only authorizes a collectionGroup() query when the query's own filters
  // alone can prove the rule holds for every possible result — changing
  // this shape without re-checking that rule can silently reintroduce the
  // "getDoc() works, the real feed query doesn't" gap hit and fixed in
  // commit d6b2ad6 (see that commit, and firestore.rules' own comment on
  // /{path=**}/statuses/{statusId}, for the full story).
  Stream<List<StatusGroup>> watchStatusFeed(String uid) {
    return _db
        .collectionGroup('statuses')
        .where('visibleToUids', arrayContains: uid)
        .where('expiresAt', isGreaterThan: Timestamp.now())
        .snapshots()
        .map((snap) {
          final statuses = snap.docs
              .map((doc) => Status.fromFirestore(doc.id, doc.data()))
              .toList();

          final byOwner = <String, List<Status>>{};
          for (final status in statuses) {
            byOwner.putIfAbsent(status.ownerUid, () => []).add(status);
          }

          final groups = byOwner.entries
              .map(
                (e) => StatusGroup(
                  ownerUid: e.key,
                  statuses: e.value
                    ..sort((a, b) => a.createdAt.compareTo(b.createdAt)),
                ),
              )
              .toList();

          // Own group first, always. Among everyone else, most recently
          // posted author first — deterministic, not just a stability
          // patch: List.sort() isn't guaranteed stable, so without a real
          // secondary key here, two non-owner groups could visibly swap
          // places on every snapshot for no actual change. No "unviewed
          // first" ordering here, that needs per-status viewed state (see
          // hasViewedStatus below), which is a separate concern from this
          // feed query.
          groups.sort((a, b) {
            final aIsOwn = a.ownerUid == uid;
            final bIsOwn = b.ownerUid == uid;
            if (aIsOwn != bIsOwn) return aIsOwn ? -1 : 1;
            if (aIsOwn) return 0; // at most one own group can exist
            return b.statuses.last.createdAt.compareTo(
              a.statuses.last.createdAt,
            );
          });

          return groups;
        });
  }

  // The non-feed counterpart to watchStatusFeed above — fetches one
  // specific owner's active statuses directly via get(), for opening a
  // status from an avatar ring outside the friends-scoped feed (e.g. a
  // stranger's public 'Hamı'-mode status), not by finding them already
  // present in a live query result. This is deliberately NOT a
  // visibleToUids-based list query: per firestore.rules' own comment, ANY
  // query against a statuses collection (collectionGroup or a plain
  // per-owner subcollection query alike) is classified `list` and stays
  // friends-only — the new isPublic-based public access only ever
  // authorizes get()-ing one already-known document by its exact path, so
  // `owner.activeStatusIds` (denormalized by onStatusCreated/
  // onStatusDeleted, functions/src/index.ts) is what supplies those exact
  // ids up front, one get() per id.
  //
  // Takes an already-resolved User rather than an ownerUid — every call
  // site that would open this (the avatar-ring screens) already has the
  // owner's User doc in hand (that's the whole reason activeStatusIds
  // lives there rather than requiring a fresh fetch), so re-fetching it
  // here would just be a redundant read for the common case. No currentUid
  // param: unlike firestore.rules-side checks, the SDK attaches the
  // signed-in user's own auth token to every get() automatically — there's
  // nothing for this function to do with an explicit uid, the rule already
  // evaluates request.auth.uid on its own.
  Future<StatusGroup?> fetchStatusGroupForUser({
    required User owner,
  }) async {
    final now = DateTime.now();
    final results = await Future.wait(
      owner.activeStatusIds.map((statusId) async {
        try {
          final doc = await _db
              .collection('users')
              .doc(owner.id)
              .collection('statuses')
              .doc(statusId)
              .get();
          if (!doc.exists) return null;
          final status = Status.fromFirestore(doc.id, doc.data()!);
          // Double-checked client-side even though the rule already
          // filters non-visible ids down to the ones that actually
          // returned data — activeStatusIds can lag behind a TTL-driven
          // delete (see that field's own comment, models.dart) by up to
          // 24h, during which a since-expired status's id could still be
          // in the array and still get()-able (deletion hasn't happened
          // yet), even though it should no longer be shown as "active".
          if (!status.expiresAt.isAfter(now)) return null;
          return status;
        } on FirebaseException {
          // Denied by firestore.rules' isPublic/privacyList/visibleToUids
          // check — e.g. this specific status is 'contactsExcept' and
          // currentUid is in that particular status's exclusion list, even
          // though other ids in activeStatusIds (posted under a different
          // privacyList, or before/after an exclusion changed) may still
          // be visible. Expected, not an error: just means this one id
          // doesn't belong in the resulting group.
          return null;
        }
      }),
    );

    final statuses = results.whereType<Status>().toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (statuses.isEmpty) return null;
    return StatusGroup(ownerUid: owner.id, statuses: statuses);
  }

  // Single-doc check: has `viewerUid` already viewed this specific status.
  // One read per status currently shown in the feed — bounded by feed
  // size, not a scale concern (same reasoning as the SCALE NOTE comments
  // in functions/src/index.ts). Deliberately decoupled from
  // watchStatusFeed's own stream so the main feed listener doesn't have to
  // also fan out a viewers/ read per status on every snapshot.
  Future<bool> hasViewedStatus({
    required String ownerUid,
    required String statusId,
    required String viewerUid,
  }) async {
    final doc = await _db
        .collection('users')
        .doc(ownerUid)
        .collection('statuses')
        .doc(statusId)
        .collection('viewers')
        .doc(viewerUid)
        .get();
    return doc.exists;
  }

  // Write-side counterpart to hasViewedStatus above — called once by
  // StatusViewerScreen when a non-owner's status segment is actually shown
  // (never for the owner's own group). viewedAt MUST be
  // FieldValue.serverTimestamp(), not a client-supplied DateTime.now():
  // firestore.rules' viewers/{viewerUid} write rule requires
  // `request.resource.data.viewedAt == request.time`, which only a real
  // server timestamp sentinel satisfies (see that rule's own comment for
  // the anti-spoofing rationale). Plain set(), no merge — the viewer doc
  // has exactly this one field, so there's nothing to preserve across
  // repeat views of the same status.
  //
  // Batched together with a second write to the VIEWER's own user doc —
  // lastViewedStatusOwnerAt.{ownerUid} — rather than a separate call or a
  // new server trigger (see User.lastViewedStatusOwnerAt's own comment,
  // models.dart, and User.hasUnviewedStatusFrom for what reads it back).
  // Piggybacking here keeps "one write fires exactly when a status is
  // actually viewed" as a single atomic unit; there's no serverTimestamp()
  // anti-spoofing requirement on this second field the way there is for
  // viewedAt above (this one only affects the writer's own ring
  // rendering, not what anyone else can see), but serverTimestamp() is
  // still used for ordinary clock-skew correctness against the owner's
  // server-written mostRecentStatusCreatedAt.
  Future<void> markStatusViewed({
    required String ownerUid,
    required String statusId,
    required String viewerUid,
  }) {
    final batch = _db.batch();
    batch.set(
      _db
          .collection('users')
          .doc(ownerUid)
          .collection('statuses')
          .doc(statusId)
          .collection('viewers')
          .doc(viewerUid),
      {'viewedAt': FieldValue.serverTimestamp()},
    );
    batch.update(
      _db.collection('users').doc(viewerUid),
      {'lastViewedStatusOwnerAt.$ownerUid': FieldValue.serverTimestamp()},
    );
    return batch.commit();
  }

  // Owner-only live list of who has viewed one specific status segment,
  // most-recent-view-first — matches WhatsApp's own viewers-list ordering.
  // firestore.rules' viewers/{viewerUid} `allow read` only lets ownerUid
  // list the full subcollection (a non-owner's request would simply be
  // rejected before this ever resolves, so no caller-side uid check is
  // needed here — same trust boundary as watchStatusFeed relying on its
  // own collectionGroup rule). Scoped to a single status's own viewers
  // subcollection, bounded by however many people viewed that one status —
  // not a scale concern, same reasoning as hasViewedStatus above.
  Stream<List<StatusViewer>> watchStatusViewers({
    required String ownerUid,
    required String statusId,
  }) {
    return _db
        .collection('users')
        .doc(ownerUid)
        .collection('statuses')
        .doc(statusId)
        .collection('viewers')
        .orderBy('viewedAt', descending: true)
        .snapshots()
        .map(
          (snap) => snap.docs
              .map((d) => StatusViewer.fromFirestore(d.id, d.data()))
              .toList(),
        );
  }

  // Plain client-side delete — firestore.rules already authorizes this
  // directly (`allow delete: if isSignedIn() && request.auth.uid ==
  // userId` on the status doc), no Cloud Function needed the way
  // deleteGroupChat needs server-side creator-immunity logic. The
  // already-deployed onStatusDeleted trigger handles cascade cleanup
  // (viewers subcollection + Storage media) after this delete lands.
  Future<void> deleteStatus({
    required String ownerUid,
    required String statusId,
  }) {
    return _db
        .collection('users')
        .doc(ownerUid)
        .collection('statuses')
        .doc(statusId)
        .delete();
  }

  // Server-side Storage copy — see functions/src/index.ts's
  // copyMediaToStatus for the full rationale (avoids a client
  // download+re-upload round trip when forwarding existing chat media
  // to a status; the source URL itself can't just be reused directly,
  // since chats/{chatId}/{fileName}'s read rule is chat-membership-based
  // while statuses/{ownerUid}/{fileName}'s is visibleToUids-based).
  // Returns the copied file's public download URL, ready to pass
  // straight into createStatus() without any further compress/upload
  // step. Same httpsCallable(...).call({...}) shape as toggleReaction/
  // deleteGroupChat above, on the same _functions instance.
  Future<String> copyMediaToStatus({
    required String sourceChatId,
    required String sourceFileName,
    required String statusId,
  }) async {
    final result = await _functions.httpsCallable('copyMediaToStatus').call({
      'sourceChatId': sourceChatId,
      'sourceFileName': sourceFileName,
      'statusId': statusId,
    });
    final path = result.data['path'] as String;
    return await FirebaseStorage.instance.ref(path).getDownloadURL();
  }

  // Reverse direction — forwarding a status' photo/video into a chat. See
  // functions/src/index.ts's copyStatusMediaToChat for the full
  // rationale (status media can't just be reused directly in a chat
  // message: firestore.rules' isValidatedMedia() requires a
  // mediaOriginChatId + validatedUploads marker that only a real chat
  // upload has, which the Cloud Function itself creates for the copy).
  // Returns both the copied file's own download URL and its bare
  // fileName (== mediaFileName), since the caller needs the fileName to
  // pass as mediaOriginChatId's companion when sending the actual
  // message — copyMediaToStatus's own caller (createStatus) never needed
  // this, since a status doesn't carry mediaOriginChatId/mediaFileName
  // fields at all.
  Future<({String downloadUrl, String fileName})> copyStatusMediaToChat({
    required String statusOwnerUid,
    required String statusId,
    required String targetChatId,
  }) async {
    final result = await _functions.httpsCallable('copyStatusMediaToChat').call({
      'statusOwnerUid': statusOwnerUid,
      'statusId': statusId,
      'targetChatId': targetChatId,
    });
    final path = result.data['path'] as String;
    final fileName = result.data['fileName'] as String;
    final downloadUrl = await FirebaseStorage.instance.ref(path).getDownloadURL();
    return (downloadUrl: downloadUrl, fileName: fileName);
  }

  // Storage path statuses/{ownerUid}/{fileName} — mirrors uploadChatImage's
  // chats/{chatId}/{fileName} shape below.
  String newStatusId(String ownerUid) {
    return _db.collection('users').doc(ownerUid).collection('statuses').doc().id;
  }

  Future<String> uploadStatusImage({
    required String ownerUid,
    required String statusId,
    required String filePath,
    required String fileName,
    void Function(UploadTask task)? onTaskStarted,
    void Function(double progress)? onProgress,
  }) async {
    final ref = FirebaseStorage.instance
        .ref()
        .child('statuses')
        .child(ownerUid)
        .child(fileName);
    final task = ref.putFile(
      File(filePath),
      SettableMetadata(customMetadata: {
        'uploaderUid': ownerUid,
        'statusId': statusId,
      }),
    );
    onTaskStarted?.call(task);
    if (onProgress != null) {
      task.snapshotEvents.listen((snapshot) {
        if (snapshot.totalBytes > 0) {
          onProgress(snapshot.bytesTransferred / snapshot.totalBytes);
        }
      });
    }
    await task;
    return await ref.getDownloadURL();
  }

  Future<String> uploadStatusVideo({
    required String ownerUid,
    required String statusId,
    required String filePath,
    required String fileName,
    void Function(UploadTask task)? onTaskStarted,
    void Function(double progress)? onProgress,
  }) async {
    final ref = FirebaseStorage.instance
        .ref()
        .child('statuses')
        .child(ownerUid)
        .child(fileName);
    final task = ref.putFile(
      File(filePath),
      SettableMetadata(customMetadata: {
        'uploaderUid': ownerUid,
        'statusId': statusId,
      }),
    );
    onTaskStarted?.call(task);
    if (onProgress != null) {
      task.snapshotEvents.listen((snapshot) {
        if (snapshot.totalBytes > 0) {
          onProgress(snapshot.bytesTransferred / snapshot.totalBytes);
        }
      });
    }
    await task;
    return await ref.getDownloadURL();
  }

  // Deliberately does NOT set visibleToUids — firestore.rules' allow
  // create on users/{uid}/statuses/{statusId} rejects any client-supplied
  // visibleToUids outright (see that rule's own comment), and the
  // onStatusCreated Cloud Function trigger computes the real value
  // server-side right after this write lands. expiresAt is a concrete
  // client-computed Timestamp, NOT FieldValue.serverTimestamp() — a
  // serverTimestamp() sentinel resolves to "now", not "now+24h", which
  // would break every consumer (watchStatusFeed's expiresAt filter,
  // Status.fromFirestore) expecting a real future expiry.
  Future<String> createStatus({
    required String statusId,
    required String ownerUid,
    required String type,
    String? mediaUrl,
    String? text,
    String? caption,
    required String privacyMode,
    List<String> privacyList = const [],
  }) async {
    await _db
        .collection('users')
        .doc(ownerUid)
        .collection('statuses')
        .doc(statusId)
        .set({
      'ownerUid': ownerUid,
      'type': type,
      if (mediaUrl != null) 'mediaUrl': mediaUrl,
      if (text != null) 'text': text,
      if (caption != null) 'caption': caption,
      'createdAt': FieldValue.serverTimestamp(),
      'expiresAt': Timestamp.fromDate(
        DateTime.now().toUtc().add(const Duration(hours: 24)),
      ),
      'privacyMode': privacyMode,
      'privacyList': privacyList,
    });
    return statusId;
  }

  // Deterministic pair id — sorted so it's the same regardless of who
  // initiates, mirroring friendRequestDocId's own reasoning above. This is
  // what lets set(..., merge: true) be race-safe with no transaction: a
  // simultaneous tap from both sides either both hit `create` (whichever
  // Firestore serializes first) or one `create` + one `update`, and
  // firestore.rules' chats update rule already allows any current member
  // to write as long as members/admins don't actually change (see that
  // rule's own comment) — which merge-writing the identical members list
  // never does.
  String directChatDocId(String uidA, String uidB) {
    final sorted = [uidA, uidB]..sort();
    return '${sorted[0]}_${sorted[1]}';
  }

  // Finds or creates the 1:1 chat between two users, for flows (like a
  // status reply/reaction, or the "Mesaj" button on a user's profile card)
  // that may be the first-ever message between two friends. mugam-v2 (the
  // old React Native app this project migrated away from) used to create
  // 1:1 chats itself via a random addDoc() id — now retired, no longer
  // sending or creating new messages/chats — so any such doc still in the
  // collection is fixed, historical data, not something new ones keep
  // appearing alongside going forward.
  //
  // Fast path: the deterministic id alone, ONE cheap document read — this
  // is deliberately not "always scan every chat this uid has and pick the
  // most recently active one" (a version of this function briefly did
  // exactly that, to guard against a legacy mugam-v2 doc being more
  // recently active than the deterministic one): with mugam-v2 retired,
  // that reconciliation is only ever relevant for the fixed set of pairs
  // that already have such a legacy doc, not an ongoing risk, and paying a
  // full collection query on every single tap of "Mesaj" — confirmed
  // on-device as a real, noticeable slowdown — is the wrong tradeoff for a
  // concern that no longer grows. Callers that already have this uid's
  // Chat list loaded (chats_screen.dart, the "Mesaj" button) check that
  // list's own most-recently-active pick FIRST and only call this function
  // at all as a fallback — see those call sites' own comments.
  //
  // Legacy fallback query only runs when the deterministic doc doesn't
  // exist yet at all — covers a pre-existing mugam-v2-era chat for this
  // pair from before this app ever wrote to it. If more than one such
  // legacy chat somehow exists, picks the most recently active one rather
  // than an arbitrary/query-order one, and never throws over it. Only
  // creates a new doc (at the deterministic id) when neither exists.
  // Deliberately drops mugam-v2's initiatorUid/INVITES-collection fields —
  // that's specific to its musician-matching flow and has no equivalent
  // here (this app's friend system is symmetric — see [[mugam-friends]]).
  Future<String> getOrCreateDirectChat({
    required String myUid,
    required String otherUid,
  }) async {
    final detId = directChatDocId(myUid, otherUid);
    final detDoc = await _db.collection('chats').doc(detId).get().timeout(_writeTimeout);
    if (detDoc.exists) return detId;

    final legacyMatches = await _db
        .collection('chats')
        .where('members', arrayContains: myUid)
        .get()
        .timeout(_writeTimeout);
    final legacyChats = legacyMatches.docs.where((d) {
      final data = d.data();
      if (data['isGroup'] == true) return false;
      final members = List<String>.from(
        data['members'] as List? ?? const [],
      );
      return members.contains(otherUid);
    }).toList();
    if (legacyChats.isNotEmpty) {
      legacyChats.sort((a, b) {
        final aTime = a.data()['lastMessageTime'] as Timestamp?;
        final bTime = b.data()['lastMessageTime'] as Timestamp?;
        // Stable tiebreaker (doc id) when both sides are null — Firestore
        // makes no ordering guarantee for a query with no orderBy, so
        // returning 0 here let the SAME two-null-lastMessageTime pair
        // resolve to a DIFFERENT "first" legacy chat on different runs of
        // this exact query — confirmed on-device as the same contact
        // opening a different historical chat on every fresh app launch.
        if (aTime == null && bTime == null) return a.id.compareTo(b.id);
        if (aTime == null) return 1;
        if (bTime == null) return -1;
        return bTime.compareTo(aTime);
      });
      return legacyChats.first.id;
    }

    final now = FieldValue.serverTimestamp();
    await _db.collection('chats').doc(detId).set({
      'isGroup': false,
      'members': [myUid, otherUid],
      // `preview` снято вместе с N76 — его не читал никто.
      'lastMessageAt': now,
      'lastMessageTime': now,
      'createdAt': now,
      'unreadCount': <String, int>{},
    }, SetOptions(merge: true)).timeout(_writeTimeout);
    return detId;
  }

  // Mirrors mugam-v2's createGroupChat() Firestore write shape exactly
  // (isGroup, name, emoji, photoURL, members, admins, createdBy, preview,
  // timestamps, completed, unreadCount — see mugam-v2/src/firebase/
  // firestore.ts) so both apps' group chats are structurally identical.
  // One deliberate difference: the "X created the group" system message is
  // written with senderId == the real creator's uid (not the literal
  // string 'system' mugam-v2 uses), specifically so the already-existing
  // onNewMessage Cloud Function push trigger resolves a real display name
  // and fires correctly on its own — mugam-v2 instead sends its own push
  // directly from the client (reading every recipient's push tokens
  // itself), which this app deliberately never does anywhere else; adding
  // that pattern here just for groups would be a step backward, not
  // matching a standard.
  Future<String> createGroupChat({
    required String creatorUid,
    required String creatorName,
    required String groupName,
    required List<String> memberUids,
    required String emoji,
    String? photoURL,
  }) async {
    final members = [
      creatorUid,
      ...memberUids.where((u) => u != creatorUid),
    ];
    final now = FieldValue.serverTimestamp();
    final chatRef = await _db.collection('chats').add({
      'isGroup': true,
      'name': groupName,
      'emoji': emoji,
      'photoURL': photoURL,
      'members': members,
      'admins': [creatorUid],
      'createdBy': creatorUid,
      // Поле `preview` здесь было и не читалось НИКЕМ (обход по `lib/` и
      // `functions/` 08.08 — ноль чтений): карточку рисует `lastMessage`,
      // который пишет сервер триггером на системном сообщении ниже.
      // Снято вместе с N76, чтобы не выглядело источником превью.
      'lastMessageAt': now,
      'lastMessageTime': now,
      'createdAt': now,
      'unreadCount': <String, int>{},
      // First message written below gets seq 1 directly (no transaction —
      // the chat doc doesn't exist for anyone else to race yet).
      'messageSeq': 1,
    });

    await chatRef.collection('messages').add({
      'senderId': creatorUid,
      'text': '$creatorName qrupu yaratdı',
      'type': 'text',
      'isSystem': true,
      'seq': 1,
      // Display-only wall-clock time — ordering is `seq`.
      'timestamp': Timestamp.now(),
    });

    return chatRef.id;
  }

  // Uses a transaction because we may need to both remove `uid` from
  // `admins` AND add a newly-promoted admin in the same write —
  // Firestore doesn't allow arrayRemove and arrayUnion on the same
  // field in one update, so the new `admins` array must be computed
  // client-side and written as a plain list, inside a transaction to
  // avoid racing a concurrent membership/role change.
  //
  // The system message MUST be written before the transaction, not
  // after: firestore.rules' isChatMember() (required by the messages
  // subcollection's `allow create`) reads the chat doc's CURRENT
  // committed `members` array. If the transaction removing `uid` from
  // `members` ran first, the leaving user would already be gone from
  // that array by the time the message write's rule check runs —
  // guaranteeing permission-denied on every single leave, for every
  // member, deterministically (confirmed via on-device testing — this
  // isn't a race condition, the ordering makes it 100% reproducible).
  // Deliberately two sequential awaits rather than folding the message
  // write into the same transaction too: we haven't verified how
  // security rules' cross-document reads behave for a second write's
  // rule evaluation from inside an in-flight transaction (pre- vs.
  // mid-transaction state), so two plain sequential writes — correctly
  // ordered — is the fix that doesn't require guessing about that.
  //
  // Known, accepted tradeoff: if the system-message write succeeds but
  // the transaction below then fails for an unrelated reason (e.g. a
  // transient network error), the chat briefly shows "X left the
  // group" while X is technically still a member. Minor and unlikely
  // versus the previous 100%-reproducible failure this replaces.
  Future<void> leaveGroup({
    required String chatId,
    required String uid,
    required String userName,
  }) async {
    final chatRef = _db.collection('chats').doc(chatId);

    await _commitMessage(
      chatId: chatId,
      data: {
        'senderId': uid,
        'text': '$userName qrupdan çıxdı',
        'type': 'text',
        'isSystem': true,
        // Display-only wall-clock time — ordering is `seq`.
        'timestamp': Timestamp.now(),
      },
    );

    await _db.runTransaction((tx) async {
      final snap = await tx.get(chatRef);
      final data = snap.data() ?? {};
      // Одно правило на оба пути ухода — см. chat_departure.dart. Здесь
      // же снимается и `activeUsers`: отметка присутствия не должна
      // переживать членство.
      final after = chatAfterDeparture(
        members: List<String>.from(data['members'] as List? ?? const []),
        admins: List<String>.from(data['admins'] as List? ?? const []),
        activeUsers: List<String>.from(
          data['activeUsers'] as List? ?? const [],
        ),
        uid: uid,
      );

      final remainingAdmins = List<String>.from(after.admins);
      // WhatsApp-style guarantee: a group is never left without an admin —
      // if the sole admin leaves and members remain, randomly promote one.
      if (after.needsAdminPromotion) {
        remainingAdmins.add(
          after.members[Random().nextInt(after.members.length)],
        );
      }

      tx.update(chatRef, {
        'members': after.members,
        'admins': remainingAdmins,
        'activeUsers': after.activeUsers,
      });
    });
  }

  Future<void> addGroupMember({
    required String chatId,
    required String uid,
    required String userName,
    required String addedByName,
    required String adminUid,
  }) async {
    final chatRef = _db.collection('chats').doc(chatId);
    await chatRef.update({
      'members': FieldValue.arrayUnion([uid]),
    });

    await _commitMessage(
      chatId: chatId,
      data: {
        'senderId': adminUid,
        'text': '$addedByName $userName qrupa əlavə etdi',
        'type': 'text',
        'isSystem': true,
        // Display-only wall-clock time — ordering is `seq`.
        'timestamp': Timestamp.now(),
      },
    );
  }

  // Client-side creator protection: mugam-v2 has no check anywhere (neither
  // in removeGroupMember nor properly enforced in GroupInfo.tsx's UI —
  // verified by reading its source) preventing an admin from removing the
  // group's own createdBy uid, which would leave the group creatorless.
  // This is that missing guard, added here rather than left as a gap to
  // copy — a rules-level version of the same protection is planned for a
  // later phase; this is the client-side layer, not a replacement for it.
  Future<void> removeGroupMember({
    required String chatId,
    required String uid,
    required String userName,
    required String removedByName,
    required String adminUid,
  }) async {
    final chatRef = _db.collection('chats').doc(chatId);
    // Транзакция, а не чтение с последующей записью: правило ухода одно на
    // оба пути (chat_departure.dart) и работает со списками целиком, а
    // список, вычисленный по снимку вне транзакции, затёр бы чужую
    // одновременную правку. Заодно проверка «создателя не удаляют»
    // перестала опираться на снимок, устаревший к моменту записи.
    await _db.runTransaction((tx) async {
      final snap = await tx.get(chatRef);
      final data = snap.data() ?? {};
      if (uid == data['createdBy']) {
        throw Exception('Cannot remove the group creator');
      }

      // Повышение администратора здесь не делается и не делалось: этот путь
      // ведёт админ, и без администратора группа после него не остаётся.
      final after = chatAfterDeparture(
        members: List<String>.from(data['members'] as List? ?? const []),
        admins: List<String>.from(data['admins'] as List? ?? const []),
        activeUsers: List<String>.from(
          data['activeUsers'] as List? ?? const [],
        ),
        uid: uid,
      );

      tx.update(chatRef, {
        'members': after.members,
        'admins': after.admins,
        'activeUsers': after.activeUsers,
      });
    });

    await _commitMessage(
      chatId: chatId,
      data: {
        'senderId': adminUid,
        'text': '$removedByName $userName qrupdan çıxardı',
        'type': 'text',
        'isSystem': true,
        // Display-only wall-clock time — ordering is `seq`.
        'timestamp': Timestamp.now(),
      },
    );
  }

  Future<void> makeGroupAdmin({
    required String chatId,
    required String uid,
    required String userName,
    required String adminUid,
    required String adminName,
  }) async {
    final chatRef = _db.collection('chats').doc(chatId);
    await chatRef.update({
      'admins': FieldValue.arrayUnion([uid]),
    });

    await _commitMessage(
      chatId: chatId,
      data: {
        'senderId': adminUid,
        'text': '$adminName $userName-ni admin etdi',
        'type': 'text',
        'isSystem': true,
        // Display-only wall-clock time — ordering is `seq`.
        'timestamp': Timestamp.now(),
      },
    );
  }

  // Two client-side checks, both before any write:
  //  - Creator immunity: the group's createdBy uid can never be dismissed
  //    as admin, same protection as removeGroupMember in Phase C.
  //  - Last-admin guarantee: dismissing `uid` may not leave `admins`
  //    empty. This differs from leaveGroup's sole-admin case (which
  //    auto-promotes a replacement, since someone is actually leaving the
  //    group there) — here both people remain members, so there's no one
  //    to silently promote and blocking the action is the correct
  //    behavior instead.
  Future<void> dismissAsAdmin({
    required String chatId,
    required String uid,
    required String userName,
    required String adminUid,
    required String adminName,
  }) async {
    final chatRef = _db.collection('chats').doc(chatId);
    final snap = await chatRef.get();
    final data = snap.data() ?? {};
    if (uid == data['createdBy']) {
      throw Exception('Cannot dismiss the group creator as admin');
    }
    final admins = List<String>.from(data['admins'] as List? ?? const []);
    if (admins.where((a) => a != uid).isEmpty) {
      throw Exception('Cannot dismiss the last remaining admin');
    }

    await chatRef.update({
      'admins': FieldValue.arrayRemove([uid]),
    });

    await _commitMessage(
      chatId: chatId,
      data: {
        'senderId': adminUid,
        'text': '$adminName $userName-ni admin statusundan çıxardı',
        'type': 'text',
        'isSystem': true,
        // Display-only wall-clock time — ordering is `seq`.
        'timestamp': Timestamp.now(),
      },
    );
  }

  // No system message: renaming/re-emoji-ing a group is cosmetic, not an
  // event worth announcing — mugam-v2's own updateGroupInfo has no
  // addDoc/system-message call either.
  Future<void> updateGroupInfo({
    required String chatId,
    required String name,
    required String emoji,
    String? photoURL,
  }) async {
    await _db.collection('chats').doc(chatId).update({
      'name': name,
      'emoji': emoji,
      'photoURL': ?photoURL,
    });
  }

  // Mirrors uploadAvatar's shape above rather than mugam-v2's XHR/blob
  // upload (a React Native-specific pattern that doesn't apply here).
  // Returns the URL only, same as every other upload* function in this
  // file — none of them write the URL back to Firestore themselves, that's
  // left to the caller (see updateGroupInfo's own photoURL param above).
  Future<String> uploadGroupPhoto({
    required String chatId,
    required String uri,
  }) async {
    final ref = FirebaseStorage.instance
        .ref()
        .child('groups')
        .child(chatId)
        .child('avatar.jpg');
    await ref.putFile(File(uri));
    return await ref.getDownloadURL();
  }

  // Client-side document deletion is denied entirely by firestore.rules —
  // this goes through the deleteGroupChat Cloud Function instead (Admin SDK,
  // bypasses rules), which re-verifies server-side that the caller is the
  // group's creator AND still a member (Phase G) before deleting the chat
  // doc and batch-deleting its messages subcollection. Same
  // httpsCallable(...).call({...}) shape as toggleReaction above, on the
  // same europe-west3 _functions instance.
  Future<void> deleteGroupChat(String chatId) async {
    await _functions.httpsCallable('deleteGroupChat').call({
      'chatId': chatId,
    });
  }

  // One-off lookup for a single message by id, regardless of whether it's
  // within the currently-loaded window (finding #4) — used by
  // message_info_screen.dart to resolve the read/delivered comparison by
  // timestamp instead of by position in a (now possibly-partial) messages
  // list, since a paginated list has no stable notion of "index" for a
  // message outside whatever's currently loaded.
  Future<Message?> fetchMessageById({
    required String chatId,
    required String messageId,
  }) async {
    final doc = await _db
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .doc(messageId)
        .get();
    if (!doc.exists) return null;
    return Message.fromFirestore(doc.id, doc.data()!);
  }

  // Live tail window only (finding #4) — the most recent
  // messageTailWindowSize messages, not the entire history. Older messages
  // are loaded on demand via fetchOlderMessages/watchOlderMessagesInRange
  // (see ChatMessagesController), which also keeps them live once loaded
  // rather than trading real-time reactions/read-receipts away for the
  // memory/read-cost savings this limit exists for.
  //
  // A plain Stream<List<Message>> — ChatMessagesController is purely a sync
  // writer for whatever this delivers (upserting into LocalMessageStore,
  // see that class's own doc comment); "is this genuinely a new message,
  // and should the UI auto-scroll for it" is no longer this stream's
  // concern at all. That used to be tracked here (an isFirst-scoped
  // isInitialLoad/addedMessageIds pair derived from Firestore's own
  // docChanges), but that signal didn't actually mean "a new message
  // appeared in what the UI renders" — a message THIS device just sent
  // reports as freshly `added` here the same as one from someone else,
  // even though it was already visible as a pending row before this
  // listener ever confirmed it. ChatMessagesController now derives that
  // signal correctly instead, by diffing LocalMessageStore's own
  // before/after snapshots — the one place that actually knows what was or
  // wasn't already rendered.
  Stream<List<Message>> watchMessages(String chatId) {
    return _db
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .orderBy('seq', descending: false)
        .limitToLast(messageTailWindowSize)
        .snapshots()
        .map(
          (snap) => snap.docs
              .map((doc) => Message.fromFirestore(doc.id, doc.data()))
              .toList(),
        );
  }

  // One-time fetch of the page immediately older than beforeSeq —
  // triggered by scrolling near the top of the loaded history. Not a live
  // listener itself; ChatMessagesController separately widens
  // watchOlderMessagesInRange's upper bound to cover whatever this returns,
  // so the newly-loaded page still gets live reaction/read-receipt updates
  // going forward.
  Future<List<Message>> fetchOlderMessages({
    required String chatId,
    required int beforeSeq,
    int limit = messageTailWindowSize,
  }) async {
    final snap = await _db
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .orderBy('seq', descending: false)
        .endBefore([beforeSeq])
        .limitToLast(limit)
        .get();
    return snap.docs
        .map((doc) => Message.fromFirestore(doc.id, doc.data()))
        .toList();
  }

  // Live listener scoped to [fromSeq, toSeq) — everything paginated in via
  // fetchOlderMessages so far, up to (but deliberately not overlapping) the
  // live tail window's own oldest message. Kept as its own listener rather
  // than folding into watchMessages' unbounded query so the tail stays
  // fixed at messageTailWindowSize regardless of how much history has been
  // paginated in during this session — ChatMessagesController is what
  // recreates this with a wider toSeq as the tail's own oldest message
  // shifts forward over time.
  Stream<List<Message>> watchOlderMessagesInRange({
    required String chatId,
    required int fromSeq,
    required int toSeq,
  }) {
    return _db
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .orderBy('seq', descending: false)
        .startAt([fromSeq])
        .endBefore([toSeq])
        .snapshots()
        .map(
          (snap) => snap.docs
              .map((doc) => Message.fromFirestore(doc.id, doc.data()))
              .toList(),
        );
  }

  // All image/video messages in a chat, for a media thumbnail strip.
  // deletedForAll is filtered CLIENT-side here, not via a Firestore
  // `.where('deletedForAll', isEqualTo: false)` — that was tried first and
  // silently broke the thumbnail strip for nearly every chat: sendImage/
  // VideoMessage never write a `deletedForAll` field at all (it's only
  // ever set, to true, by deleteMessageForAll), so almost every real
  // message has no `deletedForAll` field whatsoever, and a Firestore
  // equality filter never matches a document where the field is entirely
  // absent — the query was excluding nearly all media, not just deleted
  // media. Filtering client-side on the mapped List<Message> instead
  // (Message.fromFirestore's own `data['deletedForAll'] ?? false` default
  // makes the absent-vs-false distinction irrelevant once it's a Dart
  // bool) sidesteps that gotcha entirely, matching how deletedFor
  // (per-user delete) is already filtered client-side everywhere else in
  // this file (see chat_screen.dart's
  // `.where((m) => !m.deletedFor.contains(currentUid))`) rather than in a
  // query. Deliberately still does NOT filter the per-user `deletedFor`
  // array here — Firestore has no "array does not contain" query, and
  // this method's own caller is expected to apply that same client-side
  // filter itself, same as chat_screen.dart does for the main message list.
  Stream<List<Message>> watchChatMedia(String chatId) {
    return _db
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .where('type', whereIn: ['image', 'video'])
        // Живой слушатель ограничен окном самых свежих медиа (B33) —
        // раньше он держал подписку на все медиа чата разом. Запрос идёт
        // по убыванию seq именно ради этого: с limit по возрастанию в
        // окно попали бы самые СТАРЫЕ медиа, то есть ровно не те.
        .orderBy('seq', descending: true)
        .limit(chatMediaWindowSize)
        .snapshots()
        // Пустой снимок ИЗ КЭША — не ответ, а молчание (N14). Тот же
        // признак и та же узость, что у watchChats: пусто с сервера —
        // настоящий ответ, непустое из кэша — настоящие данные; молчание
        // это только два условия вместе. Не отдавая такой снимок, поток
        // оставляет провайдер в состоянии загрузки, и экран рисует
        // ожидание вместо пустоты, выданной за факт.
        .where((snap) => !(snap.docs.isEmpty && snap.metadata.isFromCache))
        .map(
          (snap) => snap.docs
              .map((doc) => Message.fromFirestore(doc.id, doc.data()))
              .where((m) => !m.deletedForAll)
              // Обратно по возрастанию: порядок ленты и полосы превью —
              // часть контракта этого потока, окном он меняться не должен.
              .toList()
              .reversed
              .toList(),
        );
  }

  Map<String, dynamic>? _buildReplyTo({
    String? replyToId,
    String? replyToText,
    String? replyToSenderName,
    String? replyToImageURL,
    String? replyToVideoURL,
  }) {
    if (replyToId == null) return null;
    final map = <String, dynamic>{
      'id': replyToId,
      'text': replyToText ?? '',
      'senderName': replyToSenderName ?? '',
    };
    if (replyToImageURL != null) {
      map['imageURL'] = replyToImageURL;
    }
    if (replyToVideoURL != null) {
      map['videoURL'] = replyToVideoURL;
    }
    return map;
  }

  // Mirrors _buildReplyTo above exactly, but as its own separate nested map
  // (replyToStatus, not replyTo) — see Message.replyToStatusId's own doc
  // comment for why a status reply is never written through the replyTo
  // fields/map. ownerUid is required (not just id) because
  // UserStatusViewerScreen needs it up front to fetch the author's status
  // group; if it's missing there's nothing a tap handler could open, so
  // treat that the same as replyToStatusId itself being absent.
  Map<String, dynamic>? _buildReplyToStatus({
    String? replyToStatusId,
    String? replyToStatusOwnerUid,
    String? replyToStatusType,
    String? replyToStatusText,
    String? replyToStatusThumbnailURL,
  }) {
    if (replyToStatusId == null || replyToStatusOwnerUid == null) {
      return null;
    }
    final map = <String, dynamic>{
      'id': replyToStatusId,
      'ownerUid': replyToStatusOwnerUid,
      'type': replyToStatusType ?? 'text',
      'text': replyToStatusText ?? '',
    };
    if (replyToStatusThumbnailURL != null) {
      map['thumbnailURL'] = replyToStatusThumbnailURL;
    }
    return map;
  }

  // Generates a message doc id client-side, up front, before any upload or
  // send attempt — used by the pending-media queue so every retry of the
  // same queued item writes to the same doc via sendXMessage's messageId
  // param instead of creating a new document each time.
  String generateMessageId(String chatId) {
    return _db.collection('chats').doc(chatId).collection('messages').doc().id;
  }

  // Every send function funnels through here. Assigns `seq` — a per-chat
  // monotonic integer bumped in the same transaction as the message write —
  // as the ONE source of truth for message order
  // (watchMessages/fetchOlderMessages/watchOlderMessagesInRange/
  // _findLastMessage/watchChatMedia all orderBy('seq') now, not 'timestamp').
  // Unlike a timestamp, this is assigned synchronously server-side inside
  // the transaction, so it's never null in the local cache and never
  // dependent on device clock accuracy — the class of bug that motivated
  // this (see the git history around 2026-07-31: FieldValue.serverTimestamp()
  // resolving to null pre-ack made freshly-sent messages sort as the oldest
  // message and briefly vanish from watchMessages' limitToLast(50) window)
  // is structurally impossible with seq.
  //
  // The counter itself lives at chats/{chatId}/meta/counters — a document
  // this transaction has ALL to itself — rather than on the main chat doc.
  // It used to live there (a plain `messageSeq` field), which meant every
  // single message send transactionally contended with every other write to
  // that same document: typing.{uid} (every ~3s while a job offer is
  // pending), lastReadAt/lastReadMsgId/unreadCount (markChatAsReadBy),
  // deliveredTo, activeUsers, negotiationSeenAt, etc. Confirmed on-device
  // (2026-08-01) as a real cause of stuck sends: under that contention a
  // send's transaction could take longer than this method's own timeout,
  // the client would give up and retry with an overlapping second
  // transaction attempt (same idempotent messageId), and Firestore's own
  // automatic retry-on-conflict for BOTH attempts made the whole thing even
  // slower — a message could end up never landing before
  // pendingQueueMaxAttempts ran out, despite the server eventually being
  // willing to accept it. Isolating the counter removes the contention at
  // its root instead of just widening the timeout around it (see
  // MessageSendController's own backoff/timeout comments for the other half
  // of this fix).
  //
  // Migration: existing chats already have a `messageSeq` field on their
  // main doc from before this counter moved. The first send after this
  // change seeds chats/{chatId}/meta/counters from that old field's current
  // value, INSIDE this same transaction (not a separate read beforehand) —
  // that's what makes the seed itself race-safe: if two sends race to be
  // the first to seed, Firestore's transaction conflict detection forces
  // the loser to retry, and its retry sees the winner's freshly-created
  // counter doc instead of re-seeding from the same stale base (which would
  // otherwise hand out the same seq to two different messages). The old
  // `messageSeq` field on the main chat doc is left as-is (harmless,
  // unread by anything after this change) rather than cleaned up — deleting
  // it isn't worth a second write for a value nothing looks at anymore.
  //
  // messageId (when provided, by the offline pending-send queue) keeps the
  // exact same idempotent-retry guarantee _writeMessageIfAbsent used to
  // provide on its own: every retry path (manual retry, per-chat auto-retry
  // on reconnect, the WorkManager background task, and the app-restart
  // re-queue) reuses the same messageId generated once at enqueue time
  // (generateMessageId above), so "already exists" here means a previous
  // attempt already committed — a no-op, not a second seq/write.
  //
  // Writes NOTHING to the chat document itself — not the preview, not any
  // counter. That used to happen here (a `chatUpdate` map each send method
  // passed in) and went through two wrong shapes before this one: awaited,
  // it put a network round trip on the critical send path and made slow
  // acks look like failed sends; fire-and-forget, it silently lost the
  // preview whenever the process died first. Both were attempts to solve
  // "when should the client write this", when the answer is that the
  // client shouldn't. onNewMessage (functions/src/index.ts) derives the
  // preview from the message document this transaction creates, ordered
  // against every other writer by lastMessageSeq — see that file for the
  // full ordering rules.
  //
  // Returns (wrote, seq): `seq` is always populated on a non-throwing
  // return — even the idempotent-retry "already exists" case reads the
  // existing doc's own seq back rather than just reporting `false` with no
  // seq, because LocalMessageStore.markConfirmed (see that class's doc
  // comment) needs the real seq value either way to update this device's
  // own pending row in place, whether THIS call is what originally wrote
  // it or an earlier attempt already did.
  Future<(bool wrote, int seq)> _commitMessage({
    required String chatId,
    required Map<String, dynamic> data,
    String? messageId,
  }) async {
    final chatRef = _db.collection('chats').doc(chatId);
    final counterRef = chatRef.collection('meta').doc('counters');
    final messageRef = messageId != null
        ? chatRef.collection('messages').doc(messageId)
        : chatRef.collection('messages').doc();
    // Seed floor for a chat whose counter doc doesn't exist yet — computed
    // OUTSIDE the transaction because the Flutter SDK's transactions can
    // only tx.get() a DocumentReference, never run a query. Racing two
    // first-ever sends is still safe: both read the same floor, but only
    // one's tx.set(counterRef) wins; the loser's transaction conflicts on
    // that same document and re-runs, and its re-run sees the winner's
    // counter doc and takes the normal (already-seeded) branch instead.
    final int seedFloor = await _resolveSeedFloor(chatId, chatRef, counterRef);
    final (wrote, seq) = await _db.runTransaction<(bool, int)>((tx) async {
      if (messageId != null) {
        final existing = await tx.get(messageRef);
        if (existing.exists) {
          final existingSeq = (existing.data()?['seq'] as num?)?.toInt() ?? 0;
          return (false, existingSeq);
        }
      }
      final counterSnap = await tx.get(counterRef);
      final baseSeq = counterSnap.exists
          ? (counterSnap.data()?['messageSeq'] as num?)?.toInt() ?? 0
          : seedFloor;
      final nextSeq = baseSeq + 1;
      tx.set(messageRef, {...data, 'seq': nextSeq});
      tx.set(counterRef, {'messageSeq': nextSeq});
      return (true, nextSeq);
    });
    // The transaction above just wrote it if it didn't exist, so every
    // later send in this session can skip _resolveSeedFloor's probe.
    _seededCounterChats.add(chatId);
    return (wrote, seq);
  }

  // What a not-yet-created chats/{chatId}/meta/counters doc should start
  // from. Returns 0 (the normal case) for a brand-new chat with no
  // messages, so the first message gets seq 1.
  //
  // Deliberately the MAX of the newest existing message's own seq and the
  // legacy `messageSeq` field on the chat doc, not just the legacy field:
  // that field stops being maintained the moment this chat's counter doc
  // exists, so it's frozen at whatever it held on migration day. Seeding
  // from it alone would be correct exactly once — but if the counter doc
  // were ever removed (a stray console delete, a future cleanup script, a
  // member exercising the rules' write permission), the next send would
  // re-seed from that stale value and hand out a seq that a message
  // already has. Duplicate seqs don't just misorder the list, they break
  // startAt/endBefore pagination (both bounds are seq values) in a way
  // that's very hard to trace back here. Reading the real newest message
  // makes re-seeding idempotent and self-correcting instead.
  //
  // Short-circuited by _seededCounterChats so this costs one extra document
  // read per chat per app session, not one per message sent.
  Future<int> _resolveSeedFloor(
    String chatId,
    DocumentReference<Map<String, dynamic>> chatRef,
    DocumentReference<Map<String, dynamic>> counterRef,
  ) async {
    if (_seededCounterChats.contains(chatId)) return 0;
    try {
      final counterProbe = await counterRef.get().timeout(_writeTimeout);
      if (counterProbe.exists) {
        _seededCounterChats.add(chatId);
        return 0; // unused — tx takes the already-seeded path
      }
      final newest = await chatRef
          .collection('messages')
          .orderBy('seq', descending: true)
          .limit(1)
          .get()
          .timeout(_writeTimeout);
      final newestSeq = newest.docs.isEmpty
          ? 0
          : (newest.docs.first.data()['seq'] as num?)?.toInt() ?? 0;
      final chatSnap = await chatRef.get().timeout(_writeTimeout);
      final legacySeq =
          (chatSnap.data()?['messageSeq'] as num?)?.toInt() ?? 0;
      return newestSeq > legacySeq ? newestSeq : legacySeq;
    } catch (e, st) {
      // Never blocks a send on this probe — the transaction re-reads the
      // counter doc itself and only consults this floor when that doc is
      // genuinely absent. Returning 0 here for an existing chat would be
      // wrong, so this is logged rather than silently swallowed.
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'FirestoreService: _resolveSeedFloor probe failed',
      );
      return 0;
    }
  }

  // Returns the message's assigned seq (see _commitMessage) — the pending-
  // send queue/retry loop uses it to update LocalMessageStore's local row
  // in place once the send is confirmed.
  Future<int> sendMessage({
    required String chatId,
    required String senderId,
    required String text,
    // How many times this message has already been forwarded — 0 for a
    // normal send. See sendImageMessage's own forwardCount doc comment.
    int forwardCount = 0,
    String? replyToId,
    String? replyToText,
    String? replyToSenderName,
    String? replyToImageURL,
    String? replyToVideoURL,
    String? replyToStatusId,
    String? replyToStatusOwnerUid,
    String? replyToStatusType,
    String? replyToStatusText,
    String? replyToStatusThumbnailURL,
    // If provided, writes with .doc(messageId).set(...) instead of .add(...)
    // — same idempotency purpose as sendImageMessage's messageId param, used
    // by the offline pending-send queue so a retry of the same queued text
    // message overwrites rather than duplicates.
    String? messageId,
  }) async {
    final replyTo = _buildReplyTo(
      replyToId: replyToId,
      replyToText: replyToText,
      replyToSenderName: replyToSenderName,
      replyToImageURL: replyToImageURL,
      replyToVideoURL: replyToVideoURL,
    );
    final replyToStatus = _buildReplyToStatus(
      replyToStatusId: replyToStatusId,
      replyToStatusOwnerUid: replyToStatusOwnerUid,
      replyToStatusType: replyToStatusType,
      replyToStatusText: replyToStatusText,
      replyToStatusThumbnailURL: replyToStatusThumbnailURL,
    );
    final data = {
      'senderId': senderId,
      'text': text,
      'type': 'text',
      'clientPlatform': 'flutter',
      'forwardCount': forwardCount,
      // Display-only wall-clock time (the HH:mm bubble time) — ordering is
      // `seq`, assigned by _commitMessage, not this field. See its own doc
      // comment.
      'timestamp': Timestamp.now(),
      'imageURL': null,
      'audioURL': null,
      if (replyTo != null) 'replyTo': replyTo,
      if (replyToStatus != null) 'replyToStatus': replyToStatus,
    };
    final (_, seq) = await _commitMessage(
      chatId: chatId,
      data: data,
      messageId: messageId,
    );
    return seq;
  }

  // customMetadata is enforced by storage.rules (uploaderUid/chatId must
  // match the real request.auth.uid and the path's chatId, or the write is
  // rejected outright) — by the time onChatMediaUploaded's onFinalize
  // trigger reads it back, it's guaranteed authentic, not just
  // self-reported. fileName is caller-provided (derived from the
  // already-idempotent messageId, not DateTime.now()) so retries of the
  // same queued item always target the same Storage object instead of
  // orphaning a fresh one on every attempt.
  // onTaskStarted hands the caller the live UploadTask the moment it's
  // created — the offline queue uses this to keep a reference it can
  // .cancel() if the user taps the in-progress upload's cancel button,
  // rather than just hiding the item while the transfer keeps running
  // unseen in the background. onProgress reports real bytesTransferred/
  // totalBytes fractions off the same task's snapshotEvents, for the
  // WhatsApp-style circular progress ring — not a decorative animation.
  Future<String> uploadChatImage({
    required String chatId,
    required String filePath,
    required String senderId,
    required String fileName,
    void Function(UploadTask task)? onTaskStarted,
    void Function(double progress)? onProgress,
  }) async {
    final ref = FirebaseStorage.instance
        .ref()
        .child('chats')
        .child(chatId)
        .child(fileName);
    final task = ref.putFile(
      File(filePath),
      SettableMetadata(
        customMetadata: {'uploaderUid': senderId, 'chatId': chatId},
      ),
    );
    onTaskStarted?.call(task);
    if (onProgress != null) {
      task.snapshotEvents.listen((snapshot) {
        if (snapshot.totalBytes > 0) {
          onProgress(snapshot.bytesTransferred / snapshot.totalBytes);
        }
      });
    }
    await task;
    return await ref.getDownloadURL();
  }

  // Returns the message's assigned seq — see sendMessage's own doc comment.
  Future<int> sendImageMessage({
    required String chatId,
    required String senderId,
    required String imageURL,
    int? imageWidth,
    int? imageHeight,
    // Optional caption sent alongside the photo — same 'text' field every
    // message type already carries, just populated here instead of left
    // as ''. Used by forwarding-with-a-caption today; a first-send caption
    // UI could reuse the same param later.
    String caption = '',
    // How many times this message has already been forwarded — 0 for a
    // normal send, msg.forwardCount + 1 when _forwardMessage builds a
    // forwarded copy (chat_screen.dart). Drives the "Yönləndirilib" bubble
    // label — see Message.forwardCount.
    int forwardCount = 0,
    // Which validated upload this image actually is: mediaOriginChatId ==
    // chatId for a fresh send, or an earlier chat's id when forwarding an
    // existing message's photo. Required (by firestore.rules) for every
    // flutter-sent image message — see Message.mediaOriginChatId.
    String? mediaOriginChatId,
    String? mediaFileName,
    String? replyToId,
    String? replyToText,
    String? replyToSenderName,
    String? replyToImageURL,
    String? replyToVideoURL,
    String? replyToStatusId,
    String? replyToStatusOwnerUid,
    String? replyToStatusType,
    String? replyToStatusText,
    String? replyToStatusThumbnailURL,
    // If provided, writes with .doc(messageId).set(...) instead of .add(...)
    // — makes retries of this exact same send idempotent (same id = same
    // document, no duplicate) instead of creating a new document each retry.
    String? messageId,
  }) async {
    final replyTo = _buildReplyTo(
      replyToId: replyToId,
      replyToText: replyToText,
      replyToSenderName: replyToSenderName,
      replyToImageURL: replyToImageURL,
      replyToVideoURL: replyToVideoURL,
    );
    final replyToStatus = _buildReplyToStatus(
      replyToStatusId: replyToStatusId,
      replyToStatusOwnerUid: replyToStatusOwnerUid,
      replyToStatusType: replyToStatusType,
      replyToStatusText: replyToStatusText,
      replyToStatusThumbnailURL: replyToStatusThumbnailURL,
    );
    final data = {
      'senderId': senderId,
      'text': caption,
      'type': 'image',
      'clientPlatform': 'flutter',
      'forwardCount': forwardCount,
      'imageURL': imageURL,
      if (imageWidth != null) 'imageWidth': imageWidth,
      if (imageHeight != null) 'imageHeight': imageHeight,
      if (mediaOriginChatId != null) 'mediaOriginChatId': mediaOriginChatId,
      if (mediaFileName != null) 'mediaFileName': mediaFileName,
      'audioURL': null,
      // Display-only wall-clock time — ordering is `seq`, see
      // _commitMessage's own doc comment.
      'timestamp': Timestamp.now(),
      if (replyTo != null) 'replyTo': replyTo,
      if (replyToStatus != null) 'replyToStatus': replyToStatus,
    };
    final (_, seq) = await _commitMessage(
      chatId: chatId,
      data: data,
      messageId: messageId,
    );
    // The one chat-doc field this app still denormalises client-side. It
    // rode along in the preview write until that moved to onNewMessage, and
    // it deliberately did NOT move with it: deleteMessageForAll still
    // decrements it from the client, so a server-side increment would
    // double-count every image for as long as any already-installed build
    // keeps writing this one. Both halves have to move together, onto a
    // one-off recount — see the Cloud Function's own comment.
    //
    // Счётчик изображений здесь больше не пишется (N3). Раньше на
    // каждую отправленную фотографию уходила ОТДЕЛЬНАЯ запись в
    // chats/{chatId} — в тот самый горячий документ, ради которого
    // превью свели в одну серверную транзакцию (B16), а слушателей — в
    // одного (B17). Само число теперь считается по запросу и точно, см.
    // countChatImages ниже; денормализованное поле, которое можно
    // расходить с реальностью, просто перестало существовать, поэтому
    // ни переносить на сервер, ни пересчитывать миграцией нечего.
    return seq;
  }

  Future<String> uploadChatVideo({
    required String chatId,
    required String filePath,
    required String senderId,
    required String fileName,
    void Function(UploadTask task)? onTaskStarted,
    void Function(double progress)? onProgress,
  }) async {
    final ref = FirebaseStorage.instance
        .ref()
        .child('chats')
        .child(chatId)
        .child(fileName);
    final task = ref.putFile(
      File(filePath),
      SettableMetadata(
        customMetadata: {'uploaderUid': senderId, 'chatId': chatId},
      ),
    );
    onTaskStarted?.call(task);
    if (onProgress != null) {
      task.snapshotEvents.listen((snapshot) {
        if (snapshot.totalBytes > 0) {
          onProgress(snapshot.bytesTransferred / snapshot.totalBytes);
        }
      });
    }
    await task;
    return await ref.getDownloadURL();
  }

  // Returns the message's assigned seq — see sendMessage's own doc comment.
  Future<int> sendVideoMessage({
    required String chatId,
    required String senderId,
    required String videoURL,
    int? videoDurationMs,
    int? videoWidth,
    int? videoHeight,
    String caption = '',
    // See sendImageMessage's own forwardCount doc comment.
    int forwardCount = 0,
    String? mediaOriginChatId,
    String? mediaFileName,
    String? replyToId,
    String? replyToText,
    String? replyToSenderName,
    String? replyToImageURL,
    String? replyToVideoURL,
    String? replyToStatusId,
    String? replyToStatusOwnerUid,
    String? replyToStatusType,
    String? replyToStatusText,
    String? replyToStatusThumbnailURL,
    String? messageId,
  }) async {
    final replyTo = _buildReplyTo(
      replyToId: replyToId,
      replyToText: replyToText,
      replyToSenderName: replyToSenderName,
      replyToImageURL: replyToImageURL,
      replyToVideoURL: replyToVideoURL,
    );
    final replyToStatus = _buildReplyToStatus(
      replyToStatusId: replyToStatusId,
      replyToStatusOwnerUid: replyToStatusOwnerUid,
      replyToStatusType: replyToStatusType,
      replyToStatusText: replyToStatusText,
      replyToStatusThumbnailURL: replyToStatusThumbnailURL,
    );
    final data = {
      'senderId': senderId,
      'text': caption,
      'type': 'video',
      'clientPlatform': 'flutter',
      'forwardCount': forwardCount,
      'videoURL': videoURL,
      if (videoDurationMs != null) 'videoDurationMs': videoDurationMs,
      if (videoWidth != null) 'videoWidth': videoWidth,
      if (videoHeight != null) 'videoHeight': videoHeight,
      if (mediaOriginChatId != null) 'mediaOriginChatId': mediaOriginChatId,
      if (mediaFileName != null) 'mediaFileName': mediaFileName,
      'imageURL': null,
      'audioURL': null,
      // Display-only wall-clock time — ordering is `seq`, see
      // _commitMessage's own doc comment.
      'timestamp': Timestamp.now(),
      if (replyTo != null) 'replyTo': replyTo,
      if (replyToStatus != null) 'replyToStatus': replyToStatus,
    };
    final (_, seq) = await _commitMessage(
      chatId: chatId,
      data: data,
      messageId: messageId,
    );
    return seq;
  }

  // Generic file/document upload — no compression step (unlike image/video),
  // the raw picked file goes straight to Storage. Shares the exact same
  // flat chats/{chatId}/{fileName} path and customMetadata shape as
  // uploadChatImage/uploadChatVideo, so it's covered by the same
  // storage.rules size check and the same onChatMediaUploaded ->
  // validatedUploads trust chain — nothing type-specific needed there.
  Future<String> uploadChatFile({
    required String chatId,
    required String filePath,
    required String senderId,
    required String fileName,
    void Function(UploadTask task)? onTaskStarted,
    void Function(double progress)? onProgress,
  }) async {
    final ref = FirebaseStorage.instance
        .ref()
        .child('chats')
        .child(chatId)
        .child(fileName);
    final task = ref.putFile(
      File(filePath),
      SettableMetadata(
        customMetadata: {'uploaderUid': senderId, 'chatId': chatId},
      ),
    );
    onTaskStarted?.call(task);
    if (onProgress != null) {
      task.snapshotEvents.listen((snapshot) {
        if (snapshot.totalBytes > 0) {
          onProgress(snapshot.bytesTransferred / snapshot.totalBytes);
        }
      });
    }
    await task;
    return await ref.getDownloadURL();
  }

  // Returns the message's assigned seq — see sendMessage's own doc comment.
  Future<int> sendFileMessage({
    required String chatId,
    required String senderId,
    required String fileURL,
    required String fileName,
    int? fileSizeBytes,
    String caption = '',
    // See sendImageMessage's own forwardCount doc comment.
    int forwardCount = 0,
    String? mediaOriginChatId,
    String? mediaFileName,
    String? replyToId,
    String? replyToText,
    String? replyToSenderName,
    String? replyToImageURL,
    String? replyToVideoURL,
    String? replyToStatusId,
    String? replyToStatusOwnerUid,
    String? replyToStatusType,
    String? replyToStatusText,
    String? replyToStatusThumbnailURL,
    String? messageId,
  }) async {
    final replyTo = _buildReplyTo(
      replyToId: replyToId,
      replyToText: replyToText,
      replyToSenderName: replyToSenderName,
      replyToImageURL: replyToImageURL,
      replyToVideoURL: replyToVideoURL,
    );
    final replyToStatus = _buildReplyToStatus(
      replyToStatusId: replyToStatusId,
      replyToStatusOwnerUid: replyToStatusOwnerUid,
      replyToStatusType: replyToStatusType,
      replyToStatusText: replyToStatusText,
      replyToStatusThumbnailURL: replyToStatusThumbnailURL,
    );
    final data = {
      'senderId': senderId,
      'text': caption,
      'type': 'file',
      'clientPlatform': 'flutter',
      'forwardCount': forwardCount,
      'fileURL': fileURL,
      'fileName': fileName,
      if (fileSizeBytes != null) 'fileSizeBytes': fileSizeBytes,
      if (mediaOriginChatId != null) 'mediaOriginChatId': mediaOriginChatId,
      if (mediaFileName != null) 'mediaFileName': mediaFileName,
      'imageURL': null,
      'audioURL': null,
      // Display-only wall-clock time — ordering is `seq`, see
      // _commitMessage's own doc comment.
      'timestamp': Timestamp.now(),
      if (replyTo != null) 'replyTo': replyTo,
      if (replyToStatus != null) 'replyToStatus': replyToStatus,
    };
    final (_, seq) = await _commitMessage(
      chatId: chatId,
      data: data,
      messageId: messageId,
    );
    return seq;
  }

  // Downloads an already-sent file message's bytes to a local path so it
  // can be opened with open_filex (which needs a real file, not a URL).
  // Goes straight through the Storage ref built from mediaOriginChatId/
  // mediaFileName (the same pair firestore.rules' isValidatedMedia() trusts)
  // rather than a generic HTTP GET against fileURL — reuses the exact
  // access-controlled path chat membership already governs, and avoids
  // pulling in a second HTTP client dependency just for this.
  Future<void> downloadChatFile({
    required String mediaOriginChatId,
    required String mediaFileName,
    required String destPath,
    void Function(double progress)? onProgress,
  }) async {
    final ref = FirebaseStorage.instance
        .ref()
        .child('chats')
        .child(mediaOriginChatId)
        .child(mediaFileName);
    final task = ref.writeToFile(File(destPath));
    if (onProgress != null) {
      task.snapshotEvents.listen((snapshot) {
        if (snapshot.totalBytes > 0) {
          onProgress(snapshot.bytesTransferred / snapshot.totalBytes);
        }
      });
    }
    await task;
  }

  // No dedicated uploadChatLocationSnapshot — a location message's map
  // snapshot is just an image (see LocationPickerScreen._captureSnapshot),
  // uploaded through the exact same flat chats/{chatId}/{fileName} path
  // and customMetadata shape as any other photo, so uploadChatImage above
  // is reused directly rather than duplicating an identical method body.
  // Returns the message's assigned seq — see sendMessage's own doc comment.
  Future<int> sendLocationMessage({
    required String chatId,
    required String senderId,
    required String locationImageURL,
    required double latitude,
    required double longitude,
    String caption = '',
    // See sendImageMessage's own forwardCount doc comment.
    int forwardCount = 0,
    String? mediaOriginChatId,
    String? mediaFileName,
    String? replyToId,
    String? replyToText,
    String? replyToSenderName,
    String? replyToImageURL,
    String? replyToVideoURL,
    String? replyToStatusId,
    String? replyToStatusOwnerUid,
    String? replyToStatusType,
    String? replyToStatusText,
    String? replyToStatusThumbnailURL,
    String? messageId,
  }) async {
    final replyTo = _buildReplyTo(
      replyToId: replyToId,
      replyToText: replyToText,
      replyToSenderName: replyToSenderName,
      replyToImageURL: replyToImageURL,
      replyToVideoURL: replyToVideoURL,
    );
    final replyToStatus = _buildReplyToStatus(
      replyToStatusId: replyToStatusId,
      replyToStatusOwnerUid: replyToStatusOwnerUid,
      replyToStatusType: replyToStatusType,
      replyToStatusText: replyToStatusText,
      replyToStatusThumbnailURL: replyToStatusThumbnailURL,
    );
    final data = {
      'senderId': senderId,
      'text': caption,
      'type': 'location',
      'clientPlatform': 'flutter',
      'forwardCount': forwardCount,
      'locationImageURL': locationImageURL,
      'latitude': latitude,
      'longitude': longitude,
      if (mediaOriginChatId != null) 'mediaOriginChatId': mediaOriginChatId,
      if (mediaFileName != null) 'mediaFileName': mediaFileName,
      'imageURL': null,
      'audioURL': null,
      // Display-only wall-clock time — ordering is `seq`, see
      // _commitMessage's own doc comment.
      'timestamp': Timestamp.now(),
      if (replyTo != null) 'replyTo': replyTo,
      if (replyToStatus != null) 'replyToStatus': replyToStatus,
    };
    final (_, seq) = await _commitMessage(
      chatId: chatId,
      data: data,
      messageId: messageId,
    );
    return seq;
  }

  Future<String> uploadChatAudio({
    required String chatId,
    required String filePath,
    required String senderId,
    required String fileName,
  }) async {
    final ref = FirebaseStorage.instance
        .ref()
        .child('chats')
        .child(chatId)
        .child(fileName);
    await ref.putFile(
      File(filePath),
      SettableMetadata(
        customMetadata: {'uploaderUid': senderId, 'chatId': chatId},
      ),
    );
    return await ref.getDownloadURL();
  }

  // Returns the message's assigned seq — see sendMessage's own doc comment.
  Future<int> sendAudioMessage({
    required String chatId,
    required String senderId,
    required String audioURL,
    List<int>? waveform,
    String caption = '',
    // See sendImageMessage's own forwardCount doc comment.
    int forwardCount = 0,
    String? mediaOriginChatId,
    String? mediaFileName,
    String? replyToId,
    String? replyToText,
    String? replyToSenderName,
    String? replyToImageURL,
    String? replyToVideoURL,
    String? replyToStatusId,
    String? replyToStatusOwnerUid,
    String? replyToStatusType,
    String? replyToStatusText,
    String? replyToStatusThumbnailURL,
    String? messageId,
  }) async {
    final replyTo = _buildReplyTo(
      replyToId: replyToId,
      replyToText: replyToText,
      replyToSenderName: replyToSenderName,
      replyToImageURL: replyToImageURL,
      replyToVideoURL: replyToVideoURL,
    );
    final replyToStatus = _buildReplyToStatus(
      replyToStatusId: replyToStatusId,
      replyToStatusOwnerUid: replyToStatusOwnerUid,
      replyToStatusType: replyToStatusType,
      replyToStatusText: replyToStatusText,
      replyToStatusThumbnailURL: replyToStatusThumbnailURL,
    );
    final data = {
      'senderId': senderId,
      'text': caption,
      'type': 'audio',
      'clientPlatform': 'flutter',
      'forwardCount': forwardCount,
      'audioURL': audioURL,
      if (waveform != null) 'waveform': waveform,
      if (mediaOriginChatId != null) 'mediaOriginChatId': mediaOriginChatId,
      if (mediaFileName != null) 'mediaFileName': mediaFileName,
      'imageURL': null,
      // Display-only wall-clock time — ordering is `seq`, see
      // _commitMessage's own doc comment.
      'timestamp': Timestamp.now(),
      if (replyTo != null) 'replyTo': replyTo,
      if (replyToStatus != null) 'replyToStatus': replyToStatus,
    };
    final (_, seq) = await _commitMessage(
      chatId: chatId,
      data: data,
      messageId: messageId,
    );
    return seq;
  }

  // Single source of truth for forwarding one message into one target
  // chat — dispatches by type to the matching send*Message method above,
  // carrying forward-chain depth (message.forwardCount + 1, see
  // Message.forwardCount) and the original media-validation fields
  // through. Moved here from chat_screen.dart's own private
  // _forwardMessage (Phase C1) so ForwardSheet (Phase C2, its own file)
  // can call it directly without reaching into ChatScreen's private
  // state — this was always data-layer orchestration over the send*
  // methods above, not UI logic.
  //
  // captionOverride, when non-null, REPLACES the source message's own
  // text/caption on every destination copy — used by ForwardSheet's
  // optional caption field. Deliberately a replace, not an append: an
  // append would need to invent a separator/ordering convention with no
  // existing precedent in this app, while replace matches how
  // captionOverride already behaves as just "the caption to use", same
  // shape as every send*Message method's own `caption` parameter.
  // Passing null (the caller has nothing typed) preserves the exact
  // original text/caption, unchanged from Phase C1's behavior.
  Future<void> forwardMessage({
    required Message message,
    required String targetChatId,
    required String senderId,
    String? captionOverride,
  }) async {
    // mediaOriginChatId/mediaFileName let firestore.rules confirm this
    // media really was a validated upload (see onChatMediaUploaded)
    // rather than trusting the URL string alone — a forward has to carry
    // them through from the original message, not just its URL. Messages
    // sent before this field existed don't have them and can no longer
    // be forwarded.
    final isMedia =
        message.type == 'image' ||
        message.type == 'audio' ||
        message.type == 'video' ||
        message.type == 'file' ||
        message.type == 'location';
    if (isMedia &&
        (message.mediaOriginChatId == null || message.mediaFileName == null)) {
      throw Exception('Media message predates forward-validation fields');
    }
    final forwardCount = message.forwardCount + 1;
    final caption = captionOverride ?? message.text;
    switch (message.type) {
      case 'image':
        final imageURL = message.imageURL;
        if (imageURL != null) {
          await sendImageMessage(
            chatId: targetChatId,
            senderId: senderId,
            imageURL: imageURL,
            caption: caption,
            forwardCount: forwardCount,
            mediaOriginChatId: message.mediaOriginChatId,
            mediaFileName: message.mediaFileName,
          );
        }
        break;
      case 'audio':
        final audioURL = message.audioURL;
        if (audioURL != null) {
          await sendAudioMessage(
            chatId: targetChatId,
            senderId: senderId,
            audioURL: audioURL,
            caption: caption,
            forwardCount: forwardCount,
            mediaOriginChatId: message.mediaOriginChatId,
            mediaFileName: message.mediaFileName,
          );
        }
        break;
      case 'video':
        final videoURL = message.videoURL;
        if (videoURL != null) {
          await sendVideoMessage(
            chatId: targetChatId,
            senderId: senderId,
            videoURL: videoURL,
            caption: caption,
            forwardCount: forwardCount,
            mediaOriginChatId: message.mediaOriginChatId,
            mediaFileName: message.mediaFileName,
          );
        }
        break;
      case 'file':
        final fileURL = message.fileURL;
        if (fileURL != null) {
          await sendFileMessage(
            chatId: targetChatId,
            senderId: senderId,
            fileURL: fileURL,
            fileName: message.fileName ?? 'Fayl',
            fileSizeBytes: message.fileSizeBytes,
            caption: caption,
            forwardCount: forwardCount,
            mediaOriginChatId: message.mediaOriginChatId,
            mediaFileName: message.mediaFileName,
          );
        }
        break;
      case 'location':
        final locationImageURL = message.locationImageURL;
        final lat = message.latitude;
        final lng = message.longitude;
        if (locationImageURL != null && lat != null && lng != null) {
          await sendLocationMessage(
            chatId: targetChatId,
            senderId: senderId,
            locationImageURL: locationImageURL,
            latitude: lat,
            longitude: lng,
            caption: caption,
            forwardCount: forwardCount,
            mediaOriginChatId: message.mediaOriginChatId,
            mediaFileName: message.mediaFileName,
          );
        }
        break;
      default:
        await sendMessage(
          chatId: targetChatId,
          senderId: senderId,
          text: caption,
          forwardCount: forwardCount,
        );
    }
  }

  // Waits for the onChatMediaUploaded Storage trigger to write its
  // validatedUploads marker for a just-uploaded file — without this, the
  // caller's next step (creating the message doc) would race the trigger
  // and fail firestore.rules' validation check most of the time, since the
  // trigger typically takes a second or more to fire. Uses a snapshot
  // listener rather than blindly retrying the message-doc write itself, so
  // a normal-latency wait never produces a doomed write attempt. Returns
  // false (not an exception) on timeout so the caller can fold it into its
  // own existing retry/backoff cycle rather than treating it as a distinct
  // error class.
  Future<bool> waitForValidatedUpload({
    required String chatId,
    required String fileName,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final ref = _db
        .collection('validatedUploads')
        .doc(chatId)
        .collection('files')
        .doc(fileName);
    final existing = await ref.get();
    if (existing.exists) return true;

    final completer = Completer<bool>();
    final sub = ref.snapshots().listen((snap) {
      if (snap.exists && !completer.isCompleted) {
        completer.complete(true);
      }
    });
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) completer.complete(false);
    });
    try {
      return await completer.future;
    } finally {
      timer.cancel();
      await sub.cancel();
    }
  }

  // Distinct from the chat-level lastReadMsgId (which only means the
  // recipient scrolled past this message) — this records that `uid`
  // actually started playback at least once. arrayUnion is idempotent and
  // creates the field if it doesn't exist yet, so this is safe to call on
  // messages sent before this field existed too.
  Future<void> markVoiceMessageListened({
    required String chatId,
    required String messageId,
    required String uid,
  }) {
    return _db
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .doc(messageId)
        .update({
          'listenedBy': FieldValue.arrayUnion([uid]),
        });
  }

  Future<void> deleteMessageForAll({
    required String chatId,
    required String messageId,
  }) async {
    final msgRef = _db
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .doc(messageId);
    // Транзакция, а не простое обновление: повторный вызов на уже
    // удалённом сообщении не должен ничего менять второй раз.
    // Раньше она читала ещё и тип сообщения — только чтобы решить,
    // уменьшать ли mediaImageCount; вторая половина этой пары ушла
    // вместе с первой (N3, см. sendImageMessage).
    await _db.runTransaction((tx) async {
      final snap = await tx.get(msgRef);
      final data = snap.data();
      if (data == null || data['deletedForAll'] == true) return;
      tx.update(msgRef, {
        'deletedForAll': true,
        'deletedAt': nowInstantIso(),
        'text': '',
      });
    });
  }

  // Точное число видимых изображений чата — по запросу, вместо
  // денормализованного счётчика (N3).
  //
  // Два агрегатных запроса вместо чтения поля: агрегат тарифицируется как
  // одно чтение на каждую тысячу совпавших документов, то есть на любом
  // реальном чате это одно-два чтения — дешевле, чем держать поле,
  // которое пишется на каждую отправку фотографии и умеет разъезжаться.
  //
  // Вычитание, а не один запрос с фильтром: «не удалено у всех» в
  // Firestore не выражается — у подавляющего большинства сообщений поля
  // deletedForAll нет вовсе, а запрос по отсутствующему полю ничего не
  // находит. Зато `deletedForAll == true` находит ровно те, где его
  // проставил deleteMessageForAll, — их и вычитаем из общего числа.
  Future<int> countChatImages(String chatId) async {
    final messages = _db
        .collection('chats')
        .doc(chatId)
        .collection('messages');
    final all = await messages.where('type', isEqualTo: 'image').count().get();
    final tombstoned = await messages
        .where('type', isEqualTo: 'image')
        .where('deletedForAll', isEqualTo: true)
        .count()
        .get();
    final total = all.count ?? 0;
    final removed = tombstoned.count ?? 0;
    final visible = total - removed;
    return visible < 0 ? 0 : visible;
  }

  // Per-chat throttle for refreshChatPreview below. The client-side half of
  // the anti-stampede protection the callable also enforces server-side:
  // this stops a screen that rebuilds often (or a chat reopened repeatedly)
  // from turning one stale preview into a stream of calls.
  static const Duration _previewRefreshCooldown = Duration(seconds: 30);
  final Map<String, DateTime> _lastPreviewRefreshAt = {};

  // Asks the server to recompute this chat's card preview, for the one case
  // the client can detect but deliberately cannot fix itself: the chat
  // document's lastMessageSeq lagging the newest message actually present.
  // That happens for every chat predating lastMessageSeq (field absent,
  // read as 0) and for any chat whose onNewMessage invocation failed
  // outright — the trigger's own retries are the first line of defence,
  // this is the backstop for when they're exhausted.
  //
  // The client can't recompute it because preview text is formatted in
  // exactly one place, server-side (previewText in functions/src/index.ts);
  // giving Dart a second copy to self-heal with would recreate the
  // duplication that motivated moving it there. So it asks instead.
  //
  // Failures are swallowed: this is opportunistic repair of a cosmetic
  // field, and a chat must open normally whether or not it succeeds.
  Future<void> refreshChatPreviewIfStale({
    required String chatId,
    required int storedSeq,
    required int newestKnownSeq,
  }) async {
    if (newestKnownSeq <= storedSeq) return;
    final last = _lastPreviewRefreshAt[chatId];
    if (last != null &&
        DateTime.now().difference(last) < _previewRefreshCooldown) {
      return;
    }
    _lastPreviewRefreshAt[chatId] = DateTime.now();
    try {
      await _functions
          .httpsCallable('refreshChatPreview')
          .call({'chatId': chatId}).timeout(_writeTimeout);
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'FirestoreService: refreshChatPreview failed',
      );
    }
  }

  // "Delete for me" never touches the shared lastMessage/lastMessageTime —
  // every other member must keep seeing the real preview. But if the
  // message being hidden IS the chat's current last message, record that
  // this uid personally deleted it (lastMessageDeletedFor) so this one
  // viewer's own chat-list card can swap in the "Bu mesajı sildiniz"
  // placeholder instead — see chats_screen.dart's _ChatListItem.
  Future<void> deleteMessageForMe({
    required String chatId,
    required String messageId,
    required String uid,
  }) async {
    await _db
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .doc(messageId)
        .update({
          'deletedFor': FieldValue.arrayUnion([uid]),
        });
    final last = await _findLastMessage(chatId);
    if (last?.key == messageId) {
      await _db.collection('chats').doc(chatId).update({
        'lastMessageDeletedFor': FieldValue.arrayUnion([uid]),
      });
    }
  }

  // Reactions are written exclusively by the toggleMessageReaction Cloud
  // Function — a client-side transaction can't be validated by Firestore
  // rules at the field-content level (rules see "reactions changed", not
  // "only the caller's own uid moved within it"), so a modified client
  // could otherwise forge another user's reaction. `uid` is no longer
  // taken as a parameter here: the function derives it from the caller's
  // own auth token, which is the whole point.
  Future<void> toggleReaction({
    required String chatId,
    required String messageId,
    required String emoji,
  }) async {
    await _functions.httpsCallable('toggleMessageReaction').call({
      'chatId': chatId,
      'messageId': messageId,
      'emoji': emoji,
    });
  }

  Future<String> startCall({
    required String calleeUid,
    required CallType type,
  }) async {
    final result = await _functions.httpsCallable('startCall').call({
      'calleeUid': calleeUid,
      'type': type.name,
    });
    return (result.data as Map)['callId'] as String;
  }

  Future<void> respondToCall({
    required String callId,
    required bool accept,
  }) async {
    await _functions.httpsCallable('respondToCall').call({
      'callId': callId,
      'accept': accept,
    });
  }

  Future<void> endCall({required String callId}) async {
    await _functions.httpsCallable('endCall').call({'callId': callId});
  }

  Future<Map<String, dynamic>> generateAgoraToken({
    required String channelName,
  }) async {
    final result = await _functions.httpsCallable('generateAgoraToken').call({
      'channelName': channelName,
    });
    return Map<String, dynamic>.from(result.data as Map);
  }

  Stream<Call?> watchCall(String callId) {
    return _db.collection('calls').doc(callId).snapshots().map(
      (snap) => snap.exists ? Call.fromFirestore(snap.id, snap.data()!) : null,
    );
  }

  // Слушает входящие звонки для текущего пользователя (status == ringing, calleeId == uid)
  Stream<Call?> watchIncomingCalls(String uid) {
    return _db
        .collection('calls')
        .where('calleeId', isEqualTo: uid)
        .where('status', isEqualTo: 'ringing')
        .snapshots()
        .map((snap) => snap.docs.isEmpty
            ? null
            : Call.fromFirestore(snap.docs.first.id, snap.docs.first.data()));
  }

  Future<void> deleteMessagePermanently({
    required String chatId,
    required String messageId,
  }) async {
    await _db
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .doc(messageId)
        .delete();
  }

  // The newest message in the chat that isn't deletedForAll — i.e. the
  // message lastMessage/lastMessageTime should currently denormalize.
  //
  // Страницы расширяются 10 → 100 → 1000, как у серверного близнеца
  // findNewestVisibleMessage (B14). Прежний единственный запрос на 50
  // сообщений при полностью удалённом хвосте отвечал «нечего показывать»
  // вместо «ищи дальше», причём молча. Обычный случай при этом стал
  // дешевле: почти всегда хватает первой страницы из десяти.
  static const List<int> _lastMessagePageSizes = [10, 100, 1000];

  Future<MapEntry<String, Map<String, dynamic>>?> _findLastMessage(
    String chatId,
  ) async {
    DocumentSnapshot<Map<String, dynamic>>? cursor;
    for (final size in _lastMessagePageSizes) {
      var query = _db
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .orderBy('seq', descending: true)
          .limit(size);
      if (cursor != null) query = query.startAfterDocument(cursor);
      final snap = await query.get();
      if (snap.docs.isEmpty) return null;
      for (final doc in snap.docs) {
        final data = doc.data();
        if (data['deletedForAll'] != true) {
          return MapEntry(doc.id, data);
        }
      }
      // Страница короче запрошенной — история кончилась.
      if (snap.docs.length < size) return null;
      cursor = snap.docs.last;
    }
    return null;
  }

  Future<void> starMessage({
    required String uid,
    required String chatId,
    required String chatName,
    required String senderName,
    required Message message,
  }) async {
    await _db
        .collection('users')
        .doc(uid)
        .collection('starred')
        .doc(message.id)
        .set({
          'chatId': chatId,
          'chatName': chatName,
          'senderId': message.senderId,
          'senderName': senderName,
          'text': message.text,
          'type': message.type,
          'imageURL': message.imageURL,
          'audioURL': message.audioURL,
          'videoURL': message.videoURL,
          'fileURL': message.fileURL,
          'fileName': message.fileName,
          'timestamp': message.timestamp,
          'starredAt': FieldValue.serverTimestamp(),
        });
  }

  Future<void> unstarMessage({required String uid, required String messageId}) {
    return _db
        .collection('users')
        .doc(uid)
        .collection('starred')
        .doc(messageId)
        .delete();
  }

  Stream<List<StarredMessage>> watchStarredMessages(String uid) {
    return _db
        .collection('users')
        .doc(uid)
        .collection('starred')
        .orderBy('starredAt', descending: true)
        .snapshots()
        // Пустой снимок ИЗ КЭША — не ответ, а молчание (N14). Тот же
        // признак и та же узость, что у watchChats: пусто с сервера —
        // настоящий ответ, непустое из кэша — настоящие данные; молчание
        // это только два условия вместе. Не отдавая такой снимок, поток
        // оставляет провайдер в состоянии загрузки, и экран рисует
        // ожидание вместо пустоты, выданной за факт.
        .where((snap) => !(snap.docs.isEmpty && snap.metadata.isFromCache))
        .map(
          (snap) => snap.docs
              .map((doc) => StarredMessage.fromFirestore(doc.id, doc.data()))
              .toList(),
        );
  }

  Future<Map<String, dynamic>?> fetchChatData(String chatId) async {
    final doc = await _db.collection('chats').doc(chatId).get();
    return doc.data();
  }

  Stream<Map<String, dynamic>> watchChatMeta(String chatId) {
    return _watchChatDoc(chatId).map((snap) {
      final data = snap.data() ?? {};
      // Сервер только что сказал, какая расписка у нас записана —
      // запоминаем, чтобы markChatAsReadBy не переписывал её тем же
      // значением (A3). Делается здесь, а не на экране: экран и его
      // провайдеры пересоздаются при каждом входе в чат, а ответ нужен
      // раньше первой попытки записи.
      final myUid = FirebaseAuth.instance.currentUser?.uid;
      if (myUid != null) {
        _noteRecordedReadMsgId(
          chatId,
          (data['lastReadMsgId'] as Map<String, dynamic>?)?[myUid] as String?,
        );
      }
      return {
        // ЕСТЬ ЛИ ДОКУМЕНТ — признак существования, а не догадка по
        // пустоте (N34).
        //
        // До него отсутствующий документ отдавался как обычный чат с
        // `members: []`, и «чата больше нет» было неотличимо от «чат
        // есть, участников нет». Догадываться по пустоте потребитель не
        // может в принципе: пустой снимок из кэша означает «ещё не
        // знаю», а не «удалён», — поэтому состояний три, и называет их
        // тип, а не bool (см. ChatExistence).
        'existence': chatExistenceOf(
          exists: snap.exists,
          isFromCache: snap.metadata.isFromCache,
        ),
        // Отдельным ключом, потому что отвечает на ДРУГОЙ вопрос:
        // `existence` говорит «есть ли документ», этот — «подтвердил ли
        // сервер». Решение об исключении человека из чата требует
        // второго: состав из кэша может отставать на сессию (N33).
        //
        // Лишних перестроений почти не даёт: значение меняется один раз
        // за открытие чата, на переходе «кэш → сервер», и `.distinct`
        // гасит всё остальное.
        'fromCache': snap.metadata.isFromCache,
        // Lets chat_screen.dart's AppBar title resolve off this live
        // stream alone instead of also waiting on chatDataProvider's
        // separate one-time fetch just to learn isGroup — the two used to
        // resolve independently, so the title sat on a "..." placeholder
        // until BOTH landed even when this stream's own snapshot (already
        // needed for otherUidResolved/deliveredTo/etc.) had arrived first.
        'isGroup': data['isGroup'] ?? false,
        'members': List<String>.from(data['members'] ?? const []),
        'deliveredTo': Map<String, dynamic>.from(data['deliveredTo'] ?? {}),
        // Докуда доставлено каждому — по номеру сообщения (B18).
        // deliveredTo рядом остаётся только на время переходного окна,
        // пока в ходу сборки, которые номер не пишут.
        'deliveredSeq': Map<String, dynamic>.from(data['deliveredSeq'] ?? {}),
        // Время доставки — момент, когда продвинулся deliveredSeq. Нужен
        // экрану «Məlumat»: номер отвечает «докуда доставлено», но не
        // «когда», а показывать там время визита нельзя (см.
        // _recordDeliveries).
        'deliveredAt': Map<String, dynamic>.from(data['deliveredAt'] ?? {}),
        'lastReadMsgId': Map<String, dynamic>.from(data['lastReadMsgId'] ?? {}),
        'lastReadAt': Map<String, dynamic>.from(data['lastReadAt'] ?? {}),
        // Needed by chat_screen.dart's own "unread badge is stuck" repair
        // path (see there) — the onNewMessage Cloud Function increments
        // this asynchronously, so it can land AFTER the reader's own
        // markChatAsReadBy zeroed it, leaving a permanent phantom count.
        'unreadCount': Map<String, dynamic>.from(data['unreadCount'] ?? {}),
        // Live so a group rename/role change reflects in the app bar
        // without needing to reopen the chat screen — see chat_screen.dart's
        // app bar, which reads these instead of the one-time
        // chatDataProvider for group chats specifically.
        'admins': List<String>.from(data['admins'] ?? const []),
        'createdBy': data['createdBy'] ?? '',
        'name': data['name'] ?? '',
        'emoji': data['emoji'] ?? '💬',
        'photoURL': data['photoURL'],
        // "İş təklif et" negotiation state — deliberately NOT including
        // clearedBy (only ChatMessagesController's own narrow
        // watchChatClearedAt stream needs it) or typing (only the job-offer
        // banner's status line needs it, via the equally narrow
        // watchChatTyping below): folding either into this general-purpose
        // projection would re-run every one of this stream's listeners,
        // including chat_screen.dart's entire build() method, on every
        // clearedBy/typing write, for no benefit to any of them — see
        // watchChatTyping's own comment for the confirmed on-device cost of
        // getting this wrong.
        'jobOfferBy': data['jobOfferBy'],
        'jobOfferAt': data['jobOfferAt'],
        'eventDate': data['eventDate'],
        'eventType': data['eventType'],
        'eventLocation': data['eventLocation'],
        'eventNotes': data['eventNotes'],
        'waitingForDateAt': data['waitingForDateAt'],
        'cancelledBy': data['cancelledBy'],
        'recipientAgreed': (data['recipientAgreed'] ?? false) as bool,
        'recipientAgreedAt': data['recipientAgreedAt'],
        // Явный шаг раунда: 'proposed' | 'dated' | 'agreed' | 'ended'.
        // Отсутствует на документах, которые не трогали с прежней сборки, —
        // читатель обязан откатываться на прежний вывод по флагам, см.
        // chat_screen.dart. Кто и когда закрыл раунд отказом: сторону
        // (передумал инициатор или отказался получатель) даёт сравнение
        // roundEndedBy с jobOfferBy, отдельного поля для этого намеренно нет.
        'roundStep': data['roundStep'],
        'roundEndedBy': data['roundEndedBy'],
        'roundEndedAt': data['roundEndedAt'],
        'negotiationSeenAt': Map<String, dynamic>.from(
          data['negotiationSeenAt'] ?? {},
        ),
        // Which message the shared card preview currently describes. Read
        // by chat_screen.dart purely to notice when it has fallen behind
        // the messages actually present and ask the server to recompute
        // (refreshChatPreviewIfStale) — absent on every chat predating the
        // field, which reads as 0 and therefore heals on first open.
        'lastMessageSeq': (data['lastMessageSeq'] as num?)?.toInt() ?? 0,
      };
      // Общий слушатель приносит и типизацию, и метаданные — всё, что не
      // меняет именно эту проекцию, гасится здесь, чтобы chat_screen не
      // перестраивался на чужие записи. Ровно та цена, ради которой эти
      // потоки и держат раздельными.
    }).distinct(_deepEquals);
  }

  Future<void> markChatAsDelivered({
    required String chatId,
    required String uid,
  }) async {
    try {
      await _db.collection('chats').doc(chatId).update({
        'deliveredTo.$uid': nowInstantIso(),
      }).timeout(_writeTimeout);
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'FirestoreService: markChatAsDelivered failed',
      );
    }
  }

  // Докуда доставлено — по номеру сообщения, а не по времени (B18).
  //
  // Что было не так со временем: `deliveredTo.{uid}` хранит момент
  // последнего ОТКРЫТИЯ чата, а галочка проверяла его на `!= null`. То
  // есть вторая галочка означала «собеседник когда-то заходил сюда», и
  // горела под сообщением, которое он заведомо не получал: в боевых
  // данных нашёлся чат, где отметка на 8,3 часа старше сообщения. Тот же
  // класс, что `readBy` (B28), только этот виден пользователю.
  //
  // Ключ к защите от петли «снимок → запись → снимок» — сходимость: после
  // записи `deliveredSeq` равен `lastMessageSeq`, и условие ниже перестаёт
  // выполняться. Кэш в памяти закрывает окно между отправкой запроса и
  // приходом снимка с результатом, когда условие ещё истинно, — без него
  // пачка снимков успевала бы породить пачку одинаковых записей. Ровно из
  // такого механизма вырос write-шторм, разобранный в A3.
  final Map<String, int> _deliveredSeqWritten = {};

  void _recordDeliveries(
    QuerySnapshot<Map<String, dynamic>> snap,
    String uid,
  ) {
    for (final doc in snap.docs) {
      final data = doc.data();
      final lastSeq = (data['lastMessageSeq'] as num?)?.toInt() ?? 0;
      if (lastSeq <= 0) continue;
      final deliveredSeq = data['deliveredSeq'] as Map<String, dynamic>?;
      final mine = (deliveredSeq?[uid] as num?)?.toInt() ?? 0;
      if (lastSeq <= mine) continue;
      final written = _deliveredSeqWritten[doc.id] ?? 0;
      if (lastSeq <= written) continue;
      _deliveredSeqWritten[doc.id] = lastSeq;
      _db
          .collection('chats')
          .doc(doc.id)
          .update({
            'deliveredSeq.$uid': lastSeq,
            // Момент САМОЙ доставки, а не последнего открытия чата.
            // Пишется этой же операцией намеренно: отдельная запись стоила
            // бы второго обновления горячего документа (A3), а нужна она
            // ровно тогда же, когда продвинулся номер.
            //
            // Зачем понадобилось: экран «Məlumat» показывал время
            // «Çatdırıldı» из `deliveredTo`, то есть из отметки визита, и
            // на устройстве 02.08 доставка оказалась ПОЗЖЕ прочтения
            // (20:38 против 20:37) — получатель просто пять раз заходил в
            // чат после того, как прочитал. Номер `deliveredSeq` эту
            // строку починить не мог: он не время.
            'deliveredAt.$uid': nowInstantIso(),
          })
          .timeout(_writeTimeout)
          .catchError((Object e, StackTrace st) {
            // Откат отметки: иначе одна неудачная запись навсегда
            // закрыла бы этот чат от повторной попытки в этой сессии.
            if (_deliveredSeqWritten[doc.id] == lastSeq) {
              _deliveredSeqWritten[doc.id] = written;
            }
            FirebaseCrashlytics.instance.recordError(
              e,
              st,
              reason: 'FirestoreService: deliveredSeq write failed',
            );
          });
    }
  }

  // Tracks who's currently viewing a chat so the push-notification Cloud
  // Function can skip notifying them — mirrors mugam-v2's
  // addActiveUser/removeActiveUser exactly (same field, same arrayUnion/
  // arrayRemove semantics).
  Future<void> addActiveUser({
    required String chatId,
    required String uid,
  }) async {
    try {
      await _db.collection('chats').doc(chatId).update({
        'activeUsers': FieldValue.arrayUnion([uid]),
      }).timeout(_writeTimeout);
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'FirestoreService: addActiveUser failed',
      );
    }
  }

  Future<void> removeActiveUser({
    required String chatId,
    required String uid,
  }) async {
    try {
      await _db.collection('chats').doc(chatId).update({
        'activeUsers': FieldValue.arrayRemove([uid]),
      }).timeout(_writeTimeout);
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'FirestoreService: removeActiveUser failed',
      );
    }
  }

  // Writes online + lastSeen together — used both by PresenceService's
  // heartbeat (see docs/presence-system.md) and by the logout flow below,
  // which calls this directly (not via PresenceService.stop()) because it
  // must run *before* AuthService().logout() while the user is still
  // authenticated; Firestore rules would reject the write once signed out.
  // activeChatId — в каком чате пользователь СЕЙЧАС (N19). Пишется рядом с
  // сердцебиением присутствия намеренно: у отметки о присутствии обязан
  // быть срок годности, а здесь он уже есть — `lastSeen` обновляется раз в
  // 60 с, пока приложение на переднем плане, и перестаёт обновляться, как
  // только оно свёрнуто, убито или потеряло сеть.
  //
  // Прежний признак `activeUsers` в документе чата такого срока не имел:
  // uid добавлялся при входе на экран и удалялся только в `dispose`.
  // Свернул приложение с открытым чатом, убил его или потерял связь —
  // отметка оставалась навсегда, а сервер по ней ПОДАВЛЯЕТ push. То есть
  // человек молча переставал получать уведомления об этом чате.
  //
  // Ключ пишется ВСЕГДА, в том числе как null: по наличию самого поля
  // сервер отличает новую сборку от старой (см. переходное окно в
  // реестре, N19). У старой сборки поля нет вовсе — для неё сервер
  // продолжает смотреть на activeUsers.
  Future<void> setUserPresence(
    String uid, {
    required bool online,
    String? activeChatId,
    String? activeEventId,
    int? presenceIntervalMs,
  }) async {
    try {
      await _db.collection('users').doc(uid).update({
        'online': online,
        'lastSeen': FieldValue.serverTimestamp(),
        'activeChatId': online ? activeChatId : null,
        // Карточка мероприятия — своё поле рядом, тот же механизм. Тоже
        // всегда, в том числе null: иначе отметка «смотрю сюда» пережила
        // бы уход с экрана и глушила уведомления навсегда — ровно N19.
        'activeEventId': online ? activeEventId : null,
        // Интервал сердцебиения этой сборки: сервер берёт двойной от него
        // как срок годности отметки присутствия (см. freshnessWindowMs).
        if (presenceIntervalMs != null)
          'presenceIntervalMs': presenceIntervalMs,
      }).timeout(_writeTimeout);
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'FirestoreService: setUserPresence failed',
      );
    }
  }

  // UI-state write for the friend-requests unread dot — fire-and-forget
  // from FriendRequestsScreen's initState the moment it opens. Silent on
  // failure, matching this feature's existing rollback-safety posture
  // (incomingFriendRequestsProvider errors already hide the whole Dost
  // sorğuları row rather than surfacing a hard error): a failed write here
  // just means the dot doesn't clear yet, not a broken screen.
  Future<void> markFriendRequestsViewed(String uid) async {
    try {
      await _db.collection('users').doc(uid).update({
        'lastViewedFriendRequestsAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {
      // Silent — see comment above.
    }
  }

  // Logout cleanup, mirroring mugam-v2's pre-signOut steps: defensively
  // strip the user's uid from every chat's activeUsers (in case they logged
  // out without normally leaving a chat first, which would otherwise leave
  // them permanently exempt from push notifications).
  Future<void> clearActiveUserFromAllChats(String uid) async {
    try {
      // ФОРМА ЗАПРОСА ЗАДАНА ПРАВИЛАМИ, А НЕ УДОБСТВОМ (N32). Фильтр по
      // `activeUsers` выглядит точнее — он отбирал бы ровно те чаты, где
      // отметка есть, — но правило чтения `chats` доказывается полем
      // `members`, а Firestore авторизует запрос только когда его
      // СОБСТВЕННЫЕ фильтры доказывают правило для любого возможного
      // результата. Сервер отказывал по правам на КАЖДОМ вызове, отказ
      // уходил в catch ниже, и уборка не срабатывала ни разу с самого
      // появления правил. Найдено тестом форм запросов, не на устройстве.
      //
      // Поэтому фильтр — по участию, а наличие отметки проверяется уже на
      // клиенте: чатов у человека десятки, не тысячи. Тот же приём и та же
      // причина, что у `agreementExistsForRound` выше.
      //
      // Плата за выбор: чат, из которого человек вышел, сюда не попадёт —
      // фильтр по `members` его не вернёт. Это не потеря: уход теперь
      // снимает отметку тем же движением, что и членство (`leaveGroup` /
      // `removeGroupMember` через `chatAfterDeparture`), поэтому оставить
      // её там больше нечему.
      final snap = await _db
          .collection('chats')
          .where('members', arrayContains: uid)
          .get()
          .timeout(_writeTimeout);
      for (final doc in snap.docs) {
        final active = List<String>.from(
          doc.data()['activeUsers'] as List? ?? const [],
        );
        if (!active.contains(uid)) continue;
        await doc.reference
            .update({
              'activeUsers': FieldValue.arrayRemove([uid]),
            })
            .timeout(_writeTimeout);
      }
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'FirestoreService: clearActiveUserFromAllChats failed',
      );
    }
  }


  // Какая расписка уже лежит в документе каждого чата. Живёт в сервисе, а
  // не в состоянии экрана — и это принципиально (A3).
  //
  // Гвард в chat_screen сверяется с `chatMetaProvider`, а тот объявлен
  // autoDispose: при каждом входе в чат провайдер создаётся заново, и
  // если экран успеет захотеть написать раньше первого снимка, сверять
  // будет не с чем. Здесь значение переживает и пересоздание экрана, и
  // пересоздание провайдера, а заполняется из watchChatMeta — то есть
  // приходит от сервера, а не восстанавливается по памяти экрана.
  final Map<String, String> _lastReadMsgIdWritten = {};

  // Зовётся из watchChatMeta на каждом снимке документа чата: сервер уже
  // сказал, какая расписка записана, и повторять её незачем.
  void _noteRecordedReadMsgId(String chatId, String? msgId) {
    if (msgId == null) return;
    _lastReadMsgIdWritten[chatId] = msgId;
  }

  // Обнуление счётчика непрочитанных — отдельно от расписки (N22).
  //
  // Почему не через markChatAsReadBy, как было раньше: у того есть гвард
  // «расписка про это же сообщение уже записана — писать нечего», и он
  // прав. Но счётчик залипает ИМЕННО на последнем входящем сообщении —
  // из-за гонки с Cloud Function, которая инкрементит его асинхронно и
  // может успеть после того, как читатель уже обнулил (B15). То есть у
  // починки идентификатор всегда совпадает с записанным, и общий метод
  // глушил её вместе с холостыми расписками. Стоило это залипшего числа
  // на карточке чата, найденного тестировщиком в тот же вечер.
  //
  // Разделение не только чинит, но и честнее по смыслу: расписка
  // фиксирует СОБЫТИЕ (что прочитано и когда), счётчик чинит СОСТОЯНИЕ.
  // Плюс запись дешевле — одно поле вместо трёх, и время прочтения при
  // починке не сдвигается, чего и добивалась правка A3.
  Future<void> resetUnreadCount({
    required String chatId,
    required String uid,
  }) async {
    try {
      await _db.collection('chats').doc(chatId).update({
        'unreadCount.$uid': 0,
      }).timeout(_writeTimeout);
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'FirestoreService: resetUnreadCount failed',
      );
    }
  }

  Future<void> markChatAsReadBy({
    required String chatId,
    required String uid,
    required String lastMsgId,
  }) async {
    // Расписка про это же сообщение уже записана — писать нечего.
    // Дело не только в лишней записи в горячий документ: отправитель
    // видит на экране «Məlumat» ВРЕМЯ прочтения, и повторная запись
    // сдвигала его на момент очередного захода в чат, подменяя отметку о
    // прочтении отметкой о визите (тот же класс, что B18 и B28).
    //
    // Проверено на устройстве 02.08: на сборке с этой правкой время в
    // «Məlumat» при повторных открытиях чата стоит на месте, на сборке
    // без неё — сдвигается.
    if (_lastReadMsgIdWritten[chatId] == lastMsgId) return;
    _lastReadMsgIdWritten[chatId] = lastMsgId;
    try {
      // Здесь был ещё `readBy: arrayUnion([uid])` — убран 02.08 вместе с
      // самим полем (B28). Его никто никогда не читал: ни экран, ни
      // функции, ни правила. При этом список рос монотонно и никогда не
      // очищался при новом сообщении, то есть даже как признак «все
      // прочли последнее» он был бы ложным — достаточно было один раз
      // открыть чат, чтобы навсегда попасть в этот список. Считает
      // прочтение `lastReadMsgId.{uid}` ниже, и только он.
      await _db.collection('chats').doc(chatId).update({
        'lastReadAt.$uid': nowInstantIso(),
        'lastReadMsgId.$uid': lastMsgId,
        'unreadCount.$uid': 0,
      }).timeout(_writeTimeout);
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'FirestoreService: markChatAsReadBy failed',
      );
    }
  }

  // "Çatı təmizlə" — per-user chat clear (mugam-v2's clearChatForUser).
  // Only ever hides messages for this uid (ChatMessagesController filters
  // on the cutoff via watchChatClearedAt below); never touches any other
  // member's view and never deletes anything server-side.
  Future<void> clearChatForUser({
    required String chatId,
    required String uid,
  }) async {
    try {
      await _db.collection('chats').doc(chatId).update({
        'clearedBy.$uid': nowInstantIso(),
      }).timeout(_writeTimeout);
    } catch (e, st) {
      debugPrint('\u274c clearChatForUser failed: $e');
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'FirestoreService: clearChatForUser failed',
      );
    }
  }

  // "İş təklif et" — proposes a job to the other party in a 1:1 chat.
  // chat_screen.dart's menu hides this item once jobOfferBy is already
  // set, matching mugam-v2's own {!jobOfferBy && (...)} gating.
  // Предложение создаётся СРАЗУ содержательным: дата, тип, место и
  // заметки выбираются в листе ДО отправки и уходят одной записью
  // (пункт 3 плана). Состояния «предложение есть, даты нет» новая
  // сборка больше не создаёт — отсюда и `roundStep: 'dated'` ниже, шаг
  // `proposed` этим методом не пишется вовсе.
  //
  // Параметры содержания обязательны намеренно, включая те, что могут
  // быть пустыми строками. Необязательный параметр здесь означал бы
  // «можно вызвать и не передать» — то есть оставленную лазейку создать
  // пустое предложение мимо листа. Пустоту передаёт вызывающий, явно.
  Future<void> setJobOffer({
    required String chatId,
    required String uid,
    required DateTime eventDate,
    required String eventType,
    required String eventLocation,
    required String eventNotes,
  }) async {
    try {
      await _db.collection('chats').doc(chatId).update({
        'jobOfferBy': uid,
        'jobOfferAt': nowInstantIso(),
        // A prior round on this same (persistent, never-forked) chat may
        // have left recipientAgreed stuck at true forever — acceptJobOffer
        // only ever sets it true, nothing ever resets it back on accept.
        // Without clearing it here, a second "İş təklif et" round's
        // Razıyam tap writes recipientAgreed:true again, but the
        // onChatUpdated Cloud Function's guard (before.recipientAgreed ===
        // true -> return) would see it as ALREADY true and never re-fire —
        // silently skipping PersonalEvent creation for every round after
        // the first.
        'recipientAgreed': false,
        'recipientAgreedAt': null,
        'waitingForDateAt': null,
        'negotiationSeenAt': {},
        // A prior round may have left a stale cancelledBy from an earlier
        // "İmtina" sitting on the doc — clear it so a fresh offer never
        // carries a leftover "X cancelled" value forward.
        'cancelledBy': null,
        // ЕДИНСТВЕННОЕ МЕСТО, ГДЕ ЧИСТИТСЯ СЛЕД ПРОШЛОГО РАУНДА. С этой
        // правки cancelChat больше не стирает содержание предложения —
        // иначе отказ стирал бы сам себя, и «явный отказ как состояние»
        // закладывать было бы не во что. Значит след живёт до следующего
        // предложения, и обнулить его обязан именно этот метод.
        //
        // Набор полей раунда фиксированный: ни массивов, ни карт по uid
        // среди них нет (negotiationSeenAt — карта, но и она сбрасывается
        // здесь и ограничена участниками чата). Поэтому документ чата от
        // раундов не растёт: каждый следующий переписывает те же ключи.
        'roundStep': 'dated',
        'roundEndedBy': null,
        'roundEndedAt': null,
        // Содержание прошлого раунда чистится ЗДЕСЬ ЖЕ, и это не украшение
        // симметрии. Проверка на устройствах 03.08: после состоявшейся
        // сделки новое предложение уходило с датой и типом предыдущего —
        // у инициатора стояло «Tarix dəyiş» вместо «Tarix seç», а у
        // получателя кнопка «Razıyam» была сразу золотой, то есть он мог
        // одним тапом согласиться на дату, которой в этом раунде никто не
        // выбирал, и договор создался бы на данных прошлой сделки.
        //
        // Дефект существовал и до правки роли cancelChat, но был виден
        // только на пути «согласие → новое предложение»: на пути «отказ →
        // новое предложение» его прятала уборка внутри cancelChat. Убрав
        // ту уборку ради следа раунда, я обнажил его на обоих путях —
        // поэтому чистка и переехала сюда целиком.
        //
        // С пунктом 3 сюда приходят уже выбранные значения, и это делает
        // тот дефект невозможным по устройству, а не по внимательности:
        // все четыре поля пишутся ВСЕГДА и безусловно, включая пустые
        // строки у места и заметок. Уцелеть прошлому значению негде —
        // каждое из четырёх перезаписывается на каждом новом предложении.
        // НЕ заменять пустое значение на пропуск ключа ради экономии: тем
        // самым вернётся ровно та дыра, через которую дата прошлой сделки
        // доезжала до нового раунда.
        //
        // НЕ приводить дату к UTC — то же «плавающее» гражданское время,
        // что и в saveChatEventDate ниже (N4).
        'eventDate': eventDate.toIso8601String(),
        'eventType': eventType,
        'eventLocation': eventLocation,
        'eventNotes': eventNotes,
      }).timeout(_writeTimeout);
    } catch (e, st) {
      debugPrint('\u274c setJobOffer failed: $e');
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'FirestoreService: setJobOffer failed',
      );
    }
  }

  // Initiator picks/changes the proposed event's date+type+location+notes
  // while a job offer is pending — lives on the chat doc, not yet a real
  // PersonalEvent (mirrors mugam-v2's saveChatEventDate).
  Future<void> saveChatEventDate({
    required String chatId,
    required DateTime eventDate,
    required String eventType,
    required String eventLocation,
    required String eventNotes,
  }) async {
    try {
      await _db.collection('chats').doc(chatId).update({
        // НЕ приводить к UTC вместе с остальными отметками времени
        // (N4). Это «плавающее» гражданское время: тədbir в 20:00
        // остаётся в 20:00 в том месте, где он проходит, а не сдвигается
        // вслед за поясом смотрящего. Перевод в UTC сломал бы показ даты
        // договора при поездке — то есть создал бы баг там, где его нет.
        // Единообразие здесь — ложная цель, см. запрет в реестре.
        'eventDate': eventDate.toIso8601String(),
        'eventType': eventType,
        'eventLocation': eventLocation,
        'eventNotes': eventNotes,
        // Причина напоминания «ждут от вас дату» только что исчезла —
        // дата выбрана (N17). Раньше это поле не сбрасывал никто до конца
        // раунда, а статусная строка плашки инициатора проверяет его
        // ПЕРВЫМ: с первого раннего тапа и до согласия там висело
        // «🤝 cavab gözləyir», перекрывая и «печатает», и «прочитал».
        //
        // Повторного окна сброс не создаёт: показ гасится отметкой
        // negotiationSeenAt, а не наличием поля.
        'waitingForDateAt': null,
        // Шаг раунда, а не содержание: «предложение с датой». Пишется и при
        // повторном заходе через «Tarix dəyiş» — значение то же самое,
        // запись идемпотентна.
        'roundStep': 'dated',
      }).timeout(_writeTimeout);
    } catch (e, st) {
      debugPrint('\u274c saveChatEventDate failed: $e');
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'FirestoreService: saveChatEventDate failed',
      );
    }
  }

  // Recipient taps "Razıyam" before the initiator has picked a date yet —
  // lets the initiator's banner show "waiting for a date" (mugam-v2's
  // setWaitingForDate). Writes a timestamp (not a bare bool) so the
  // initiator's own client can durably tell "have I already seen the
  // waiting-for-date signal for THIS particular flip" via
  // negotiationSeenAt, instead of racing to self-reset a shared flag the
  // moment whichever client happens to be live-mounted observes it —
  // that self-resetting design is what silently dropped this nudge
  // on-device (confirmed 2026-08-01: the initiator's screen simply wasn't
  // mounted at the exact instant the flag flipped, and by the time it
  // reopened the flag had already been reset/overwritten by someone else).
  Future<void> setWaitingForDate({
    required String chatId,
    required bool waiting,
  }) async {
    try {
      await _db.collection('chats').doc(chatId).update({
        'waitingForDateAt': waiting ? nowInstantIso() : null,
      }).timeout(_writeTimeout);
    } catch (e, st) {
      debugPrint('\u274c setWaitingForDate failed: $e');
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'FirestoreService: setWaitingForDate failed',
      );
    }
  }

  // Durable per-uid "I have shown this uid's own client the latest
  // negotiation dialog (waiting-for-date nudge or agreed celebration)"
  // marker — mirrors the existing lastReadAt.{uid} idiom (see
  // markChatAsReadBy below) instead of a shared self-resetting flag, so a
  // dialog that fires while this uid's chat screen isn't mounted is never
  // silently lost: reopening the chat re-compares the signal's own
  // timestamp against this mark and still shows it if it's newer.
  Future<void> markNegotiationSeen({
    required String chatId,
    required String uid,
  }) async {
    try {
      await _db.collection('chats').doc(chatId).update({
        'negotiationSeenAt.$uid': nowInstantIso(),
      }).timeout(_writeTimeout);
    } catch (e, st) {
      debugPrint('\u274c markNegotiationSeen failed: $e');
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'FirestoreService: markNegotiationSeen failed',
      );
    }
  }

  // Either party taps "İmtina" on a pending job offer, before or after a
  // date was picked — ends the negotiation without ever creating a
  // PersonalEvent (unlike acceptJobOffer below). Unlike an agreed offer,
  // nothing was actually finalized here, so the ongoing 1:1 chat itself
  // must NOT be marked completed/hidden — only the negotiation fields
  // reset, so "İş təklif et" becomes offerable again and the chat stays
  // exactly where it was. (mugam-v2's own cancelChat sets completed:true
  // here too, which silently vanishes the whole conversation from both
  // parties' chat list the moment anyone declines a proposal — confirmed
  // on-device as a real, confusing regression, not intentional parity
  // worth keeping.)
  Future<void> cancelChat({
    required String chatId,
    required String uid,
  }) async {
    try {
      await _db.collection('chats').doc(chatId).update({
        // Дубль на переходное окно: прежние сборки прячут плашку по
        // jobOfferBy, новые — по roundStep. Снимается вместе с
        // recipientAgreed, условие в реестре.
        'cancelledBy': uid,
        // Раунд закрыт отказом. Сторона не записывается отдельным полем:
        // roundEndedBy == jobOfferBy означает «инициатор передумал», иначе
        // «получатель отказался». В чате на двоих третьего случая нет, так
        // что вывод полный — а второе поле было бы вторым источником той же
        // правды, который однажды разойдётся с первым.
        'roundStep': 'ended',
        'roundEndedBy': uid,
        'roundEndedAt': nowInstantIso(),
        // СОДЕРЖАНИЕ РАУНДА БОЛЬШЕ НЕ СТИРАЕТСЯ. jobOfferBy, jobOfferAt и
        // event* остаются на документе до следующего предложения — без них
        // от отказа не оставалось следа вовсе: поле cancelledBy стояло
        // рядом с пустотой, и «получатель отказался» было неотличимо от
        // «раунда никогда не было». Чистит их setJobOffer, и только он.
        //
        // Что продолжает сбрасываться и почему: recipientAgreed обязан
        // остаться false, иначе серверный сторож (before.recipientAgreed ===
        // true -> выход) пропустит следующее согласие; waitingForDateAt и
        // negotiationSeenAt — отметки показанных окон этого раунда, для
        // закрытого раунда они бессмысленны.
        'waitingForDateAt': null,
        'recipientAgreed': false,
        'recipientAgreedAt': null,
        'negotiationSeenAt': {},
      }).timeout(_writeTimeout);
    } catch (e, st) {
      debugPrint('\u274c cancelChat failed: $e');
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'FirestoreService: cancelChat failed',
      );
    }
  }

  // Recipient taps "Razıyam" once a date is set — this is the ONLY
  // client-side write on accept. It just flags the chat doc; the
  // onChatUpdated Cloud Function (functions/src/index.ts) is what actually
  // creates the PersonalEvent (with ownerUid = the INITIATOR, not this
  // uid) and marks the chat completed, since personalEvents' own create
  // rule requires the creator to become ownerUid — which must stay the
  // initiator, not whoever accepts. Doing this server-side with the Admin
  // SDK is what makes that possible without loosening that rule.
  /// Возвращает `true`, если согласие ДОШЛО до базы.
  ///
  /// Раньше метод глотал исключение молча, и экран не мог отличить «не
  /// записалось» от «записалось». А это разные вещи и разные действия
  /// человека: в первом случае нажать надо ещё раз, во втором нельзя —
  /// второй договор на ту же сделку не даст создать защита в
  /// `onChatUpdated`, и повтор просто ничего не изменит.
  Future<bool> acceptJobOffer({
    required String chatId,
    required String uid,
  }) async {
    try {
      await _db.collection('chats').doc(chatId).update({
        'recipientAgreed': true,
        'recipientAgreedAt': nowInstantIso(),
        // Дубль на переходное окно. Серверный триггер пока смотрит на
        // recipientAgreed — перевод его на roundStep идёт отдельным шагом,
        // вместе со снятием дубля, иначе одна выкатка меняла бы и клиента,
        // и условие срабатывания функции разом.
        'roundStep': 'agreed',
      }).timeout(_writeTimeout);
      return true;
    } catch (e, st) {
      debugPrint('\u274c acceptJobOffer failed: $e');
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'FirestoreService: acceptJobOffer failed',
      );
      return false;
    }
  }

  // Per-uid "still typing" timestamp, scoped only to the job-offer
  // banners' status line — chat_screen.dart throttles calls to this (once
  // per ~3s) from the composer's onChanged, not this method itself, to
  // keep write volume down while a job offer is pending.
  Future<void> setTyping({
    required String chatId,
    required String uid,
  }) async {
    try {
      await _db.collection('chats').doc(chatId).update({
        'typing.$uid': nowInstantIso(),
      }).timeout(_writeTimeout);
    } catch (e, st) {
      debugPrint('\u274c setTyping failed: $e');
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'FirestoreService: setTyping failed',
      );
    }
  }

  // Narrow, dedicated stream of just this uid's clearedBy cutoff — used
  // ONLY by ChatMessagesController (never folded into watchChatMeta's
  // general-purpose projection below) so that unrelated chat-doc churn
  // (typing writes, jobOfferBy, etc.) never re-triggers the message
  // pagination listeners that consume this.
  //
  // Emits ChatClearedAt, not a bare DateTime?, because a missing value here
  // has two entirely different meanings and only one of them is an answer:
  //
  //   document exists, no clearedBy for this uid -> known(null): this chat
  //     has genuinely never been cleared. A fact, safe to act on and to
  //     persist.
  //   document not in the local cache and the server hasn't answered ->
  //     unknown: we know nothing. NOT a fact, must never be persisted.
  //
  // Folding both into null is what N13 was: the second case was written to
  // disk as "never cleared", and unlike the earlier members of this family
  // that mistake does NOT heal when connectivity returns — the false record
  // outlives the outage and is trusted on every later cold open.
  //
  // `snap.exists || !snap.metadata.isFromCache` is the exact test, not a
  // heuristic: a snapshot either carries the document (whatever its age —
  // a stale cutoff is still a real one, and cutoffs only move forward), or
  // it comes from the server, which is authoritative about the document not
  // existing. Only "absent AND merely from cache" is silence.
  //
  // includeMetadataChanges is required for the same reason: without it, the
  // cache-miss -> server-confirms-absent transition carries no data change
  // and would never be raised, stranding a genuinely deleted chat in the
  // unknown state forever.
  Stream<ChatClearedAt> watchChatClearedAt(String chatId, String uid) {
    return _watchChatDoc(chatId)
        .map((snap) {
          if (!snap.exists && snap.metadata.isFromCache) {
            return const ChatClearedAt.unknown();
          }
          final raw = snap.data()?['clearedBy'];
          if (raw is! Map) return const ChatClearedAt.known(null);
          final value = raw[uid];
          if (value == null) return const ChatClearedAt.known(null);
          return ChatClearedAt.known(DateTime.tryParse(value.toString()));
        })
        .distinct();
  }

  // Narrow, dedicated stream of just the typing map — same rationale as
  // watchChatClearedAt above, and for the same reason: typing.{uid} writes
  // every ~3s while a job offer is pending, and it used to be folded into
  // watchChatMeta's general projection, which chat_screen.dart's entire
  // ~1000-line build() watches directly. That meant every typing write
  // rebuilt the whole chat screen (message list included) instead of just
  // the job-offer banner's one status line — confirmed as the dominant
  // contributor to a runaway write/rebuild storm (~20 chats/{chatId}
  // writes/sec, ~2000 onChatUpdated invocations in under 5 minutes) that
  // heated the device and starved real message sends of contention on the
  // same document via _commitMessage's transaction. Only the small
  // Consumer built around this stream (see _buildJobOfferBanner) should
  // ever watch it.
  Stream<Map<String, dynamic>> watchChatTyping(String chatId) {
    return _watchChatDoc(chatId)
        .map((snap) => Map<String, dynamic>.from(snap.data()?['typing'] ?? {}))
        .distinct(_deepEquals);
  }

  Stream<List<PersonalEvent>> watchPersonalEvents(String uid) {
    return _db
        .collection('personalEvents')
        .where('ownerUid', isEqualTo: uid)
        .snapshots()
        // Пустой снимок ИЗ КЭША — не ответ, а молчание (N14). Тот же
        // признак и та же узость, что у watchChats: пусто с сервера —
        // настоящий ответ, непустое из кэша — настоящие данные; молчание
        // это только два условия вместе. Не отдавая такой снимок, поток
        // оставляет провайдер в состоянии загрузки, и экран рисует
        // ожидание вместо пустоты, выданной за факт.
        .where((snap) => !(snap.docs.isEmpty && snap.metadata.isFromCache))
        .map(
          (snap) => snap.docs
              .map((doc) => PersonalEvent.fromFirestore(doc.id, doc.data()))
              .toList(),
        );
  }

  Stream<List<PersonalEvent>> watchEventsAsParticipant(String uid) {
    return _db
        .collection('personalEvents')
        .where('musicians', arrayContains: uid)
        .snapshots()
        // Пустой снимок ИЗ КЭША — не ответ, а молчание (N14). Тот же
        // признак и та же узость, что у watchChats: пусто с сервера —
        // настоящий ответ, непустое из кэша — настоящие данные; молчание
        // это только два условия вместе. Не отдавая такой снимок, поток
        // оставляет провайдер в состоянии загрузки, и экран рисует
        // ожидание вместо пустоты, выданной за факт.
        .where((snap) => !(snap.docs.isEmpty && snap.metadata.isFromCache))
        .map(
          (snap) => snap.docs
              .map((doc) => PersonalEvent.fromFirestore(doc.id, doc.data()))
              .toList(),
        );
  }

  /// [replacedEventId] — id мероприятия, взамен которого это создано
  /// («Əvəz et»). По нему сервер узнаёт пару «удалили старое, создали
  /// новое» и шлёт ОДНО уведомление «tədbir əvəz edildi» вместо двух —
  /// «silindi» и «əlavə olundunuz», из которых первое пугает зря.
  Future<String> addPersonalEvent({
    required String ownerUid,
    required String date,
    required String type,
    required String location,
    required String notes,
    required List<String> participantUids,
    String? replacedEventId,
  }) async {
    final ref = await _db.collection('personalEvents').add({
      'ownerUid': ownerUid,
      'date': date,
      'type': type,
      'location': location,
      'notes': notes,
      'musicians': participantUids,
      // Ответы состава — шаг 1 работы «договоры и мероприятия — одна
      // сущность» (`docs/plan.md`). Пишется рядом с `musicians`, НИКЕМ на
      // этом шаге не читается. Правило — одной функцией на всех писателей
      // (`core/agreements/event_answers.dart`), а не строкой здесь: иначе
      // создание и правка разошлись бы в том, что значит «состав», и
      // разошлись бы молча.
      // `ownerUid` — чтобы владелец, попавший в состав, не оказался ждущим
      // ответа на собственном вечере (N112).
      'answers': answersForParticipants(participantUids, ownerUid: ownerUid),
      'isAgree': false,
      'agreementChatId': null,
      'partnerUid': null,
      'partnerName': null,
      'status': 'agreed',
      // Те же четыре поля, что пишет серверная половина (onChatUpdated):
      // договор, заведённый вручную, и договор из согласованного предложения
      // обязаны иметь один набор полей — иначе отмена по согласию работала
      // бы на одних и молча не работала на других.
      'cancelRequestedBy': null,
      'cancelRequestedAt': null,
      'cancelConfirmedBy': null,
      'cancelledAt': null,
      'replacedEventId': replacedEventId,
      // Признак автора: Firestore-триггер видит before/after, но не видит,
      // КТО писал, а от этого зависит, кому уходит уведомление и чьё имя в
      // нём стоит. Правила не дают выставить его чужим uid.
      'lastActionBy': ownerUid,
      'lastActionType': replacedEventId == null ? 'created' : 'replaced',
      'createdAt': FieldValue.serverTimestamp(),
    }).timeout(_writeTimeout);
    return ref.id;
  }

  Future<void> updatePersonalEvent(String eventId, Map<String, dynamic> data) {
    return _db.collection('personalEvents').doc(eventId).update(data).timeout(_writeTimeout);
  }

  /// Есть ли уже договор, созданный из этого чата.
  ///
  /// Нужен для ожидания после «Razıyam»: сам договор создаёт Cloud
  /// Function (`onChatUpdated`), а не приложение, поэтому в момент записи
  /// согласия его ещё нет. Раньше человека уводили в «Müqavilələr»
  /// немедленно — и при неудаче функции он приходил в список, где ничего
  /// не появилось, без единого слова о том, что пошло не так.
  ///
  /// ФОРМА ЗАПРОСА ЗАДАНА ПРАВИЛАМИ, А НЕ УДОБСТВОМ. Первая редакция
  /// фильтровала по одному `agreementChatId` — и сервер отказывал по
  /// правам: чтение `personalEvents` разрешено владельцу ИЛИ участнику, а
  /// фильтр по чату этого не доказывает. Firestore авторизует запрос
  /// только когда его СОБСТВЕННЫЕ фильтры доказывают правило для любого
  /// возможного результата (та же ловушка, что у ленты статусов, коммит
  /// d6b2ad6 и комментарий выше в этом файле).
  ///
  /// Поэтому фильтр — по участию, ровно той же формы, что у
  /// `eventsAsParticipantProvider`, а совпадение по чату проверяется уже
  /// на клиенте: договоров у человека десятки, не тысячи.
  /// [roundAt] — `jobOfferAt` текущего раунда. Обязателен: без него
  /// «договор этого раунда» неотличим от «договор когда-либо в этом
  /// чате», а прошлый договор лежит в чате всегда, начиная со второй
  /// сделки. Проверка отвечала бы «готово» мгновенно, и ожидание после
  /// «Razıyam» не ждало бы ничего (N29).
  Future<bool> agreementExistsForRound(
    String chatId,
    String uid,
    String? roundAt,
  ) async {
    if (roundAt == null || roundAt.isEmpty) return false;
    final snap = await _db
        .collection('personalEvents')
        .where('musicians', arrayContains: uid)
        .get()
        .timeout(_writeTimeout);
    return snap.docs.any((d) {
      final v = d.data();
      return v['agreementChatId'] == chatId && v['jobOfferAt'] == roundAt;
    });
  }

  /// Удалить мероприятие — у ВСЕХ. Правила разрешают это только
  /// владельцу.
  Future<void> deletePersonalEvent(String eventId) {
    return _db
        .collection('personalEvents')
        .doc(eventId)
        .delete()
        .timeout(_writeTimeout);
  }

  /// Выйти из ЧУЖОГО мероприятия — убрать себя из участников.
  ///
  /// Не удаление: в мероприятии заняты и другие люди, у них оно остаётся.
  /// Из календаря вышедшего оно пропадает и перестаёт конфликтовать с
  /// новыми датами — ровно то, ради чего ход и заведён (`firestore.rules`
  /// → personalEvents → `leavesEvent`, разбор там же).
  ///
  /// `arrayRemove`, а не перезапись списка: он идемпотентен по природе —
  /// повторный вызов ничего не портит, и две попытки подряд не могут
  /// вычеркнуть лишнего. Тот же принцип, что у сборщика сирот.
  Future<void> leavePersonalEvent(String eventId, String uid) {
    return _db
        .collection('personalEvents')
        .doc(eventId)
        .update({
          'musicians': FieldValue.arrayRemove([uid]),
          // Без этих двух полей «вышел сам» и «владелец убрал» на сервере
          // неразличимы — из musicians в обоих случаях пропадает один uid,
          // — и уведомление ушло бы не тому. Правило `leavesEvent`
          // разрешает ровно эту тройку ключей и ничего сверх.
          'lastActionBy': uid,
          'lastActionType': 'left',
        })
        .timeout(_writeTimeout);
  }

  // ОТМЕНА ДОГОВОРА ПО СОГЛАСИЮ — четыре хода, по одному на каждое
  // разрешённое правилом изменение (`firestore.rules` → personalEvents).
  //
  // Каждый метод пишет РОВНО те ключи, что разрешает его правило, и
  // ничего сверх: правила построены на `hasOnly`, поэтому лишнее поле
  // здесь — не «немного больше данных», а отказ по правам целиком.
  //
  // Отказ НЕ ГЛОТАЕТСЯ ни одним из четырёх: `permission-denied` здесь
  // означает, что вторая сторона успела сходить первой, и это ровно то,
  // о чём человеку надо сказать словами. Перехват превратил бы «не
  // получилось никогда» в «получилось» — класс «перехват без последствий
  // делает поломку невидимой». Разбор в `agreements_screen.dart`, где
  // отказ и превращается в слова.

  /// Прочитать мероприятие С СЕРВЕРА, минуя кэш (N45).
  ///
  /// Нужно ровно для одного: после отказа по правам спросить, объясняет
  /// ли состояние документа этот отказ. Из кэша ответ бесполезен — там
  /// лежит ровно та картина, из которой мы и решили, что ход законен, и
  /// она подтвердит нашу же ошибку.
  ///
  /// Возвращает `null`, когда прочитать не удалось (сети нет, документ
  /// исчез): тогда сказать нечего, и вызывающий обязан считать причину
  /// неизвестной, а не додумывать.
  Future<PersonalEvent?> fetchPersonalEventFromServer(String eventId) async {
    try {
      final snap = await _db
          .collection('personalEvents')
          .doc(eventId)
          .get(const GetOptions(source: Source.server))
          .timeout(_writeTimeout);
      final data = snap.data();
      if (!snap.exists || data == null) return null;
      return PersonalEvent.fromFirestore(snap.id, data);
    } catch (_) {
      return null;
    }
  }

  /// Ход первый: предложить отмену.
  ///
  /// `lastActionBy`/`lastActionType` пишутся всеми четырьмя ходами, а не
  /// только снятием: имя автора для текста уведомления сервер берёт
  /// именно из `lastActionBy`, и без него «{Ad} müqavilənin ləğvini təklif
  /// etdi» назвало бы владельца вместо просящего.
  Future<void> requestAgreementCancel(String eventId, String uid) {
    return _db
        .collection('personalEvents')
        .doc(eventId)
        .update({
          'cancelRequestedBy': uid,
          'cancelRequestedAt': FieldValue.serverTimestamp(),
          'lastActionBy': uid,
          'lastActionType': 'cancelRequested',
        })
        .timeout(_writeTimeout);
  }

  /// Вернуть договор из «под вопросом» в силу — «продолжаю без него».
  ///
  /// **Ход односторонний и НЕОБРАТИМЫЙ**, в отличие от отмены: та лишь
  /// задаёт вопрос второй стороне и без её согласия ничего не меняет, а
  /// этот немедленно даёт обещание прийти. Поэтому вызывающий обязан
  /// спросить подтверждение — оно нужно не «важному» действию, а
  /// необратимому.
  ///
  /// Доступен ТОЛЬКО владельцу и ТОЛЬКО при поводе `memberLeft`; и то и
  /// другое закреплено правилом `restoresEvent()` в `firestore.rules`, а
  /// не вежливостью экрана. При поводе «исчезла работа» возвращать не к
  /// чему: родительский договор отменён по согласию, и обратного хода у
  /// отмены нет вовсе.
  Future<void> restoreUnsettledAgreement(String eventId, String uid) {
    return _db
        .collection('personalEvents')
        .doc(eventId)
        .update({
          'status': 'agreed',
          'lastActionBy': uid,
          // ЛИТЕРАЛ, а не константа `kRestoredDeed`, — и это не
          // небрежность. Проход по исходникам, сторожащий имена поступков
          // (`test/agreement_cancel_test.dart`), читает ЛИТЕРАЛЫ: он
          // существует затем, чтобы придуманное имя сюда не пролезло.
          // Спрячь значение за константу — и сторож перестанет его
          // видеть, то есть ослабнет ровно там, где сторожит. Все четыре
          // имени отмены написаны здесь по той же причине.
          //
          // Константа при этом есть и нужна: по ней тест сверяет имя с
          // `firestore.rules`. Значение одно, читателей два, и каждый
          // читает своим способом.
          'lastActionType': 'restored',
        })
        .timeout(_writeTimeout);
  }

  /// Ход второй: подтвердить ЧУЖОЙ запрос. Договор становится `cancelled`.
  Future<void> confirmAgreementCancel(String eventId, String uid) {
    return _db
        .collection('personalEvents')
        .doc(eventId)
        .update({
          'status': 'cancelled',
          'cancelConfirmedBy': uid,
          'cancelledAt': FieldValue.serverTimestamp(),
          'lastActionBy': uid,
          'lastActionType': 'cancelConfirmed',
        })
        .timeout(_writeTimeout);
  }

  /// Отзыв: запросивший передумал.
  ///
  /// Отзыв и отказ пишут ОДНО И ТО ЖЕ — пустые поля запроса, — и
  /// различаются только именем поступка. Имя не косметика: сервер видит
  /// `before`/`after`, но не видит, кто писал, и без имени уведомление
  /// ушло бы не тому. Подделать его правила не дают — отозвать может
  /// только сам запросивший (разбор — класс «подделывается не действие, а
  /// рассказ о нём»).
  Future<void> withdrawAgreementCancel(String eventId, String uid) {
    return _db
        .collection('personalEvents')
        .doc(eventId)
        .update({
          'cancelRequestedBy': null,
          'cancelRequestedAt': null,
          'lastActionBy': uid,
          'lastActionType': 'cancelWithdrawn',
        })
        .timeout(_writeTimeout);
  }

  /// Отказ: вторая сторона не согласна на отмену.
  Future<void> declineAgreementCancel(String eventId, String uid) {
    return _db
        .collection('personalEvents')
        .doc(eventId)
        .update({
          'cancelRequestedBy': null,
          'cancelRequestedAt': null,
          'lastActionBy': uid,
          'lastActionType': 'cancelDeclined',
        })
        .timeout(_writeTimeout);
  }

  /// Отметки «прочитано» — ПОТОКОМ, а не разовым чтением.
  ///
  /// Разовое чтение стояло здесь, пока отметку снимал только сам человек:
  /// список менялся лишь его собственным тапом, и экран знал об этом без
  /// всякой подписки.
  ///
  /// С N40 отметку снимает ещё и сервер — у второй стороны, когда договор
  /// правят (`clearReadMark`, functions/src/index.ts). Разовое чтение
  /// сделало бы это бесполезным: экран договоров живёт в `IndexedStack` и
  /// от первого показа до конца сессии не пересоздаётся, то есть золотая
  /// рамка «непрочитано» вернулась бы не раньше перезапуска приложения. На
  /// iOS, где push'а нет вовсе (N20), это и есть единственный признак
  /// правки — признак, приходящий назавтра, не признак.
  /// `distinct` ОБЯЗАТЕЛЕН, а не оптимизация «на всякий случай».
  ///
  /// Документ `users/{uid}` — самый горячий в приложении: в него бьётся
  /// сердцебиение присутствия (`setUserPresence`, раз в 30–60 с, а при
  /// открытом чате чаще). Без отсева экран договоров — четыре тысячи строк
  /// и три вложенных списка — перерисовывался бы целиком на каждый удар,
  /// хотя отметки прочтения при этом не менялись ни разу.
  ///
  /// Найдено собственным разбором сразу после того, как поток был написан:
  /// подписка ставилась на нужное поле, но слушала весь документ. Тот же
  /// класс, что «одно поле на два вопроса» — здесь один документ на два
  /// потока с несопоставимой частотой.
  Stream<List<String>> watchReadAgreementIds(String uid) {
    return _db
        .collection('users')
        .doc(uid)
        .snapshots()
        .map(
          (doc) =>
              (doc.data()?['readAgreementIds'] as List?)?.cast<String>() ??
              const <String>[],
        )
        .distinct(listEquals);
  }

  Future<void> saveReadAgreementId(String uid, String agreementId) {
    return _db.collection('users').doc(uid).update({
      'readAgreementIds': FieldValue.arrayUnion([agreementId]),
    });
  }

  // ---------------------------------------------------------------------
  // Friends (friendRequests/{requestId} + users/{uid}/friends/{friendUid})
  // See lib/firebase/models.dart's FriendRequest class for the full
  // lifecycle rationale and firestore.rules for what each of these is
  // actually allowed to do server-side.
  // ---------------------------------------------------------------------

  // Deterministic pair id — sorted so it's the same regardless of who's
  // "from" and who's "to", which is what lets a single doc.get()/snapshot
  // (rather than an OR of two queries) answer "what's the relationship
  // between these two people right now."
  String friendRequestDocId(String uidA, String uidB) {
    final sorted = [uidA, uidB]..sort();
    return '${sorted[0]}_${sorted[1]}';
  }

  // Drives the "Add friend" button's state on a profile screen: null (no
  // relationship), pending (sent-by-me or sent-to-me — check
  // .fromUid/.otherUid against the viewer), or accepted (already friends).
  Stream<FriendRequest?> watchFriendRequestBetween(String uidA, String uidB) {
    return _db
        .collection('friendRequests')
        .doc(friendRequestDocId(uidA, uidB))
        .snapshots()
        .map(
          (doc) => doc.exists
              ? FriendRequest.fromFirestore(doc.id, doc.data()!)
              : null,
        );
  }

  Future<void> sendFriendRequest({
    required String fromUid,
    required String toUid,
  }) {
    final id = friendRequestDocId(fromUid, toUid);
    return _db.collection('friendRequests').doc(id).set({
      'fromUid': fromUid,
      'toUid': toUid,
      'status': 'pending',
      'createdAt': FieldValue.serverTimestamp(),
      'respondedAt': null,
    });
  }

  Future<void> acceptFriendRequest(String requestId) {
    return _db.collection('friendRequests').doc(requestId).update({
      'status': 'accepted',
      'respondedAt': FieldValue.serverTimestamp(),
    });
  }

  // Covers cancel (sender, still pending), decline (recipient, still
  // pending), and unfriend (either side, already accepted) — all three
  // are the same delete at the data level; see firestore.rules for why one
  // `allow delete` covers all of them.
  Future<void> removeFriendRequestOrFriendship(String requestId) {
    return _db.collection('friendRequests').doc(requestId).delete();
  }

  Stream<List<FriendRequest>> watchIncomingFriendRequests(String uid) {
    return _db
        .collection('friendRequests')
        .where('toUid', isEqualTo: uid)
        .where('status', isEqualTo: 'pending')
        .snapshots()
        .map(
          (snap) => snap.docs
              .map((doc) => FriendRequest.fromFirestore(doc.id, doc.data()))
              .toList(),
        );
  }

  Stream<List<FriendRequest>> watchOutgoingFriendRequests(String uid) {
    return _db
        .collection('friendRequests')
        .where('fromUid', isEqualTo: uid)
        .where('status', isEqualTo: 'pending')
        .snapshots()
        .map(
          (snap) => snap.docs
              .map((doc) => FriendRequest.fromFirestore(doc.id, doc.data()))
              .toList(),
        );
  }

  // Confirmed friends' uids only — server-maintained, see the
  // users/{uid}/friends comment in firestore.rules.
  Stream<List<String>> watchFriendUids(String uid) {
    return _db
        .collection('users')
        .doc(uid)
        .collection('friends')
        .snapshots()
        .map((snap) => snap.docs.map((doc) => doc.id).toList());
  }
}

final firestoreServiceProvider = Provider<FirestoreService>(
  (_) => FirestoreService(),
);

final musiciansProvider = StreamProvider<List<User>>(
  (ref) => ref.watch(firestoreServiceProvider).watchAllUsers(),
);

final allUsersProvider = StreamProvider<List<User>>(
  (ref) => ref.watch(firestoreServiceProvider).watchAllUsers(),
);

// autoDispose with a grace period, not a bare autoDispose — this is read
// per-message-bubble for every sender (chat_screen.dart's message list),
// so a plain ListView.builder recycling a bubble out of and back into the
// build range (normal scroll-up-to-read-history-then-back-down) would
// otherwise dispose and re-fetch the same user on every pass, risking a
// visible blank-name/avatar flicker each time. ref.keepAlive() overrides
// the default "dispose the instant listeners hit zero" behavior; onCancel
// (last listener gone) starts a grace timer instead of disposing
// immediately, onResume (a new listener before that timer fires) cancels
// it, so only a sender nobody has scrolled near in a while actually gets
// disposed. 10s comfortably covers a normal scroll-away-and-back or a
// pause to read older messages, while still reclaiming memory for
// senders no longer in view within a reasonable window (not held for the
// entire chat-screen lifetime, unlike a plain non-autoDispose family).
final userByIdProvider = FutureProvider.autoDispose.family<User?, String>((
  ref,
  uid,
) {
  final link = ref.keepAlive();
  Timer? disposeTimer;
  ref.onCancel(() {
    disposeTimer = Timer(const Duration(seconds: 10), link.close);
  });
  ref.onResume(() {
    disposeTimer?.cancel();
  });
  ref.onDispose(() {
    disposeTimer?.cancel();
  });
  return ref.watch(firestoreServiceProvider).fetchUserById(uid);
});

final currentUserProvider = StreamProvider.family<User?, String>((
  ref,
  uid,
) {
  return ref.watch(firestoreServiceProvider).watchUserById(uid);
});

final callProvider = StreamProvider.family<Call?, String>((ref, callId) {
  return ref.watch(firestoreServiceProvider).watchCall(callId);
});

// One-off lookup, used only as a fallback when a message referenced by id
// (e.g. lastReadMsgId in message_info_screen.dart) isn't already present in
// ChatMessagesController's currently-loaded window (finding #4) — so this
// is expected to almost always hit cheaply for recent chats and only
// actually fetch for messages well back in a long history.
final messageByIdProvider = FutureProvider.autoDispose
    .family<Message?, ({String chatId, String messageId})>((ref, args) {
      return ref
          .watch(firestoreServiceProvider)
          .fetchMessageById(chatId: args.chatId, messageId: args.messageId);
    });

final personalEventsProvider =
    StreamProvider.family<List<PersonalEvent>, String>(
      (ref, uid) =>
          ref.watch(firestoreServiceProvider).watchPersonalEvents(uid),
    );

final eventsAsParticipantProvider =
    StreamProvider.family<List<PersonalEvent>, String>(
      (ref, uid) =>
          ref.watch(firestoreServiceProvider).watchEventsAsParticipant(uid),
    );

final readAgreementIdsProvider = StreamProvider.family<List<String>, String>(
  (ref, uid) => ref.watch(firestoreServiceProvider).watchReadAgreementIds(uid),
);

final chatsProvider = StreamProvider.family<List<Chat>, String>((ref, uid) {
  return ref.watch(firestoreServiceProvider).watchChats(uid);
});

final statusFeedProvider =
    StreamProvider.family<List<StatusGroup>, String>((ref, uid) {
      return ref.watch(firestoreServiceProvider).watchStatusFeed(uid);
    });

// autoDispose — called once per status currently shown in the feed as the
// user scrolls through many different owners' statuses over the app's
// lifetime, same "don't pin every combination ever seen" rationale as
// messageByIdProvider's own autoDispose above. viewerUid is deliberately
// NOT part of the family key (there is only ever one signed-in user at a
// time, unlike ownerUid which varies per status) — read directly from
// FirebaseAuth here rather than threaded through as a parameter, matching
// the precedent in core/settings/upload_limit_settings.dart.
final hasViewedStatusProvider = FutureProvider.autoDispose
    .family<bool, ({String ownerUid, String statusId})>((ref, args) {
      final viewerUid = FirebaseAuth.instance.currentUser?.uid ?? '';
      return ref
          .watch(firestoreServiceProvider)
          .hasViewedStatus(
            ownerUid: args.ownerUid,
            statusId: args.statusId,
            viewerUid: viewerUid,
          );
    });

// autoDispose — only ever watched while StatusViewersScreen (the owner's
// "Baxanlar" list) is on-screen for one specific status, same rationale as
// hasViewedStatusProvider's own autoDispose above.
final statusViewersProvider = StreamProvider.autoDispose
    .family<List<StatusViewer>, ({String ownerUid, String statusId})>((
      ref,
      args,
    ) {
      return ref
          .watch(firestoreServiceProvider)
          .watchStatusViewers(ownerUid: args.ownerUid, statusId: args.statusId);
    });

// autoDispose — only ever watched via widget.chatId within chat_screen.dart's
// own lifetime (plus message_info_screen.dart reading the same two), so
// tearing down on exit and re-fetching/re-subscribing on re-entry is the
// same already-proven pattern chatMessagesControllerProvider's own tail
// listener uses for this exact screen, not a new one.
final chatDataProvider =
    FutureProvider.autoDispose.family<Map<String, dynamic>?, String>((
      ref,
      chatId,
    ) {
      return ref.watch(firestoreServiceProvider).fetchChatData(chatId);
    });

final chatMetaProvider =
    StreamProvider.autoDispose.family<Map<String, dynamic>, String>((
      ref,
      chatId,
    ) {
      return ref.watch(firestoreServiceProvider).watchChatMeta(chatId);
    });

// Narrow counterpart to chatMetaProvider above, watched ONLY by the
// job-offer banner's small status-line Consumer in chat_screen.dart — see
// watchChatTyping's own comment for why this must stay separate from
// chatMetaProvider rather than being read off chatMetaAsync.value like
// every other negotiation field.
final chatTypingProvider =
    StreamProvider.autoDispose.family<Map<String, dynamic>, String>((
      ref,
      chatId,
    ) {
      return ref.watch(firestoreServiceProvider).watchChatTyping(chatId);
    });

final starredMessagesProvider =
    StreamProvider.family<List<StarredMessage>, String>((ref, uid) {
      return ref.watch(firestoreServiceProvider).watchStarredMessages(uid);
    });

// Число видимых изображений чата — считается по требованию, на экране,
// который его показывает (N3). Autodispose по умолчанию у FutureProvider
// .family: пересчёт происходит при входе на экран, а не живёт фоном.
final chatImageCountProvider = FutureProvider.family<int, String>((
  ref,
  chatId,
) {
  return ref.watch(firestoreServiceProvider).countChatImages(chatId);
});

final chatMediaProvider = StreamProvider.family<List<Message>, String>((
  ref,
  chatId,
) {
  return ref.watch(firestoreServiceProvider).watchChatMedia(chatId);
});

// autoDispose — watched only while a specific profile screen is open (the
// "Add friend" button's state), same "don't pin every pair ever viewed"
// rationale as hasViewedStatusProvider/chatDataProvider above.
final friendRequestBetweenProvider = StreamProvider.autoDispose
    .family<FriendRequest?, ({String uidA, String uidB})>((ref, args) {
      return ref
          .watch(firestoreServiceProvider)
          .watchFriendRequestBetween(args.uidA, args.uidB);
    });

final incomingFriendRequestsProvider =
    StreamProvider.family<List<FriendRequest>, String>((ref, uid) {
      return ref
          .watch(firestoreServiceProvider)
          .watchIncomingFriendRequests(uid);
    });

final outgoingFriendRequestsProvider =
    StreamProvider.family<List<FriendRequest>, String>((ref, uid) {
      return ref
          .watch(firestoreServiceProvider)
          .watchOutgoingFriendRequests(uid);
    });

final friendUidsProvider = StreamProvider.family<List<String>, String>((
  ref,
  uid,
) {
  return ref.watch(firestoreServiceProvider).watchFriendUids(uid);
});

// Drives the unread dot on the settings gear icon + the Dost sorğuları row
// (see ProfileSettingsScreen/profile_screen.dart's _HeaderIconButton) — a
// plain Provider, not a StreamProvider: reading .asData?.value off its two
// underlying streams already degrades to null/empty on loading or error
// rather than throwing, so the same rollback-safety posture as
// incomingFriendRequestsProvider's own AsyncError handling falls out of
// this for free (no dot rather than a surfaced error). A request with a
// null createdAt (server timestamp not yet landed, same benign race as
// onStatusCreated elsewhere) is treated as unread — safer than assuming
// it's old.
final hasUnreadFriendRequestsProvider = Provider.family<bool, String>((
  ref,
  uid,
) {
  final incoming =
      ref.watch(incomingFriendRequestsProvider(uid)).asData?.value ?? [];
  if (incoming.isEmpty) return false;
  final lastViewed =
      ref.watch(currentUserProvider(uid)).asData?.value?.lastViewedFriendRequestsAt;
  if (lastViewed == null) return true;
  return incoming.any(
    (r) => r.createdAt == null || r.createdAt!.compareTo(lastViewed) > 0,
  );
});
