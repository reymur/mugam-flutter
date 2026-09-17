import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/agreements/event_status_view.dart';
import 'package:mugam_flutter/core/agreements/lineup_rows.dart';
import 'package:mugam_flutter/firebase/models.dart';

// РАССЫЛКА СОСТОЯНИЯ ПО ПРИГЛАШЕНИЯМ — то, что осталось от набора.
//
// ЗДЕСЬ БЫЛО 18 ВЕРДИКТОВ НА `lineupRows` — строки «кого я позвал», собранные
// из двух источников. Сняты 17.09 вместе с самим правилом, решением владельца
// по варианту Б: список людей на вечере ОДИН, и стережёт его теперь
// `party_rows_test.dart`.
//
// ЧТО ИЗ НИХ ПЕРЕЖИЛО СНЯТИЕ, названо поимённо, чтобы следующий не счёл
// потерянным:
//   • «позван и ответил», «позван и молчит», «НЕ позван с причиной» —
//     переехали в `party_rows_test.dart` вместе с правилом;
//   • «ПОЗВАН, А В СОСТАВЕ НЕТ — приглашение снято» — стало решением владельца
//     «снятый не строка вовсе», и вердикт там же под этим именем;
//   • «имя живое первым, запасное вторым» — снимок имени остался у
//     непозванного, вердикт переехал;
//   • «порядок шаблона» — порядок теперь у состава, и его держит вердикт
//     «состав в своём порядке, непозванные в конец».
//
// ЧЕГО НЕТ НИ ТАМ, НИ ЗДЕСЬ, и это сказано прямо (I50): вердиктов на разбор
// двух источников. Второго источника не существует, проверять нечего.

void main() {
  group('кому передаётся выбор владельца (12.09)', () {
    PersonalEvent child({
      String id = 'c',
      String parent = 'p',
      String invitee = 'guest',
      String status = 'agreed',
    }) =>
        PersonalEvent.fromFirestore(id, {
          'ownerUid': 'rafael',
          'parentEventId': parent,
          'date': '2026-09-11T20:00:00',
          'musicians': [invitee],
          'status': status,
        });

    PersonalEvent parentDoc() => PersonalEvent.fromFirestore('p', {
          'ownerUid': 'rafael',
          'date': '2026-09-11T20:00:00',
          'musicians': const <String>[],
          'status': 'agreed',
        });

    test('все приглашения этого вечера — поимённо, а не числом', () {
      final ids = invitationsFollowing('p', [
        child(id: 'c1', invitee: 'a'),
        child(id: 'c2', invitee: 'b'),
      ]);
      expect(ids, ['c1', 'c2']);
    });

    test('ОТМЕНЁННОЕ приглашение не трогается', () {
      // Снятое приглашение возвращать нечем и незачем: вопрос человеку сняли,
      // и заново он задаётся обычным приглашением, а не сменой состояния.
      final ids = invitationsFollowing('p', [
        child(id: 'c1'),
        child(id: 'c2', status: kStatusCancelled),
      ]);
      expect(ids, ['c1']);
    });

    test('ЧУЖИЕ ПРИГЛАШЕНИЯ И САМ РОДИТЕЛЬ не попадают', () {
      // Родитель пишется отдельно, первым id: попади он сюда вторым разом,
      // одна и та же запись ушла бы в пакет дважды.
      final ids = invitationsFollowing('p', [
        child(id: 'c1'),
        child(id: 'other', parent: 'p2'),
        parentDoc(),
      ]);
      expect(ids, ['c1']);
    });

    // КАНАРЕЙКА (I31): три вердикта выше утверждают ОТСУТСТВИЕ лишнего и
    // зазеленели бы разом, ослепни правило до пустого списка.
    test('КАНАРЕЙКА: правило вообще что-то находит', () {
      expect(invitationsFollowing('p', [child(id: 'c1')]), isNotEmpty);
    });
  });
}
