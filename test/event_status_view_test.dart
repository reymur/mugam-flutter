import 'package:flutter_test/flutter_test.dart';
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

  group('выход наверх — те же три условия, что в правиле restoresEvent', () {
    test('владельцу, из unsettled, по поводу ушедшего — да', () {
      expect(
        showsRestore(
          isOwner: true,
          status: kStatusUnsettled,
          unsettledReason: kReasonMemberLeft,
        ),
        isTrue,
      );
    });

    // ВТОРАЯ ПОЛОВИНА, ЗАВЕДЕНА 08.09 (работа 7, шаг 1).
    //
    // ЗДЕСЬ СТОЯЛ ОБРАТНЫЙ ВЕРДИКТ — «по поводу „исчезла работа“ — НЕТ, и это
    // не строгость», с доводом «возвращать не к чему». Записан снятием, а не
    // стёрт: снятый молча вердикт назавтра заводят заново.
    //
    // Довод был неверен: вечер — это ДЕНЬ И СОСТАВ, а не тот договор, под
    // который звали. Решение владельца 08.09.
    test('по поводу «исчезла работа» — ТОЖЕ да', () {
      expect(
        showsRestore(
          isOwner: true,
          status: kStatusUnsettled,
          unsettledReason: kReasonWorkCancelled,
        ),
        isTrue,
      );
    });

    test('НЕ владельцу — нет, и по обоим поводам', () {
      // `restoresEvent()` требует `ownerUid == uid`; покажи кнопку другому — и
      // он получит отказ по правам, ничего не поняв.
      //
      // Оба повода проверяются порознь нарочно: расширен ПОВОД, а не круг
      // решающих, и одна проба этого не доказала бы.
      for (final r in [kReasonMemberLeft, kReasonWorkCancelled]) {
        expect(
          showsRestore(
            isOwner: false,
            status: kStatusUnsettled,
            unsettledReason: r,
          ),
          isFalse,
          reason: 'по поводу $r выход наверх есть только у владельца',
        );
      }
    });

    test('из «в силе» и из отменённого — нет, и по обоим поводам', () {
      for (final s in [kStatusAgreed, kStatusCancelled]) {
        for (final r in [kReasonMemberLeft, kReasonWorkCancelled]) {
          expect(
            showsRestore(isOwner: true, status: s, unsettledReason: r),
            isFalse,
            reason: 'состояние $s не имеет выхода наверх (повод $r)',
          );
        }
      }
    });

    // ПЕРЕЧИСЛЕНИЕ, А НЕ «ЛЮБОЙ ПОВОД» — вердикт ради того, чтобы условие не
    // упростили до «состояние unsettled и владелец». На двух сегодняшних
    // поводах упрощение вело бы себя одинаково, а первый же новый повод
    // поехал бы в «можно вернуть» молча.
    //
    // Имена взяты живые: `ownerDoubt` правила уже принимают в
    // `ownerSetsStatus`, `cancelRequested` — одно из четырёх имён отмены.
    test('повод не из перечисленных — нет', () {
      for (final r in ['ownerDoubt', 'cancelRequested', 'restored', '']) {
        expect(
          showsRestore(
            isOwner: true,
            status: kStatusUnsettled,
            unsettledReason: r,
          ),
          isFalse,
          reason: 'повод «$r» выхода наверх не даёт',
        );
      }
    });

    test('повода нет вовсе — нет', () {
      // «Поля нет» и «поле не то» — два разных пути, и второй не доказывает
      // первого (I47).
      expect(
        showsRestore(
          isOwner: true,
          status: kStatusUnsettled,
          unsettledReason: null,
        ),
        isFalse,
      );
    });
  });

  group('надпись выхода наверх', () {
    // ГЛАВНЫЙ ВЕРДИКТ ГРУППЫ: показ и надпись не могут разойтись.
    //
    // Он утверждает НАЛИЧИЕ, значит сам себе канарейка (I31): ослепни разбор
    // — и надписи не найдётся ни одной, вердикт покраснеет.
    test('у каждого повода, где выход есть, надпись НАЙДЕНА', () {
      for (final r in [kReasonMemberLeft, kReasonWorkCancelled]) {
        expect(
          showsRestore(isOwner: true, status: kStatusUnsettled,
              unsettledReason: r),
          isTrue,
          reason: 'повод $r обязан давать выход наверх',
        );
        expect(
          restoreLabel(r),
          isNotNull,
          reason: 'у повода $r выход есть, а слов для кнопки нет — '
              'человек увидел бы кнопку без надписи',
        );
      }
    });

    // Обратная половина. Без неё «надписи есть у всех» было бы истинно и
    // тогда, когда надпись выдаётся ЛЮБОМУ поводу: кнопка нашлась бы там,
    // где сервер откажет.
    test('где выхода нет, надписи ТОЖЕ нет', () {
      for (final r in ['ownerDoubt', 'cancelRequested', 'restored', '', null]) {
        expect(
          showsRestore(isOwner: true, status: kStatusUnsettled,
              unsettledReason: r),
          isFalse,
          reason: 'повод «$r» выхода наверх не даёт',
        );
        expect(
          restoreLabel(r),
          isNull,
          reason: 'у повода «$r» выхода нет, а надпись нашлась — кнопка '
              'появилась бы там, где правило откажет',
        );
      }
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
      // И правило на этом поводе открывает выход — то есть цепочка
      // «документ → модель → правило» сомкнулась.
      expect(
        showsRestore(
          isOwner: true,
          status: e.status,
          unsettledReason: e.unsettledReason,
        ),
        isTrue,
      );
    });

    test('поля нет — повода нет, и это НЕ «повод неизвестен»', () {
      // Замер 07.09: поля нет у 121 документа прода из 121. Значит `null`
      // здесь сегодня обычная жизнь, и выход наверх открывать не по чему.
      final e = PersonalEvent.fromFirestore('e', {
        'ownerUid': 'rafael',
        'date': '2026-09-16T18:00:00',
        'musicians': const <String>[],
        'status': kStatusUnsettled,
      });
      expect(e.unsettledReason, isNull);
      expect(
        showsRestore(isOwner: true, status: e.status, unsettledReason: null),
        isFalse,
      );
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
}
