import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/models/activity_type.dart';

extension UserListFiltering on List<User> {
  List<User> excludingUid(String uid) => where((u) => u.id != uid).toList();
}

class User {
  final String id;
  final String name;
  final String emoji;
  final String instrument;
  // Structured "Fəaliyyət növü" selection — `instrument` above stays a
  // derived display string (ActivityType.toDisplayLabel()) for every screen
  // that just prints/searches it as text; this is the queryable/structured
  // source of truth, written alongside it by EditProfileScreen. Null for
  // any user doc that predates this field, or that never set an activity
  // type.
  final ActivityType? activityType;
  final String city;
  final double rating;
  final int reviews;
  final bool available;
  final bool goldRing;
  final bool online;
  final Timestamp? lastSeen;
  // В каком чате человек СЕЙЧАС (N19). Пишется рядом с сердцебиением
  // присутствия, поэтому у признака есть срок годности: перестало биться
  // сердце — значение протухло, даже если само поле осталось.
  // null — в приложении, но не в чате; ключа нет вовсе — сборка, которая
  // его не пишет (см. переходное окно N19 в реестре).
  final String? activeChatId;
  // Интервал сердцебиения ЭТОЙ сборки. Сервер берёт двойной от него как
  // окно свежести; клиент — здесь же, чтобы обе стороны судили по одному
  // правилу, а смена частоты не требовала синхронного обновления всех.
  final int? presenceIntervalMs;
  final String bio;
  final String? photoURL;
  final int gigs;
  final bool verified;
  final String role;
  // Server-enforced cap (storage.rules reads this same field via
  // firestore.get()) on any single chat-media/file upload, in megabytes —
  // user-configurable in Settings, range [100, 2048]. Defaults to 100 for
  // any user doc written before this field existed.
  final int maxUploadSizeMb;
  // UI-state only, not sensitive — client-written the moment
  // FriendRequestsScreen opens (see markFriendRequestsViewed), compared
  // against each incoming FriendRequest.createdAt to drive the unread dot
  // on the settings gear icon and the Dost sorğuları row. Deliberately a
  // separate field from lastSeen above, which is presence-only.
  final Timestamp? lastViewedFriendRequestsAt;
  // Denormalized onto the user doc by onStatusCreated (functions/src/
  // index.ts) — the expiresAt of whichever status that trigger most
  // recently saw, regardless of privacyMode/isPublic (the avatar ring this
  // backs is a presence-style "do they currently have one" indicator, not a
  // visibility check — every screen showing a ring already fetches this
  // same User doc, same free-ride as isActuallyOnline below, avoiding an
  // N+1 per-row status query). Deliberately NOT recomputed on expiry itself
  // (no scheduled function exists, and Firestore's own TTL-based cleanup on
  // statuses can lag up to 24h behind expiresAt — see Status.expiresAt's
  // own comment) — hasActiveStatus below is what actually keeps this
  // truthful moment-to-moment despite that, the same way isActuallyOnline
  // cross-checks a possibly-stale `online` bool against lastSeen.
  final Timestamp? mostRecentStatusExpiresAt;
  // Denormalized alongside mostRecentStatusExpiresAt by the same
  // onStatusCreated trigger (arrayUnion on create, arrayRemove by
  // onStatusDeleted on delete — explicit or TTL-driven expiry, both fire
  // the same trigger). What mostRecentStatusExpiresAt alone can't provide:
  // a get()-able document id. A non-friend viewer can never list
  // users/{ownerUid}/statuses (that query stays visibleToUids-gated,
  // unchanged by the isPublic/get() split — see firestore.rules), so this
  // is how such a viewer's client discovers which statusId(s) to get()
  // once isPublic authorizes actually reading one. Defaults to an empty
  // list for any user doc predating this field, same as every other
  // predates-the-field default in this file.
  final List<String> activeStatusIds;
  // Denormalized alongside mostRecentStatusExpiresAt/activeStatusIds by the
  // same onStatusCreated trigger, just the new status's createdAt instead
  // of expiresAt — this is the "gold ring" side of ring parity: a fixed
  // point in time this owner most recently posted, compared against a
  // viewer's own lastViewedStatusOwnerAt entry for this owner (see
  // hasUnviewedStatusFrom below) to tell a truly-unviewed status apart
  // from one the viewer already saw. Never recomputed on expiry, same
  // caveat as mostRecentStatusExpiresAt.
  final Timestamp? mostRecentStatusCreatedAt;
  // Lives on the VIEWER's own user doc (not the owner's) — keyed by
  // ownerUid, one entry per status-author this viewer has ever viewed a
  // status from. Written client-side, batched alongside the existing
  // viewers/{viewerUid} write in FirestoreService.markStatusViewed (same
  // call, same batch, no new server trigger) — see that method's own
  // comment. Purely self-scoped ring-rendering state, not security-
  // relevant the way viewers/{viewerUid}'s own viewedAt is (that field
  // gates what the STATUS OWNER can see about who viewed them), so unlike
  // that field this one carries no serverTimestamp()-enforcement rule.
  // Defaults to an empty map for any user doc predating this field.
  final Map<String, Timestamp> lastViewedStatusOwnerAt;

  const User({
    required this.id,
    required this.name,
    required this.emoji,
    required this.instrument,
    this.activityType,
    required this.city,
    required this.rating,
    required this.reviews,
    required this.available,
    required this.goldRing,
    required this.online,
    this.lastSeen,
    this.activeChatId,
    this.presenceIntervalMs,
    required this.bio,
    this.photoURL,
    this.gigs = 0,
    this.verified = false,
    this.role = 'user',
    this.maxUploadSizeMb = 100,
    this.lastViewedFriendRequestsAt,
    this.mostRecentStatusExpiresAt,
    this.activeStatusIds = const [],
    this.mostRecentStatusCreatedAt,
    this.lastViewedStatusOwnerAt = const {},
  });

  factory User.fromFirestore(String id, Map<String, dynamic> data) {
    return User(
      id: id,
      name: (data['name'] ?? data['displayName'] ?? 'İstifadəçi') as String,
      emoji: (data['emoji'] ?? '🎵') as String,
      instrument: (data['instrument'] ?? data['specialty'] ?? '') as String,
      activityType: ActivityType.fromMap(
        data['activityType'] as Map<String, dynamic>?,
      ),
      city: (data['city'] ?? '') as String,
      rating: ((data['rating'] ?? 0) as num).toDouble(),
      reviews: (data['reviews'] ?? 0) as int,
      available: (data['available'] ?? false) as bool,
      goldRing: (data['goldRing'] ?? false) as bool,
      online: (data['online'] ?? false) as bool,
      lastSeen: data['lastSeen'] as Timestamp?,
      activeChatId: data['activeChatId'] as String?,
      presenceIntervalMs: (data['presenceIntervalMs'] as num?)?.toInt(),
      bio: (data['bio'] ?? '') as String,
      photoURL: data['photoURL'] as String?,
      gigs: (data['gigs'] ?? 0) as int,
      verified: (data['verified'] ?? false) as bool,
      role: (data['role'] ?? 'user') as String,
      maxUploadSizeMb: (data['maxUploadSizeMb'] ?? 100) as int,
      lastViewedFriendRequestsAt: data['lastViewedFriendRequestsAt'] as Timestamp?,
      mostRecentStatusExpiresAt: data['mostRecentStatusExpiresAt'] as Timestamp?,
      activeStatusIds:
          List<String>.from(data['activeStatusIds'] as List? ?? const []),
      mostRecentStatusCreatedAt: data['mostRecentStatusCreatedAt'] as Timestamp?,
      // A FieldValue.serverTimestamp() entry reads back as null in the
      // writing client's own optimistic local snapshot until the server
      // ack lands (standard Firestore behavior, not a data error) —
      // unconditionally casting every entry crashed this whole User's
      // parse (and therefore every list containing them, e.g. the home
      // feed) the instant anyone viewed a status. Confirmed on-device:
      // `type 'Null' is not a subtype of type 'Timestamp'`. Skipping
      // not-yet-resolved entries here is harmless — hasUnviewedStatusFrom
      // just sees them as "not yet viewed" for the brief window until the
      // next snapshot arrives with the real timestamp.
      lastViewedStatusOwnerAt: Map<String, Timestamp>.fromEntries(
        (data['lastViewedStatusOwnerAt'] as Map<String, dynamic>? ?? const {})
            .entries
            .where((e) => e.value is Timestamp)
            .map((e) => MapEntry(e.key, e.value as Timestamp)),
      ),
    );
  }

