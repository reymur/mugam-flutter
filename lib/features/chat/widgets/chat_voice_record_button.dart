import 'package:flutter/material.dart';

import '../../../core/theme/colors.dart';
import '../../../shared/widgets/voice_hold_recorder.dart';

// ---------------------------------------------------------------------------
// ПРАВАЯ КНОПКА СТРОКИ ВВОДА ЧАТА ДЛЯ ГОЛОСОВОГО (13.09, вариант Б, шаг 3)
// ---------------------------------------------------------------------------
// Запись — общая с листом выхода (`lib/shared/widgets/voice_hold_recorder.dart`).
// Здесь то, что в строке ввода принадлежит ЧАТУ: при замке на месте микрофона
// стоит «отправить» — остановить запись и отдать её хвосту чата, то есть в
// очередь отправки сообщением. У листа выхода на этом месте своя кнопка
// («остановить», запись встаёт строкой), и склеивать их нельзя (I58).
//
// Вынесена из `chat_screen.dart` в свой файл ради одного: чтобы место вызова
// «чат» поднималось тестом. Разметку строки ввода внутри экрана чата тест не
// поднимет — экран тянет Firestore. Порча общей записи обязана ронять и этот
// тест (`test/chat_voice_record_button_test.dart`), а не только общий.

class ChatVoiceRecordButton extends StatelessWidget {
  const ChatVoiceRecordButton({
    super.key,
    required this.controller,
    required this.uploading,
  });

  final VoiceHoldController controller;

  /// Голосовое уходит в очередь отправки — крутилка на кнопке, как было.
  final bool uploading;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (!controller.isLocked) {
          return VoiceHoldMicButton(controller: controller, busy: uploading);
        }
        return GestureDetector(
          onTap: controller.stop,
          child: Container(
            width: 44,
            height: 44,
            decoration: const BoxDecoration(
              color: kGold,
              shape: BoxShape.circle,
            ),
            child: uploading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: kOnGold,
                    ),
                  )
                : const Icon(Icons.send, color: kOnGold, size: 20),
          ),
        );
      },
    );
  }
}
