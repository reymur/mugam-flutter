// ПРЕДЛОЖЕНИЕ РАБОТЫ — отдельный документ `chats/{chatId}/offers/{offerId}`
// (решение автора 13.08). Разбор — `docs/plan.md`, работа 1; права —
// `firestore.rules`, блок `offers`; парный тест —
// `functions/test/job-offer-rules.test.ts`.
//
// Здесь — ЧТЕНИЕ документа и РЕШЕНИЕ, что показать. Записи отсюда не идут:
// у каждого хода свой вызов в сервисе, и правила разрешают ровно четыре
// (создание, отметки, принятие, отзыв).

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
    this.eventTime = '',
    this.eventLocation = '',
    this.eventNotes = '',
    this.anchorMessageId,
    this.answers = const {},
    this.acceptedBy,
    this.withdrawnBy,
  });

  final String id;
  final String createdBy;
  final List<String> dates;
  final String eventType;
  final String eventTime;
  final String eventLocation;
  final String eventNotes;
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
    return JobOffer(
      id: id,
      createdBy: data['createdBy'] as String? ?? '',
      dates: (data['dates'] as List?)?.whereType<String>().toList() ?? const [],
      eventType: data['eventType'] as String? ?? '',
      eventTime: data['eventTime'] as String? ?? '',
      eventLocation: data['eventLocation'] as String? ?? '',
      eventNotes: data['eventNotes'] as String? ?? '',
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
    required this.canPickDays,
    required this.canSend,
    required this.canAccept,
    required this.canWithdraw,
    required this.canRecordVoice,
  });

  /// Квадратики у дат живые.
  final bool canPickDays;

  /// Кнопка «Göndər» под отметками.
  final bool canSend;

  /// Кнопка «Qəbul edirəm».
  final bool canAccept;

  /// Отзыв предложения инициатором.
  final bool canWithdraw;

  /// «bu təklifə danış» — микрофон в самой карточке.
  final bool canRecordVoice;

  /// Ничего не предложено — карточка только смотрится.
  bool get isReadOnly =>
      !canPickDays && !canSend && !canAccept && !canWithdraw && !canRecordVoice;
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
      canPickDays: false,
      canSend: false,
      canAccept: false,
      canWithdraw: false,
      canRecordVoice: false,
    );
  }

  if (role == OfferRole.recipient) {
    // Отметки живые, пока раунд открыт, — включая переотметку после
    // отправки: «не устраивает — говорят голосом, музыкант меняет отметки и
    // шлёт снова» (docs/plan.md).
    return const OfferCardActions(
      canPickDays: true,
      canSend: true,
      canAccept: false,
      canWithdraw: false,
      canRecordVoice: true,
    );
  }

  // Инициатор. Принять можно только то, на что уже ответили: до ответа
  // принимать нечего, и кнопка там означала бы согласие с пустотой.
  return OfferCardActions(
    canPickDays: false,
    canSend: false,
    canAccept: state == OfferState.answered,
    canWithdraw: true,
    canRecordVoice: true,
  );
}
