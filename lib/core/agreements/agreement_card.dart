/// Что карточка договора ГОВОРИТ о его судьбе — правило, отдельное от
/// правила «что человеку сейчас доступно» (`agreement_cancel.dart`).
///
/// Вынесено 07.08 после того, как прогон на двух устройствах показал три
/// разные неправды на одном экране (N53):
///
/// 1. **не тот человек** — у получателя карточка называла его самого и
///    отправителем договора, и тем, кто отменил. Причина в данных:
///    `partnerName` это имя второй стороны С ТОЧКИ ЗРЕНИЯ ВЛАДЕЛЬЦА, и у
///    получателя имени владельца в документе нет вовсе;
/// 2. **не тот поступок** — «İmtina etdi» («отказался») на исходе, который
///    был согласием: один предложил отмену, второй согласился. Слово
///    переехало из словаря чатового раунда, где отказ действительно исход
///    (N54);
/// 3. **не та дата** — под красным бейджем стояла дата СОЗДАНИЯ договора,
///    а `cancelledAt` в документе есть и на экран не выводился ни разу.
///
/// Функция отдаёт **uid, а не имена**: имена живут в списке пользователей,
/// который к правилу отношения не имеет, и подстановка их сюда сделала бы
/// правило непроверяемым без него. Кто как называется — дело экрана.
library;

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../firebase/models.dart';
import 'agreement_cancel.dart';

/// Чем кончилась история договора — то, что карточка обязана назвать.
enum AgreementOutcome {
  /// Договор в силе. Сюда же попадает договор со СТОЯЩИМ запросом отмены:
  /// запрос — не исход, а вопрос, и отвечает на него `CancelStage`.
  active,

  /// Отменён ПО СОГЛАСИЮ: один предложил, второй согласился. Обе стороны
  /// названы, потому что одного имени у этого исхода не бывает.
  cancelledByAgreement,

  /// Запрос отозван тем, кто его подал. Договор жив.
  requestWithdrawn,

  /// В отмене отказано второй стороной. Договор жив.
  requestDeclined,
}

/// Какую дату показывать под бейджем.
///
/// Прежде показывалась одна и та же — `createdAt`, — и под зелёным бейджем
/// она читалась верно («договор заключён тогда-то»), а под красным
/// превращалась в неправду о времени отмены.
enum AgreementStamp { created, cancelled }

/// Какую отметку времени показывать и по какой сортировать.
///
/// Одно правило на список и на карточку: если написанное на карточке и
/// то, по чему список отсортирован, — разные поля, список читается как
/// перепутанный, и человек ищет карточку там, где видел её минуту назад.
AgreementStamp agreementStamp(String status) =>
    status == 'cancelled' ? AgreementStamp.cancelled : AgreementStamp.created;

/// Само значение отметки — то, что показывается и по чему сортируется.
dynamic agreementStampValue(PersonalEvent e) =>
    agreementStamp(e.status) == AgreementStamp.cancelled
        ? e.cancelledAt
        : e.createdAt;

/// Порядок в списке договоров: новое сверху, и НИЧЕГО кроме.
///
/// Прежде список шёл в два этажа — сначала непрочитанные, потом
/// прочитанные, и внутри каждого по свежести. Значит карточка новее могла
/// стоять ниже старой, а прочтение переставляло её на глазах: человек
/// возвращался и не находил её там, где видел (решение владельца 07.08 —
/// оставить один порядок; непрочитанность и так показана рамкой и точкой).
///
/// Отсутствующая отметка уходит вниз, а не наверх: у только что созданного
/// договора `serverTimestamp()` возвращается из кэша `null` и появляется
/// через миг — с обратным правилом он прыгал бы сверху вниз на глазах.
int compareAgreementsByStamp(PersonalEvent a, PersonalEvent b) {
  final av = agreementStampValue(a);
  final bv = agreementStampValue(b);
  if (av is Timestamp && bv is Timestamp) {
    final cmp = bv.compareTo(av);
    if (cmp != 0) return cmp;
  } else if (av is Timestamp) {
    return -1;
  } else if (bv is Timestamp) {
    return 1;
  }
  // Устойчивый доводчик: без него две несравнимые карточки меняются
  // местами на каждой перерисовке без единого изменения в данных.
  return a.id.compareTo(b.id);
}

/// Что карточка говорит о судьбе договора.
class AgreementCardState {
  final AgreementOutcome outcome;

  /// Кто предложил отмену — только у [AgreementOutcome.cancelledByAgreement].
  final String? proposedByUid;

  /// Кто согласился на отмену — там же.
  final String? confirmedByUid;

  /// Кто отозвал запрос или отказал — у двух «живых» исходов.
  final String? actedByUid;

  final AgreementStamp stamp;

