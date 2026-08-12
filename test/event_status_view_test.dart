import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/agreements/event_status_view.dart';

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
        lastActionType: kReasonMemberLeft,
        leftMemberName: 'Teymur',
      );
      expect(v.reason, 'Teymur ayrıldı');
    });

    test('имени нет — повод всё равно назван', () {
      // Кнопка «Onsuz davam edirəm» без причины на экране — действие, которого
      // человек не понимает. Имя может не доехать, повод — обязан.
      final v = eventStatusView(
        status: kStatusUnsettled,
        lastActionType: kReasonMemberLeft,
      );
      expect(v.reason, 'İştirakçı ayrıldı');
    });

    test('исчезла работа — свой повод, другими словами', () {
      final v = eventStatusView(
        status: kStatusUnsettled,
        lastActionType: kReasonWorkCancelled,
      );
      expect(v.reason, 'İş ləğv olundu');
      expect(
        v.reason,
        isNot(
          eventStatusView(
            status: kStatusUnsettled,
            lastActionType: kReasonMemberLeft,
          ).reason,
        ),
      );
    });

    test('повод неизвестен — молчим, а не выдумываем причину', () {
      final v = eventStatusView(
        status: kStatusUnsettled,
        lastActionType: 'нечто',
      );
      expect(v.reason, isNull);
      // Само состояние при этом показано: неизвестен повод, а не состояние.
      expect(v.label, 'Şübhə altında');
    });
  });

  group('«Onsuz davam edirəm» — те же три условия, что в правиле', () {
    test('владельцу, из unsettled, по поводу ушедшего — да', () {
      expect(
        showsContinueWithout(
          isOwner: true,
          status: kStatusUnsettled,
          lastActionType: kReasonMemberLeft,
        ),
        isTrue,
      );
    });

    test('НЕ владельцу — нет', () {
      // `restoresEvent()` требует `ownerUid == uid`; покажи кнопку другому — и
      // он получит отказ по правам, ничего не поняв.
      expect(
        showsContinueWithout(
          isOwner: false,
          status: kStatusUnsettled,
          lastActionType: kReasonMemberLeft,
        ),
        isFalse,
      );
    });

    test('из «в силе» и из отменённого — нет', () {
      for (final s in [kStatusAgreed, kStatusCancelled]) {
        expect(
          showsContinueWithout(
            isOwner: true,
            status: s,
            lastActionType: kReasonMemberLeft,
          ),
          isFalse,
          reason: 'состояние $s не имеет выхода «продолжаю без него»',
        );
      }
    });

    test('по поводу «исчезла работа» — НЕТ, и это не строгость', () {
      // Возвращать не к чему: родительский договор отменён по согласию обеих
      // сторон, и обратного хода у отмены нет вовсе. «Всё в силе» на
      // приглашении без работы обещает несуществующее.
      expect(
        showsContinueWithout(
          isOwner: true,
          status: kStatusUnsettled,
          lastActionType: kReasonWorkCancelled,
        ),
        isFalse,
      );
    });
  });
}
