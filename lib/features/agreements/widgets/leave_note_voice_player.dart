/// ПОКАЗ ГОЛОСА ПРИЧИНЫ ВЫХОДА — с диска, не по ссылке (N232, шаг 2).
///
/// Отдельным файлом, а не внутри строки состава, по одной причине: строка
/// состава (`_PartyMemberRow`) **показывает, а не решает** (I32, I58), и
/// знать про хранилище ей незачем. Сюда приходят `eventId` и `uid`, отсюда
/// уходит готовый проигрыватель.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/agreements/leave_note_voice.dart';
import '../../../core/theme/colors.dart';
import '../../../firebase/firestore_service.dart';
import '../../../shared/widgets/voice_player.dart';

/// Хранилище скачанных причин. Настоящая дорога к хранилищу приходит от
/// `FirestoreService`, папка — временная папка телефона.
final leaveNoteVoiceStoreProvider = Provider<LeaveNoteVoiceStore>((ref) {
  final service = ref.watch(firestoreServiceProvider);
  return LeaveNoteVoiceStore(
    download: service.downloadLeaveNoteVoice,
    cacheDir: getTemporaryDirectory,
  );
});

/// Файл причины для пары «вечер + человек».
///
/// Семейство, а не один провайдер: у каждой причины свой файл. Riverpod
/// помнит уже выполненное, поэтому повторное раскрытие «?» в том же заходе
/// не идёт ни в хранилище, ни на диск — а между заходами то же делает сам
/// файл.
final leaveNoteVoiceFileProvider =
    FutureProvider.family<File, ({String eventId, String uid})>((ref, key) {
      return ref
          .watch(leaveNoteVoiceStoreProvider)
          .voiceFile(eventId: key.eventId, uid: key.uid);
    });

/// Проигрыватель причины: пока файл едет — та же строка с волной, но без
/// источника; приехал — играет с диска.
///
/// **Волна приходит из документа вечера, а не из файла**, поэтому вид строки
/// не ждёт сети: человек сразу видит, что записано, и сколько её.
///
/// Отката на `voiceUrl` здесь нет намеренно — см. шапку
/// `core/agreements/leave_note_voice.dart`.
class LeaveNoteVoicePlayer extends ConsumerWidget {
  const LeaveNoteVoicePlayer({
    super.key,
    required this.eventId,
    required this.uid,
    required this.waveform,
  });

  /// Вечер, из которого вышли.
  final String eventId;

  /// Чья причина — он же имя файла в хранилище.
  final String uid;

  final List<int> waveform;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final file = ref.watch(
      leaveNoteVoiceFileProvider((eventId: eventId, uid: uid)),
    );
    return VoicePlayer(
      // `localFilePath` сильнее `audioURL` у самого проигрывателя, но здесь
      // второй не передаётся ВОВСЕ: ссылка с токеном из дороги убрана.
      localFilePath: file.value?.path,
      waveform: waveform,
      accentColor: kGold,
      labelColor: kText,
      playedColor: kGold,
      dotColor: kGold,
    );
  }
}