  const AgreementCardState({
    required this.outcome,
    required this.stamp,
    this.proposedByUid,
    this.confirmedByUid,
    this.actedByUid,
  });
}

/// Единственное место, где решается, что написано на карточке.
///
/// ПРО ДВА ЖИВЫХ ИСХОДА — отзыв и отказ. В данных они не оставляют почти
/// ничего: `cancelRequestedBy` и `cancelRequestedAt` очищаются, `status`
/// остаётся `agreed`, и отличаются они ТОЛЬКО именем поступка в
/// `lastActionType`. До 07.08 карточка этих полей не читала вовсе, то есть
/// после отказа и после отзыва экран возвращался к обычному действующему
/// договору и следа не оставалось никакого. Это не сломанное отображение,
/// а отсутствующее: в данных этих веток не существовало ни разу, показывать
/// их никто не писал.
///
/// Цена молчания выше обычной: push на iOS не работает вовсе (нет платного
/// аккаунта Apple, N25-push), поэтому экран — единственное место, где
/// человек мог бы узнать исход. Не скажет он — не скажет никто.
///
/// След живёт ровно до следующего поступка: правка договора выставит
/// `lastActionType: 'edited'`, и строка исчезнет. Это честно — она говорит
/// «последним здесь было вот что», а не «когда-то было».
AgreementCardState agreementCardState({
  required String status,
  required String? cancelRequestedBy,
  required String? cancelConfirmedBy,
  required String? lastActionBy,
  required String? lastActionType,
}) {
  // Отменённость старше всего остального — ровно как в `resolveCancelStage`:
  // у отменённого договора поля запроса НЕ очищаются, и разбор по ним
  // увидел бы стоящий запрос там, где всё уже кончилось.
  if (status == 'cancelled') {
    return AgreementCardState(
      outcome: AgreementOutcome.cancelledByAgreement,
      proposedByUid: cancelRequestedBy,
      confirmedByUid: cancelConfirmedBy,
      stamp: agreementStamp(status),
    );
  }
  if (lastActionType == kCancelWithdrawn) {
    return AgreementCardState(
      outcome: AgreementOutcome.requestWithdrawn,
      actedByUid: lastActionBy,
      stamp: AgreementStamp.created,
    );
  }
  if (lastActionType == kCancelDeclined) {
    return AgreementCardState(
      outcome: AgreementOutcome.requestDeclined,
      actedByUid: lastActionBy,
      stamp: AgreementStamp.created,
    );
  }
  // Сюда же попадает `cancelRequested`: стоящий запрос — не исход. Ответ
  // на него рисуется по `CancelStage`, и дублировать его следом значило бы
  // сказать человеку одно и то же дважды, разными словами.
  return const AgreementCardState(
    outcome: AgreementOutcome.active,
    stamp: AgreementStamp.created,
  );
}

// ---------------------------------------------------------------------------
// СЛОВА ПОСТУПКА — с глаголом в нужном лице
// ---------------------------------------------------------------------------
// Найдено на устройстве 07.08, сразу после починки имён: строка выходила
// «Siz ləğv təklifini geri götürdü». По-азербайджански с «Siz» глагол
// обязан стоять во ВТОРОМ лице («götürdünüz»), с именем — в третьем
// («götürdü»). Подстановка имени в строку с одним фиксированным окончанием
// даёт верно ровно в половине случаев, а вторая половина — про самого
// смотрящего, то есть та, которую он читает чаще всего.
//
// Слова живут здесь, а не в экране, чтобы их можно было проверить тестом:
// у обоих лиц по четыре поступка, и глазами эту таблицу не удержать.

/// Поступок, о котором говорит карточка.
enum AgreementDeed {
  /// Предложил отмену.
  proposedCancel,

  /// Согласился на отмену.
  agreedToCancel,

  /// Забрал свой запрос обратно.
  withdrewRequest,

  /// Не согласился на отмену.
  refusedCancel,
}

/// Глагольная часть строки. Имя (или «Siz») подставляет экран.
///
/// [byViewer] — поступок совершил тот, кто смотрит.
String deedText(AgreementDeed deed, {required bool byViewer}) {
  switch (deed) {
    case AgreementDeed.proposedCancel:
      return byViewer ? 'təklif etdiniz' : 'təklif etdi';
    case AgreementDeed.agreedToCancel:
      return byViewer ? 'razılaşdınız' : 'razılaşdı';
    case AgreementDeed.withdrewRequest:
      return byViewer
          ? 'ləğv təklifini geri götürdünüz'
          : 'ləğv təklifini geri götürdü';
    case AgreementDeed.refusedCancel:
      return byViewer ? 'ləğvə razı olmadınız' : 'ləğvə razı olmadı';
  }
}
