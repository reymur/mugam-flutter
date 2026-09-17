import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/agreements/event_answers.dart';
import 'package:mugam_flutter/core/agreements/lineup.dart';
import 'package:mugam_flutter/core/agreements/party_rows.dart';
import 'package:mugam_flutter/firebase/models.dart';

// ОДИН ЧЕЛОВЕК — ОДНА СТРОКА (решение владельца 17.09, вариант Б).
//
// ВТОРАЯ ПОЛОВИНА СТОРОЖА. Первая живёт в `source_invariants_test.dart` и
// сторожит «второй список»: строку участника рисует ровно одно место. Здесь
// сторожится «uid дважды»: одно и то же имя не может выйти из правила двумя
// строками, сколько бы источников в него ни пришло.
//
// ПОВОД — ЖИВОЙ ДЕФЕКТ 17.09, найденный глазами на трубке. Вечер
// `qrqTFjiZ8sP5F09eoXAU`: Теймур был и в составе, и в шаблоне, и вышел на
// экран двумя строками с одним и тем же «gəlir». Ни один сторож этого не
// поймал: разделы были непересекающимися по свойству ДАННЫХ, а не по правилу,
// и свойство ушло вместе с отдельными документами.
//
// СОБЫТИЕ СТРОИТСЯ ЧЕРЕЗ `fromFirestore`: карта ответов у модели закрыта, и
// это тот же путь, которым документ приходит в проде (I55).

const owner = 'rafael';
const guest = 'teymur';
const other = 'said';

PersonalEvent event({
  List<String> musicians = const [],
  Map<String, String> answers = const {},
  String ownerUid = owner,
}) =>
    PersonalEvent.fromFirestore('e', {
      'ownerUid': ownerUid,
      'date': '2026-09-18T19:00:00.000',
      'musicians': musicians,
      'answers': answers,
      'answersWrittenByOwner': true,
      'status': 'agreed',
    });

