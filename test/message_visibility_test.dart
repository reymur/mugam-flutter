import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/chat/message_visibility.dart';
import 'package:mugam_flutter/firebase/models.dart';

// isMessageVisible is now the single predicate three separate call sites
// depend on (the message list, older-message pagination, and the media
// gallery). Before it existed each of them answered the question slightly
// differently, and pagination didn't answer it at all — which is the bug
// class this pins down.
Message _message({
  String id = 'm1',
  DateTime? sentAt,
  List<String> deletedFor = const [],
  bool deletedForAll = false,
}) {
  return Message(
    id: id,
    chatId: 'c1',
    senderId: 'u_other',
    text: 'hello',
    type: 'text',
    timestamp: sentAt == null ? null : Timestamp.fromDate(sentAt),
    deletedFor: deletedFor,
    deletedForAll: deletedForAll,
  );
}

void main() {
  final cutoff = DateTime.utc(2026, 8, 1, 12);

  group('clear-chat cutoff', () {
    test('no cutoff shows everything', () {
      final m = _message(sentAt: cutoff.subtract(const Duration(days: 30)));
      expect(isMessageVisible(m, uid: 'me', clearedAt: null), isTrue);
    });

    test('older than the cutoff is hidden', () {
      final m = _message(sentAt: cutoff.subtract(const Duration(seconds: 1)));
      expect(isMessageVisible(m, uid: 'me', clearedAt: cutoff), isFalse);
    });

    test('exactly at the cutoff is hidden (cutoff is inclusive)', () {
      final m = _message(sentAt: cutoff);
      expect(isMessageVisible(m, uid: 'me', clearedAt: cutoff), isFalse);
    });

    test('newer than the cutoff is shown', () {
      final m = _message(sentAt: cutoff.add(const Duration(seconds: 1)));
      expect(isMessageVisible(m, uid: 'me', clearedAt: cutoff), isTrue);
    });

    test('a pending send with no timestamp survives any cutoff', () {
      final m = _message(sentAt: null);
      expect(isMessageVisible(m, uid: 'me', clearedAt: cutoff), isTrue);
    });
  });

  group('per-user delete', () {
    test('hidden for the user who deleted it', () {
      final m = _message(sentAt: cutoff, deletedFor: const ['me']);
      expect(isMessageVisible(m, uid: 'me', clearedAt: null), isFalse);
    });

    test('still shown to everyone else', () {
      final m = _message(sentAt: cutoff, deletedFor: const ['someone_else']);
      expect(isMessageVisible(m, uid: 'me', clearedAt: null), isTrue);
    });

    test('an empty uid disables only the per-user filter', () {
      final m = _message(sentAt: cutoff, deletedFor: const ['me']);
      expect(isMessageVisible(m, uid: '', clearedAt: null), isTrue);
      expect(isMessageVisible(m, uid: '', clearedAt: cutoff), isFalse);
    });
  });

  // Deliberate: chat_screen renders these as a "Bu mesaj silindi" tombstone
  // until its own purge timer hard deletes them, so they must keep counting
  // as visible rows — otherwise pagination would page straight past a run of
  // deleted messages looking for something to show.
  test('deleted-for-everyone stays visible as a tombstone', () {
    final m = _message(sentAt: cutoff, deletedForAll: true);
    expect(isMessageVisible(m, uid: 'me', clearedAt: null), isTrue);
  });
}
