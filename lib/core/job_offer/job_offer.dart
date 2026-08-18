// ПРЕДЛОЖЕНИЕ РАБОТЫ — отдельный документ `chats/{chatId}/offers/{offerId}`
// (решение автора 13.08). Разбор — `docs/plan.md`, работа 1; права —
// `firestore.rules`, блок `offers`; парный тест —
// `functions/test/job-offer-rules.test.ts`.
//
// Здесь — ЧТЕНИЕ документа и РЕШЕНИЕ, что показать. Записи отсюда не идут:
// у каждого хода свой вызов в сервисе, и правила разрешают ровно четыре
// (создание, отметки, принятие, отзыв).

import 'day_details.dart';

/// Роль в ОДНОМ предложении. Роль принадлежит предложению, а не человеку:
/// в чате нет ни работодателей, ни музыкантов — есть двое участников, и
/// позвать на работу может любой (N127, поймано парным тестом).
enum OfferRole {
  /// Тот, кто это предложение создал.
  initiator,

  /// Второй участник чата — тот, кого зовут.
  recipient,
}

/// Состояние предложения. Раунд закрывается принятием или отзывом, и после
/// закрытия отметки не принимаются — так же в правилах (`roundOpen()`).
enum OfferState {
  /// Отправлено, ответа ещё нет.
  awaitingAnswer,

  /// Музыкант отметился — в том числе НУЛЁМ дней: это ответ «не могу ни на
  /// один», а не отсутствие ответа.
  answered,

  /// «Qəbul edirəm» нажато, вечера созданы.
  accepted,

  /// Отозвано инициатором.
  withdrawn,
}

class JobOffer {
  const JobOffer({
    required this.id,
    required this.createdBy,
    required this.dates,
    required this.eventType,
    this.details = const {},
    this.anchorMessageId,
    this.answers = const {},
    this.acceptedBy,
    this.withdrawnBy,
  });

  final String id;
  final String createdBy;
  final List<String> dates;
  final String eventType;

  /// Подробности ПО ДНЯМ: ключ — тот же ISO-день, что лежит в `dates`.
  ///
  /// **Здесь до 19.08 стояли три плоские строки** —
  /// `eventTime`/`eventLocation`/`eventNotes`, одни на всё предложение.
  /// Писатель перестал их писать 14.08 (`71d2ae9`), а читатель остался и
  /// продолжал их спрашивать: чтение по несуществующему полю не падает, оно
  /// возвращает пусто (I44), поэтому «Ətraflı» на карточке не показывался
  /// НИ РАЗУ и никто не покраснел (N139).
  ///
  /// **Дни без единой вписанной подробности в карту не попадают вовсе** —
  /// так их пишет `createOffer`, и читателю это переживать обязательно:
  /// отсутствие ключа здесь законно и означает «ничего не вписано».
  final Map<String, DayDetails> details;

  final String? anchorMessageId;

  /// Отмеченные дни по uid. **Карта, а не общий список**, и это не про
  /// будущих нескольких музыкантов: в общем списке свою отметку от чужой не
  /// отличить, и правило «трогать только своё» стало бы невыразимым —
  /// пришлось бы верить экрану.
  final Map<String, List<String>> answers;

  final String? acceptedBy;
  final String? withdrawnBy;

  /// Ответил ли этот человек. **Отличается от «отметил хоть один день»**, и
  /// путать их нельзя: пустой список — это сказанное «не могу ни на один»,
  /// а отсутствие ключа — несказанное ничего. Свести их в один ответ значит
  /// потерять различие между отказом и молчанием (I47).
  bool hasAnswered(String uid) => answers.containsKey(uid);

  List<String> pickedBy(String uid) => answers[uid] ?? const [];

  /// Дни, которые человек НЕ отметил. Показываются мелко и серо («10, 12 —
  /// yox»): отказ показан, но не выделен — он не поступок, а остаток
  /// выбора (`docs/design/README.md`).
  List<String> declinedBy(String uid) {
    if (!hasAnswered(uid)) return const [];
    final picked = pickedBy(uid).toSet();
    return dates.where((d) => !picked.contains(d)).toList();
  }

  OfferRole roleOf(String uid) =>
      uid == createdBy ? OfferRole.initiator : OfferRole.recipient;

  /// Порядок ветвей здесь ЗНАЧИМ, и потому назван словами: отзыв и принятие
  /// старше ответа, иначе отвеченное-и-отозванное показалось бы просто
  /// отвеченным.
  OfferState get state {
    if (withdrawnBy != null) return OfferState.withdrawn;
    if (acceptedBy != null) return OfferState.accepted;
    if (answers.isNotEmpty) return OfferState.answered;
    return OfferState.awaitingAnswer;
  }