  // Builds a User from an Algolia search hit (AlgoliaSearchService,
  // lib/core/search/) rather than a Firestore doc — only the fields
  // actually synced into the index (see toAlgoliaUserRecord,
  // functions/src/algoliaShared.ts) are populated; everything else
  // (bio, gigs, verified, activityType, reviews, ...) gets the same
  // "predates this field" default fromFirestore already uses elsewhere in
  // this class. This is deliberately a partial/placeholder User: every
  // screen that navigates to a search result (UserProfileScreen) already
  // overlays currentUserProvider(user.id)'s live Firestore data over
  // whatever User it was constructed with, so these placeholders get
  // filled in with the real profile immediately — same mechanism already
  // in place for any other stale/partial User passed into that screen.
  //
  // lastSeen/mostRecentStatusExpiresAt/mostRecentStatusCreatedAt are
  // denormalized in the index as epoch millis (Algolia numeric filters/
  // facets need plain numbers, not Timestamps) — rebuilt back into
  // Timestamps here so isActuallyOnline/hasActiveStatus/
  // hasUnviewedStatusFrom work identically off an Algolia-sourced User as
  // off a Firestore-sourced one (needed by the group/event participant
  // pickers that render a status ring + online dot straight from search
  // results, unlike search_screen.dart's own tile which doesn't).
  factory User.fromAlgoliaHit(Map<String, dynamic> hit) {
    Timestamp? millisToTimestamp(dynamic millis) => millis == null
        ? null
        : Timestamp.fromMillisecondsSinceEpoch((millis as num).toInt());

    return User(
      id: (hit['objectID'] ?? hit['id'] ?? '') as String,
      name: (hit['name'] ?? 'İstifadəçi') as String,
      emoji: (hit['emoji'] ?? '🎵') as String,
      instrument: (hit['instrument'] ?? '') as String,
      city: (hit['city'] ?? '') as String,
      rating: ((hit['rating'] ?? 0) as num).toDouble(),
      reviews: 0,
      available: (hit['available'] ?? false) as bool,
      goldRing: false,
      online: (hit['online'] ?? false) as bool,
      lastSeen: millisToTimestamp(hit['lastSeen']),
      bio: '',
      photoURL: hit['photoURL'] as String?,
      mostRecentStatusExpiresAt: millisToTimestamp(hit['mostRecentStatusExpiresAt']),
      mostRecentStatusCreatedAt: millisToTimestamp(hit['mostRecentStatusCreatedAt']),
    );
  }

  // Shared with SearchFilters.toAlgoliaFilters (filter_sheet.dart), which
  // reimplements this same check as an Algolia numeric filter (Algolia
  // records are static snapshots — there's no getter to call server-side,
  // so the "is this recent enough" window has to be a query-time constant
  // both places agree on).
  static const Duration onlineGracePeriod = Duration(minutes: 2);

  // `online` alone isn't trustworthy — PresenceService's heartbeat pauses
  // (not clears) on backgrounding, so a long-backgrounded user can stay
  // `online: true` indefinitely with no further write until they return or
  // sign out (see docs/presence-system.md). Cross-checking against lastSeen
  // corrects for that: 2 minutes is double the 60s heartbeat interval, so
  // one missed/delayed beat doesn't falsely flip someone offline.
  // Окно берётся из presenceFreshness, а не из константы: сборка
  // объявляет свой интервал сердцебиения сама, и все признаки
  // присутствия обязаны судить по одному правилу.
  //
  // Почему это важнее экономии: в шапке чата стоит «● Onlayn», а прямо
  // под ней, в плашке переговоров, — строка присутствия. При разных
  // окнах через минуту после ухода собеседника они начинали
  // противоречить друг другу на одном экране («Onlayn» и «1 dəq əvvəl»
  // одновременно). Два индикатора, спорящих между собой, хуже одного
  // неточного: человек перестаёт верить обоим.
  //
  // Проверка `online` сохранена — она ловит явный выход из аккаунта
  // (`stop()` пишет false). Убитое приложение ею не ловится вовсе, его
  // отсекает только свежесть: в проде есть аккаунты с `online: true`,
  // застрявшим на месяц.
  bool get isActuallyOnline => online && isPresenceFresh;

  // Окно свежести присутствия — ровно то же правило, что у сервера
  // (functions/src/presence.ts, freshnessWindowMs): двойной интервал
  // сердцебиения, объявленный самой сборкой, зажатый в 30–120 с. Поля
  // нет — сборка его не объявляет, работает прежнее окно 120 с.
  //
  // Одно правило на клиенте и на сервере здесь важнее экономии: если
  // экран покажет «в чате», а сервер в ту же секунду решит «слать push»,
  // разойдутся не цифры, а обещания, данные человеку.
  static const Duration presenceFreshnessFloor = Duration(seconds: 30);

  // Окно для запроса «Onlayn indi» в поиске. Отдельная константа, потому
  // что там окно нужно ОДНО на всех: фильтр уходит в Algolia одним
  // числовым условием по денормализованному lastSeen, а условие «у
  // каждого своё окно» в таком запросе не выражается — арифметики по
  // записи там нет.
  //
  // Значение равно окну сборки, бьющейся раз в 30 с, то есть совпадает с
  // тем, что показывает зелёная точка у всех, кто сегодня в ходу. Для
  // сборки, не объявляющей интервал, точка держится дольше (120 с), чем
  // живёт её место в выдаче, — расхождение в безопасную сторону:
  // человека скорее не покажут, чем покажут отсутствующего.
  static const Duration onlineQueryWindow = Duration(seconds: 60);

  Duration get presenceFreshness {
    final declared = presenceIntervalMs;
    if (declared == null) return onlineGracePeriod;
    final doubled = Duration(milliseconds: 2 * declared);
    if (doubled < presenceFreshnessFloor) return presenceFreshnessFloor;
    if (doubled > onlineGracePeriod) return onlineGracePeriod;
    return doubled;
  }

  // Приложение подавало признаки жизни в пределах своего окна. В отличие
  // от isActuallyOnline не смотрит на `online` вовсе: убитое приложение
  // оставляет его `true` навсегда, и доверять ему нельзя — доверять можно
  // только свежести.
  bool get isPresenceFresh {
    final seen = lastSeen;
    if (seen == null) return false;
    return DateTime.now().difference(seen.toDate()) < presenceFreshness;
  }

  // Смотрит ли человек СЕЙЧАС именно в этот чат. Оба условия обязательны:
  // сам признак без срока годности застревал бы навсегда (ровно дефект
  // N19), а свежесть без признака не говорит, ГДЕ человек находится.
  bool isViewingChat(String chatId) =>
      activeChatId == chatId && isPresenceFresh;

  // Same shape as isActuallyOnline above: a denormalized field alone isn't
  // trustworthy (mostRecentStatusExpiresAt is only ever written forward by
  // onStatusCreated, never cleared), so this cross-checks it against the
  // current time client-side — exactly the same query-time expiry check
  // watchStatusFeed's own expiresAt filter already relies on, just applied
  // to this one denormalized timestamp instead of a live query.
  bool get hasActiveStatus =>
      mostRecentStatusExpiresAt != null &&
      mostRecentStatusExpiresAt!.toDate().isAfter(DateTime.now());

  // Gold/muted ring parity check: called on the VIEWER's own User instance
  // (`this`), passed the status OWNER's User instance — mirrors where each
  // field actually lives (lastViewedStatusOwnerAt on the viewer's doc,
  // mostRecentStatusCreatedAt on the owner's doc). True ("gold", unviewed)
  // when the owner has ever posted a status and either this viewer has
  // never viewed anything from that owner, or their last view of that
  // owner predates the owner's most recent post.
  bool hasUnviewedStatusFrom(User owner) {
    if (owner.mostRecentStatusCreatedAt == null) return false;
    final lastViewed = lastViewedStatusOwnerAt[owner.id];
    return lastViewed == null ||
        lastViewed.toDate().isBefore(owner.mostRecentStatusCreatedAt!.toDate());
  }
}

