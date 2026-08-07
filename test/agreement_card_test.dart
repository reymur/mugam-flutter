import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/agreements/agreement_card.dart';
import 'package:mugam_flutter/core/agreements/agreement_cancel.dart';
import 'package:mugam_flutter/firebase/models.dart';

// N53/N54 — что карточка договора говорит о его судьбе.
//
// Найдено 07.08 прогоном на двух устройствах: на одном экране сошлись три
// разные неправды — не тот человек, не тот поступок, не та дата. Первую
// видно только со второго телефона, вторую — только зная данные, третью —
// только сверив с документом.
//
// Тесты идут ПО ИСХОДАМ, по одному на каждый: исходов четыре, и три из них
// в проде не случались ни разу, то есть их отображение до сегодняшнего дня
// не проверял никто.

const owner = 'owner-uid';
const partner = 'partner-uid';

AgreementCardState state({
  String status = 'agreed',
  String? requestedBy,
  String? confirmedBy,
  String? lastBy,
  String? lastType,
}) =>
    agreementCardState(
      status: status,
      cancelRequestedBy: requestedBy,
      cancelConfirmedBy: confirmedBy,
      lastActionBy: lastBy,
      lastActionType: lastType,
    );

extension _WithOffer on PersonalEvent {
  PersonalEvent copyWithOffer(String at) => PersonalEvent(
        id: id,
        ownerUid: ownerUid,
        date: date,
        type: type,
        location: location,
        notes: notes,
        participantUids: participantUids,
        isAgree: isAgree,
        status: status,
        createdAt: createdAt,
        cancelledAt: cancelledAt,
        jobOfferAt: at,
      );
}