  static JobOffer fromMap(String id, Map<String, dynamic> data) {
    // Мягкое чтение намеренно: у документа три возможных писателя (наш
    // клиент, наш сервер мимо правил, правка руками в консоли), и жёсткое
    // приведение здесь роняло бы карточку целиком из-за одного поля (I49).
    final rawAnswers = data['answers'];
    final answers = <String, List<String>>{};
    if (rawAnswers is Map) {
      rawAnswers.forEach((key, value) {
        if (key is String && value is List) {
          answers[key] = value.whereType<String>().toList();
        }
      });
    }
    // Тем же мягким чтением, что и `answers` выше, и по той же причине.
    // Ключ — ISO-день; чужая запись под нестроковым ключом или не-картой в
    // значении просто не попадает в результат, а не роняет карточку.
    final rawDetails = data['details'];
    final details = <String, DayDetails>{};
    if (rawDetails is Map) {
      rawDetails.forEach((key, value) {
        if (key is String && value is Map) {
          details[key] = DayDetails.fromMap(Map<String, dynamic>.from(value));
        }
      });
    }
    return JobOffer(
      id: id,
      createdBy: data['createdBy'] as String? ?? '',
      dates: (data['dates'] as List?)?.whereType<String>().toList() ?? const [],
      eventType: data['eventType'] as String? ?? '',
      details: details,
      anchorMessageId: data['anchorMessageId'] as String?,
      answers: answers,
      acceptedBy: data['acceptedBy'] as String?,
      withdrawnBy: data['withdrawnBy'] as String?,
    );
  }
}

/// ЧТО КАРТОЧКА ПРЕДЛАГАЕТ СДЕЛАТЬ — и это единственное место, где такой
/// вопрос решается.
///
/// **ЗАЧЕМ ОТДЕЛЬНО ОТ ВИДЖЕТА.** I32 говорит прямо: ни один сторож в этом
/// проекте не смотрит на порядок ветвей в разметке, механически он не
/// выразим, а **выразимо следствие — таблица «состояние × роль → какие
/// действия предложены», прогоняемая тестом**. Вот она. Пока решение живёт
/// внутри `build()`, проверить его нечем, и цена этого уже заплачена дважды:
/// N125 (участнику нечем ответить — блок ответа осиротел при пересборке по
/// макету, тринадцать часов в проде, 569 зелёных тестов) и N108.
///
/// Таблица утверждает НАЛИЧИЕ действий, значит сама себе канарейка (I31):
/// ослепни она — вернёт пустой набор, а пустого не ждёт ни одна строка.
class OfferCardActions {
  const OfferCardActions({
    required this.canAnswer,
    required this.canPickDays,
    required this.canSend,
    required this.canAccept,
    required this.canWithdraw,
    required this.canRecordVoice,
  });

  /// **ОТВЕТИТЬ НА ПРЕДЛОЖЕНИЕ — ход есть, и делается он НА ЭКРАНЕ**
  /// (`JobOfferAnswerSheet`), а не в карточке.
  ///
  /// Поле отвечает на «предложен ли человеку этот ход», а НЕ на «показывать
  /// ли что-то этой карточке». Разница решает: второе — свойство места
  /// показа, и такому свойству здесь не место (I58, переключатель «а этому
  /// не показывать» есть признак склейки двух дел). Первое — свойство
  /// состояния и роли, то есть ровно то, что эта функция и разбирает.
  ///
  /// Поэтому карточка, которой некуда открыть экран, просто не рисует
  /// ничего: `canAnswer` остаётся `true` — ход-то предложен, — а вести
  /// его некуда, и вешать тап в пустоту хуже, чем не вешать.
  final bool canAnswer;

  /// Квадратики у дат живые.
  ///
  /// **МЁРТВОЕ ПОЛЕ С 19.08: всегда `false`.** Отметка дней уехала на
  /// экран (`canAnswer` выше), и внутри карточки этот ход больше не
  /// делается. Поле оставлено намеренно — снимается одним заходом ПОСЛЕ
  /// шага 2 вместе с `canSend`, `_checkbox`, `_picked` и их тестами (I51).
  final bool canPickDays;

  /// Кнопка «Göndər» под отметками.
  ///
  /// **МЁРТВОЕ ПОЛЕ С 19.08: всегда `false`**, по той же причине и с той же
  /// судьбой, что `canPickDays`.
  final bool canSend;

  /// Кнопка «Qəbul edirəm».
  final bool canAccept;

  /// Отзыв предложения инициатором.
  final bool canWithdraw;

  /// «bu təklifə danış» — микрофон в самой карточке.
  final bool canRecordVoice;

  /// Ничего не предложено — карточка только смотрится.
  bool get isReadOnly =>
      !canAnswer &&
      !canPickDays &&
      !canSend &&
      !canAccept &&
      !canWithdraw &&
      !canRecordVoice;
}

