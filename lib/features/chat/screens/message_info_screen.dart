import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
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
    return DateFormat('d MMM, HH:mm').format(dt);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chatMeta = ref.watch(chatMetaProvider(chatId)).value ?? {};
    final chatData = ref.watch(chatDataProvider(chatId)).value;
    final messagesAsync = ref.watch(messagesProvider(chatId));

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
          style: GoogleFonts.playfairDisplay(fontSize: 18, color: kText),
        ),
      ),
      body: messagesAsync.when(
        loading: () =>
            const Center(child: CircularProgressIndicator(color: kGold)),
        error: (_, _) => const Center(
          child: Text('Xəta', style: TextStyle(color: kMuted)),
        ),
        data: (messages) {
          // A message still in the offline queue has no Firestore document
          // yet, so it can't have a real deliveredTo/lastReadMsgId entry —
          // any value found for those below would belong to a different,
          // already-sent message. Show the local queue state instead.
          if (message.localSendStatus == 'queued' ||
              message.localSendStatus == 'uploading' ||
              message.localSendStatus == 'failed') {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (message.localSendStatus == 'failed')
                    _buildInfoRow(
                      Icons.error_outline,
                      'Göndərilmədi',
                      '',
                      color: kRed,
                    )
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
          }
          final members = (chatMeta['members'] as List?)?.cast<String>();
          final otherUid = members?.firstWhere(
            (m) => m != message.senderId,
            orElse: () => '',
          );
          final otherUidResolved = (otherUid != null && otherUid.isNotEmpty)
              ? otherUid
              : null;
          final deliveredTo =
              chatMeta['deliveredTo'] as Map<String, dynamic>? ?? {};
          final lastReadMsgId =
              chatMeta['lastReadMsgId'] as Map<String, dynamic>? ?? {};
          final lastReadAt =
              chatMeta['lastReadAt'] as Map<String, dynamic>? ?? {};

          bool isDelivered = false;
          bool isRead = false;
          if (otherUidResolved != null) {
            final allMsgIds = messages.map((m) => m.id).toList();
            final index = allMsgIds.indexOf(message.id);
            final lastReadId = lastReadMsgId[otherUidResolved] as String?;
            final lastReadIndex = lastReadId != null
                ? allMsgIds.indexOf(lastReadId)
                : -1;
            isRead = lastReadIndex >= index && index != -1;
            isDelivered = deliveredTo[otherUidResolved] != null || isRead;
          }
          final deliveredAt = otherUidResolved != null
              ? _asTimeString(deliveredTo[otherUidResolved])
              : null;
          final readAt = otherUidResolved != null
              ? _asTimeString(lastReadAt[otherUidResolved])
              : null;
          final otherName = chatData?['name'] as String? ?? '';

          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildInfoRow(
                  Icons.done,
                  'Göndərildi',
                  _formatInfoTime(message.timestamp),
                ),
                if (isDelivered)
                  _buildInfoRow(
                    Icons.done_all,
                    'Çatdırıldı',
                    _formatInfoTime(deliveredAt),
                  ),
                if (isRead)
                  _buildInfoRow(
                    Icons.done_all,
                    otherName.isNotEmpty ? '$otherName oxudu' : 'Oxundu',
                    _formatInfoTime(readAt),
                    color: kReadBlue,
                  ),
              ],
            ),
          );
        },
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
