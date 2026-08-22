import '../agreements/event_answers.dart';
import 'job_offer.dart';

// СБОРКА ПАЧКИ ПРИ ПРИЁМЕ — N вечеров плюс отметка о принятии, одной
// операцией.
//
// **ЭТО НЕ «ЧИСТАЯ ФУНКЦИЯ РЯДОМ», А САМ ПУТЬ ПРОДА** (I55). Репозиторий
// зовёт её и записывает РОВНО то, что она вернула, без единого решения
// своего: у `JobOfferRepository.accept` не осталось ни одной строки,
// которая бы что-то выбирала. Значит порча здесь портит прод, а не соседа,
// и зелёный результат после порчи означал бы дырку в проверке, а не удачу.
//
// **ПОЧЕМУ ПАЧКОЙ, А НЕ ПО ОДНОМУ.** Принятие необратимо: отозвать принятое
// правило не даёт (`roundOpen()` закрывает и это). Создание вечеров по
// одному оставило бы при обрыве связи половину дней созданными, а
// предложение — непринятым; человек увидел бы часть вечеров в календаре и
// кнопку «Cavaba bax» на месте. `WriteBatch` либо проходит целиком, либо не
// проходит вовсе.
//
// **ЧИСЛО ЗАПИСЕЙ В ПАЧКЕ — N + 1, И ОНО ОГРАНИЧЕНО ПРАВИЛОМ, А НЕ
// НАДЕЖДОЙ.** `dates.size() <= 31` в `firestore.rules` даёт не больше 32
// записей при пределе Firestore в 500. Предел взят извне и нами не мерен
// (I6), поэтому правило заменяет «влезает по здравому смыслу» на «влезает
// доказуемо».

/// Один вечер пачки: имя документа и его содержимое.
class AcceptedEventDraft {
  const AcceptedEventDraft({required this.id, required this.data});

  /// **`${offerId}_${isoDay}`, и это защита от повтора, а не украшение.**
  ///
  /// Записывается через `set`, а не `add`. Два нажатия подряд, повтор при
  /// потере связи, второй телефон того же человека — всё это даёт ТЕ ЖЕ
  /// документы, а не вторые. С `add` каждый повтор рождал бы новый вечер, и
  /// человек нашёл бы в календаре два одинаковых дня, не понимая, откуда.
  final String id;

  final Map<String, dynamic> data;
}

/// Что записывает приём: вечера и правка самого предложения.
class AcceptBatch {
  const AcceptBatch({required this.events, required this.offerPatch});

  final List<AcceptedEventDraft> events;

  /// Ровно два ключа — больше правило не пустит
  /// (`changedKeys().hasOnly(['acceptedBy', 'acceptedAt'])`).
  final Map<String, dynamic> offerPatch;
}