class Chat {
  final String id;
  final String name;
  final String emoji;
  final String lastMessage;
  final DateTime? lastMessageTime;
  // uids who deleted-for-themselves the message that lastMessage currently
  // denormalizes — lastMessage/lastMessageTime stay the one shared value
  // for every member (WhatsApp parity: deleting for yourself never changes
  // what anyone else sees), so a viewer whose own uid is in this list shows
  // the "Bu mesajı sildiniz" placeholder instead of lastMessage; every other
  // member keeps seeing the real preview. Reset to [] whenever lastMessage
  // itself changes to a different message (see firestore_service.dart's
  // send*/​_refreshLastMessagePreview).
  final List<String> lastMessageDeletedFor;
  final int unreadCount;
  final List<String> members;
  final bool isGroup;
  final String? photoURL;
  // Поля `completed` здесь больше нет — оно удалено целиком (02.08).
  //
  // Оно осталось от отменённой схемы «завершённый чат форкается в новый»
  // (парность с mugam-v2), которую свернули после живой проверки: чат
  // «исчезал» посреди разговора, а «Mesaj» открывал не ту ветку. С уходом
  // той схемы поле перестало на что-либо влиять — его писали (клиент при
  // создании чата, onChatUpdated после сделки) и разбирали здесь, но НЕ
  // читал никто и никогда.
  //
  // Признаком раунда переговоров оно быть и не могло: `setJobOffer` его
  // не сбрасывает, поэтому после первой же сделки оно навсегда true —
  // включая все последующие раунды. Открытость раунда выводится из
  // `jobOfferBy` и `recipientAgreed` (см. jobOfferRoundOpen в
  // chat_screen.dart).
  //
  // Удалено, а не оставлено «на всякий случай», именно потому, что живая
  // на вид запись — ловушка: кто-нибудь однажды обопрётся на неё как на
  // рабочий признак. Историю сделок хранит personalEvents, у каждого
  // договора есть agreementChatId обратно на чат.
  // Empty for every 1:1 chat (mugam-v2 never wrote either field for those —
  // only createGroupChat does) and for group docs from before these fields
  // existed, so an empty default is the correct "absent" value here, not a
  // parsing error.
  final List<String> admins;
  final String createdBy;
  // How many messages currently exist in this chat (not lifetime-ever-sent)
  // — server-owned via onNewMessage/onMessageDeleted's symmetric Firestore
  // triggers (see functions/src/index.ts), not incremented client-side.
  // Defaults to 0 for any chat doc that predates this field, same as
  // admins/createdBy above.
  final int messageCount;
  // Per-uid "clear chat for me" cutoff (ISO string on the doc, parsed to
  // DateTime here) — messages sent at or before this timestamp are hidden
  // ONLY for that uid (ChatMessagesController filters on it), never
  // deleted server-side and never affecting any other member's view. See
  // firestore_service.dart's clearChatForUser.
  final Map<String, DateTime> clearedBy;
  // uid of whoever proposed a job via "İş təklif et" — null when no offer
  // is pending. Only meaningful for 1:1 chats (mirrors mugam-v2's
  // jobOfferBy); the chat_screen.dart menu hides the offer item while this
  // is set, and shows the initiator/recipient negotiation banners instead.
  final String? jobOfferBy;
  // When jobOfferBy was set — lets the negotiation banners tell "has the
  // other party read/typed anything since this specific offer" apart from
  // "have they ever read this chat" (lastReadAt/typing alone can't
  // distinguish those once a chat has any history).
  final DateTime? jobOfferAt;
  // The negotiated event fields below live on the CHAT doc while a job
  // offer is pending (proposed, possibly still being haggled over) — they
  // are only ever promoted into a real, permanent PersonalEvent once the
  // recipient accepts (see the onChatUpdated Cloud Function), exactly like
  // mugam-v2's own separation of "chat negotiation state" from "finalized
  // Agreement".
  final DateTime? eventDate;
  final String? eventType;
  final String? eventLocation;
  final String? eventNotes;
  // Set by the recipient tapping "Razıyam" before the initiator has picked
  // a date — lets the initiator's own banner show "the other side is
  // waiting for a date" (mugam-v2's setWaitingForDate). A timestamp, not a
  // bare bool: durable so a late-mounted initiator screen can still tell
  // "is this newer than the last negotiation dialog I showed" via
  // negotiationSeenAt, instead of relying on catching a live true→false
  // flip (which is exactly what silently dropped this nudge on-device —
  // see firestore_service.dart's setWaitingForDate).
  final DateTime? waitingForDateAt;
  // When the recipient tapped "Razıyam" to accept — same durability
  // rationale as waitingForDateAt, for the "agreed" celebration dialog.
  final DateTime? recipientAgreedAt;
  // uid of whoever tapped "İmtina" (cancel) on a pending job offer — set by
  // cancelChat, same moment either party's decision ends the negotiation
  // without ever creating a PersonalEvent. Отменённое предложение договора
  // не создаёт вовсе; на экране «Müqavilələr» состояние «отменён» читается
  // из собственного поля cancelledBy у PersonalEvent, а не отсюда. У этого
  // поля на документе чата читателя по-прежнему нет.
  final String? cancelledBy;
  // Per-uid "last typed at" timestamp (ISO string on the doc), scoped
  // ONLY to driving the job-offer banners' status line — this app has no
  // general-purpose typing indicator elsewhere (see PresenceService's own
  // header comment deferring that to a future WebSocket gateway); this is
  // the same cheap chat-doc-field approach mugam-v2 already used, not that
  // gateway.
  final Map<String, DateTime> typing;

  const Chat({
    required this.id,
    required this.name,
    required this.emoji,
    required this.lastMessage,
    this.lastMessageTime,
    this.lastMessageDeletedFor = const [],
    required this.unreadCount,
    required this.members,
    required this.isGroup,
    this.photoURL,
    this.admins = const [],
    this.createdBy = '',
    this.messageCount = 0,
    this.clearedBy = const {},
    this.jobOfferBy,
    this.jobOfferAt,
    this.eventDate,
    this.eventType,
    this.eventLocation,
    this.eventNotes,
    this.waitingForDateAt,
    this.recipientAgreedAt,
    this.cancelledBy,
    this.typing = const {},
  });

  // uid is the viewing (signed-in) user — unreadCount is stored server-side
  // as a per-user map ({uid: count}, see onNewMessage/markChatAsReadBy in
  // functions/src/index.ts and firestore_service.dart), so this must read
  // only that uid's own entry. Summing every entry in the map would show
  // the combined unread count of every participant, not this user's own.
  factory Chat.fromFirestore(String id, Map<String, dynamic> data, String uid) {
    return Chat(
      id: id,
      name: data['name'] ?? '',
      emoji: data['emoji'] ?? '💬',
      lastMessage: data['lastMessage'] ?? '',
      lastMessageTime: data['lastMessageTime'] != null
          ? (data['lastMessageTime'] as Timestamp).toDate()
          : null,
      lastMessageDeletedFor: List<String>.from(
        data['lastMessageDeletedFor'] as List? ?? const [],
      ),
      unreadCount: () {
        final raw = data['unreadCount'];
        if (raw is int) return raw;
        if (raw is Map) return (raw[uid] as num?)?.toInt() ?? 0;
        return 0;
      }(),
      members: List<String>.from(data['members'] as List? ?? const []),
      isGroup: data['isGroup'] ?? false,
      photoURL: data['photoURL'],
      admins: List<String>.from(data['admins'] as List? ?? const []),
      createdBy: data['createdBy'] ?? '',
      messageCount: (data['messageCount'] as num?)?.toInt() ?? 0,
      clearedBy: _parseIsoDateMap(data['clearedBy']),
      jobOfferBy: data['jobOfferBy'] as String?,
      jobOfferAt: data['jobOfferAt'] != null
          ? DateTime.tryParse(data['jobOfferAt'] as String)
          : null,
      eventDate: data['eventDate'] != null
          ? DateTime.tryParse(data['eventDate'] as String)
          : null,
      eventType: data['eventType'] as String?,
      eventLocation: data['eventLocation'] as String?,
      eventNotes: data['eventNotes'] as String?,
      waitingForDateAt: data['waitingForDateAt'] != null
          ? DateTime.tryParse(data['waitingForDateAt'] as String)
          : null,
      recipientAgreedAt: data['recipientAgreedAt'] != null
          ? DateTime.tryParse(data['recipientAgreedAt'] as String)
          : null,
      cancelledBy: data['cancelledBy'] as String?,
      typing: _parseIsoDateMap(data['typing']),
    );
  }

