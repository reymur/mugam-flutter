import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/firebase/models.dart';
import 'package:mugam_flutter/shared/widgets/event_conflict_banner.dart';

// N38 — состав при СМЕНЕ набора конфликтов, то есть когда человек крутит
// колесо.
//
// Наблюдалось дважды, 04.08 и 06.08, обоими прогонами на устройстве: в
// форме нового мероприятия человек прокручивал дату через день, где
// мероприятие стоит минута в минуту, состав того дня подмешивался, а при
// возврате на прежнюю дату — оставался. Люди при этом выглядят ровно как
// поставленные руками и сохраняются в мероприятие вместе с ним: 05.08 так
// в чужие календари попали двое, которых никто не звал.
//
// Снятие подмешанного было ровно в одном месте — ответе «Yeni tədbir», — а
// смену даты не отслеживало ничто.

const me = 'me-uid';
const teymur = 'teymur';
const ramil = 'ramil';
const sevgi = 'sevgi';

PersonalEvent ev({
  String id = 'e1',
  String owner = teymur,
  List<String> people = const [ramil],
}) =>
    PersonalEvent(
      id: id,
      ownerUid: owner,
      date: '2026-08-09T12:00:00.000',
      type: 'Toy',
      location: '',
      notes: '',
      participantUids: people,
      isAgree: false,
    );

void main() {
  group('прокрутил через занятый день и вернулся', () {
    test('подмешанные уходят вместе с конфликтом, из которого пришли', () {
      // Главный тест находки. Состояние — то самое, что было на экране
      // 06.08: в участниках Теймур (от конфликта 8 августа) и Ramil (от
      // конфликта 9 августа), а конфликта девятого больше нет.
      final change = participantsAfterConflictChange(
        current: const [teymur, ramil],
        merged: {teymur, ramil},
        conflicts: const [],
        explicitlyRemoved: const {},
        currentUid: me,
        isEditing: false,
      );
      expect(change.participants, isEmpty);
      expect(change.merged, isEmpty);
    });

    test('выбранный руками при смене даты не пропадает', () {
      // Обратная половина: снимать надо РОВНО подмешанных. Правило
      // «чистить состав на смену даты» прошло бы тест выше и молча
      // выбрасывало бы людей, позванных человеком.
      final change = participantsAfterConflictChange(
        current: const [sevgi, ramil],
        merged: {ramil},
        conflicts: const [],
        explicitlyRemoved: const {},
        currentUid: me,
        isEditing: false,
      );
      expect(change.participants, [sevgi]);
      expect(change.merged, isEmpty);
    });
  });

  group('новый конфликт подмешивается тем же правилом', () {
    test('состав нового конфликта приходит, прежнего — уходит', () {
      // Смена одного занятого дня на другой: в списке обязан оказаться
      // состав нового мероприятия и только он.
      final change = participantsAfterConflictChange(
        current: const [sevgi, ramil],
        merged: {ramil},
        conflicts: [ev(owner: teymur, people: const [])],
        explicitlyRemoved: const {},
        currentUid: me,
        isEditing: false,
      );
      expect(change.participants, [sevgi, teymur]);
      expect(change.merged, {teymur});
    });

    test('отметка «подмешан» обновляется, а не копится', () {
      // Забыть обновить merged — значит оставить в нём людей прошлого
      // конфликта: следующее снятие промахнётся мимо новых, и дефект
      // вернётся на ход позже.
      final change = participantsAfterConflictChange(
        current: const [ramil],
        merged: {ramil},
        conflicts: [ev(owner: teymur, people: const [])],
        explicitlyRemoved: const {},
        currentUid: me,
        isEditing: false,
      );
      expect(change.merged, {teymur});
      expect(change.merged.contains(ramil), isFalse);
    });

    test('убранного руками новый конфликт не возвращает', () {
      final change = participantsAfterConflictChange(
        current: const [],
        merged: const {},
        conflicts: [ev(owner: teymur, people: const [ramil])],
        explicitlyRemoved: const {ramil},
        currentUid: me,
        isEditing: false,
      );
      expect(change.participants, [teymur]);
    });

    test('при нескольких конфликтах не подмешивается никто', () {
      // Правило переноса выводилось для «конфликт один»: какое из
      // нескольких человек имел в виду, скажет переключатель.
      final change = participantsAfterConflictChange(
        current: const [ramil],
        merged: {ramil},
        conflicts: [ev(id: 'a'), ev(id: 'b')],
        explicitlyRemoved: const {},
        currentUid: me,
        isEditing: false,
      );
      expect(change.participants, isEmpty);
      expect(change.merged, isEmpty);
    });

    test('при правке существующего не подмешивается вообще ничего', () {
      final change = participantsAfterConflictChange(
        current: const [sevgi],
        merged: const {},
        conflicts: [ev()],
        explicitlyRemoved: const {},
        currentUid: me,
        isEditing: true,
      );
      expect(change.participants, [sevgi]);
    });
  });
}
