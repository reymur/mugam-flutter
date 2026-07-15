import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart' hide User;
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'models.dart';

// Live-tail window size for watchMessages (finding #4) — how many of the
// most recent messages stay covered by the always-on live listener. Older
// history is paginated in separately (see ChatMessagesController) rather
// than this growing per chat's total history size.
const int messageTailWindowSize = 50;

class FirestoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseFunctions _functions = FirebaseFunctions.instanceFor(
    region: 'europe-west3',
  );

  Future<User?> fetchUserById(String uid) async {
    final doc = await _db.collection('users').doc(uid).get();
    if (!doc.exists) return null;
    return User.fromFirestore(doc.id, doc.data()!);
  }

  Stream<User?> watchUserById(String uid) {
    return _db.collection('users').doc(uid).snapshots().map(
      (doc) => doc.exists ? User.fromFirestore(doc.id, doc.data()!) : null,
    );
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
    required String instrument,
    required String city,
    required bool available,
    String? photoURL,
  }) async {
    await _db.collection('users').doc(uid).update({
      'displayName': displayName,
      'bio': bio,
      'instrument': instrument,
      'specialty': instrument,
      'city': city,
      'available': available,
      'updatedAt': FieldValue.serverTimestamp(),
      if (photoURL != null) 'photoURL': photoURL,
    });
  }

  Stream<List<User>> _watchUsers(Query<Map<String, dynamic>> query) {
    return query.snapshots().map(
      (snap) =>
          snap.docs.map((doc) => User.fromFirestore(doc.id, doc.data())).toList(),
    );
  }

  Stream<List<User>> watchMusicians() {
    return _watchUsers(_db.collection('users').where('role', isEqualTo: 'musician'));
  }

  // Unfiltered by role — screens that need to pick from any registered
  // user (e.g. tagging event participants), unlike watchMusicians() above
  // which powers the home screen's musician-only feed.
  Stream<List<User>> watchAllUsers() {
    return _watchUsers(_db.collection('users'));
  }

  Stream<List<Chat>> watchChats(String uid) {
    return _db
        .collection('chats')
        .where('members', arrayContains: uid)
        .snapshots()
        .map(
          (snap) =>
              snap.docs
                  .map((doc) => Chat.fromFirestore(doc.id, doc.data()))
                  // mugam-v2 marks a direct chat completed once the pair
                  // finalizes a Razılaşma (agreement) and starts a fresh
                  // chat doc the next time they talk — its own chat list
                  // hides completed chats the same way, so without this
                  // filter every past agreement's chat resurfaces as a
                  // separate duplicate entry for the same person.
                  .where((chat) => !chat.completed)
                  .toList()
                ..sort((a, b) {
                  if (a.lastMessageTime == null && b.lastMessageTime == null) {
                    return 0;
                  }
                  if (a.lastMessageTime == null) return 1;
                  if (b.lastMessageTime == null) return -1;
                  return b.lastMessageTime!.compareTo(a.lastMessageTime!);
                }),
        );
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
  Future<void> markStatusViewed({
    required String ownerUid,
    required String statusId,
    required String viewerUid,
  }) {
    return _db
        .collection('users')
        .doc(ownerUid)
        .collection('statuses')
        .doc(statusId)
        .collection('viewers')
        .doc(viewerUid)
        .set({'viewedAt': FieldValue.serverTimestamp()});
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

  // Read-side for the Status creation privacy picker's contacts
  // multiselect (contactsExcept/onlyShareWith). users/{uid}/contacts/
  // {otherUid} docs carry no meaningful fields of their own (see
  // firestore.rules' own comment on that collection — only the otherUid
  // path segment matters), so this just enumerates doc IDs and resolves
  // each to a full User. Future.wait fan-out rather than a whereIn batch:
  // no batching convention exists anywhere else in this file to reuse, and
  // a contacts list is bounded by how many people you've actually chatted
  // with, not global user count — same "not a scale concern" reasoning as
  // hasViewedStatus's own doc comment above.
  Future<List<User>> fetchMyContacts(String uid) async {
    final snap = await _db
        .collection('users')
        .doc(uid)
        .collection('contacts')
        .get();
    final users = await Future.wait(snap.docs.map((d) => fetchUserById(d.id)));
    return users.whereType<User>().toList();
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
      'preview': '$creatorName qrupu yaratdı',
      'lastMessageAt': now,
      'lastMessageTime': now,
      'createdAt': now,
      'completed': false,
      'unreadCount': <String, int>{},
    });

    await chatRef.collection('messages').add({
      'senderId': creatorUid,
      'text': '$creatorName qrupu yaratdı',
      'type': 'text',
      'isSystem': true,
      'timestamp': now,
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

    await chatRef.collection('messages').add({
      'senderId': uid,
      'text': '$userName qrupdan çıxdı',
      'type': 'text',
      'isSystem': true,
      'timestamp': FieldValue.serverTimestamp(),
    });

    await _db.runTransaction((tx) async {
      final snap = await tx.get(chatRef);
      final data = snap.data() ?? {};
      final members = List<String>.from(data['members'] as List? ?? const []);
      final admins = List<String>.from(data['admins'] as List? ?? const []);
      final wasAdmin = admins.contains(uid);

      final remainingMembers = members.where((m) => m != uid).toList();
      final remainingAdmins = admins.where((a) => a != uid).toList();

      // WhatsApp-style guarantee: a group is never left without an admin —
      // if the sole admin leaves and members remain, randomly promote one.
      if (wasAdmin && remainingAdmins.isEmpty && remainingMembers.isNotEmpty) {
        final promoted =
            remainingMembers[Random().nextInt(remainingMembers.length)];
        remainingAdmins.add(promoted);
      }

      tx.update(chatRef, {
        'members': remainingMembers,
        'admins': remainingAdmins,
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

    await chatRef.collection('messages').add({
      'senderId': adminUid,
      'text': '$addedByName $userName qrupa əlavə etdi',
      'type': 'text',
      'isSystem': true,
      'timestamp': FieldValue.serverTimestamp(),
    });
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
    final snap = await chatRef.get();
    if (uid == snap.data()?['createdBy']) {
      throw Exception('Cannot remove the group creator');
    }

    await chatRef.update({
      'members': FieldValue.arrayRemove([uid]),
      'admins': FieldValue.arrayRemove([uid]),
    });

    await chatRef.collection('messages').add({
      'senderId': adminUid,
      'text': '$removedByName $userName qrupdan çıxardı',
      'type': 'text',
      'isSystem': true,
      'timestamp': FieldValue.serverTimestamp(),
    });
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

    await chatRef.collection('messages').add({
      'senderId': adminUid,
      'text': '$adminName $userName-ni admin etdi',
      'type': 'text',
      'isSystem': true,
      'timestamp': FieldValue.serverTimestamp(),
    });
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

    await chatRef.collection('messages').add({
      'senderId': adminUid,
      'text': '$adminName $userName-ni admin statusundan çıxardı',
      'type': 'text',
      'isSystem': true,
      'timestamp': FieldValue.serverTimestamp(),
    });
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
  // isFirst lives in this closure, so it's scoped to one subscription's
  // lifetime — a fresh chat-screen mount (new subscription via autoDispose)
  // correctly gets its own "first snapshot" again, rather than this being
  // some global per-chatId flag.
  Stream<MessagesSnapshot> watchMessages(String chatId) {
    bool isFirst = true;
    return _db
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .orderBy('timestamp', descending: false)
        .limitToLast(messageTailWindowSize)
        .snapshots()
        .map((snap) {
          final messages = snap.docs
              .map((doc) => Message.fromFirestore(doc.id, doc.data()))
              .toList();
          // The very first snapshot's docChanges all report as `added`
          // (every doc is new to this listener) — that's history loading,
          // not new messages arriving, so addedMessageIds is deliberately
          // left empty for it rather than reporting the whole history.
          final addedIds = isFirst
              ? const <String>[]
              : snap.docChanges
                    .where((c) => c.type == DocumentChangeType.added)
                    .map((c) => c.doc.id)
                    .toList();
          final result = MessagesSnapshot(
            messages: messages,
            isInitialLoad: isFirst,
            addedMessageIds: addedIds,
          );
          isFirst = false;
          return result;
        });
  }

  // One-time fetch of the page immediately older than beforeTimestamp —
  // triggered by scrolling near the top of the loaded history. Not a live
  // listener itself; ChatMessagesController separately widens
  // watchOlderMessagesInRange's upper bound to cover whatever this returns,
  // so the newly-loaded page still gets live reaction/read-receipt updates
  // going forward.
  Future<List<Message>> fetchOlderMessages({
    required String chatId,
    required Timestamp beforeTimestamp,
    int limit = messageTailWindowSize,
  }) async {
    final snap = await _db
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .orderBy('timestamp', descending: false)
        .endBefore([beforeTimestamp])
        .limitToLast(limit)
        .get();
    return snap.docs
        .map((doc) => Message.fromFirestore(doc.id, doc.data()))
        .toList();
  }

  // Live listener scoped to [fromTimestamp, toTimestamp) — everything
  // paginated in via fetchOlderMessages so far, up to (but deliberately not
  // overlapping) the live tail window's own oldest message. Kept as its own
  // listener rather than folding into watchMessages' unbounded query so the
  // tail stays fixed at messageTailWindowSize regardless of how much
  // history has been paginated in during this session — ChatMessagesController
  // is what recreates this with a wider toTimestamp as the tail's own oldest
  // message shifts forward over time.
  Stream<List<Message>> watchOlderMessagesInRange({
    required String chatId,
    required Timestamp fromTimestamp,
    required Timestamp toTimestamp,
  }) {
    return _db
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .orderBy('timestamp', descending: false)
        .startAt([fromTimestamp])
        .endBefore([toTimestamp])
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
        .orderBy('timestamp', descending: false)
        .snapshots()
        .map(
          (snap) => snap.docs
              .map((doc) => Message.fromFirestore(doc.id, doc.data()))
              .where((m) => !m.deletedForAll)
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

  // Generates a message doc id client-side, up front, before any upload or
  // send attempt — used by the pending-media queue so every retry of the
  // same queued item writes to the same doc via sendXMessage's messageId
  // param instead of creating a new document each time.
  String generateMessageId(String chatId) {
    return _db.collection('chats').doc(chatId).collection('messages').doc().id;
  }

  // Used by sendImageMessage/sendAudioMessage/sendVideoMessage when a
  // messageId is provided (i.e. a queued offline media send). The offline
  // queue's retry() and its automatic per-chat loop — or the foreground
  // queue and the WorkManager background task — can end up both attempting
  // the same queued item at once, each with its own freshly uploaded file
  // URL. A plain .set() would let whichever write lands last silently
  // overwrite the other's videoURL/imageURL/audioURL. Wrapping it in a
  // transaction that only writes if the document doesn't exist yet makes
  // the second, racing write a no-op instead of a corruption.
  Future<bool> _writeMessageIfAbsent({
    required String chatId,
    required String messageId,
    required Map<String, dynamic> data,
  }) {
    final ref = _db
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .doc(messageId);
    return _db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (snap.exists) return false;
      tx.set(ref, data);
      return true;
    });
  }

  Future<void> sendMessage({
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
    // If provided, writes with .doc(messageId).set(...) instead of .add(...)
    // — same idempotency purpose as sendImageMessage's messageId param, used
    // by the offline pending-send queue so a retry of the same queued text
    // message overwrites rather than duplicates.
    String? messageId,
  }) async {
    final now = FieldValue.serverTimestamp();
    final replyTo = _buildReplyTo(
      replyToId: replyToId,
      replyToText: replyToText,
      replyToSenderName: replyToSenderName,
      replyToImageURL: replyToImageURL,
      replyToVideoURL: replyToVideoURL,
    );
    final data = {
      'senderId': senderId,
      'text': text,
      'type': 'text',
      'clientPlatform': 'flutter',
      'forwardCount': forwardCount,
      'timestamp': now,
      'imageURL': null,
      'audioURL': null,
      if (replyTo != null) 'replyTo': replyTo,
    };
    bool wrote = true;
    if (messageId != null) {
      wrote = await _writeMessageIfAbsent(
        chatId: chatId,
        messageId: messageId,
        data: data,
      );
    } else {
      await _db.collection('chats').doc(chatId).collection('messages').add(data);
    }
    if (!wrote) return;
    await _db.collection('chats').doc(chatId).update({
      'lastMessage': text,
      'lastMessageTime': now,
    });
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

  Future<void> sendImageMessage({
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
    // If provided, writes with .doc(messageId).set(...) instead of .add(...)
    // — makes retries of this exact same send idempotent (same id = same
    // document, no duplicate) instead of creating a new document each retry.
    String? messageId,
  }) async {
    final now = FieldValue.serverTimestamp();
    final replyTo = _buildReplyTo(
      replyToId: replyToId,
      replyToText: replyToText,
      replyToSenderName: replyToSenderName,
      replyToImageURL: replyToImageURL,
      replyToVideoURL: replyToVideoURL,
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
      'timestamp': now,
      if (replyTo != null) 'replyTo': replyTo,
    };
    bool wrote = true;
    if (messageId != null) {
      wrote = await _writeMessageIfAbsent(
        chatId: chatId,
        messageId: messageId,
        data: data,
      );
    } else {
      await _db
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .add(data);
    }
    if (!wrote) return;
    await _db.collection('chats').doc(chatId).update({
      'lastMessage': '🖼 Şəkil',
      'lastMessageTime': now,
      // Every chat was backfilled with an accurate starting value (one-off
      // migration, run before this line ever shipped) — safe to always use
      // a plain atomic increment, no "field missing" fallback needed.
      'mediaImageCount': FieldValue.increment(1),
    });
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

  Future<void> sendVideoMessage({
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
    String? messageId,
  }) async {
    final now = FieldValue.serverTimestamp();
    final replyTo = _buildReplyTo(
      replyToId: replyToId,
      replyToText: replyToText,
      replyToSenderName: replyToSenderName,
      replyToImageURL: replyToImageURL,
      replyToVideoURL: replyToVideoURL,
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
      'timestamp': now,
      if (replyTo != null) 'replyTo': replyTo,
    };
    bool wrote = true;
    if (messageId != null) {
      wrote = await _writeMessageIfAbsent(
        chatId: chatId,
        messageId: messageId,
        data: data,
      );
    } else {
      await _db
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .add(data);
    }
    if (!wrote) return;
    await _db.collection('chats').doc(chatId).update({
      'lastMessage': '🎥 Video',
      'lastMessageTime': now,
    });
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

  Future<void> sendFileMessage({
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
    String? messageId,
  }) async {
    final now = FieldValue.serverTimestamp();
    final replyTo = _buildReplyTo(
      replyToId: replyToId,
      replyToText: replyToText,
      replyToSenderName: replyToSenderName,
      replyToImageURL: replyToImageURL,
      replyToVideoURL: replyToVideoURL,
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
      'timestamp': now,
      if (replyTo != null) 'replyTo': replyTo,
    };
    bool wrote = true;
    if (messageId != null) {
      wrote = await _writeMessageIfAbsent(
        chatId: chatId,
        messageId: messageId,
        data: data,
      );
    } else {
      await _db
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .add(data);
    }
    if (!wrote) return;
    await _db.collection('chats').doc(chatId).update({
      'lastMessage': '📄 $fileName',
      'lastMessageTime': now,
    });
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
  Future<void> sendLocationMessage({
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
    String? messageId,
  }) async {
    final now = FieldValue.serverTimestamp();
    final replyTo = _buildReplyTo(
      replyToId: replyToId,
      replyToText: replyToText,
      replyToSenderName: replyToSenderName,
      replyToImageURL: replyToImageURL,
      replyToVideoURL: replyToVideoURL,
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
      'timestamp': now,
      if (replyTo != null) 'replyTo': replyTo,
    };
    bool wrote = true;
    if (messageId != null) {
      wrote = await _writeMessageIfAbsent(
        chatId: chatId,
        messageId: messageId,
        data: data,
      );
    } else {
      await _db
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .add(data);
    }
    if (!wrote) return;
    await _db.collection('chats').doc(chatId).update({
      'lastMessage': '📍 Məkan',
      'lastMessageTime': now,
    });
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

  Future<void> sendAudioMessage({
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
    String? messageId,
  }) async {
    final now = FieldValue.serverTimestamp();
    final replyTo = _buildReplyTo(
      replyToId: replyToId,
      replyToText: replyToText,
      replyToSenderName: replyToSenderName,
      replyToImageURL: replyToImageURL,
      replyToVideoURL: replyToVideoURL,
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
      'timestamp': now,
      if (replyTo != null) 'replyTo': replyTo,
    };
    bool wrote = true;
    if (messageId != null) {
      wrote = await _writeMessageIfAbsent(
        chatId: chatId,
        messageId: messageId,
        data: data,
      );
    } else {
      await _db
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .add(data);
    }
    if (!wrote) return;
    await _db.collection('chats').doc(chatId).update({
      'lastMessage': '🎤 Səs mesajı',
      'lastMessageTime': now,
    });
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
    // Transaction, not a plain update: needs the message's own type (to
    // know whether mediaImageCount needs decrementing) and must be
    // idempotent against a repeat call on an already-deleted message
    // (which would otherwise double-decrement).
    final wasImage = await _db.runTransaction((tx) async {
      final snap = await tx.get(msgRef);
      final data = snap.data();
      if (data == null || data['deletedForAll'] == true) return false;
      tx.update(msgRef, {
        'deletedForAll': true,
        'deletedAt': DateTime.now().toIso8601String(),
        'text': '',
      });
      return data['type'] == 'image';
    });
    if (wasImage) {
      await _db.collection('chats').doc(chatId).update({
        'mediaImageCount': FieldValue.increment(-1),
      });
    }
  }

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
    return _db.collection('chats').doc(chatId).snapshots().map((snap) {
      final data = snap.data() ?? {};
      return {
        'members': List<String>.from(data['members'] ?? const []),
        'deliveredTo': Map<String, dynamic>.from(data['deliveredTo'] ?? {}),
        'lastReadMsgId': Map<String, dynamic>.from(data['lastReadMsgId'] ?? {}),
        'lastReadAt': Map<String, dynamic>.from(data['lastReadAt'] ?? {}),
        // Maintained by sendImageMessage/deleteMessageForAll via atomic
        // FieldValue.increment — every chat was backfilled with an
        // accurate starting value before that logic went live (one-off
        // Cloud Function migration, already run and spot-checked), so no
        // "field missing" fallback is needed here.
        'mediaImageCount': (data['mediaImageCount'] as num?)?.toInt() ?? 0,
        // Live so a group rename/role change reflects in the app bar
        // without needing to reopen the chat screen — see chat_screen.dart's
        // app bar, which reads these instead of the one-time
        // chatDataProvider for group chats specifically.
        'admins': List<String>.from(data['admins'] ?? const []),
        'createdBy': data['createdBy'] ?? '',
        'name': data['name'] ?? '',
        'emoji': data['emoji'] ?? '💬',
        'photoURL': data['photoURL'],
      };
    });
  }

  Future<void> markChatAsDelivered({
    required String chatId,
    required String uid,
  }) async {
    try {
      await _db.collection('chats').doc(chatId).update({
        'deliveredTo.$uid': DateTime.now().toIso8601String(),
      });
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'FirestoreService: markChatAsDelivered failed',
      );
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
      });
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
      });
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'FirestoreService: removeActiveUser failed',
      );
    }
  }

  // Logout cleanup, mirroring mugam-v2's pre-signOut steps: mark the user
  // offline and defensively strip their uid from every chat's activeUsers
  // (in case they logged out without normally leaving a chat first, which
  // would otherwise leave them permanently exempt from push notifications).
  Future<void> setUserOnline(String uid, bool online) async {
    try {
      await _db.collection('users').doc(uid).update({'online': online});
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'FirestoreService: setUserOnline failed',
      );
    }
  }

  Future<void> clearActiveUserFromAllChats(String uid) async {
    try {
      final snap = await _db
          .collection('chats')
          .where('activeUsers', arrayContains: uid)
          .get();
      for (final doc in snap.docs) {
        await doc.reference.update({
          'activeUsers': FieldValue.arrayRemove([uid]),
        });
      }
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'FirestoreService: clearActiveUserFromAllChats failed',
      );
    }
  }

  Future<void> markChatAsReadBy({
    required String chatId,
    required String uid,
    required String lastMsgId,
  }) async {
    try {
      await _db.collection('chats').doc(chatId).update({
        'readBy': FieldValue.arrayUnion([uid]),
        'lastReadAt.$uid': DateTime.now().toIso8601String(),
        'lastReadMsgId.$uid': lastMsgId,
      });
    } catch (e, st) {
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'FirestoreService: markChatAsReadBy failed',
      );
    }
  }

  Future<List<Event>> fetchEvents() async {
    final snap = await _db.collection('events').limit(10).get();
    return snap.docs
        .map((doc) => Event.fromFirestore(doc.id, doc.data()))
        .toList();
  }

  Future<List<Room>> fetchRooms() async {
    final snap = await _db.collection('rooms').limit(10).get();
    return snap.docs
        .map((doc) => Room.fromFirestore(doc.id, doc.data()))
        .toList();
  }

  Stream<List<PersonalEvent>> watchPersonalEvents(String uid) {
    return _db
        .collection('personalEvents')
        .where('ownerUid', isEqualTo: uid)
        .snapshots()
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
        .map(
          (snap) => snap.docs
              .map((doc) => PersonalEvent.fromFirestore(doc.id, doc.data()))
              .toList(),
        );
  }

  Future<String> addPersonalEvent({
    required String ownerUid,
    required String date,
    required String type,
    required String location,
    required String notes,
    required List<String> participantUids,
  }) async {
    final ref = await _db.collection('personalEvents').add({
      'ownerUid': ownerUid,
      'date': date,
      'type': type,
      'location': location,
      'notes': notes,
      'musicians': participantUids,
      'isAgree': false,
      'agreementChatId': null,
      'partnerUid': null,
      'partnerName': null,
      'status': 'agreed',
      'cancelledBy': null,
      'createdAt': FieldValue.serverTimestamp(),
    });
    return ref.id;
  }

  Future<void> updatePersonalEvent(String eventId, Map<String, dynamic> data) {
    return _db.collection('personalEvents').doc(eventId).update(data);
  }

  Future<List<String>> loadReadAgreementIds(String uid) async {
    try {
      final doc = await _db.collection('users').doc(uid).get();
      if (!doc.exists) return [];
      return (doc.data()?['readAgreementIds'] as List?)?.cast<String>() ?? [];
    } catch (_) {
      return [];
    }
  }

  Future<void> saveReadAgreementId(String uid, String agreementId) {
    return _db.collection('users').doc(uid).update({
      'readAgreementIds': FieldValue.arrayUnion([agreementId]),
    });
  }
}

final firestoreServiceProvider = Provider<FirestoreService>(
  (_) => FirestoreService(),
);

final musiciansProvider = StreamProvider<List<User>>(
  (ref) => ref.watch(firestoreServiceProvider).watchMusicians(),
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

final eventsProvider = FutureProvider<List<Event>>(
  (ref) => ref.watch(firestoreServiceProvider).fetchEvents(),
);

final roomsProvider = FutureProvider<List<Room>>(
  (ref) => ref.watch(firestoreServiceProvider).fetchRooms(),
);

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

// autoDispose — read once when the Status creation privacy picker opens,
// same "don't pin every combination ever seen" rationale as
// hasViewedStatusProvider above; no keepAlive-with-grace-period dance like
// userByIdProvider needs, since this isn't re-fetched on a scrolling
// list's recycling.
final myContactsProvider = FutureProvider.autoDispose.family<List<User>, String>(
  (ref, uid) => ref.watch(firestoreServiceProvider).fetchMyContacts(uid),
);

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

final starredMessagesProvider =
    StreamProvider.family<List<StarredMessage>, String>((ref, uid) {
      return ref.watch(firestoreServiceProvider).watchStarredMessages(uid);
    });

final chatMediaProvider = StreamProvider.family<List<Message>, String>((
  ref,
  chatId,
) {
  return ref.watch(firestoreServiceProvider).watchChatMedia(chatId);
});