  // Shared parse for the two per-uid { uid: isoString } maps above
  // (clearedBy/typing) — silently drops any entry whose value isn't a
  // parseable ISO string rather than throwing, since a malformed single
  // entry shouldn't break the whole chat doc's parse.
  static Map<String, DateTime> _parseIsoDateMap(dynamic raw) {
    if (raw is! Map) return const {};
    final result = <String, DateTime>{};
    for (final entry in raw.entries) {
      final parsed = DateTime.tryParse(entry.value?.toString() ?? '');
      if (parsed != null) result[entry.key as String] = parsed;
    }
    return result;
  }
}

class Message {
  final String id;
  // Which chat this row belongs to — null for a Message built straight from
  // a chat-scoped Firestore query (chats/{chatId}/messages/...), where the
  // caller already knows chatId from context and this would be redundant
  // plumbing through every fromFirestore call site. Always set for a row
  // that lives in LocalMessageStore, which — unlike a Firestore
  // subcollection query — has no other way to route a flat, cross-chat
  // pending-sends index back to the chat each entry belongs to.
  final String? chatId;
  final String senderId;
  final String text;
  final String? imageURL;
  final String? audioURL;
  final String? videoURL;
  // Real duration/as-displayed pixel size read from the source file's own
  // metadata at send time (flutter_video_info) — null for messages sent
  // before these fields existed. width/height are carried as plain data
  // (not derived from a decoded thumbnail) so the video bubble sizes
  // identically before and after a pending item is replaced by the real
  // sent message.
  final int? videoDurationMs;
  final int? videoWidth;
  final int? videoHeight;
  // As-displayed pixel size read from the picked file at send time (see
  // _probeImageSize in chat_screen.dart) — null for messages sent before
  // this field existed. Same rationale as videoWidth/videoHeight: carried
  // as plain data so the photo bubble sizes identically before and after a
  // pending item is replaced by the real sent message.
  final int? imageWidth;
  final int? imageHeight;
  // Identify exactly which validated Storage upload this message's media
  // came from — mediaOriginChatId is the chat the file was actually
  // uploaded into (equals this message's own chat for a fresh send, or an
  // earlier chat's id when this message is a forward), mediaFileName is
  // the object name under chats/{mediaOriginChatId}/. Together they let
  // firestore.rules confirm a validatedUploads marker exists rather than
  // trusting the imageURL/videoURL/audioURL string outright. Null for any
  // message sent before this field existed — such messages can no longer
  // be forwarded (see toggleReaction/onChatMediaUploaded security pass).
  final String? mediaOriginChatId;
  final String? mediaFileName;
  // 'file' type only — fileName is the original human-readable name the
  // sender picked (used for display and as the extension source for the
  // local open/download cache), distinct from mediaFileName above (the
  // Storage object's own name, messageId-based like every other media
  // type). fileSizeBytes is informational (already enforced server-side by
  // storage.rules against the sender's own maxUploadSizeMb at upload time).
  final String? fileURL;
  final String? fileName;
  final int? fileSizeBytes;
  // 'location' type only — a static snapshot of the map at the picked
  // point (captured client-side via RepaintBoundary, uploaded through the
  // same flat Storage path as every other media type — no Google Static
  // Maps API call, see LocationPickerScreen), plus the actual coordinates
  // it was captured at. Kept as its own field rather than reusing imageURL
  // so a location message can never be mistaken for (or rendered by) the
  // plain 'image' bubble/gallery-filter logic elsewhere, same reasoning as
  // fileURL being separate from imageURL above.
  final String? locationImageURL;
  final double? latitude;
  final double? longitude;
  // Fixed-length (40) 0-100 normalized amplitude bars captured live during
  // recording — null for messages sent before this field existed.
  final List<int>? waveform;
  // Uids who have actually started playback of this voice message at
  // least once — distinct from chat-level read receipts (lastReadMsgId),
  // which only mean the recipient scrolled past it. Written via
  // FirestoreService.markVoiceMessageListened.
  final List<String> listenedBy;
  final Timestamp? timestamp;
  // Per-chat monotonic sequence number, assigned atomically server-side by
  // FirestoreService._commitMessage — the ordering/pagination key
  // everything sorts by now, NOT timestamp (see that function's own doc
  // comment for why: unlike a timestamp it's never null pre-ack and never
  // depends on device clock accuracy). Nullable only because it doesn't
  // exist on pre-migration data — see the 2026-07-31 chats/messages wipe.
  final int? seq;
  final String type; // 'text', 'image', 'audio', 'video', 'file', 'location'
  final String? replyToId;
  final String? replyToText;
  final String? replyToSenderName;
  final String? replyToImageURL;
  final String? replyToVideoURL;
  // A reply to someone's status/story (WhatsApp-style swipe-up), as opposed
  // to a reply to another chat message (replyToId above). Deliberately a
  // SEPARATE set of fields rather than repurposing replyToId: replyToId's
  // own tap handler (_scrollToMessage in chat_screen.dart) searches this
  // chat's own message history for a doc with that id, which a statusId
  // would never match — it would silently hang searching, then report "not
  // found", rather than opening the status. replyToStatusOwnerUid is
  // required alongside replyToStatusId because UserStatusViewerScreen (the
  // screen this reply's own tap handler opens) needs the author's uid up
  // front to fetch their status group — a status doc's id alone doesn't
  // encode who posted it without a separate lookup.
  final String? replyToStatusId;
  final String? replyToStatusOwnerUid;
  final String? replyToStatusType; // 'text' | 'image' | 'video'
  final String? replyToStatusText;
  final String? replyToStatusThumbnailURL;
  final bool deletedForAll;
  final List<String> deletedFor;
  final String? deletedAt;
  final Map<String, List<String>> reactions;
  // Client-only, never round-tripped through Firestore (fromFirestore never
  // sets these) — used solely to render a not-yet-sent pending-queue item
  // as a synthetic Message. localSendStatus is null for every real,
  // server-confirmed message; 'queued' | 'uploading' | 'failed' otherwise.
  final String? localFilePath;
  final String? localSendStatus;
  // Real Storage upload fraction (0.0-1.0) while localSendStatus is
  // 'queued'/'uploading' — image/video only, null otherwise. See
  // PendingMediaMessage.uploadProgress for where this comes from.
  final double? localUploadProgress;
  // Already-decoded preview bytes captured at send time (the full picked
  // photo for 'image', a small generated frame for 'video') — set only on
  // a synthetic pending message, see PendingMediaMessage.previewBytes for
  // why: it lets the bubble paint the real image on its very first frame
  // (via a precacheImage call made before this message ever became
  // visible) instead of a decode gap flashing the placeholder background.
  final Uint8List? localPreviewBytes;
  // Client-only retry bookkeeping for a still-pending row (localSendStatus
  // != null) — moved here from the old, now-deleted PendingMediaMessage
  // class when LocalMessageStore unified "pending" and "confirmed" into one
  // row type instead of two separate objects reconciled at render time (see
  // LocalMessageStore's own doc comment). attemptCount drives the retry
  // backoff/max-attempts cutoff. uploadedUrl is set once a prior attempt's
  // Storage upload step succeeded but the Firestore write after it didn't
  // (timeout, reconnect) — the next attempt reuses it instead of
  // re-uploading the whole file again. videoHd is the HD-quality setting
  // captured once at enqueue time (read live at compression time inside the
  // background isolate has no Riverpod ref to read a live setting from).
  final int attemptCount;
  final String? uploadedUrl;
  final bool videoHd;
  // True for auto-generated announcements ("X created the group", "X left
  // the group") — rendered as centered gray text, no bubble/avatar, same
  // as mugam-v2's own system messages (see createGroupChat/leaveGroup
  // there). senderId for these is the real acting user's uid (not a
  // literal 'system' string) so the existing onNewMessage push-notification
  // Cloud Function still resolves a real display name — isSystem is purely
  // a rendering distinction, not a push-routing one.
  final bool isSystem;
  // How many times this message has been forwarded — 0 for a normal send.
  // Set from the source message's own forwardCount + 1 when
  // _forwardMessage builds a forwarded copy (chat_screen.dart), so
  // forwarding an already-forwarded message grows the chain depth rather
  // than resetting it. Drives the "Yönləndirilib"/"Dəfələrlə
  // yönləndirilib" bubble label. num? rather than int? in fromFirestore
  // below, matching Chat.messageCount's own pattern (Phase B) — Firestore
  // can hand back either representation depending on how the value was
  // written/read.
  final int forwardCount;