/// Собрать пачку по ответу музыканта.
///
/// **ДНИ БЕРУТСЯ ИЗ ОТВЕТА, А НЕ ИЗ ПРЕДЛОЖЕНИЯ.** Звали на пять, музыкант
/// смог три — вечеров должно родиться три. Взять `offer.dates` значило бы
/// создать вечера на дни, на которые человек прямо сказал «нет», и записать
/// это в его календарь как согласие.
///
/// **ПУСТОЙ ОТВЕТ СЮДА НЕ ДОХОДИТ**, и держит это `canAcceptAnswer` у
/// кнопки: ноль отмеченных дней — законный ответ «не могу ни в один», и
/// принимать там нечего. Если он всё же дойдёт, пачка выйдет из одной
/// правки предложения и ни одного вечера — то есть «принято, а вечеров
/// нет». Поэтому здесь стоит проверка, а не молчаливое согласие.
AcceptBatch buildAcceptBatch({
  required JobOffer offer,
  required String chatId,
  required String initiatorUid,
  required String recipientUid,
  required String recipientName,
  required DateTime acceptedAt,
}) {
  final picked = offer.pickedBy(recipientUid).toList()..sort();
  if (picked.isEmpty) {
    throw ArgumentError(
      'принимать нечего: музыкант не отметил ни одного дня. '
      'Кнопку в этом состоянии рисовать нельзя — см. canAcceptAnswer',
    );
  }

  final participants = [initiatorUid, recipientUid];

  final events = [
    for (final iso in picked)
      AcceptedEventDraft(
        id: '${offer.id}_$iso',
        data: <String, dynamic>{
          // Владелец — тот, кто принимает. Правило создания требует
          // `ownerUid == request.auth.uid` и ничего сверх того.
          'ownerUid': initiatorUid,
          'date': iso,
          'type': offer.eventType,
          // Место и заметка — ПОДРОБНОСТИ ЭТОГО ДНЯ, а не общие на всё
          // предложение: у каждого дня они свои (`DayDetails`, макет
          // `mugam-14-secim`). День без вписанных подробностей в карту не
          // попадает вовсе — отсутствие ключа законно и значит «ничего не
          // вписано».
          'location': offer.details[iso]?.location ?? '',
          'notes': _notesFor(offer, iso),
          'musicians': participants,
          'answers': answersForParticipants(
            participants,
            ownerUid: initiatorUid,
          ),
          kAnswersWrittenByOwner: true,
          // Договор двух людей, а не личный вечер. По этому полю
          // `eventCardKind` решает, какую карточку рисовать, а профиль —
          // кого показывать в «Müqavilələr».
          'isAgree': true,
          'agreementChatId': chatId,
          'partnerUid': recipientUid,
          'partnerName': recipientName,
          'status': 'agreed',
          // КОГДА УШЛО ПРЕДЛОЖЕНИЕ, а не когда его приняли. Читают
          // `agreementStampValue` и `agreementArrivalValue`: по нему
          // карточки сортируются и на каждой печатается дата прихода.
          // Пусто здесь означало бы дату принятия на всех N карточках.
          'jobOfferAt': offer.createdAt,
          // Те же четыре поля, что у обоих существующих писателей: вечер
          // из предложения и вечер, заведённый руками, обязаны иметь один
          // набор полей — иначе отмена по согласию работала бы на одних и
          // молча не работала на других.
          'cancelRequestedBy': null,
          'cancelRequestedAt': null,
          'cancelConfirmedBy': null,
          'cancelledAt': null,
          'replacedEventId': null,
          'lastActionBy': initiatorUid,
          // МОЛЧАНИЕ СЕРВЕРА, И ОНО НАРОЧНОЕ.
          //
          // `onPersonalEventCreated` при `lastActionType == 'agreed'`
          // выходит сразу (`functions/src/index.ts:2325`). Без этого
          // музыкант получил бы N уведомлений «вас добавили» — по одному на
          // каждый день, — и все об одном своём же ответе.
          //
          // **Одно уведомление на предложение вместо N — это шаг 4 (N130),
          // и снимается молчание ТАМ, а не здесь.** Сегодня музыкант о
          // принятии не узнаёт вовсе, и это записано, чтобы не считалось
          // сделанным.
          //
          // I54 применительно к этому ходу: поле, по которому сервер судит
          // о смысле произошедшего, пишет участник. Здесь оно используется,
          // чтобы сервер промолчал, — тише, чем ложное уведомление, но
          // класс тот же, и на шаге 4 это место надо пересмотреть.
          'lastActionType': 'agreed',
          'createdAt': acceptedAt.toIso8601String(),
        },
      ),
  ];

  return AcceptBatch(
    events: events,
    offerPatch: <String, dynamic>{
      'acceptedBy': initiatorUid,
      'acceptedAt': acceptedAt.toIso8601String(),
    },
  );
}

/// Заметка вечера — время и одежда этого дня, если они вписаны.
///
/// У вечера нет отдельного поля времени: `PersonalEvent` знает `date`,
/// `type`, `location`, `notes` и больше ничего. Терять вписанное время
/// нельзя — ради него человек и открывал подробности, — поэтому оно
/// уходит в заметку, а не пропадает.
///
/// **ГОЛОСОВОЕ СЮДА НЕ ПЕРЕНОСИТСЯ, И ЭТО СКАЗАНО, ЧТОБЫ НЕ ВЫГЛЯДЕЛО
/// ПРОПУСКОМ.** У вечера нет поля под запись, а класть ссылку в текст
/// заметки значит показать человеку URL. Запись остаётся жить в
/// предложении: переписка никуда не девается, предложение из неё не
/// исчезает (`allow delete: if false`), и «Ətraflı» открывается там же.
String _notesFor(JobOffer offer, String iso) {
  final d = offer.details[iso];
  if (d == null) return '';
  final parts = [
    if (d.time.isNotEmpty) d.time,
    if (d.dress.isNotEmpty) d.dress,
  ];
  return parts.join(' · ');
}
