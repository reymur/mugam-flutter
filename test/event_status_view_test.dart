import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/agreements/event_answers.dart';
import 'package:mugam_flutter/core/agreements/event_deed_line.dart';
import 'package:mugam_flutter/core/agreements/event_status_view.dart';
import 'package:mugam_flutter/firebase/models.dart';

import 'support/source_text.dart';

// ШАГ 6 — состояние вечера на карточке. Починка N116: до неё карточка вечера
// не показывала состояние ВООБЩЕ (ноль упоминаний `event.status` против
// одиннадцати в карточке договора), и вечер «под вопросом» выглядел целым.

void main() {
  group('плашка состояния', () {
    test('в силе — «Dəqiq», и она ПОКАЗЫВАЕТСЯ, а не молчит', () {
      // Отсутствие плашки читается как «состояние неизвестно», а не «всё в
      // порядке»: пустое место не отличает целый вечер от экрана, который про
      // состояние не знает. Этим и был N116.
      final v = eventStatusView(status: kStatusAgreed);
      expect(v.label, 'Dəqiq');
      expect(v.tone, EventStatusTone.firm);
      expect(v.reason, isNull);
    });

    test('отменён — своя плашка, отдельным тоном', () {
      final v = eventStatusView(status: kStatusCancelled);
      expect(v.label, 'Ləğv edilib');
      expect(v.tone, EventStatusTone.cancelled);
    });

    test('под вопросом — свой тон, НЕ тот же, что у отмены', () {
      // Красный отдан отмене целиком (N110). Совпади тона — одно и то же
      // означало бы два разных состояния, и человек прочёл бы «под вопросом»
      // как «отменено».
      final doubt = eventStatusView(status: kStatusUnsettled);
      final cancelled = eventStatusView(status: kStatusCancelled);
      expect(doubt.tone, EventStatusTone.doubt);
      expect(doubt.tone, isNot(cancelled.tone));
      expect(doubt.label, isNot(cancelled.label));
    });

    test('неизвестное значение читается как «в силе», а не роняет экран', () {
      // Поле пишут трое (I49), и чужая строка не должна оставлять карточку
      // без состояния вовсе.
      expect(eventStatusView(status: 'нечто').tone, EventStatusTone.firm);
    });
  });

  group('повод «под вопроса» — строка под плашкой', () {
    test('ушёл участник: имя названо, когда оно известно', () {
      final v = eventStatusView(
        status: kStatusUnsettled,
        unsettledReason: kReasonMemberLeft,
        leftMemberName: 'Teymur',
      );
      expect(v.reason, 'Teymur ayrıldı');
    });

    test('имени нет — повод всё равно назван', () {
      // Кнопка «Onsuz davam edirəm» без причины на экране — действие, которого
      // человек не понимает. Имя может не доехать, повод — обязан.
      final v = eventStatusView(
        status: kStatusUnsettled,
        unsettledReason: kReasonMemberLeft,
      );
      expect(v.reason, 'İştirakçı ayrıldı');
    });

    test('исчезла работа — свой повод, другими словами', () {
      final v = eventStatusView(
        status: kStatusUnsettled,
        unsettledReason: kReasonWorkCancelled,
      );
      expect(v.reason, 'İş ləğv olundu');
      expect(
        v.reason,
        isNot(
          eventStatusView(
            status: kStatusUnsettled,
            unsettledReason: kReasonMemberLeft,
          ).reason,
        ),
      );
    });

    test('повод неизвестен — молчим, а не выдумываем причину', () {
      final v = eventStatusView(
        status: kStatusUnsettled,
        unsettledReason: 'нечто',
      );
      expect(v.reason, isNull);
      // Само состояние при этом показано: неизвестен повод, а не состояние.
      expect(v.label, 'Şübhə altında');
    });
  });

  // ВЫХОД НАВЕРХ ПОВТОРЯЕТ УСЛОВИЯ `ownerSetsStatus`, А НЕ `restoresEvent`.
  //
  // **ХОД СМЕНИЛСЯ 12.09**: возврат пишется как `agreed` + `ownerFirm`, и
  // правило сервера повода не спрашивает вовсе. Прежние вердикты требовали
  // повод из двух — они сохранены ниже снятием, а не стёрты, потому что
  // снятый молча вердикт назавтра заводят заново.
  group('выход наверх — те же условия, что в правиле ownerSetsStatus', () {
    test('владельцу, из «под вопросом» — да, при любом поводе', () {
      for (final r in <String?>[
        kReasonMemberLeft,
        kReasonWorkCancelled,
        null,
        'незнакомый',
      ]) {
        expect(
          showsRestore(isOwner: true, status: kStatusUnsettled),
          isTrue,
          reason: 'повод $r на показ выхода не влияет',
        );
      }
    });

    // ЗДЕСЬ СТОЯЛИ ДВА ВЕРДИКТА — «повод не из перечисленных — нет» и «повода
    // нет вовсе — нет». Сняты 12.09 вместе с самим перечислением.
    //
    // **Цена прежнего условия названа числом:** у вечера, который владелец
    // пометил «İş dəqiq deyil», повода НЕТ (клиенту писать его запрещено), и
    // выхода наверх у такого вечера не было ни одного. Состояние без выхода —
    // скрытая отмена (решение владельца 08.09).
    test('повода нет вовсе — ТЕПЕРЬ ДА, и это главный случай', () {
      expect(showsRestore(isOwner: true, status: kStatusUnsettled), isTrue);
    });

    test('НЕ владельцу — нет', () {
      // `ownerSetsStatus` требует `ownerUid == uid`; покажи кнопку другому — и
      // он получит отказ по правам, ничего не поняв.
      expect(showsRestore(isOwner: false, status: kStatusUnsettled), isFalse);
    });

    test('из «в силе» и из отменённого — нет', () {
      // Из отмены возврата нет ни у кого: `ownerSetsStatus` принимает только
      // `agreed` и `unsettled`, а `ownerRestoresOwnEvent` писателя не имеет.
      for (final s in [kStatusAgreed, kStatusCancelled]) {
        expect(
          showsRestore(isOwner: true, status: s),
          isFalse,
          reason: 'состояние $s выхода наверх не имеет',
        );
      }
    });

    // КАНАРЕЙКА: правило не свелось к «всегда да». Без неё вердикты выше
    // прошли бы и на функции, возвращающей `true` при любом входе (I9).
    test('КАНАРЕЙКА: правило даёт оба ответа', () {
      final all = {
        showsRestore(isOwner: true, status: kStatusUnsettled),
        showsRestore(isOwner: true, status: kStatusAgreed),
      };
      expect(all.length, 2, reason: 'правило схлопнулось в один ответ');
    });
  });

  group('надпись выхода наверх', () {
    // ГЛАВНЫЙ ВЕРДИКТ ГРУППЫ: показ и надпись не могут разойтись.
    //
    // Он утверждает НАЛИЧИЕ, значит сам себе канарейка (I31): ослепни разбор
    // — и надписи не найдётся ни одной, вердикт покраснеет.
    test('надпись есть при ЛЮБОМ поводе, включая его отсутствие', () {
      // ЗДЕСЬ СТОЯЛА ПАРА «у повода надпись НАЙДЕНА» / «где выхода нет,
      // надписи ТОЖЕ нет». Вторая половина снята 12.09 вместе с проверкой
      // повода в `showsRestore`: теперь выход есть у любого вечера под
      // вопросом, и `null` означал бы кнопку без слов.
      for (final r in <String?>[
        kReasonMemberLeft,
        kReasonWorkCancelled,
        null,
        'ownerDoubt',
        '',
      ]) {
        expect(
          restoreLabel(r),
          isNotEmpty,
          reason: 'у повода «$r» кнопка есть, а слов для неё нет',
        );
      }
    });

    // КАНАРЕЙКА К ВЕРДИКТУ ВЫШЕ: надпись не одна на всех. Без неё «слова
    // находятся всегда» прошло бы и на функции, отдающей одну строку при
    // любом поводе, — а у ушедшего участника слова СВОИ.
    test('у ушедшего участника надпись ДРУГАЯ, а не общая', () {
      expect(restoreLabel(kReasonMemberLeft), kRestoreLabelMemberLeft);
      expect(restoreLabel(null), kRestoreLabelWorkCancelled);
      expect(restoreLabel(kReasonMemberLeft),
          isNot(restoreLabel(kReasonWorkCancelled)));
    });

    test('надписи у двух поводов РАЗНЫЕ', () {
      expect(kRestoreLabelMemberLeft, isNot(kRestoreLabelWorkCancelled));
    });

    // N205 — ЛОВУШКА ПРОБЕЛА, и этот вердикт заведён из-за неё.
    //
    // По-азербайджански «всё равно» — `onsuz da`, «без него» — `onsuz`.
    // Значит «Onsuz da davam edirik» значит ровно то, что нужно второму
    // поводу, и отличается от надписи первого ОДНИМ ПРОБЕЛОМ. Две кнопки
    // разного смысла, различимые пробелом, — правило и его нарушение на
    // самом опасном расстоянии (I42): не вплотную, чтобы заметить глазом,
    // и не в разных файлах, чтобы заметить несогласием.
    //
    // Вердикт запрещает не сам пробел, а НАЧАЛО со слова `Onsuz` — потому
    // что именно оно делает две надписи неразличимыми при беглом чтении.
    test('надпись второго повода НЕ начинается со слова «Onsuz» (N205)', () {
      expect(
        kRestoreLabelWorkCancelled.startsWith('Onsuz'),
        isFalse,
        reason: 'N205: «Onsuz da davam edirik» отличается от '
            '«$kRestoreLabelMemberLeft» одним пробелом. Две кнопки разного '
            'смысла, различимые пробелом, — правило и его нарушение на самом '
            'опасном расстоянии.',
      );
      // Соседка-канарейка к вердикту выше: она проверяет ОТСУТСТВИЕ, и
      // ослепни разбор (пустая строка вместо надписи), ноль совпадений
      // читался бы как порядок. Здесь ноль означал бы «надписи нет вовсе».
      expect(kRestoreLabelWorkCancelled, isNotEmpty);
      expect(kRestoreLabelMemberLeft.startsWith('Onsuz'), isTrue,
          reason: 'канарейка: разбор `startsWith` умеет находить это слово — '
              'иначе вердикт выше был бы зелёным от слепоты');
    });
  });

  // -------------------------------------------------------------------------
  // ПРОВОДКА ВЫХОДА НАВЕРХ — работа 7, шаг 8, клиентская половина, 09.09
  // -------------------------------------------------------------------------
  // ЗАЧЕМ ЭТИ ВЕРДИКТЫ, ЕСЛИ ПРАВИЛО УЖЕ ПОКРЫТО ВЫШЕ. Правило было покрыто и
  // зелено с 08.09 — и всё это время НЕДОСТИЖИМО: модель не читала
  // `unsettledReason`, подать повод было нечем, а экран `showsRestore` не звал
  // вовсе. Тест этого не видел, потому что подаёт повод сам (I9: проверка,
  // которая не может провалиться, ничего не доказывает про прод).
  //
  // Отсюда два вердикта на то, чего правило о себе не знает: что поле доезжает
  // ИЗ ДОКУМЕНТА и что экран зовёт правило, а не пишет своё условие.
  group('выход наверх проведён до конца, а не только написан', () {
    test('повод доезжает ИЗ ДОКУМЕНТА в модель', () {
      final e = PersonalEvent.fromFirestore('e', {
        'ownerUid': 'rafael',
        'date': '2026-09-16T18:00:00',
        'musicians': const <String>[],
        'status': kStatusUnsettled,
        'unsettledReason': kReasonWorkCancelled,
      });
      expect(e.unsettledReason, kReasonWorkCancelled);
      // Повод решает не показ кнопки, а её СЛОВА: цепочка «документ → модель
      // → надпись» сомкнулась.
      expect(restoreLabel(e.unsettledReason), kRestoreLabelWorkCancelled);
      expect(showsRestore(isOwner: true, status: e.status), isTrue);
    });

    test('поля нет — выход ЕСТЬ, и это главный случай (12.09)', () {
      // Замер 07.09: поля нет у 121 документа прода из 121. Прежде вердикт
      // требовал здесь `isFalse` — то есть у всех этих вечеров выхода наверх
      // не было бы ни одного. Перевёрнут вместе с правилом.
      final e = PersonalEvent.fromFirestore('e', {
        'ownerUid': 'rafael',
        'date': '2026-09-16T18:00:00',
        'musicians': const <String>[],
        'status': kStatusUnsettled,
      });
      expect(e.unsettledReason, isNull);
      expect(showsRestore(isOwner: true, status: e.status), isTrue);
      expect(restoreLabel(e.unsettledReason), kRestoreLabelWorkCancelled);
    });

    test('ЧУЖОЙ ТИП В ПОЛЕ не роняет разбор — падение уронило бы календарь', () {
      // I49: поле пишет сервер мимо правил, плюс рука в консоли.
      //
      // **ЭТОТ ВЕРДИКТ САМ ПО СЕБЕ НЕ ДОКАЗЫВАЕТ НИЧЕГО, и это выяснено
      // порчей 09.09.** Ожидаемый ответ здесь `null` — а `null` выходит и
      // когда защита работает, и когда поле НЕ ЧИТАЮТ ВОВСЕ. Порча «модель
      // перестала читать повод» его не уронила: я предсказал два упавших,
      // упал один.
      //
      // Он держится на соседе выше — «повод доезжает ИЗ ДОКУМЕНТА», — который
      // от той же порчи краснеет. Порознь брать нельзя: сам по себе он тот
      // случай, что I9, — проверка, которая не может провалиться.
      final e = PersonalEvent.fromFirestore('e', {
        'ownerUid': 'rafael',
        'date': '2026-09-16T18:00:00',
        'musicians': const <String>[],
        'status': kStatusUnsettled,
        'unsettledReason': 42,
      });
      expect(e.unsettledReason, isNull);
    });

    test('ЭКРАН ЗОВЁТ ПРАВИЛО, а не пишет своё условие', () {
      // Своё условие на экране разошлось бы с сервером МОЛЧА, и человек
      // получил бы кнопку, которой отказывают. Проверяется по исходнику:
      // разметку тестом не прогнать (I32).
      final code = readCode('lib/features/agreements/screens/agreements_screen.dart');
      // Канарейка к вырезке: кусок читается, иначе ноль ниже — слепота.
      expect(code.contains('_restoreEvent('), isTrue,
          reason: 'канарейка: ход возврата исчез, вердикты ниже зелены даром');
      expect(code.contains('showsRestore('), isTrue,
          reason: 'экран перестал звать правило показа: условие уехало в '
              'разметку, где его не сторожит никто');
      expect(code.contains('restoreLabel('), isTrue,
          reason: 'надпись зашита на экране: у двух поводов она РАЗНАЯ, и '
              'второе место с тем же решением разойдётся (N49)');
      // Надписи В РАЗМЕТКЕ быть не должно — только через правило.
      expect(code.contains("'Onsuz davam edirəm'"), isFalse,
          reason: 'надпись первого повода вписана в экран мимо правила');
      expect(code.contains("'Yenə də davam edirik'"), isFalse,
          reason: 'надпись второго повода вписана в экран мимо правила');
    });
  });

  // -------------------------------------------------------------------------
  // ПРИГЛАШЕНИЕ ПОД ВОПРОСОМ — N221, N222; решение владельца 11.09, вечер
  // -------------------------------------------------------------------------
  // ВХОД — ДОКУМЕНТ, А НЕ ПОЛЯ ПО ОТДЕЛЬНОСТИ (I55): вердикты идут через
  // `PersonalEvent.fromFirestore`, тем путём, которым вечер приходит в прод.
  // Прежние подавали правилу `status` и повод руками — ровно так N223
  // проглядела, что нужного сочетания у живого вызывающего не бывает.
  group('вечер закрыт для ответа (N221, N222, N224)', () {
    PersonalEvent doc(Map<String, dynamic> fields) =>
        PersonalEvent.fromFirestore('child', {
          'ownerUid': 'caller',
          'musicians': ['me'],
          'isAgree': false,
          'answers': {'me': kAnswerGoing},
          ...fields,
        });

    const parent = {'parentEventId': 'parent'};

    test('в силе — строки состояния нет, ответ спрашивается', () {
      for (final e in [
        doc({...parent, 'status': kStatusAgreed}),
        doc({'status': kStatusAgreed}),
      ]) {
        expect(eventStateLabel(e), isNull);
        expect(answersClosed(e), isFalse);
      }
    });

    test('под вопросом — «Şübhə altında», ответа не спрашивают', () {
      final e = doc({
        ...parent,
        'status': kStatusUnsettled,
        'unsettledReason': kReasonWorkCancelled,
      });
      expect(eventStateLabel(e), 'Şübhə altında');
      expect(answersClosed(e), isTrue);
    });

    test('ОТМЕНЁН — «Ləğv edilib», ответа тоже не спрашивают (N224)', () {
      // Прежде отменённый вечер правило не ловило вовсе: вторая сторона
      // видела «Cavabınız» с обеими кнопками на вечере, которого нет.
      final e = doc({...parent, 'status': kStatusCancelled});
      expect(eventStateLabel(e), 'Ləğv edilib');
      expect(answersClosed(e), isTrue);
    });

    test('ПОВОД НЕ РЕШАЕТ: строка есть при любом поводе', () {
      for (final reason in <String?>[null, kReasonMemberLeft, 'незнакомый']) {
        final e = doc({
          ...parent,
          'status': kStatusUnsettled,
          'unsettledReason': ?reason,
        });
        expect(eventStateLabel(e), 'Şübhə altında', reason: '$reason');
        expect(answersClosed(e), isTrue, reason: '$reason');
      }
    });

    test('ОТВЕТ ЧЕЛОВЕКА НЕ РЕШАЕТ: кнопок нет ни у кого', () {
      // Здесь стояло «у согласившегося остаётся только отказ» — снято
      // решением владельца: под вопрос ставит хозяин, и ответ приглашённого
      // этого вопроса не снимает.
      for (final mine in [kAnswerGoing, kAnswerWaiting, kAnswerCant]) {
        final e = doc({
          ...parent,
          'status': kStatusUnsettled,
          'answers': {'me': mine},
        });
        expect(answersClosed(e), isTrue, reason: mine);
      }
    });

    test('ПРИГЛАШЕНИЕ И СОСТАВ — ОДИНАКОВО, и это решение 12.09', () {
      // ЗДЕСЬ СТОЯЛ ОБРАТНЫЙ ВЕРДИКТ: «обычный вечер под вопросом — прежнее,
      // строки нет, ответ есть», то есть добавленный в состав видел вопрос
      // «придёшь?» на вечере, который владелец сам пометил под вопросом.
      // Перевёрнут решением владельца: решает СОСТОЯНИЕ вечера, а не путь,
      // каким человек в него попал.
      final invited = doc({...parent, 'status': kStatusUnsettled});
      final inLineup = doc({'status': kStatusUnsettled});
      expect(eventStateLabel(invited), eventStateLabel(inLineup));
      expect(answersClosed(invited), answersClosed(inLineup));
      expect(answersClosed(inLineup), isTrue);
    });

    test('ПЕРЕХОД ТУДА: в силе → под вопрос — строка есть, блока нет', () {
      final before = doc({...parent, 'status': kStatusAgreed});
      // Так пишет клиент за владельца: родителю и приглашениям разом.
      final after = doc({
        ...parent,
        'status': kStatusUnsettled,
        'lastActionType': kDeedOwnerDoubt,
      });
      expect([answersClosed(before), answersClosed(after)], [false, true]);
      expect([eventStateLabel(before), eventStateLabel(after)],
          [null, 'Şübhə altında']);
    });

    test('ПЕРЕХОД ОБРАТНО: вопрос снят — строка уходит, блок возвращается', () {
      // ДОКУМЕНТ ТАКОЙ, КАКИМ ЕГО ОСТАВЛЯЕТ ВОЗВРАТ, а не чистый: ход
      // `ownerFirm` меняет только `status` и `lastAction*`, а повод, если он
      // был, остаётся лежать. Правило по поводу держало бы вернувшийся вечер
      // под вопросом навсегда — этот вердикт сторожит ключ.
      final before = doc({
        ...parent,
        'status': kStatusUnsettled,
        'unsettledReason': kReasonWorkCancelled,
      });
      final after = doc({
        ...parent,
        'status': kStatusAgreed,
        'unsettledReason': kReasonWorkCancelled,
        'lastActionType': kDeedOwnerFirm,
      });
      expect([answersClosed(before), answersClosed(after)], [true, false]);
      expect([eventStateLabel(before), eventStateLabel(after)],
          ['Şübhə altında', null]);
    });
  });
}