  // `id` is the same messageId end to end now — generated client-side
  // before the first send attempt (see FirestoreService.generateMessageId)
  // and never changed by LocalMessageStore's pending->confirmed transition
  // (see its own doc comment) — so this is just `id`. Kept as its own
  // accessor since callers (MediaThumbnailCacheManager etc.) already use
  // this name to mean "the one identifier that stays constant across a
  // message's entire lifecycle."
  String get stableMediaKey => id;

  const Message({
    required this.id,
    this.chatId,
    required this.senderId,
    required this.text,
    this.imageURL,
    this.audioURL,
    this.videoURL,
    this.videoDurationMs,
    this.videoWidth,
    this.videoHeight,
    this.imageWidth,
    this.imageHeight,
    this.mediaOriginChatId,
    this.mediaFileName,
    this.fileURL,
    this.fileName,
    this.fileSizeBytes,
    this.locationImageURL,
    this.latitude,
    this.longitude,
    this.waveform,
    this.listenedBy = const [],
    this.timestamp,
    this.seq,
    required this.type,
    this.replyToId,
    this.replyToText,
    this.replyToSenderName,
    this.replyToImageURL,
    this.replyToVideoURL,
    this.replyToStatusId,
    this.replyToStatusOwnerUid,
    this.replyToStatusType,
    this.replyToStatusText,
    this.replyToStatusThumbnailURL,
    this.deletedForAll = false,
    this.deletedFor = const [],
    this.deletedAt,
    this.reactions = const {},
    this.localFilePath,
    this.localSendStatus,
    this.localUploadProgress,
    this.localPreviewBytes,
    this.attemptCount = 0,
    this.uploadedUrl,
    this.videoHd = false,
    this.isSystem = false,
    this.forwardCount = 0,
  });

  // Every field below splits into exactly one of two ownership groups —
  // getting this split wrong is what LocalMessageStore's whole design
  // exists to prevent (see its own doc comment): "synced" fields only ever
  // come from Firestore (text, media, replies, reactions, deletion state,
  // seq, timestamp, isSystem, forwardCount); "local" fields only the
  // send/retry path on THIS device ever owns (localSendStatus,
  // localFilePath, localUploadProgress, localPreviewBytes, attemptCount,
  // uploadedUrl, videoHd). The three methods below are the only sanctioned
  // ways to move a Message from one state to another — each one is
  // explicit about which group it touches, so it's structurally impossible
  // to accidentally let one clobber the other's fields.

  // This device's own pending send just got confirmed by
  // FirestoreService._commitMessage — keep every synced field exactly as
  // this row already had it (it was this device's own optimistic copy,
  // already correct) and clear every local field back to "not pending."
  Message withConfirmedSeq(int newSeq) => Message(
    id: id,
    chatId: chatId,
    senderId: senderId,
    text: text,
    imageURL: imageURL,
    audioURL: audioURL,
    videoURL: videoURL,
    videoDurationMs: videoDurationMs,
    videoWidth: videoWidth,
    videoHeight: videoHeight,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    mediaOriginChatId: mediaOriginChatId,
    mediaFileName: mediaFileName,
    fileURL: fileURL,
    fileName: fileName,
    fileSizeBytes: fileSizeBytes,
    locationImageURL: locationImageURL,
    latitude: latitude,
    longitude: longitude,
    waveform: waveform,
    listenedBy: listenedBy,
    timestamp: timestamp,
    seq: newSeq,
    type: type,
    replyToId: replyToId,
    replyToText: replyToText,
    replyToSenderName: replyToSenderName,
    replyToImageURL: replyToImageURL,
    replyToVideoURL: replyToVideoURL,
    replyToStatusId: replyToStatusId,
    replyToStatusOwnerUid: replyToStatusOwnerUid,
    replyToStatusType: replyToStatusType,
    replyToStatusText: replyToStatusText,
    replyToStatusThumbnailURL: replyToStatusThumbnailURL,
    deletedForAll: deletedForAll,
    deletedFor: deletedFor,
    deletedAt: deletedAt,
    reactions: reactions,
    isSystem: isSystem,
    forwardCount: forwardCount,
    // local group cleared — no longer pending.
  );

  // Local-group-only update, mid-retry — a queued->uploading->failed
  // transition. Every synced field stays exactly as-is (this row hasn't
  // been confirmed by the server yet, so there IS no other synced-field
  // source to reconcile against).
  Message withLocalStatus({
    required String? status,
    int? attemptCount,
    String? uploadedUrl,
    String? localFilePath,
  }) => Message(
    id: id,
    chatId: chatId,
    senderId: senderId,
    text: text,
    imageURL: imageURL,
    audioURL: audioURL,
    videoURL: videoURL,
    videoDurationMs: videoDurationMs,
    videoWidth: videoWidth,
    videoHeight: videoHeight,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    mediaOriginChatId: mediaOriginChatId,
    mediaFileName: mediaFileName,
    fileURL: fileURL,
    fileName: fileName,
    fileSizeBytes: fileSizeBytes,
    locationImageURL: locationImageURL,
    latitude: latitude,
    longitude: longitude,
    waveform: waveform,
    listenedBy: listenedBy,
    timestamp: timestamp,
    seq: seq,
    type: type,
    replyToId: replyToId,
    replyToText: replyToText,
    replyToSenderName: replyToSenderName,
    replyToImageURL: replyToImageURL,
    replyToVideoURL: replyToVideoURL,
    replyToStatusId: replyToStatusId,
    replyToStatusOwnerUid: replyToStatusOwnerUid,
    replyToStatusType: replyToStatusType,
    replyToStatusText: replyToStatusText,
    replyToStatusThumbnailURL: replyToStatusThumbnailURL,
    deletedForAll: deletedForAll,
    deletedFor: deletedFor,
    deletedAt: deletedAt,
    reactions: reactions,
    isSystem: isSystem,
    forwardCount: forwardCount,
    localFilePath: localFilePath ?? this.localFilePath,
    localSendStatus: status,
    // Always reset, not carried over — a fresh 'uploading'/'queued'/'failed'
    // transition means whatever prior progress existed no longer reflects
    // an in-flight upload. withUploadProgress below is the only way this
    // ever becomes non-null again.
    localUploadProgress: null,
    localPreviewBytes: localPreviewBytes,
    attemptCount: attemptCount ?? this.attemptCount,
    uploadedUrl: uploadedUrl ?? this.uploadedUrl,
    videoHd: videoHd,
  );