/// Разбор один на обе стороны: обе смотрят на ОДИН документ, и разойтись
/// их вид может только по роли и состоянию, а не по тому, чей телефон.
OfferCardActions offerCardActions(JobOffer offer, String viewerUid) {
  final role = offer.roleOf(viewerUid);
  final state = offer.state;

  // Закрытый раунд не предлагает НИЧЕГО и никому — ни отметить, ни принять,
  // ни отозвать, ни сказать голосом. Стоит первым и до разбора ролей: иначе
  // каждую ветку пришлось бы помнить об этом отдельно, а забытая ветка
  // выглядела бы обычной (I34).
  if (state == OfferState.accepted || state == OfferState.withdrawn) {
    return const OfferCardActions(
      canAnswer: false,
      canPickDays: false,
      canSend: false,
      canAccept: false,
      canWithdraw: false,
      canRecordVoice: false,
    );
  }

  if (role == OfferRole.recipient) {
    // ОТВЕТ ПРЕДЛОЖЕН, ПОКА РАУНД ОТКРЫТ, — включая переответ после
    // отправки: «не устраивает — говорят голосом, музыкант меняет отметки и
    // шлёт снова» (docs/plan.md). Условие не смотрит на то, отвечал ли он
    // уже: `answered` — это состояние ПРЕДЛОЖЕНИЯ, а не запрет человеку.
    //
    // `canPickDays`/`canSend` здесь `false` с 19.08: ход тот же, место
    // другое — экран, а не карточка.
    return const OfferCardActions(
      canAnswer: true,
      canPickDays: false,
      canSend: false,
      canAccept: false,
      canWithdraw: false,
      canRecordVoice: true,
    );
  }

  // Инициатор. Принять можно только то, на что уже ответили: до ответа
  // принимать нечего, и кнопка там означала бы согласие с пустотой.
  return OfferCardActions(
    canAnswer: false,
    canPickDays: false,
    canSend: false,
    canAccept: state == OfferState.answered,
    canWithdraw: true,
    canRecordVoice: true,
  );
}


/// СТРОКА ПРЕДЛОЖЕНИЯ В ЛЕНТЕ — три состояния, и третье пришлось назвать
/// отдельно.
///
///   «5 gün təklif»     — предложение отправлено, ответа нет;
///   «3 gün cavab»      — ответили и назвали дни;
///   «gələ bilmir»      — ответили НУЛЁМ дней.
///
/// **ТРЕТЬЕ НЕ СВОДИТСЯ КО ВТОРОМУ.** «0 gün cavab» было бы верно по числу
/// и неверно по смыслу: ноль отмеченных — это ОТКАЗ, а не ответ с
/// количеством. Человек, читающий ленту, должен видеть разницу между «он
/// назвал три дня» и «он не может ни в один», не открывая экран.
///
/// Слово «təklif» / «cavab» стоит В ТЕКСТЕ, а не выводится из того, чьё
/// сообщение: через месяц при прокрутке сторона и цвет читаются плохо, а
/// слово читается всегда.
String offerFeedLine(JobOffer offer, {required String recipientUid}) {
  if (!offer.hasAnswered(recipientUid)) {
    return '${offer.dates.length} gün təklif · ${offer.eventType}';
  }
  final picked = offer.pickedBy(recipientUid);
  if (picked.isEmpty) return 'gələ bilmir';
  return '${picked.length} gün cavab';
}

/// ПОКАЗЫВАТЬ ЛИ ЭТО СООБЩЕНИЕ КАРТОЧКОЙ — и если да, то какое предложение
/// в неё класть.
///
/// **Вынесено из разметки НАМЕРЕННО, и это прямое применение I32:** на
/// порядок ветвей, в котором экран решает, что показать, в проекте нет ни
/// одного сторожа, и цена этого уже заплачена — N125, тринадцать часов в
/// проде при 569 зелёных тестах. Механически порядок не выразим; выразимо
/// следствие — решение, которое можно позвать из теста.
///
/// Три исхода, и они РАЗНЫЕ (I47), хотя два последних дают на экране одно:
///
///   • ссылки нет            → обычное сообщение, карточке взяться неоткуда;
///   • ссылка есть, документ пришёл → карточка;
///   • **ссылка есть, документа НЕТ** → обычное сообщение, и это НЕ
///     поломка. Так выглядят те миллисекунды, пока идёт первая выдача
///     потока, а ещё — предложение, удалённое из базы руками. Показать
///     здесь заглушку значило бы мигать ею при каждом открытии чата.
///
/// Возврат `null` во втором и третьем случае одинаков **на экране** и
/// различим **в разборе**: спросив `msg.offerId`, вызывающий отличит «это
/// не якорь» от «якорь, но документа нет».
JobOffer? offerCardFor(String? offerId, Map<String, JobOffer> offersById) {
  if (offerId == null) return null;
  return offersById[offerId];
}

/// Можно ли инициатору принимать.
///
/// **НОЛЬ ОТМЕЧЕННЫХ — ПРИНИМАТЬ НЕЧЕГО.** Кнопка «Qəbul edirəm» над пустым
/// ответом обещает действие без последствий: по нажатию создалось бы ноль
/// вечеров, и человек остался бы гадать, сработало или нет.
///
/// Единственный ход инициатора при нуле — **отзыв**. Он и остаётся на
/// экране, с прямо сказанным последствием.
bool canAcceptAnswer(JobOffer offer, {required String recipientUid}) =>
    offer.hasAnswered(recipientUid) &&
    offer.pickedBy(recipientUid).isNotEmpty &&
    offer.state == OfferState.answered;
