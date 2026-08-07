import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/agreements/agreement_cancel.dart';

// N45, вторая половина — почему отказано.
//
// До 07.08 экран объяснял ЛЮБОЙ `permission-denied` гонкой сторон: «вас
// опередили». Пока правила отмены не были выложены, та же ветка ловила
// отсутствие правила и рассказывала про него неправду — молча, потому что
// гонка в Crashlytics не сообщается по замыслу.
//
// Сама ошибка причин не различает и не будет: Firestore не называет ни
// правила, ни условия. Различимо состояние — и правило ниже задаёт ему
// один вопрос: объясняет ли оно отказ.
//
// Тесты идут ПО ХОДАМ: у каждого своё «объясняющее» состояние, и спутать
// их нельзя — отзыв объясняется не тем же, чем подтверждение.

const me = 'me-uid';
const other = 'other-uid';

CancelDenial verdict(
  String deed, {
  String status = 'agreed',
  String? requestedBy,
}) =>
    explainCancelDenial(
      deed: deed,
      status: status,
      cancelRequestedBy: requestedBy,
      currentUid: me,
    );

void main() {
  group('отменённый договор объясняет отказ любому ходу', () {
    // Самая частая гонка: вторая сторона подтвердила отмену, пока человек
    // читал экран. Правила запрещают при `cancelled` вообще всё.
    for (final deed in [
      kCancelRequested,
      kCancelConfirmed,
      kCancelWithdrawn,
      kCancelDeclined,
    ]) {
      test('ход $deed', () {
        expect(verdict(deed, status: 'cancelled'), CancelDenial.race);
      });
    }
  });

  group('просил отмену', () {
    test('запрос уже стоит — гонка', () {
      expect(verdict(kCancelRequested, requestedBy: other), CancelDenial.race);
    });

    test('запроса нет, а отказали — причина НЕ в гонке', () {
      // Ровно тот случай, что жил в проде: правила не выложены, поле
      // пустое, отказ настоящий, а экран говорил «вас опередили».
      expect(verdict(kCancelRequested), CancelDenial.unknown);
    });
  });

  group('подтверждал чужой запрос', () {
    test('запрос отозван — гонка', () {
      expect(verdict(kCancelConfirmed), CancelDenial.race);
    });

    test('запрос оказался моим — тоже гонка', () {
      // Второй отозвал, я успел запросить сам: подтверждать собственный
      // запрос правила не дают, и это законный исход.
      expect(verdict(kCancelConfirmed, requestedBy: me), CancelDenial.race);
    });

    test('чужой запрос на месте, а отказали — НЕ гонка', () {
      expect(
        verdict(kCancelConfirmed, requestedBy: other),
        CancelDenial.unknown,
      );
    });
  });

  group('отклонял чужой запрос', () {
    test('запрос отозван — гонка', () {
      expect(verdict(kCancelDeclined), CancelDenial.race);
    });

    test('чужой запрос на месте, а отказали — НЕ гонка', () {
      expect(
        verdict(kCancelDeclined, requestedBy: other),
        CancelDenial.unknown,
      );
    });
  });

  group('отзывал свой запрос', () {
    test('запрос больше не мой — гонка', () {
      expect(verdict(kCancelWithdrawn, requestedBy: other), CancelDenial.race);
      expect(verdict(kCancelWithdrawn), CancelDenial.race);
    });

    test('мой запрос на месте, а отказали — НЕ гонка', () {
      expect(verdict(kCancelWithdrawn, requestedBy: me), CancelDenial.unknown);
    });
  });

  group('ходы не путаются между собой', () {
    test('одно состояние даёт РАЗНЫЕ ответы разным ходам', () {
      // Стоящий чужой запрос: для «просил» это гонка (опередили), для
      // «подтверждал» — нет, подтверждать было что. Правило, отвечающее
      // одинаково всем, прошло бы половину тестов выше.
      expect(verdict(kCancelRequested, requestedBy: other), CancelDenial.race);
      expect(
        verdict(kCancelConfirmed, requestedBy: other),
        CancelDenial.unknown,
      );
    });
  });

  group('граница названа вслух и не «улучшается»', () {
    test('разрешившаяся гонка попадает в неизвестный отказ', () {
      // Второй отозвал своё, пока мы получали отказ: состояние уже не
      // объясняет ничего. Ошибка в БЕЗОПАСНУЮ сторону — осторожные слова
      // и запись в Crashlytics вместо уверенной неправды. Обратный
      // размен возвращает исходный дефект.
      expect(verdict(kCancelConfirmed, requestedBy: other),
          CancelDenial.unknown);
    });

    test('неизвестный ход не выдаётся за гонку', () {
      expect(verdict('что-то новое'), CancelDenial.unknown);
    });
  });
}