  // Pure in-memory progress-ring update while an image/video upload is in
  // flight — deliberately its own minimal method rather than folded into
  // withLocalStatus above: LocalMessageStore.updateProgress (the only
  // caller) skips scheduling a disk write for this one, since Storage's
  // snapshotEvents can fire many times a second and persisting on every
  // tick would be needless I/O for a value that's meaningless across an
  // app restart anyway (a resumed 'queued' item re-uploads from scratch,
  // correctly starting back at 0.0 via withLocalStatus's reset above).
  Message withUploadProgress(double progress) => Message(
    id: id,
    chatId: chatId,
    senderId: senderId,
    text: text,
    imageURL: imageURL,
    audioURL: audioURL,
    videoURL: videoURL,
    videoDurationMs: videoDurationMs,
    videoWidth: videoWidth,
    videoHeight: videoHeight,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    mediaOriginChatId: mediaOriginChatId,
    mediaFileName: mediaFileName,
    fileURL: fileURL,
    fileName: fileName,
    fileSizeBytes: fileSizeBytes,
    locationImageURL: locationImageURL,
    latitude: latitude,
    longitude: longitude,
    waveform: waveform,
    listenedBy: listenedBy,
    timestamp: timestamp,
    seq: seq,
    type: type,
    replyToId: replyToId,
    replyToText: replyToText,
    replyToSenderName: replyToSenderName,
    replyToImageURL: replyToImageURL,
    replyToVideoURL: replyToVideoURL,
    replyToStatusId: replyToStatusId,
    replyToStatusOwnerUid: replyToStatusOwnerUid,
    replyToStatusType: replyToStatusType,
    replyToStatusText: replyToStatusText,
    replyToStatusThumbnailURL: replyToStatusThumbnailURL,
    deletedForAll: deletedForAll,
    deletedFor: deletedFor,
    deletedAt: deletedAt,
    reactions: reactions,
    isSystem: isSystem,
    forwardCount: forwardCount,
    localFilePath: localFilePath,
    localSendStatus: localSendStatus,
    localUploadProgress: progress,
    localPreviewBytes: localPreviewBytes,
    attemptCount: attemptCount,
    uploadedUrl: uploadedUrl,
    videoHd: videoHd,
  );

  // The live Firestore listener's sync-writer found a doc for a message
  // this device already has a local row for (either this device's own
  // pending send the confirm-path hasn't caught up to yet, or a plain
  // re-sync of an already-confirmed row whose reactions/deletion-state
  // changed) — take every synced field from `real` (the freshly-read
  // Firestore doc), keep every local field from `this` (the existing local
  // row) untouched. Never called for a message with no existing local row
  // — LocalMessageStore.upsertFromFirestore uses `real` directly for that
  // case, there's nothing local to preserve.
  //
  // EXCEPT when `real` carries a seq: a seq is only ever assigned by
  // FirestoreService._commitMessage actually committing this message, so
  // its presence is proof the server has it — which makes every local send
  // field (localSendStatus/attemptCount/uploadedUrl/localFilePath/progress)
  // stale by definition, no matter what this device still believed. Keeping
  // them was a confirmed bug: a send whose write really did land server-side
  // but only *after* this client's own timeout gave up on it (the client
  // then exhausts pendingQueueMaxAttempts and marks the row 'failed') stayed
  // marked failed FOREVER — a red "not sent" bubble for a message the other
  // party could see and reply to. It also leaked: allPending() filters on
  // localSendStatus != null, so every such row stayed in the on-disk pending
  // blob permanently, growing it without bound. Delegating to
  // withConfirmedSeq keeps "what does a confirmed row look like" defined in
  // exactly one place (see LocalMessageStore.markConfirmed, the other
  // caller) rather than duplicating the field-clearing list here.
  Message reconciledWithFirestore(Message real) {
    final merged = _reconciledPreservingLocal(real);
    final realSeq = real.seq;
    return realSeq == null ? merged : merged.withConfirmedSeq(realSeq);
  }

  Message _reconciledPreservingLocal(Message real) => Message(
    id: real.id,
    chatId: chatId,
    senderId: real.senderId,
    text: real.text,
    imageURL: real.imageURL,
    audioURL: real.audioURL,
    videoURL: real.videoURL,
    videoDurationMs: real.videoDurationMs,
    videoWidth: real.videoWidth,
    videoHeight: real.videoHeight,
    imageWidth: real.imageWidth,
    imageHeight: real.imageHeight,
    mediaOriginChatId: real.mediaOriginChatId,
    mediaFileName: real.mediaFileName,
    fileURL: real.fileURL,
    fileName: real.fileName,
    fileSizeBytes: real.fileSizeBytes,
    locationImageURL: real.locationImageURL,
    latitude: real.latitude,
    longitude: real.longitude,
    waveform: real.waveform,
    listenedBy: real.listenedBy,
    timestamp: real.timestamp,
    seq: real.seq,
    type: real.type,
    replyToId: real.replyToId,
    replyToText: real.replyToText,
    replyToSenderName: real.replyToSenderName,
    replyToImageURL: real.replyToImageURL,
    replyToVideoURL: real.replyToVideoURL,
    replyToStatusId: real.replyToStatusId,
    replyToStatusOwnerUid: real.replyToStatusOwnerUid,
    replyToStatusType: real.replyToStatusType,
    replyToStatusText: real.replyToStatusText,
    replyToStatusThumbnailURL: real.replyToStatusThumbnailURL,
    deletedForAll: real.deletedForAll,
    deletedFor: real.deletedFor,
    deletedAt: real.deletedAt,
    reactions: real.reactions,
    isSystem: real.isSystem,
    forwardCount: real.forwardCount,
    // local group preserved from `this`, not `real` (a Firestore doc never
    // has any of these — Message.fromFirestore never sets them).
    localFilePath: localFilePath,
    localSendStatus: localSendStatus,
    localUploadProgress: localUploadProgress,
    localPreviewBytes: localPreviewBytes,
    attemptCount: attemptCount,
    uploadedUrl: uploadedUrl,
    videoHd: videoHd,
  );

  // chatId: optional — only LocalMessageStore's Firestore-listener sync
  // path needs it (a flat, cross-chat store has no other way to know which
  // chat a given snapshot doc belongs to); every other caller already has
  // chatId from its own already-chat-scoped query and leaves this null.
  factory Message.fromFirestore(
    String id,
    Map<String, dynamic> data, {
    String? chatId,
  }) {
    final replyTo = data['replyTo'] as Map<String, dynamic>?;
    final replyToStatus = data['replyToStatus'] as Map<String, dynamic>?;
    final rawReactions = data['reactions'] as Map<String, dynamic>? ?? {};
    return Message(
      id: id,
      chatId: chatId,
      senderId: data['senderId'] ?? '',
      text: data['text'] ?? '',
      imageURL: data['imageURL'],
      audioURL: data['audioURL'],
      videoURL: data['videoURL'],
      videoDurationMs: data['videoDurationMs'] as int?,
      videoWidth: data['videoWidth'] as int?,
      videoHeight: data['videoHeight'] as int?,
      imageWidth: data['imageWidth'] as int?,
      imageHeight: data['imageHeight'] as int?,
      mediaOriginChatId: data['mediaOriginChatId'] as String?,
      mediaFileName: data['mediaFileName'] as String?,
      fileURL: data['fileURL'] as String?,
      fileName: data['fileName'] as String?,
      fileSizeBytes: data['fileSizeBytes'] as int?,
      locationImageURL: data['locationImageURL'] as String?,
      latitude: (data['latitude'] as num?)?.toDouble(),
      longitude: (data['longitude'] as num?)?.toDouble(),
      waveform: (data['waveform'] as List?)?.cast<int>(),
      listenedBy: List<String>.from(data['listenedBy'] as List? ?? const []),
      timestamp: data['timestamp'] as Timestamp?,
      seq: (data['seq'] as num?)?.toInt(),
      type: data['type'] ?? 'text',
      replyToId: replyTo?['id'] as String?,
      replyToText: replyTo?['text'] as String?,
      replyToSenderName: replyTo?['senderName'] as String?,
      replyToImageURL: replyTo?['imageURL'] as String?,
      replyToVideoURL: replyTo?['videoURL'] as String?,
      replyToStatusId: replyToStatus?['id'] as String?,
      replyToStatusOwnerUid: replyToStatus?['ownerUid'] as String?,
      replyToStatusType: replyToStatus?['type'] as String?,
      replyToStatusText: replyToStatus?['text'] as String?,
      replyToStatusThumbnailURL: replyToStatus?['thumbnailURL'] as String?,
      deletedForAll: data['deletedForAll'] ?? false,
      deletedFor: List<String>.from(data['deletedFor'] as List? ?? const []),
      deletedAt: data['deletedAt'] as String?,
      reactions: {
        for (final entry in rawReactions.entries)
          entry.key: List<String>.from(entry.value as List? ?? const []),
      },
      isSystem: data['isSystem'] == true,
      forwardCount: (data['forwardCount'] as num?)?.toInt() ?? 0,
    );
  }
}