void main() {
  group('исход: договор в силе', () {
    test('обычный договор — ни следов, ни имён', () {
      final s = state();
      expect(s.outcome, AgreementOutcome.active);
      expect(s.stamp, AgreementStamp.created);
      expect(s.proposedByUid, isNull);
      expect(s.actedByUid, isNull);
    });

    test('стоящий запрос отмены — ЕЩЁ НЕ исход', () {
      // Запрос — вопрос, а не судьба договора; отвечает на него
      // `CancelStage`. Показать его вторым следом значило бы сказать
      // человеку одно и то же дважды, разными словами.
      final s = state(
        requestedBy: owner,
        lastBy: owner,
        lastType: kCancelRequested,
      );
      expect(s.outcome, AgreementOutcome.active);
      expect(s.stamp, AgreementStamp.created);
    });
  });

  group('исход: отменён по согласию', () {
    test('названы ОБА — предложивший и согласившийся', () {
      // Ровно то, чего не было на экране: «{кто-то} imtina etdi» называло
      // одного человека и словом «отказался».
      final s = state(
        status: 'cancelled',
        requestedBy: owner,
        confirmedBy: partner,
        lastBy: partner,
        lastType: kCancelConfirmed,
      );
      expect(s.outcome, AgreementOutcome.cancelledByAgreement);
      expect(s.proposedByUid, owner);
      expect(s.confirmedByUid, partner);
    });

    test('дата берётся ОТМЕНЫ, а не создания', () {
      final s = state(
        status: 'cancelled',
        requestedBy: partner,
        confirmedBy: owner,
        lastType: kCancelConfirmed,
      );
      expect(s.stamp, AgreementStamp.cancelled);
    });

    test('роли не переставляются местами', () {
      // Предложить отмену может любая сторона. Проверяется зеркально:
      // правило, выводящее «предложил владелец» из владения, прошло бы
      // первый тест и соврало бы на этом.
      final s = state(
        status: 'cancelled',
        requestedBy: partner,
        confirmedBy: owner,
        lastType: kCancelConfirmed,
      );
      expect(s.proposedByUid, partner);
      expect(s.confirmedByUid, owner);
    });
  });

  group('исход: запрос отозван', () {
    test('договор ЖИВ, а след остаётся', () {
      // В данных от отзыва не остаётся почти ничего: поля запроса
      // очищены, status по-прежнему agreed. Отличает его только имя
      // поступка — и до 07.08 карточка его не читала, то есть экран
      // молчал. При неработающем push (N25) это значит «не узнает никто».
      final s = state(lastBy: owner, lastType: kCancelWithdrawn);
      expect(s.outcome, AgreementOutcome.requestWithdrawn);
      expect(s.actedByUid, owner);
      expect(s.stamp, AgreementStamp.created);
    });

    test('назван тот, кто отозвал, а не владелец', () {
      final s = state(lastBy: partner, lastType: kCancelWithdrawn);
      expect(s.actedByUid, partner);
    });
  });

  group('исход: в отмене отказано', () {
    test('договор ЖИВ, след свой, не спутан с отзывом', () {
      // Отзыв и отказ оставляют В ДАННЫХ одно и то же — пустые поля
      // запроса. Различает их только имя поступка, и спутать их нельзя:
      // отзыв это «я передумал», отказ — «я не согласен».
      final s = state(lastBy: partner, lastType: kCancelDeclined);
      expect(s.outcome, AgreementOutcome.requestDeclined);
      expect(s.actedByUid, partner);
    });

    test('отказ и отзыв различаются исходом, а не только именем', () {
      final a = state(lastBy: partner, lastType: kCancelDeclined);
      final b = state(lastBy: partner, lastType: kCancelWithdrawn);
      expect(a.outcome, isNot(b.outcome));
    });
  });

  group('след живёт до следующего поступка', () {
    test('правка договора стирает след — это честно', () {
      // Строка говорит «последним здесь было вот что», а не «когда-то
      // было». Иначе она пережила бы события, которые её отменяют.
      final s = state(lastBy: owner, lastType: 'edited');
      expect(s.outcome, AgreementOutcome.active);
      expect(s.actedByUid, isNull);
    });
  });

  group('отменённость старше всего остального', () {
    test('у отменённого поля запроса не очищены — исход всё равно отмена', () {
      // Подтверждение не трогает `cancelRequestedBy`, поэтому разбор по
      // «есть ли запрос» увидел бы стоящий вопрос там, где всё кончилось.
      // Та же щель, что закрывалась в правилах как N36.
      final s = state(
        status: 'cancelled',
        requestedBy: owner,
        confirmedBy: partner,
        lastBy: partner,
        lastType: kCancelWithdrawn, // намеренно противоречивое поле
      );
      expect(s.outcome, AgreementOutcome.cancelledByAgreement);
    });
  });

  group('слова поступка — глагол в нужном лице', () {
    // «Siz təklif etdi» по-азербайджански неверно: с «Siz» глагол во
    // втором лице. Наполовину строка была правильной всегда — и неверной
    // оказывалась ровно та половина, которую человек читает про себя.
    test('про себя — второе лицо, все четыре поступка', () {
      expect(deedText(AgreementDeed.proposedCancel, byViewer: true),
          'təklif etdiniz');
      expect(deedText(AgreementDeed.agreedToCancel, byViewer: true),
          'razılaşdınız');
      expect(deedText(AgreementDeed.withdrewRequest, byViewer: true),
          'ləğv təklifini geri götürdünüz');
      expect(deedText(AgreementDeed.refusedCancel, byViewer: true),
          'ləğvə razı olmadınız');
    });

    test('про другого — третье лицо, все четыре', () {
      expect(deedText(AgreementDeed.proposedCancel, byViewer: false),
          'təklif etdi');
      expect(deedText(AgreementDeed.agreedToCancel, byViewer: false),
          'razılaşdı');
      expect(deedText(AgreementDeed.withdrewRequest, byViewer: false),
          'ləğv təklifini geri götürdü');
      expect(deedText(AgreementDeed.refusedCancel, byViewer: false),
          'ləğvə razı olmadı');
    });

    test('лица РАЗНЫЕ у каждого поступка, а не совпали случайно', () {
      // Без этого «правило», возвращающее одну и ту же строку обоим,
      // прошло бы оба теста выше, если бы формы совпали.
      for (final d in AgreementDeed.values) {
        expect(
          deedText(d, byViewer: true),
          isNot(deedText(d, byViewer: false)),
          reason: 'у поступка $d форма для себя и для другого совпала',
        );
      }
    });
  });

  group('порядок в списке — новое сверху, и ничего кроме (N55)', () {
    PersonalEvent ev(
      String id, {
      String status = 'agreed',
      DateTime? created,
      DateTime? cancelled,
    }) =>
        PersonalEvent(
          id: id,
          ownerUid: owner,
          date: '2026-09-01T19:00:00.000',
          type: 'Toy',
          location: '',
          notes: '',
          participantUids: const [],
          isAgree: true,
          status: status,
          createdAt: created == null ? null : Timestamp.fromDate(created),
          cancelledAt: cancelled == null ? null : Timestamp.fromDate(cancelled),
        );

    test('дата прихода — jobOfferAt, а не дата сделки', () {
      // Главное в N55: предложение уходит РАНЬШЕ согласия. Строка на
      // карточке говорит «Sizə göndərildi», значит и дата обязана быть
      // про отправку, а не про закрытие сделки.
      final e = ev('x', created: DateTime(2026, 8, 5, 12, 0))
          .copyWithOffer('2026-08-01T09:00:00.000');
      expect(agreementStampValue(e), DateTime(2026, 8, 1, 9, 0));
    });

    test('без jobOfferAt берётся createdAt — 25 договоров прода из 26', () {
      final e = ev('x', created: DateTime(2026, 8, 5, 12, 0));
      expect(agreementStampValue(e), DateTime(2026, 8, 5, 12, 0));
    });

    test('порядок идёт по приходу, а не по дате сделки', () {
      // Договор, предложенный раньше, но согласованный позже, обязан
      // стоять НИЖЕ: человек ищет по тому, когда ему пришло.
      final list = [
        ev('пришёл раньше', created: DateTime(2026, 8, 6))
            .copyWithOffer('2026-08-01T09:00:00.000'),
        ev('пришёл позже', created: DateTime(2026, 8, 2))
            .copyWithOffer('2026-08-05T09:00:00.000'),
      ]..sort(compareAgreementsByStamp);
      expect(list.first.id, 'пришёл позже');
    });

    test('действующие идут по дате заключения, новое первым', () {
      final list = [
        ev('старый', created: DateTime(2026, 8, 1)),
        ev('новый', created: DateTime(2026, 8, 5)),
      ]..sort(compareAgreementsByStamp);
      expect(list.first.id, 'новый');
    });

    test('отменённые идут по приходу, как и все (решение владельца)', () {
      // Порядок один на весь список, включая «Ləğv edilən»: человек
      // ищет карточку по тому, когда она у него появилась.
      final list = [
        ev('пришёл раньше',
            status: 'cancelled',
            created: DateTime(2026, 7, 1),
            cancelled: DateTime(2026, 8, 6)),
        ev('пришёл позже',
            status: 'cancelled',
            created: DateTime(2026, 8, 5),
            cancelled: DateTime(2026, 8, 2)),
      ]..sort(compareAgreementsByStamp);
      expect(list.first.id, 'пришёл позже');
    });

    test('две даты — разные поля и не подменяют друг друга', () {
      // Главная на карточке — дата договора, отдельной строкой внизу —
      // дата прихода. Смешать их нельзя: это разные события.
      final e = ev('x', created: DateTime(2026, 8, 5, 12, 0))
          .copyWithOffer('2026-08-01T09:00:00.000');
      expect(agreementSignedValue(e), DateTime(2026, 8, 5, 12, 0));
      expect(agreementArrivalValue(e), DateTime(2026, 8, 1, 9, 0));
    });

    test('нет jobOfferAt — приход берёт дату создания, пустых мест нет', () {
      // Решение владельца 07.08: строка прихода обязана быть на КАЖДОЙ
      // карточке. Момент предложения у старых договоров не записан нигде
      // — ни в мероприятии, ни в чате (тот хранит только последний
      // раунд), — поэтому берётся дата появления самого договора. Цена
      // названа вслух: у таких карточек обе даты совпадут.
      final e = ev('x', created: DateTime(2026, 8, 5));
      expect(agreementArrivalValue(e), DateTime(2026, 8, 5));
      expect(agreementSignedValue(e), DateTime(2026, 8, 5));
    });

    test('настоящая дата предложения всё равно главнее', () {
      // Запасной путь не должен затирать настоящий: где jobOfferAt есть,
      // берётся он, и только он.
      final e = ev('x', created: DateTime(2026, 8, 5))
          .copyWithOffer('2026-08-01T09:00:00.000');
      expect(agreementArrivalValue(e), DateTime(2026, 8, 1, 9, 0));
    });

    test('отметка, которую показывают, и есть отметка сортировки', () {
      // Связь правила показа с правилом порядка — то, ради чего оба
      // вынесены в одно место.
      final cancelledEv = ev('c',
          status: 'cancelled',
          created: DateTime(2026, 7, 1),
          cancelled: DateTime(2026, 8, 6));
      expect(agreementStamp(cancelledEv.status), AgreementStamp.cancelled);
      expect(agreementStampValue(cancelledEv), DateTime(2026, 7, 1));

      final liveEv = ev('a', created: DateTime(2026, 8, 1));
      expect(agreementStamp(liveEv.status), AgreementStamp.created);
      expect(agreementStampValue(liveEv), DateTime(2026, 8, 1));
    });

    test('карточка без отметки уходит вниз, а не наверх', () {
      // serverTimestamp() возвращается из кэша пустым и появляется через
      // миг: с обратным правилом только что созданный договор прыгал бы
      // сверху вниз на глазах.
      final list = [
        ev('без даты'),
        ev('с датой', created: DateTime(2026, 8, 1)),
      ]..sort(compareAgreementsByStamp);
      expect(list.first.id, 'с датой');
    });

    test('порядок не зависит ни от чего, кроме отметки', () {
      // Прежде список делился на два этажа по «прочитано», и карточка
      // переезжала от того, что человек её открыл. Здесь этого входа нет
      // вовсе: у правила ровно один аргумент — сама пара договоров.
      final a = ev('a', created: DateTime(2026, 8, 5));
      final b = ev('b', created: DateTime(2026, 8, 1));
      expect(compareAgreementsByStamp(a, b), lessThan(0));
      expect(compareAgreementsByStamp(b, a), greaterThan(0));
    });
  });
}
