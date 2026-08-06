import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/shared/widgets/event_conflict_banner.dart';

// N47 — что создаётся при выходе из ЧУЖОГО мероприятия.
//
// Наблюдалось 06.08 на устройстве. Рафаэль заводил своё мероприятие на
// время, занятое мероприятием Теймура, и ответил «Təqvimimdən sil».
// Ожидаемое сработало: из участников Теймура он вышел, мероприятие
// Теймура осталось живо. Сверх этого записалось три вещи, которых никто
// не просил: в новое мероприятие попали владелец покинутого и второй его
// участник, `replacedEventId` указал на чужой ЖИВОЙ документ, а
// `lastActionType` стал `replaced` — отчего обоим ушло «Tədbir əvəz
// edildi», рассказ о поступке, которого не было.
//
// Три отрицания — три отдельных теста. Возврат любого одного обязан
// ронять именно свой: правка, вернувшая перенос, но не ссылку, сегодня
// прошла бы общий тест и завтра снова позвала бы чужих людей.

const me = 'rafael';
const owner = 'teymur';
const other = 'ramil';

void main() {
  group('состав — только выбранный человеком', () {
    test('подмешанные из покинутого мероприятия НЕ попадают в новое', () {
      // Ровно наблюдавшийся случай: в форме к этому моменту уже стоят
      // Теймур и Ramil — их подмешало предупреждение о конфликте, а не
      // человек.
      final plan = foreignLeaveCreation(
        current: const [owner, other],
        mergedFromConflict: {owner, other},
      );
      expect(plan.participantUids, isEmpty);
    });

    test('выбранный руками остаётся — снимаются РОВНО подмешанные', () {
      // Вторая половина, без неё правило «выбрасывать всех» прошло бы
      // первый тест и потеряло бы людей, позванных человеком.
      final plan = foreignLeaveCreation(
        current: const ['sevgi', owner, other],
        mergedFromConflict: {owner, other},
      );
      expect(plan.participantUids, ['sevgi']);
    });

    test('тот же человек, выбранный руками, подмешанным не считается', () {
      // Подмешивание не возвращает убранного, а выбор руками не делает
      // человека подмешанным: множества независимы.
      final plan = foreignLeaveCreation(
        current: const [owner],
        mergedFromConflict: const <String>{},
      );
      expect(plan.participantUids, [owner]);
    });
  });

  group('ссылка на «заменённое»', () {
    test('не пишется вовсе — заменять было нечего', () {
      // Покинутое мероприятие живо и принадлежит другому человеку.
      // Ссылка на него из своей записи — утверждение, что оно заменено.
      final plan = foreignLeaveCreation(
        current: const [],
        mergedFromConflict: const <String>{},
      );
      expect(plan.replacedEventId, isNull);
    });
  });

  group('имя поступка', () {
    test('created, а не replaced', () {
      // Проверяется отдельно от ссылки, хотя сегодня `addPersonalEvent`
      // выводит имя из неё: вернись однажды ссылка без имени или имя без
      // ссылки — участники снова услышат про замену. Два утверждения —
      // два теста.
      final plan = foreignLeaveCreation(
        current: const [],
        mergedFromConflict: const <String>{},
      );
      expect(plan.lastActionType, 'created');
      expect(plan.lastActionType, isNot('replaced'));
    });
  });
}
