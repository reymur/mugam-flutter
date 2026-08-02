import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../../../core/chat/chat_messages_controller.dart';
import '../../../core/theme/colors.dart';
import '../../../firebase/firestore_service.dart';
import '../../../firebase/models.dart';

class MessageInfoScreen extends ConsumerWidget {
  final String chatId;
  final Message message;

  const MessageInfoScreen({
    super.key,
    required this.chatId,
    required this.message,
  });

  // Legacy chat docs stored deliveredTo/lastReadAt as bool `true` before the
  // timestamp migration; treat anything that isn't a String as "no exact
  // time available" instead of throwing on the cast.
  String? _asTimeString(dynamic value) {
    return value is String ? value : null;
  }

  String _formatInfoTime(dynamic value) {
    DateTime? dt;
    if (value is Timestamp) {
      dt = value.toDate();
    } else if (value is String) {
      dt = DateTime.tryParse(value);
    }
    if (dt == null) return '';
    // toLocal() обязателен: deliveredTo/lastReadAt теперь пишутся в UTC
    // (N4, см. nowInstantIso), а DateFormat рисует ровно то, что ему
    // дали — без этого время доставки и прочтения показывалось бы по
    // UTC, то есть на смещение пояса назад. Для значений из Timestamp
    // вызов безвреден: toDate() и так отдаёт локальное.
    return DateFormat('d MMM, HH:mm').format(dt.toLocal());
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chatMeta = ref.watch(chatMetaProvider(chatId)).value ?? {};
    final chatData = ref.watch(chatDataProvider(chatId)).value;
    final messages = ref.watch(chatMessagesControllerProvider(chatId)).messages;

    Widget body;
    // A message still in the offline queue has no Firestore document yet,
    // so it can't have a real deliveredTo/lastReadMsgId entry — any value
    // found for those below would belong to a different, already-sent
    // message. Show the local queue state instead.
    if (message.localSendStatus == 'queued' ||
        message.localSendStatus == 'uploading' ||
        message.localSendStatus == 'failed') {
      body = Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message.localSendStatus == 'failed')
              _buildInfoRow(Icons.error_outline, 'Göndərilmədi', '', color: kRed)
            else
              _buildInfoRow(
                Icons.access_time,
                message.localSendStatus == 'uploading'
                    ? 'Göndərilir'
                    : 'Gözləyir',
                '',
              ),
          ],
        ),
      );
    } else {
      final members =
          (chatMeta['members'] as List?)?.cast<String>() ?? const <String>[];
      // Все получатели, а не первый попавшийся участник (B29). В диалоге
      // список из одного человека — экран выглядит ровно как раньше; в
      // группе раньше показывалось состояние произвольного участника,
      // выданное за состояние всей группы.
      final recipients = members.where((m) => m != message.senderId).toList();
      final deliveredTo =
          chatMeta['deliveredTo'] as Map<String, dynamic>? ?? {};
      final lastReadMsgId =
          chatMeta['lastReadMsgId'] as Map<String, dynamic>? ?? {};
      final lastReadAt = chatMeta['lastReadAt'] as Map<String, dynamic>? ?? {};

      // Compared by timestamp, not list position (finding #4) — a
      // paginated messages list has no stable "index" for a message
      // outside whatever's currently loaded. The read-up-to message is
      // almost always recent (near the tail, already loaded); falling
      // back to messageByIdProvider only costs a single extra document
      // read for the rare case it's well back in a long history.
      bool readByUid(String uid) {
        final lastReadId = lastReadMsgId[uid] as String?;
        if (lastReadId == null || message.timestamp == null) return false;
        Timestamp? lastReadTimestamp;
        final loaded = messages.where((m) => m.id == lastReadId);
        if (loaded.isNotEmpty) {
          lastReadTimestamp = loaded.first.timestamp;
        } else {
          lastReadTimestamp = ref
              .watch(
                messageByIdProvider((chatId: chatId, messageId: lastReadId)),
              )
              .value
              ?.timestamp;
        }
        return lastReadTimestamp != null &&
            lastReadTimestamp.compareTo(message.timestamp!) >= 0;
      }

      final rows = <Widget>[
        _buildInfoRow(
          Icons.done,
          'Göndərildi',
          _formatInfoTime(message.timestamp),
        ),
      ];

      if (recipients.length <= 1) {
        final uid = recipients.isEmpty ? null : recipients.first;
        final isRead = uid != null && readByUid(uid);
        final isDelivered = uid != null && (deliveredTo[uid] != null || isRead);
        final otherName = chatData?['name'] as String? ?? '';
        if (isDelivered) {
          rows.add(
            _buildInfoRow(
              Icons.done_all,
              'Çatdırıldı',
              _formatInfoTime(_asTimeString(deliveredTo[uid])),
            ),
          );
        }
        if (isRead) {
          rows.add(
            _buildInfoRow(
              Icons.done_all,
              otherName.isNotEmpty ? '$otherName oxudu' : 'Oxundu',
              _formatInfoTime(_asTimeString(lastReadAt[uid])),
              color: kReadBlue,
            ),
          );
        }
      } else {
        // Группа: одна строка на участника. Свести их в «Çatdırıldı» без
        // имён нельзя — вопрос, ради которого этот экран открывают, звучит
        // как «кто именно прочитал», и агрегат на него не отвечает.
        final read = recipients.where(readByUid).toList();
        final delivered = recipients
            .where((u) => deliveredTo[u] != null && !read.contains(u))
            .toList();
        final pending = recipients
            .where((u) => !read.contains(u) && !delivered.contains(u))
            .toList();

        void addGroup(String title, List<String> uids, IconData icon,
            Color color, Map<String, dynamic> times) {
          if (uids.isEmpty) return;
          rows.add(_buildSectionTitle(title, uids.length));
          for (final uid in uids) {
            rows.add(
              _MemberStatusRow(
                uid: uid,
                icon: icon,
                color: color,
                time: _formatInfoTime(_asTimeString(times[uid])),
              ),
            );
          }
        }

        addGroup('Oxudu', read, Icons.done_all, kReadBlue, lastReadAt);
        addGroup('Çatdırıldı', delivered, Icons.done_all, kMuted, deliveredTo);
        addGroup('Gözləyir', pending, Icons.access_time, kMuted, const {});
      }

      body = SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows),
      );
    }

    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg2,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: kGold),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          'Məlumat',
          style: GoogleFonts.nunito(fontSize: 18, color: kText),
        ),
      ),
      body: body,
    );
  }

  Widget _buildSectionTitle(String title, int count) {
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 4),
      child: Text(
        '$title ($count)',
        style: TextStyle(
          color: kMuted,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildInfoRow(
    IconData icon,
    String label,
    String time, {
    Color color = kMuted,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: kText, fontSize: 14),
            ),
          ),
          Text(time, style: TextStyle(color: kMuted, fontSize: 12)),
        ],
      ),
    );
  }
}

// Строка участника группы. Отдельный виджет, а не метод: имя тянется из
// currentUserProvider, и без собственного ConsumerWidget каждая строка
// подписывала бы на пользователей весь экран целиком.
class _MemberStatusRow extends ConsumerWidget {
  final String uid;
  final IconData icon;
  final Color color;
  final String time;

  const _MemberStatusRow({
    required this.uid,
    required this.icon,
    required this.color,
    required this.time,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider(uid)).value;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 10),
          Text(user?.emoji ?? '👤', style: const TextStyle(fontSize: 14)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              user?.name ?? 'İstifadəçi',
              style: const TextStyle(color: kText, fontSize: 14),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(time, style: const TextStyle(color: kMuted, fontSize: 12)),
        ],
      ),
    );
  }
}