class StarredMessage {
  final String id; // == original message id
  final String chatId;
  final String chatName;
  final String senderId;
  final String senderName;
  final String text;
  final String type; // 'text', 'image', 'audio', 'video', 'file', 'location'
  final String? imageURL;
  final String? audioURL;
  final String? videoURL;
  final String? fileURL;
  final String? fileName;
  final Timestamp? timestamp;
  final Timestamp? starredAt;

  const StarredMessage({
    required this.id,
    required this.chatId,
    required this.chatName,
    required this.senderId,
    required this.senderName,
    required this.text,
    required this.type,
    this.imageURL,
    this.audioURL,
    this.videoURL,
    this.fileURL,
    this.fileName,
    this.timestamp,
    this.starredAt,
  });

  factory StarredMessage.fromFirestore(String id, Map<String, dynamic> data) {
    return StarredMessage(
      id: id,
      chatId: data['chatId'] ?? '',
      chatName: data['chatName'] ?? '',
      senderId: data['senderId'] ?? '',
      senderName: data['senderName'] ?? '',
      text: data['text'] ?? '',
      type: data['type'] ?? 'text',
      imageURL: data['imageURL'] as String?,
      audioURL: data['audioURL'] as String?,
      videoURL: data['videoURL'] as String?,
      fileURL: data['fileURL'] as String?,
      fileName: data['fileName'] as String?,
      timestamp: data['timestamp'] as Timestamp?,
      starredAt: data['starredAt'] as Timestamp?,
    );
  }
}

class Event {
  final String id;
  final String day;
  final String month;
  final String title;
  final String location;
  final List<String> tags;
  final List<String> tagColors;
  final String? spots;

  const Event({
    required this.id,
    required this.day,
    required this.month,
    required this.title,
    required this.location,
    required this.tags,
    required this.tagColors,
    this.spots,
  });

  factory Event.fromFirestore(String id, Map<String, dynamic> data) {
    return Event(
      id: id,
      day: (data['day'] ?? '') as String,
      month: (data['month'] ?? '') as String,
      title: (data['title'] ?? '') as String,
      location: (data['location'] ?? '') as String,
      tags: List<String>.from(data['tags'] as List? ?? const []),
      tagColors: List<String>.from(data['tagColors'] as List? ?? const []),
      spots: data['spots'] as String?,
    );
  }
}

class Room {
  final String id;
  final String emoji;
  final String name;
  final String members;
  final String preview;
  final bool live;
  final int avatarCount;

  const Room({
    required this.id,
    required this.emoji,
    required this.name,
    required this.members,
    required this.preview,
    required this.live,
    required this.avatarCount,
  });

  factory Room.fromFirestore(String id, Map<String, dynamic> data) {
    return Room(
      id: id,
      emoji: (data['emoji'] ?? '🏛️') as String,
      name: (data['name'] ?? '') as String,
      members: (data['members'] ?? '') as String,
      preview: (data['preview'] ?? '') as String,
      live: (data['live'] ?? false) as bool,
      avatarCount: (data['avatarCount'] ?? 0) as int,
    );
  }
}

class PersonalEvent {
  final String id;
  final String ownerUid;
  final String date;
  final String type;
  final String location;
  final String notes;
  final List<String> participantUids;
  final bool isAgree;
  final String? agreementChatId;
  final String? partnerUid;
  final String? partnerName;
  final String status;
  // ОТМЕНА ДОГОВОРА ПО СОГЛАСИЮ. Четыре поля, каждое отвечает ровно на один
  // вопрос — «кто предложил», «когда предложил», «кто подтвердил», «когда
  // отменён». Раньше здесь стояло одно `cancelledBy`, и оно врало бы по
  // смыслу: при отмене по согласию отменяют двое, а поле называет одного.
  //
  // Переименование, а не добавление рядом: поле было мёртвым — 54 договора
  // в проде, отменённых 0, ни одной записи за всё время. Пока данных нет,
  // это правка четырёх строк; с данными это была бы миграция.
  //
  // Промежуточное состояние, ради которого поля и разведены: запрос стоит,
  // status ещё 'agreed' — договор в силе, но по нему уже задан вопрос.
  // Признака-геттера для него здесь намеренно нет: читателя у него пока
  // тоже нет, а заводить код без читателя в этом проекте уже приходилось
  // выпалывать (B28, поле completed).
  final String? cancelRequestedBy;
  final dynamic cancelRequestedAt;
  final String? cancelConfirmedBy;
  final dynamic cancelledAt;
  final dynamic createdAt;

  /// Кто и ЧТО сделал последним. Пишут все четыре хода отмены, правка и
  /// выход из участников; сервер берёт отсюда автора для текста
  /// уведомления, а карточка — след двух исходов, которые в остальных
  /// полях не отличаются ничем (N53): отзыв запроса и отказ в отмене
  /// очищают `cancelRequestedBy`/`cancelRequestedAt` и оставляют
  /// `status: 'agreed'`, то есть по документу неразличимы.
  final String? lastActionBy;
  final String? lastActionType;

  /// Когда было ОТПРАВЛЕНО предложение, из которого вырос договор.
  ///
  /// Не то же самое, что `createdAt`: договор создаётся в миг согласия
  /// второй стороны, а предложение ушло раньше — иногда на минуту, иногда
  /// на дни. Для человека «пришло» — это про предложение.
  ///
  /// Пишется с 04.08 (починка N29). У 25 договоров из 26 в проде его нет,
  /// поэтому у читателя обязан быть запасной путь.
  final String? jobOfferAt;

  const PersonalEvent({
    required this.id,
    required this.ownerUid,
    required this.date,
    required this.type,
    required this.location,
    required this.notes,
    required this.participantUids,
    required this.isAgree,
    this.agreementChatId,
    this.partnerUid,
    this.partnerName,
    this.status = 'agreed',
    this.cancelRequestedBy,
    this.cancelRequestedAt,
    this.cancelConfirmedBy,
    this.cancelledAt,
    this.createdAt,
    this.lastActionBy,
    this.lastActionType,
    this.jobOfferAt,
  });

  factory PersonalEvent.fromFirestore(String id, Map<String, dynamic> data) {
    return PersonalEvent(
      id: id,
      ownerUid: (data['ownerUid'] ?? '') as String,
      date: (data['date'] ?? '') as String,
      type: (data['type'] ?? '') as String,
      location: (data['location'] ?? '') as String,
      notes: (data['notes'] ?? '') as String,
      participantUids: List<String>.from(data['musicians'] as List? ?? const []),
      isAgree: (data['isAgree'] ?? false) as bool,
      agreementChatId: data['agreementChatId'] as String?,
      partnerUid: data['partnerUid'] as String?,
      partnerName: data['partnerName'] as String?,
      status: (data['status'] ?? 'agreed') as String,
      cancelRequestedBy: data['cancelRequestedBy'] as String?,
      cancelRequestedAt: data['cancelRequestedAt'],
      cancelConfirmedBy: data['cancelConfirmedBy'] as String?,
      cancelledAt: data['cancelledAt'],
      createdAt: data['createdAt'],
      lastActionBy: data['lastActionBy'] as String?,
      lastActionType: data['lastActionType'] as String?,
      jobOfferAt: data['jobOfferAt'] as String?,
    );
  }
}

