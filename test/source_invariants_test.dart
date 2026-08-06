import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Проход по исходникам — третье средство из разбора «комментарий защищает
// строку, а не класс» (AUDIT_TODO.md). Оно ловит ровно то, чего не ловят
// ни тип, ни обычный тест: ДОПИСЫВАНИЕ нового кода мимо правила. Тот, кто
// заводит третий путь удаления участника, в `chat_departure.dart` не
// смотрит и комментария там не увидит — увидит красный тест.
//
// Здесь же место будущему проходу по цепочкам `.where(` (запрет «форма
// запроса обязана доказывать правило чтения», тот же разбор).

const _service = 'lib/firebase/firestore_service.dart';
const _eventForm = 'lib/features/agreements/screens/agreements_screen.dart';

void main() {
  late List<String> lines;
  late String source;

  setUpAll(() {
    source = File(_service).readAsStringSync();
    lines = source.split('\n');
  });

  group('удаление участника идёт только через chatAfterDeparture', () {
    test('никто не вычёркивает uid из members через arrayRemove', () {
      // Сокращение `members` — это и есть уход из чата, а уход обязан
      // снимать вместе с членством и отметку присутствия. `arrayRemove`
      // по этому полю снимает членство В ОБХОД правила и молча оставляет
      // человека в `activeUsers` — ровно та дыра, что была в
      // removeGroupMember до 04.08.
      final offenders = <String>[];
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i];
        if (l.contains("'members'") && l.contains('arrayRemove')) {
          offenders.add('$_service:${i + 1}: ${l.trim()}');
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'Участник вычёркивается из members мимо chatAfterDeparture '
            '(lib/core/chat/chat_departure.dart). Считать оставшиеся списки '
            'этим правилом и записывать их целиком, вместе с activeUsers:\n'
            '${offenders.join('\n')}',
      );
    });

    test('members и activeUsers пишутся правилом ВМЕСТЕ, а не порознь', () {
      // Пара, а не два отдельных числа: путь ухода, который позовёт
      // правило и запишет из него только members, забыв activeUsers,
      // воспроизведёт исходный дефект при живом правиле.
      final calls = 'chatAfterDeparture('.allMatches(source).length;
      final membersWrites = "'members': after.members".allMatches(source).length;
      final activeWrites =
          "'activeUsers': after.activeUsers".allMatches(source).length;

      expect(
        membersWrites,
        activeWrites,
        reason: 'Путь ухода пишет members и activeUsers порознь: '
            'members $membersWrites раз, activeUsers $activeWrites раз. '
            'Отметка присутствия обязана уходить вместе с членством.',
      );
      expect(
        calls,
        membersWrites,
        reason: 'Вызовов chatAfterDeparture $calls, а записей его результата '
            '$membersWrites. Либо правило зовут и не используют, либо путь '
            'ухода дописан мимо него.',
      );
    });
  });

  group('снятие участника мероприятия идёт одной записью', () {
    late String form;

    setUpAll(() => form = File(_eventForm).readAsStringSync());

    test('состав не сокращают мимо _applyParticipantSelection', () {
      // Тот же класс, что и уход из чата: два пути к одной операции —
      // диалог выбора и крестик на фишке. `_explicitlyRemoved` без
      // серверного правила за спиной, поэтому путь, сокративший состав
      // сам, не даёт некрасивого отказа — он молча даёт НЕВЕРНЫЙ исход:
      // перенос из конфликта возвращает человека обратно (N35).
      const forbidden = [
        '_selectedParticipantUids.remove(',
        '_selectedParticipantUids.removeWhere(',
        '_selectedParticipantUids.clear(',
      ];
      final offenders = <String>[];
      final formLines = form.split('\n');
      for (var i = 0; i < formLines.length; i++) {
        for (final f in forbidden) {
          if (formLines[i].contains(f)) {
            offenders.add('$_eventForm:${i + 1}: ${formLines[i].trim()}');
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'Состав участников сокращают мимо _applyParticipantSelection '
            '— путь уберёт человека, но не запомнит, что его убрали руками, '
            'и перенос из конфликтующего мероприятия вернёт его обратно '
            '(N35):\n${offenders.join('\n')}',
      );
    });

    test('_explicitlyRemoved пополняется ровно в одном месте', () {
      // Признак «убрал руками» ставит та же запись, что меняет состав.
      // Разойдись они — появится путь, который состав сократил, а признак
      // не поставил, и это ровно исходный N35.
      final marks = '_explicitlyRemoved.add('.allMatches(form).length;
      expect(
        marks,
        1,
        reason: '_explicitlyRemoved пополняется $marks раз(а). Ожидается '
            'ровно одно место — _applyParticipantSelection. Новый путь '
            'снятия участника обязан идти через него, а не повторять '
            'учёт у себя.',
      );
    });
  });

  group('у операций, чей автор выводится, дорога должна быть одна', () {
    test('у правки предложения ровно ОДНА дорога', () {
      // Сервер называет автором правки предложения ИНИЦИАТОРА, и
      // подкреплено это не правилом, а тем, что кнопку «Tarix dəyiş»
      // видит только он: `firestore.rules` разрешает писать event*
      // любому участнику чата. Пока дорога одна, вывод верен; появится
      // вторая — уведомление поедет не тому и не про того, и молча.
      //
      // Поиск по вызовам, сделанный однажды, — это память, а не защита.
      // Защита — вот она: второй вызов не пройдёт мимо, и тот, кто его
      // добавит, прочтёт этот текст.
      final screen =
          File('lib/features/chat/screens/chat_screen.dart').readAsStringSync();
      final calls = 'saveChatEventDate('.allMatches(screen).length;
      expect(
        calls,
        1,
        reason: 'Вызовов saveChatEventDate: $calls. Дорога к правке '
            'предложения обязана быть одна — сервер выводит её автора из '
            'того, что она доступна только инициатору, и это ничем, кроме '
            'самой единственности, не подкреплено. Появилась вторая — '
            'либо закрыть автора правилом (приём namesOnlySelf в '
            'firestore.rules), либо писать автора в документ явно.',
      );
    });
  });

  group('выход из чужого мероприятия остаётся выходом (N47)', () {
    // Починка N47 убрала из этого хода два уведомления из трёх — оба
    // ложных. Осталось ровно одно, и оно правильное: сервер говорит
    // владельцу покинутого «İştirakçı ayrıldı», выводя это из
    // `lastActionType: 'left'`, который пишет `leavePersonalEvent`.
    //
    // Тест сторожит не текст уведомления (он закреплён своим тестом в
    // functions/test/event-notifications.test.ts — «вышел сам — узнаёт
    // ВЛАДЕЛЕЦ, и только он»), а то, что на клиенте остался сам ВЫЗОВ.
    // Мы переписали эту ветку целиком; потеряйся он при следующей правке
    // — владелец просто перестанет узнавать об уходе, и не заметит этого
    // никто: ошибки не возникнет нигде, уведомление молча не придёт.
    late String form;

    setUpAll(() {
      form = File(_eventForm).readAsStringSync();
    });

    test('вызов leavePersonalEvent из формы не потерян', () {
      expect(
        'leavePersonalEvent('.allMatches(form).length,
        1,
        reason: 'Ветка «Təqvimimdən sil» обязана звать leavePersonalEvent: '
            'без него человек остаётся в чужом мероприятии, а владелец не '
            'получает «İştirakçı ayrıldı» — единственное уведомление, '
            'которое этот ход теперь порождает.',
      );
    });

    test('выход идёт ПЕРЕД созданием своего', () {
      // Порядок — не стиль: откажи выход по правам, своё не создастся и
      // дублей не будет. Обратный порядок оставил бы два мероприятия при
      // первом же отказе.
      //
      // Смотрим ВНУТРИ метода, а не по всему файлу: `addPersonalEvent`
      // зовётся и обычным сохранением, и оно стоит выше. Проверка «первый
      // add в файле идёт после leave» говорила бы о другом месте — и
      // падала бы, ничего не найдя в этом.
      final start = form.indexOf('Future<void> _replaceEvent(');
      expect(start, greaterThan(-1), reason: '_replaceEvent не найден');
      final end = form.indexOf('\n  /// Подтверждение ВЫХОДА', start);
      expect(end, greaterThan(start), reason: 'конец _replaceEvent не найден');
      final body = form.substring(start, end);

      final leave = body.indexOf('leavePersonalEvent(');
      final add = body.indexOf('addPersonalEvent(');
      expect(leave, greaterThan(-1), reason: 'выход из чужого пропал');
      expect(add, greaterThan(-1), reason: 'создание своего пропало');
      expect(
        leave,
        lessThan(add),
        reason: 'Создание своего стоит раньше выхода из чужого. При отказе '
            'по правам человек получит два мероприятия вместо нуля.',
      );
    });

    test('replacedEventId в форме не пишется руками, а берётся из правила', () {
      // Ссылка на «заменённое» — то самое, из-за чего участники чужого
      // мероприятия услышали «Tədbir əvəz edildi» о живом мероприятии.
      // Единственный способ поставить её здесь — через план
      // `foreignLeaveCreation`, где она пуста и закреплена тестом.
      final direct = RegExp(r'replacedEventId:\s*target\.id').allMatches(form);
      expect(
        direct,
        isEmpty,
        reason: 'replacedEventId снова указывает на чужой документ. При '
            'выходе из чужого мероприятия заменять нечего — оно живо и '
            'принадлежит другому (N47).',
      );
    });
  });
}
