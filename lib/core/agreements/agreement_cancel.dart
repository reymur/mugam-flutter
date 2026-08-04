/// Отмена договора по согласию — правило «что человеку сейчас доступно».
///
/// Вынесено из карточки договора по той же причине, что и правила плашки
/// конфликта: правило должно быть проверяемо тестом, а не жить внутри
/// состояния виджета. Здесь оно ещё и решает, КАКИМ ИМЕНЕМ назовётся
/// поступок, а имя определяет, кому уйдёт уведомление, — ошибиться в нём
/// дороже, чем нарисовать не ту кнопку.
library;

/// Что доступно смотрящему на договор прямо сейчас.
enum CancelStage {
  /// Договор уже отменён — ходов больше нет. Правила запрещают всё при
  /// `status == 'cancelled'`, и кнопка здесь обещала бы несделанное.
  cancelled,

  /// Запроса нет: можно предложить отмену.
  none,

  /// Просил я — жду ответа. Дорога одна: отозвать.
  requestedByMe,

  /// Просит второй — у меня ДВА разных ответа: согласиться или отказать.
  /// Одной кнопкой их не выразить: поступка два, и уведомления от них
  /// уходят разным людям.
  requestedByOther,
}

/// Имя поступка, которое уйдёт в `lastActionType`.
///
/// Значения совпадают с теми, что перечислены в `firestore.rules`
/// (`withdrawsCancelRequest` / `declinesCancelRequest`), и разойтись им
/// нельзя: правило требует буквального совпадения, а несовпадение даст
/// отказ по правам — молчаливый, если его проглотить.
///
/// Называются ВСЕ ЧЕТЫРЕ хода, а не только два снятия. У запроса и
/// подтверждения причина своя: имя автора для текста уведомления сервер
/// берёт из `lastActionBy`, а этого поля их прежняя форма не писала — и
/// «{Ad} müqavilənin ləğvini təklif etdi» называло владельца вместо
/// просящего.
const String kCancelRequested = 'cancelRequested';
const String kCancelConfirmed = 'cancelConfirmed';
const String kCancelWithdrawn = 'cancelWithdrawn';
const String kCancelDeclined = 'cancelDeclined';

/// Все имена отмены разом — для проходов по исходникам.
const Set<String> kCancelDeeds = {
  kCancelRequested,
  kCancelConfirmed,
  kCancelWithdrawn,
  kCancelDeclined,
};

/// Единственное место, где решается, какая дорога открыта.
///
/// [status] — статус договора, [cancelRequestedBy] — кто просил отмену
/// (`null`, если не просил никто), [currentUid] — кто смотрит.
CancelStage resolveCancelStage({
  required String status,
  required String? cancelRequestedBy,
  required String currentUid,
}) {
  // Отменённость старше всего остального: у отменённого договора
  // `cancelRequestedBy` НЕ очищается (подтверждение его не трогает),
  // поэтому проверка «есть ли запрос» без этой строки увидела бы
  // стоящий запрос и предложила бы на него ответить. Ровно та щель, что
  // была в правилах как N36.
  if (status == 'cancelled') return CancelStage.cancelled;
  if (cancelRequestedBy == null) return CancelStage.none;
  if (cancelRequestedBy == currentUid) return CancelStage.requestedByMe;
  return CancelStage.requestedByOther;
}
