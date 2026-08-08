import 'package:flutter_test/flutter_test.dart';

import 'support/source_text.dart';

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
    source = readCode(_service);
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

      // I9 В ЧИСТОМ ВИДЕ — и лечится он здесь НЕ соседкой. Оба сравнения
      // ниже сверяют РАВЕНСТВО счётчиков, а `0 == 0` истинно: сломайся
      // разбор (опечатка в искомой строке, переименование поля, снятые
      // кавычки), все три счёта стали бы нулями, и сторож сказал бы «пути
      // ухода сходятся», не посмотрев ни на один.
      //
      // Разница с остальными вердиктами точная: те требуют, чтобы разбор
      // ЧТО-ТО НАШЁЛ, а эти два довольны тем, что не нашли ничего. Поэтому
      // строка «нашлось хоть что-то» их не спасает — нужен нижний порог у
      // КАЖДОГО счёта по отдельности, до сравнения.
      for (final e in {
        'chatAfterDeparture(': calls,
        "'members': after.members": membersWrites,
        "'activeUsers': after.activeUsers": activeWrites,
      }.entries) {
        expect(
          e.value,
          greaterThan(0),
          reason: 'В ${_service} не найдено ни одного «${e.key}». Либо путь '
              'ухода переписан целиком, либо разбор перестал его видеть — '
              'по зелёному прогону второе неотличимо от первого (I13).',
        );
      }

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

    setUpAll(() => form = readCode(_eventForm));

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
          readCode('lib/features/chat/screens/chat_screen.dart');
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
      form = readCode(_eventForm);
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

    test('выход из чужого больше НЕ создаёт мероприятие сам', () {
      // Перестройка N51: создание ушло из этой ветки в общий путь
      // сохранения, потому что до пересчёта неизвестно, свободна ли
      // минута. Вернись `addPersonalEvent` сюда — человек снова получит
      // своё мероприятие на минуте, где у него уже стоит другое.
      // Границы куска — по КОДУ, а не по комментарию. Прежде концом
      // служил заголовок соседнего doc-комментария, и 07.08, когда
      // текстовые сторожа перешли на чтение без комментариев, этот
      // якорь исчез вместе с ними: сторож упал на чистом дереве. Тот же
      // класс, что «комментарий защищает строку»: комментарий и границей
      // быть не может — он живёт по своим законам, а не по законам кода.
      final start = form.indexOf('Future<void> _replaceEvent(');
      expect(start, isNot(-1), reason: '_replaceEvent исчез вовсе');
      final end = form.indexOf('Future<bool> _confirmLeaveForeign(', start);
      expect(end, isNot(-1),
          reason: 'сосед _confirmLeaveForeign исчез — границу куска взять '
              'неоткуда, и сторож замолчал бы, а не упал');
      final body = form.substring(start, end);
      expect(
        body.contains('addPersonalEvent('),
        isFalse,
        reason: '_replaceEvent снова создаёт мероприятие сам. Создание '
            'обязано идти общим путём сохранения, ПОСЛЕ пересчёта '
            'оставшихся конфликтов минуты (N51).',
      );
      expect(
        body.contains('leavePersonalEvent('),
        isTrue,
        reason: 'выход из чужого пропал вместе с созданием',
      );
    });

    test('сигнатуры «одно совпадение по минуте» не существует', () {
      // N51 целиком: `exactConflictAt` возвращал `PersonalEvent?`, то есть
      // одно мероприятие ПО ТИПУ, и вызывающему нечего было решать. Имя
      // убрано, чтобы третий вызывающий не появился мимо списка (I11).
      final banner =
          readCode('lib/shared/widgets/event_conflict_banner.dart');
      final sheet =
          readCode('lib/features/job_offer/screens/job_offer_date_sheet.dart');
      for (final entry in {
        'event_conflict_banner.dart': banner,
        'agreements_screen.dart': form,
        'job_offer_date_sheet.dart': sheet,
      }.entries) {
        expect(
          RegExp(r'exactConflictAt\s*\(').hasMatch(entry.value),
          isFalse,
          reason: '${entry.key}: вернулась функция, отдающая ОДНО '
              'совпадение по минуте. На минуту может встать сколько угодно '
              'мероприятий, и спрятанным окажется чужое (N51).',
        );
      }
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

  group('карточка договора называет людей по uid, а не по partnerName (N53)', () {
    late String form;

    setUpAll(() => form = readCode(_eventForm));

    test('строки сторон берут имя через nameOf, а не из документа', () {
      // `partnerName` — имя второй стороны ГЛАЗАМИ ВЛАДЕЛЬЦА. На экране
      // получателя это его собственное имя, и карточка называла его
      // отправителем договора и тем, кто отменил. Имени владельца в
      // документе нет вовсе, поэтому единственный честный источник —
      // список пользователей по uid.
      // Комментарии выкидываем: правило про КОД, а разбор дефекта живёт
      // рядом с ним словами и содержит те же строки.
      final code = form
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      final rows = RegExp(r'_PartyRow\(\s*\n\s*name:\s*([^,]+),')
          .allMatches(code)
          .map((m) => m.group(1)!.trim())
          .toList();
      expect(rows, isNotEmpty, reason: 'строки сторон не найдены вовсе');
      for (final r in rows) {
        // Правило не про имя функции, а про ИСТОЧНИК: имя стороны берётся
        // по её uid (`nameOf` или `_findUser`), и никогда — из
        // `partnerName`, потому что это поле означает «вторая сторона
        // глазами владельца».
        expect(
          r.contains('partnerName'),
          isFalse,
          reason: 'Сторона названа через partnerName: «$r». На экране '
              'получателя это его собственное имя, и карточка объявит его '
              'отправителем чужого договора (N53).',
        );
        expect(
          r.contains('nameOf(') || r.contains('_findUser('),
          isTrue,
          reason: 'Имя стороны «$r» взято не по uid. Единственный честный '
              'источник — список пользователей (N53).',
        );
      }
    });

    test('partnerName читается ровно в двух местах — запасных', () {
      // Сплошной счёт вместо перечисления мест: 07.08 проход по чтениям
      // нашёл шесть, седьмое нашёл владелец снимком со второго телефона,
      // а следом обнаружились ещё три. Перечисление устаревает при первой
      // же новой строке; число — нет.
      //
      // Разрешены ровно два: запасной путь в `nameOf` карточки договора и
      // такой же в `_nameOfParty` списка. Оба стоят под условием «uid и
      // есть partnerUid», то есть называют того, чьё это имя.
      final code = form
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      final uses = 'partnerName'.allMatches(code).length;
      expect(
        uses,
        2,
        reason: 'partnerName читается $uses раз(а) вместо двух запасных. '
            'Поле значит «вторая сторона глазами ВЛАДЕЛЬЦА»: у получателя '
            'это его собственное имя, и экран назовёт им кого угодно '
            '(N53). Имя берётся по uid.',
      );
    });

    test('слова «imtina etdi» на карточке договора не осталось', () {
      // Отказа как ИСХОДА не существует: `declinesCancelRequest` очищает
      // поля запроса и оставляет договор в силе. Слово переехало сюда из
      // чатового раунда, где отказ действительно исход, и называло
      // согласие отказом (N54).
      final code = form
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      expect(
        code.contains('imtina etdi'),
        isFalse,
        reason: 'На карточке договора снова «imtina etdi». Отменённый по '
            'согласию договор — не отказ: один предложил, второй '
            'согласился (N54).',
      );
    });
  });

  group('кружок на сетке считает общим правилом, а не своим (N74)', () {
    // Единственная проверка, которая ЛОВИТ возврат дефекта. Парный тест в
    // `day_buckets_test` сравнивает `eventsOfDay` с `buildDayBuckets` — но
    // они обе зовут `liveEvents`, то есть сойтись обязаны по построению и
    // провалиться не могут (I9). Провалиться может ВОТ ЭТО: экран,
    // сосчитавший день сам.
    late String screen;
    setUpAll(() => screen = readCode(_eventForm));

    test('сетка зовёт eventsOfDay', () {
      // Со скобкой — вызов, а не упоминание: имя пришло бы и одним
      // импортом (N71).
      expect(
        screen.contains('eventsOfDay('),
        isTrue,
        reason: 'Сетка месяца перестала звать общее правило. Свой счёт не '
            'знает ни про отменённые, ни про повторы: 07.08 это дало «4» '
            'на числе и три строки под ним, на одном экране (N74).',
      );
    });

    test('внутри сетки своего списка «мои плюс участник» нет', () {
      // СТОГ — ТЕЛО ОДНОЙ ФУНКЦИИ, а не весь файл, и это не сужение ради
      // зелени. В том же файле есть ещё ТРИ таких сшивки — они кормят
      // форму мероприятия и проверку конфликтов (`allCombinedEvents`).
      // Тот же ли это дефект — НЕ ПРОВЕРЕНО: считать ли отменённое занятым
      // временем, вопрос отдельный, и решать его вслепую нельзя. Записано
      // подозрением в N74; сторож сторожит ровно то, что доказано.
      const marker = 'Widget _buildCalendarGridForMonth(';
      final from = screen.indexOf(marker);
      expect(from, isNot(-1),
          reason: 'функция сетки переименована — сторож смотрит в пустоту');
      final rest = screen.indexOf('\n  Widget ', from + marker.length);
      final body = screen.substring(from, rest == -1 ? screen.length : rest);

      // I13: соседка к вырезке. Пустое тело дало бы ноль совпадений и
      // зелёный вердикт, ничего не проверив.
      expect(body.length, greaterThan(200),
          reason: 'тело сетки вырезано пустым (${body.length} символов)');

      final own = RegExp(
        r'\[\s*\.\.\.personalEvents\s*,\s*\.\.\.eventsAsParticipant',
      ).allMatches(body).length;
      expect(
        own,
        0,
        reason: 'Сетка снова сшивает оба списка сама — $own раз(а). Отсюда и '
            'взялся N74: длина такого списка не равна числу мероприятий '
            'дня. Считать через eventsOfDay.',
      );
    });

    test('правило, которое здесь сторожится, вообще существует', () {
      // I13: обе проверки выше — «плохого не нашлось» и «имя нашлось».
      // Если файл правила переименуют, первая станет красной, а вот
      // вторая молча позеленеет на пустоте. Поэтому спрашиваем прямо.
      final rule = readCode('lib/core/agreements/day_buckets.dart');
      expect(rule.contains('List<PersonalEvent> eventsOfDay('), isTrue,
          reason: 'eventsOfDay больше не объявлена в day_buckets.dart — '
              'сторож выше сторожит имя, которого нет');
      expect(rule.contains('List<PersonalEvent> liveEvents('), isTrue,
          reason: 'liveEvents больше не объявлена — правило «без отменённых '
              'и без повторов» снова разъехалось по экранам');
    });
  });

  group('строка чата зовёт общее правило, а не считает сама (N76)', () {
    const _chats = 'lib/features/chats/screens/chats_screen.dart';
    late String screen;
    setUpAll(() => screen = readCode(_chats));

    test('экран зовёт chatPreview', () {
      // Со скобкой — вызов, а не упоминание: имя пришло бы и одним
      // импортом (N71), что доказано на живом случае с chatsProvider.
      expect(
        screen.contains('chatPreview('),
        isTrue,
        reason: 'Список чатов перестал звать общее правило второй строки. '
            'Своё вычисление не знает ни про системные записи, ни про '
            '«Siz», ни про очищенный чат (N76).',
      );
    });

    test('экран не решает сам, что показать вместо текста', () {
      // Три состояния второй строки — очищено, удалено у себя, обычное —
      // жили ветвлениями прямо в build(). Там их не проверить возвратом,
      // поэтому они уехали в chatPreview целиком. Возврат любой ветки
      // обратно на экран роняет этот тест.
      final own = <String>[];
      for (final form in [
        "lastMessageDeletedFor.contains(",
        "Bu mesajı sildiniz",
        "clearedBy[currentUid]",
      ]) {
        if (screen.contains(form)) own.add(form);
      }
      expect(
        own,
        isEmpty,
        reason: 'Экран снова решает содержимое второй строки сам: '
            '${own.join(", ")}. Правило целиком живёт в chatPreview — '
            'и «удалил у себя», и очищенный чат, и признак cleared, по '
            'которому прячется время.',
      );
    });

    test('правило, которое здесь сторожится, существует', () {
      // I13: обе проверки выше — «нашлось имя» и «плохого не нашлось».
      // Переименуй файл правила, и вторая молча позеленеет на пустоте.
      final rule = readCode('lib/core/chat/chat_preview.dart');
      expect(rule.contains('ChatPreview chatPreview('), isTrue,
          reason: 'chatPreview больше не объявлена — сторож выше сторожит '
              'имя, которого нет');
      // Не `contains('lastMessageIsSystem')` — это голое имя, и оно есть
      // в файле от одного объявления поля. Мета-сторож справедливо на
      // такое встаёт. Проверяется ВЕТКА целиком.
      expect(rule.contains('if (chat.lastMessageIsSystem) return null;'),
          isTrue,
          reason: 'правило перестало различать системную запись, а у неё '
              'отправитель настоящий — вернётся имя дважды');
    });
  });
}