void main() {
  group('ОДИН UID — ОДНА СТРОКА', () {
    test('человек И в составе, И в записи о непозванных — строка ОДНА', () {
      // ЭТОТ ВЕРДИКТ И ЕСТЬ ДЕФЕКТ 17.09, записанный проверкой. До сведения
      // списков такое состояние было невозможно в данных, и потому его никто
      // не проверял; теперь оно возможно, и ответ обязан быть один.
      //
      // ЧЕМ ОН НА САМОМ ДЕЛЕ ДЕРЖИТСЯ — ПОКАЗАЛА ПОРЧА, И ЭТО СТОИТ ЗНАТЬ.
      // Имя вердикта обещает «отсев двойников», а слот здесь `invited: true`,
      // и его отсекает ФИЛЬТР `invited` РАНЬШЕ отсева. Сняв отсев, этот
      // вердикт не уронишь; сняв фильтр — уронишь соседа «СНЯТЫЙ — НЕ СТРОКА».
      // Отсев двойников стережёт вердикт НИЖЕ, где слот `invited: false`.
      // Записано затем, чтобы следующий не счёл два вердикта повторами.
      final rows = partyRows(
        event: event(musicians: const [guest], answers: const {guest: kAnswerGoing}),
        notInvited: const [
          LineupSlot(uid: guest, name: 'Teymur', invited: true),
        ],
        viewerUid: owner,
      );
      expect(rows.length, 1,
          reason: 'Человек, попавший в оба источника, вышел двумя строками — '
              'это дефект 17.09 дословно');
      expect(rows.single.uid, guest);
      expect(rows.single.kind, PartyRowKind.member);
      expect(rows.single.answer, kAnswerGoing);
    });

    test('и то же самое, когда запись говорит «НЕ позван»', () {
      // Отдельным вердиктом, а не тем же: путь в правиле другой — слот с
      // `invited: false` до отсева доходит, а с `invited: true` отсекается
      // раньше. Совпадение ответа не доказывает, что проверены оба пути.
      final rows = partyRows(
        event: event(musicians: const [guest], answers: const {guest: kAnswerWaiting}),
        notInvited: const [
          LineupSlot(
            uid: guest,
            name: 'Teymur',
            invited: false,
            reason: kNotInvitedOpenRound,
          ),
        ],
        viewerUid: owner,
      );
      expect(rows.length, 1);
      // В СОСТАВЕ СИЛЬНЕЕ ЗАПИСИ О НЕПОЗВАННОМ. Он в вечере — значит позван,
      // что бы ни говорил след прошлой отправки.
      expect(rows.single.kind, PartyRowKind.member);
      expect(rows.single.answer, kAnswerWaiting);
      expect(rows.single.reason, isNull);
    });

    test('один и тот же uid дважды В САМОМ СОСТАВЕ — строка одна', () {
      // Двойника в `musicians` не должно быть никогда, но поле пишет не только
      // наш клиент (I49), и падать на показе нельзя.
      final rows = partyRows(
        event: event(musicians: const [guest, guest], answers: const {guest: kAnswerGoing}),
        notInvited: const [],
        viewerUid: owner,
      );
      expect(rows.length, 1);
    });

    test('один и тот же uid дважды в записях о непозванных — строка одна', () {
      final rows = partyRows(
        event: event(),
        notInvited: const [
          LineupSlot(uid: guest, name: 'T', invited: false, reason: kNotInvitedOpenRound),
          LineupSlot(uid: guest, name: 'T', invited: false, reason: kNotInvitedFailed),
        ],
        viewerUid: owner,
      );
      expect(rows.length, 1);
      // Первая запись старше: у слотов порядок отметки, и второй — поздняя
      // порча либо правка руками.
      expect(rows.single.reason, kNotInvitedOpenRound);
    });

    test('КАНАРЕЙКА: двое РАЗНЫХ дают две строки', () {
      // Без неё «строка одна» выполнялось бы схлопыванием всех в одну, и все
      // вердикты выше были бы зелены на правиле, которое не показывает никого.
      final rows = partyRows(
        event: event(
          musicians: const [guest, other],
          answers: const {guest: kAnswerGoing, other: kAnswerWaiting},
        ),
        notInvited: const [],
        viewerUid: owner,
      );
      expect(rows.length, 2);
      expect([for (final r in rows) r.uid], [guest, other]);
    });
  });

  group('что показывает каждая строка', () {
    test('позван и ответил', () {
      final rows = partyRows(
        event: event(musicians: const [guest], answers: const {guest: kAnswerGoing}),
        notInvited: const [],
        viewerUid: owner,
      );
      expect(rows.single.kind, PartyRowKind.member);
      expect(rows.single.answer, kAnswerGoing);
      expect(rows.single.reason, isNull);
    });

    test('позван и молчит', () {
      final rows = partyRows(
        event: event(musicians: const [guest], answers: const {guest: kAnswerWaiting}),
        notInvited: const [],
        viewerUid: owner,
      );
      expect(rows.single.answer, kAnswerWaiting);
    });

    test('ВЫШЕЛ — остаётся строкой состава, и ответ его виден', () {
      // Он в составе, и ответ `left` — самое сильное «нет», какое участник
      // может сказать. Спрятать его значило бы стереть его ход.
      final rows = partyRows(
        event: event(musicians: const [guest], answers: const {guest: kAnswerLeft}),
        notInvited: const [],
        viewerUid: owner,
      );
      expect(rows.single.kind, PartyRowKind.member);
      expect(rows.single.answer, kAnswerLeft);
    });

    test('НЕ ПОЗВАН — причина вместо ответа, и снимок имени при нём', () {
      final rows = partyRows(
        event: event(),
        notInvited: const [
          LineupSlot(
            uid: other,
            name: 'Səid Oruc',
            invited: false,
            reason: kNotInvitedOpenRound,
          ),
        ],
        viewerUid: owner,
      );
      expect(rows.single.kind, PartyRowKind.notInvited);
      expect(rows.single.reason, kNotInvitedOpenRound);
      expect(rows.single.snapshotName, 'Səid Oruc');
      // Ответа у него НЕТ вовсе: вопроса не задавали. `notAsked` сюда писать
      // нельзя — он означает отсутствие ключа, а не ответ.
      expect(rows.single.answer, isNull);
    });

    test('СНЯТЫЙ — НЕ СТРОКА (решение владельца 17.09)', () {
      // Слот говорит «звали, и ушло», а в составе человека нет — значит его
      // убрали. Убранного в вечере нет, и строки у него нет тоже.
      final rows = partyRows(
        event: event(musicians: const [guest], answers: const {guest: kAnswerGoing}),
        notInvited: const [
          LineupSlot(uid: other, name: 'Səid', invited: true),
        ],
        viewerUid: owner,
      );
      expect(rows.length, 1);
      expect(rows.single.uid, guest);
    });
  });

  group('порядок и кому что видно', () {
    test('состав в своём порядке, непозванные — В КОНЕЦ', () {
      // Первые идут на вечер, вторые нет. Мешать их значит заставлять читателя
      // разбирать каждую строку.
      final rows = partyRows(
        event: event(
          musicians: const [other, guest],
          answers: const {other: kAnswerGoing, guest: kAnswerWaiting},
        ),
        notInvited: const [
          LineupSlot(uid: 'enver', name: 'Ənvər', invited: false, reason: kNotInvitedOpenRound),
        ],
        viewerUid: owner,
      );
      expect([for (final r in rows) r.uid], [other, guest, 'enver']);
      expect(rows.last.kind, PartyRowKind.notInvited);
    });

    test('НЕПОЗВАННЫХ ВИДИТ ТОЛЬКО ВЛАДЕЛЕЦ', () {
      // «Кому не ушло» — сведения хозяина вечера о его собственной отправке.
      // Участнику они ничего не говорят, а человека, которого не звали,
      // называют перед посторонними.
      final rows = partyRows(
        event: event(musicians: const [guest], answers: const {guest: kAnswerGoing}),
        notInvited: const [
          LineupSlot(uid: other, name: 'Səid', invited: false, reason: kNotInvitedOpenRound),
        ],
        viewerUid: guest,
      );
      expect(rows.length, 1);
      expect(rows.single.uid, guest);
    });

    test('ПУСТОЙ смотрящий тоже не видит непозванных', () {
      // Пустой uid означает не «владелец», а «неизвестно, кто смотрит», то
      // есть поломку вызывающего. Сторона выбрана так, чтобы промах не
      // раскрывал чужие сведения.
      final rows = partyRows(
        event: event(musicians: const [guest], answers: const {guest: kAnswerGoing}),
        notInvited: const [
          LineupSlot(uid: other, name: 'Səid', invited: false, reason: kNotInvitedOpenRound),
        ],
        viewerUid: '',
      );
      expect(rows.length, 1);
    });

    test('КАНАРЕЙКА к трём вердиктам выше: владельцу непозванный ВИДЕН', () {
      // Три отрицания подряд зазеленели бы разом, ослепни правило до пустого
      // списка непозванных (I31).
      final rows = partyRows(
        event: event(musicians: const [guest], answers: const {guest: kAnswerGoing}),
        notInvited: const [
          LineupSlot(uid: other, name: 'Səid', invited: false, reason: kNotInvitedOpenRound),
        ],
        viewerUid: owner,
      );
      expect(rows.length, 2);
      expect(rows.last.kind, PartyRowKind.notInvited);
    });

    test('пусто и там и там — ни одной строки', () {
      expect(partyRows(event: event(), notInvited: const [], viewerUid: owner), isEmpty);
    });
  });
}