// users/{ownerUid}/statuses/{statusId} — a WhatsApp-style 24h status post.
// expiresAt is set client-side at creation (createdAt + 24h) and is what
// every read-path query must filter on; the Firestore TTL policy on this
// same field is storage cleanup only (deletion can lag up to 24h behind
// expiresAt per Firestore's own TTL semantics) and is never the authority
// for whether a status is still visible.
class Status {
  final String id;
  final String ownerUid;
  final String type; // 'text' | 'image' | 'video'
  final String? mediaUrl;
  final String? text;
  final String? caption;
  final DateTime createdAt;
  final DateTime expiresAt;
  final String privacyMode; // 'contacts' | 'contactsExcept' | 'onlyShareWith'
  // Exception list for 'contactsExcept', allowlist for 'onlyShareWith',
  // empty for 'contacts'.
  final List<String> privacyList;
  // Denormalized, server-computed audience for this status — the exact set
  // of uids (always including ownerUid) allowed to read it, derived from
  // privacyMode/privacyList + the owner's friends at the time this field
  // was last written. NEVER set by the client: it's computed and
  // maintained exclusively by Cloud Functions (onStatusCreated at
  // creation, then kept in sync by the friend-change propagation in
  // onFriendRequestUpdated/onFriendRequestDeleted — see
  // functions/src/index.ts). The client only ever reads it, as the
  // array-contains filter for its own collectionGroup('statuses') feed
  // query — firestore.rules requires every list/query read to be provably
  // scoped this way, which an exists()-based check can't satisfy.
  final List<String> visibleToUids;
  // Server-computed alongside visibleToUids by the same onStatusCreated
  // trigger — true for 'contacts'/'contactsExcept', false for
  // 'onlyShareWith' (see functions/src/index.ts). Backs firestore.rules'
  // isPublic-based `allow get` rule (a single-doc read, e.g. viewing one
  // person's status from their profile), which is now separate from the
  // unchanged visibleToUids-based `allow list` rule the feed's
  // collectionGroup query still depends on. Defaults to false for any
  // status doc written before this field existed, same as messageCount/
  // admins/createdBy's own predates-the-field defaults elsewhere in this
  // file — those legacy docs simply aren't get()-able via the new public
  // path, only via visibleToUids like before.
  final bool isPublic;

  const Status({
    required this.id,
    required this.ownerUid,
    required this.type,
    this.mediaUrl,
    this.text,
    this.caption,
    required this.createdAt,
    required this.expiresAt,
    required this.privacyMode,
    this.privacyList = const [],
    this.visibleToUids = const [],
    required this.isPublic,
  });

  factory Status.fromFirestore(String id, Map<String, dynamic> data) {
    return Status(
      id: id,
      ownerUid: (data['ownerUid'] ?? '') as String,
      type: (data['type'] ?? 'text') as String,
      mediaUrl: data['mediaUrl'] as String?,
      text: data['text'] as String?,
      caption: data['caption'] as String?,
      createdAt: (data['createdAt'] as Timestamp).toDate(),
      expiresAt: (data['expiresAt'] as Timestamp).toDate(),
      privacyMode: (data['privacyMode'] ?? 'contacts') as String,
      privacyList: List<String>.from(data['privacyList'] as List? ?? const []),
      visibleToUids:
          List<String>.from(data['visibleToUids'] as List? ?? const []),
      isPublic: (data['isPublic'] as bool?) ?? false,
    );
  }
}

// One owner's currently-visible-to-me statuses, grouped for the feed bar
// (one ring per owner, not one per status). Built client-side by
// FirestoreService.watchStatusFeed from the flat collectionGroup query
// result — not a Firestore document shape of its own.
class StatusGroup {
  final String ownerUid;
  final List<Status> statuses; // sorted by createdAt ascending

  const StatusGroup({required this.ownerUid, required this.statuses});
}

// One entry in a status owner's viewers/{viewerUid} subcollection — see
// firestore.rules' match /viewers/{viewerUid} for the write shape this
// mirrors (exactly one field, viewedAt, enforced server-side as
// request.time). Owner-only readable as a list; a viewer may only read
// their own single record (see FirestoreService.markStatusViewed and
// hasViewedStatus, which already use this subcollection without needing
// this model, since they only ever check/write a single known uid).
class StatusViewer {
  final String uid;
  final DateTime viewedAt;

  const StatusViewer({required this.uid, required this.viewedAt});

  factory StatusViewer.fromFirestore(String uid, Map<String, dynamic> data) {
    return StatusViewer(
      uid: uid,
      viewedAt: (data['viewedAt'] as Timestamp).toDate(),
    );
  }
}

// friendRequests/{requestId} — a Facebook-style friend request between two
// users. requestId is deliberately NOT an auto-id: FirestoreService derives
// it from the two uids (sorted, joined by '_'), so there can only ever be
// one document for a given pair — this is what prevents both the "two
// people send each other a request at the same instant" race and silent
// duplicate requests, without needing a transaction or an extra query.
//
// Lifecycle: created with status 'pending' by whoever sends the request →
// either transitions to 'accepted' (recipient only) or the document is
// deleted outright. Deletion deliberately covers three distinct user
// actions with one operation — sender cancels a still-pending request,
// recipient declines a still-pending request, and either side unfriends an
// already-accepted one — because at the data level all three are the same
// thing: this pair no longer has a request/friendship. See firestore.rules
// for the corresponding `allow delete` and functions/src/index.ts's
// onFriendRequestDeleted for what it triggers.
//
// On acceptance, a Cloud Function (onFriendRequestUpdated) writes a
// mirrored users/{uid}/friends/{otherUid} doc on both sides — nothing in
// this app writes that subcollection directly, same rationale as the
// existing users/{uid}/contacts/{otherUid} denormalization.
enum FriendRequestStatus { pending, accepted }

FriendRequestStatus _friendRequestStatusFromString(String value) {
  return value == 'accepted'
      ? FriendRequestStatus.accepted
      : FriendRequestStatus.pending;
}

class FriendRequest {
  final String id;
  final String fromUid;
  final String toUid;
  final FriendRequestStatus status;
  final Timestamp? createdAt;
  final Timestamp? respondedAt;

  const FriendRequest({
    required this.id,
    required this.fromUid,
    required this.toUid,
    required this.status,
    this.createdAt,
    this.respondedAt,
  });

  bool isBetween(String uidA, String uidB) =>
      (fromUid == uidA && toUid == uidB) || (fromUid == uidB && toUid == uidA);

  // Who the *other* party is, from the given viewer's perspective — used
  // by the UI to decide whether the viewer sent or received this request.
  String otherUid(String viewerUid) => fromUid == viewerUid ? toUid : fromUid;

  factory FriendRequest.fromFirestore(String id, Map<String, dynamic> data) {
    return FriendRequest(
      id: id,
      fromUid: (data['fromUid'] ?? '') as String,
      toUid: (data['toUid'] ?? '') as String,
      status: _friendRequestStatusFromString(
        (data['status'] ?? 'pending') as String,
      ),
      createdAt: data['createdAt'] as Timestamp?,
      respondedAt: data['respondedAt'] as Timestamp?,
    );
  }
}

enum CallStatus { ringing, accepted, declined, ended }

enum CallType { audio, video }

CallStatus _callStatusFromString(String value) => CallStatus.values.firstWhere(
  (e) => e.name == value,
  orElse: () => CallStatus.ringing,
);

CallType _callTypeFromString(String value) => CallType.values.firstWhere(
  (e) => e.name == value,
  orElse: () => CallType.audio,
);

class Call {
  final String id; // == channelName, same as Cloud Functions' callId
  final String callerId;
  final String calleeId;
  final CallStatus status;
  final CallType type;
  final Timestamp? createdAt;
  // CallKit (iOS)/ConnectionService (Android) call id — a real UUID,
  // deliberately distinct from `id` above. Generated once, server-side, by
  // startCall (see its own comment on why) — never generate a second one
  // client-side, caller and callee must show the exact same value.
  final String callkitUuid;
  // Caller's display name, resolved server-side by startCall so the
  // callee's native call UI can show it immediately (no extra Firestore
  // round-trip client-side, which would delay that UI appearing at all).
  final String callerName;

  const Call({
    required this.id,
    required this.callerId,
    required this.calleeId,
    required this.status,
    required this.type,
    required this.callkitUuid,
    required this.callerName,
    this.createdAt,
  });

  String otherUid(String viewerUid) => callerId == viewerUid ? calleeId : callerId;

  factory Call.fromFirestore(String id, Map<String, dynamic> data) {
    return Call(
      id: id,
      callerId: (data['callerId'] ?? '') as String,
      calleeId: (data['calleeId'] ?? '') as String,
      status: _callStatusFromString((data['status'] ?? 'ringing') as String),
      type: _callTypeFromString((data['type'] ?? 'audio') as String),
      callkitUuid: (data['callkitUuid'] ?? '') as String,
      callerName: (data['callerName'] ?? 'Zəng') as String,
      createdAt: data['createdAt'] as Timestamp?,
    );
  }
}
