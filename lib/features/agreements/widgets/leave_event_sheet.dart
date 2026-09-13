import 'package:flutter/material.dart';

import '../../../core/audio/voice_recording_session.dart';
import '../../../core/audio/voice_temp_files.dart';
import '../../../core/theme/colors.dart';
import '../../../shared/widgets/voice_hold_recorder.dart';
import '../../../shared/widgets/voice_player.dart';

// ---------------------------------------------------------------------------
// ЛИСТ ВЫХОДА «Gələ bilmirəm» — поле или голос, необязательно (13.09)
// ---------------------------------------------------------------------------
// Решение владельца: причина выхода хранится в самом вечере и видна только
// владельцу; голос делается вместе с текстом — музыкант за рулём или на сцене,
// говорить ему естественнее, чем печатать.
//
// ЗАПИСЬ — ОБЩАЯ С ЧАТОМ (решение владельца 13.09, вариант Б, шаг 2).
// Удержание, время, смахивание-отмена, замок и отказ микрофона живут в
// `lib/shared/widgets/voice_hold_recorder.dart`; своего удержания у листа нет.
// Здесь остался только ХВОСТ: готовая запись встаёт строкой, её можно
// прослушать и убрать, а уходит она кнопкой «Gələ bilmirəm» вместе с выходом.
//
// ОТПУЩЕННЫЙ МИКРОФОН НЕ ОТПРАВЛЯЕТ — в этом хвост листа и отличается от
// чата. В чате отпускание и есть отправка; здесь отправка — выход из вечера, а
// вернуться в вечер из приложения нельзя.
//
// СЛОВ НОВЫХ НЕТ: все подписи уже жили в приложении (окошко выхода 12.09,
// отказ микрофона и «Sürüşdür»/«Kilid» в чате).

/// Что человек сказал, уходя. Лист возвращает `null`, если человек передумал.
class LeaveSheetResult {
  const LeaveSheetResult({required this.text, this.voice});

  final String text;

  /// Готовая запись на телефоне, ещё не загруженная. `null` — голоса нет.
  final VoiceRecording? voice;
}

/// Как показать готовую запись до отправки.
///
/// По умолчанию — общий проигрыватель ([VoicePlayer]). Параметр заведён ради
/// теста листа: проигрыватель тянет плагин звука, которого в тесте нет, и
/// падал бы не по делу. Место вызова в карточке его не передаёт.
Widget _playerPreview(VoiceRecording recording) => VoicePlayer(
      localFilePath: recording.filePath,
      waveform: recording.waveform,
      accentColor: kGold,
      labelColor: kText,
      playedColor: kGold,
      dotColor: kGold,
    );

class LeaveEventSheet extends StatefulWidget {
  const LeaveEventSheet({
    super.key,
    required this.recorder,
    this.recordingPreview = _playerPreview,
  });

  /// Сеанс записи. Заводит и гасит его зовущий (`_leaveEvent`).
  final VoiceRecorder recorder;

  final Widget Function(VoiceRecording recording) recordingPreview;

  @override
  State<LeaveEventSheet> createState() => _LeaveEventSheetState();
}

class _LeaveEventSheetState extends State<LeaveEventSheet> {
  final _text = TextEditingController();
  VoiceRecording? _voice;

  /// Запись отдана зовущему — удалять её файл больше не наше дело.
  bool _handedOver = false;

  late final VoiceHoldController _hold = VoiceHoldController(
    recorder: widget.recorder,
    onRecorded: _onRecorded,
    onNoPermission: () {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Mikrofon icazəsi verilmədi')),
      );
    },
  );

  /// ХВОСТ ЛИСТА: запись встаёт строкой, прежняя уходит вместе со своим файлом.
  Future<void> _onRecorded(VoiceRecording recording) async {
    if (!mounted) {
      deleteVoiceTempFiles([recording.filePath]);
      return;
    }
    final previous = _voice;
    setState(() => _voice = recording);
    if (previous != null) deleteVoiceTempFiles([previous.filePath]);
  }

  void _discardVoice() {
    final v = _voice;
    if (v == null) return;
    setState(() => _voice = null);
    deleteVoiceTempFiles([v.filePath]);
  }

  void _send() {
    _handedOver = true;
    Navigator.pop(context, LeaveSheetResult(text: _text.text, voice: _voice));
  }

  @override
  void dispose() {
    // Лист закрыли посреди записи — запись отменяется, а не дописывается.
    _hold.cancel();
    _hold.dispose();
    // Лист закрыт без отправки — запись пропадает. Удаляем явно, а не
    // надеемся на систему (N129): запись без выхода потом не найти.
    final v = _voice;
    if (!_handedOver && v != null) deleteVoiceTempFiles([v.filePath]);
    _text.dispose();
    super.dispose();
  }

  Widget _roundButton({
    required IconData icon,
    required Color iconColor,
    required Color fill,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: fill,
          shape: BoxShape.circle,
          border: Border.all(color: kBorder),
        ),
        child: Icon(icon, color: iconColor, size: 22),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return ListenableBuilder(
      listenable: _hold,
      builder: (context, _) {
        final recording = _hold.isRecording;
        final locked = _hold.isLocked;
        final voice = _voice;
        return Container(
          padding: EdgeInsets.fromLTRB(20, 18, 20, 8 + bottomInset),
          decoration: const BoxDecoration(
            color: kBg2,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Gələ bilmirəm',
                  style: TextStyle(color: kText, fontSize: 17),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Təşkilatçı xəbər tutacaq.',
                  style: TextStyle(color: kTextSecondary, fontSize: 14),
                ),
                const SizedBox(height: 14),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    // При замке — корзина: отмена без записи, как в чате.
                    if (locked) ...[
                      _roundButton(
                        icon: Icons.delete_outline,
                        iconColor: kRed,
                        fill: kBg3,
                        onTap: _hold.cancel,
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: recording
                          ? VoiceRecordingStrip(controller: _hold)
                          : TextField(
                              controller: _text,
                              maxLines: 3,
                              minLines: 1,
                              style: const TextStyle(color: kText, fontSize: 15),
                              decoration: const InputDecoration(
                                hintText: 'Səbəb — istəyə bağlı',
                                hintStyle:
                                    TextStyle(color: kMuted, fontSize: 14),
                                enabledBorder: UnderlineInputBorder(
                                  borderSide: BorderSide(color: kBorder),
                                ),
                                focusedBorder: UnderlineInputBorder(
                                  borderSide: BorderSide(color: kGold),
                                ),
                              ),
                            ),
                    ),
                    const SizedBox(width: 8),
                    // При замке — «остановить»: запись встаёт строкой, а не
                    // уходит. Без замка — общая кнопка записи удержанием.
                    if (locked)
                      _roundButton(
                        icon: Icons.check,
                        iconColor: kOnGold,
                        fill: kGold,
                        onTap: _hold.stop,
                      )
                    else
                      VoiceHoldMicButton(controller: _hold),
                  ],
                ),
                if (voice != null) ...[
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(child: widget.recordingPreview(voice)),
                      IconButton(
                        onPressed: _discardVoice,
                        icon: const Icon(Icons.close, color: kMuted),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child:
                          const Text('Geri', style: TextStyle(color: kMuted)),
                    ),
                    TextButton(
                      // Пока идёт запись, уйти нельзя: сказанное ещё не готово,
                      // и выход унёс бы полуслово.
                      onPressed: recording ? null : _send,
                      child: const Text(
                        'Gələ bilmirəm',
                        style: TextStyle(color: kRed),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
