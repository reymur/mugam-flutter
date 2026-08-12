/// СОСТОЯНИЕ ВЕЧЕРА НА КАРТОЧКЕ — шаг 6 (`docs/plan.md`), починка **N116**.
///
/// **Найдено сборкой макета с экраном 12.08:** в `mugam-6-kart` статус стоит
/// первым блоком отдельной плашкой («Dəqiq», зелёная обводка), а на карточке
/// вечера его не было **ни в каком виде** — ноль упоминаний `event.status`
/// против одиннадцати в карточке договора. То есть вечер «под вопросом» и
/// вечер отменённый выглядели как обычные.
///
/// Правило вынесено сюда, а не написано в экране, потому что читателей у него
/// двое: сама плашка и решение, какие кнопки показывать (кнопка «Onsuz davam
/// edirəm» существует ровно для одного состояния и одного повода).
library;

/// Что показать про состояние вечера.
class EventStatusView {
  const EventStatusView({required this.label, required this.tone, this.reason});

  /// Слово на плашке.
  final String label;

  final EventStatusTone tone;

  /// **ПОВОД — отдельной строкой под плашкой, и он обязателен для «под
  /// вопросом».** Кнопка «Onsuz davam edirəm» без строки про ушедшего — это
  /// действие без причины на экране: человек видит предложение продолжить
  /// «без него», не зная, кто ушёл и когда (решение владельца 12.08).
  final String? reason;
}

enum EventStatusTone {
  /// В силе: зелёная обводка, как в макете.
  firm,

  /// Под вопросом: приглушённая обводка. **Не красная** — красный отдан
  /// отмене целиком (N110), и красить им «под вопросом» значило бы дать
  /// одному цвету два состояния.
  doubt,

  /// Отменён: красная обводка.
  cancelled,
}

/// Слова состояний. Литералами здесь, рядом с правилом, — как у ответов
/// состава: их читает проход по исходникам, и вынос значения за константу
/// сделал бы его невидимым там, где он сторожит.
const String kStatusAgreed = 'agreed';
const String kStatusUnsettled = 'unsettled';
const String kStatusCancelled = 'cancelled';

/// Поводы «под вопроса» — их два, третий (`ownerDoubt`) не написан вовсе:
/// поставить `unsettled` клиент не может, это делает только сервер
/// (`markEventUnsettled`). Разбор — шаг 6 в `docs/plan.md`.
const String kReasonMemberLeft = 'memberLeft';
const String kReasonWorkCancelled = 'workCancelled';

/// Как показать состояние. `null` — показывать нечего (вечер в силе и
/// говорить об этом незачем)? **Нет: «в силе» показывается тоже.**
///
/// Плашка стоит всегда, и это решение, а не привычка: отсутствие плашки
/// читается как «состояние неизвестно», а не как «всё в порядке». Пустое
/// место не отличает целый вечер от экрана, который про состояние не знает —
/// ровно тем и был дефект N116.
EventStatusView eventStatusView({
  required String status,
  String? lastActionType,
  String? leftMemberName,
}) {
  switch (status) {
    case kStatusCancelled:
      return const EventStatusView(
        label: 'Ləğv edilib',
        tone: EventStatusTone.cancelled,
      );
    case kStatusUnsettled:
      return EventStatusView(
        label: 'Şübhə altında',
        tone: EventStatusTone.doubt,
        reason: switch (lastActionType) {
          kReasonMemberLeft =>
            leftMemberName == null
                ? 'İştirakçı ayrıldı'
                : '$leftMemberName ayrıldı',
          kReasonWorkCancelled => 'İş ləğv olundu',
          // Повод неизвестен — молчим о нём, но само состояние показываем.
          // Придумать причину значило бы сказать человеку неправду о том,
          // почему его вечер под вопросом.
          _ => null,
        },
      );
    default:
      return const EventStatusView(label: 'Dəqiq', tone: EventStatusTone.firm);
  }
}

/// Показывать ли «Onsuz davam edirəm».
///
/// **Только владельцу, только из `unsettled`, только по поводу
/// `memberLeft`** — те же три условия, что стоят в правиле `restoresEvent()`
/// (`firestore.rules`). Написаны здесь заново намеренно: правило решает, что
/// СЕРВЕР примет, а это — что человеку ПОКАЗАТЬ. Разойдись они, человек
/// увидел бы кнопку, которая молча получает отказ.
///
/// Из `workCancelled` возврата нет: работа отменена по согласию обеих сторон,
/// и «продолжаю без него» обещало бы вечер, которого не существует.
bool showsContinueWithout({
  required bool isOwner,
  required String status,
  String? lastActionType,
}) =>
    isOwner &&
    status == kStatusUnsettled &&
    lastActionType == kReasonMemberLeft;
