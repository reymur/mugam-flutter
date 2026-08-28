/// ЧТО СЛУЧИЛОСЬ С ВЕЧЕРОМ ПОСЛЕДНИМ — одной строкой на карточке.
///
/// Заведено 28.08. Повод назван владельцем: **человек нажимает на push и
/// попадает в вечер, а что именно случилось — на экране не написано нигде.**
/// На одной трубке iOS прячет текст уведомления («1 уведомление» вместо
/// содержания), и тогда новость теряется совсем; но и с видимым текстом
/// уведомление читается ОДИН раз — открывший приложение позже не узнает
/// ничего.
///
/// --- ЭТО НЕ СОСТОЯНИЕ, И ПУТАТЬ ИХ НЕЛЬЗЯ ---
///
/// Рядом лежит `eventStatusView` — она отвечает на «в каком состоянии вечер»
/// («Dəqiq» / «Şübhə altında» / «Ləğv edilib»). Её плашка **снята с экрана
/// 13.08 решением автора** и остаётся снятой: «под вопросом» музыканту не
/// нужно, вечер либо есть, либо отменён (N179).
///
/// Здесь вопрос другой — **кто и что сделал последним**, — и потому это
/// отдельное правило, а не расширение той (I47: два разных вопроса решают
/// порознь; свести их значило бы вернуть снятое боком, не отменив довода).
///
/// --- ПОЧЕМУ ФУНКЦИЯ, А НЕ УСЛОВИЕ В РАЗМЕТКЕ ---
///
/// Та же причина, что у `offerFeedLine` и `offerAuthorLine`: правило внутри
/// `build` не достаётся ни одному тесту. Здесь это весит больше обычного —
/// значений у поступка **пятнадцать**, из них четыре обязаны молчать, и
/// проверить каждое поимённо можно только снаружи.
///
/// --- ФРАЗА ЦЕЛИКОМ, А НЕ ИМЯ ПЛЮС ГЛАГОЛ ---
///
/// В азербайджанском лицо выражено окончанием глагола: свой уход — «Sən
/// **ayrıldın**», чужой — «Rafael **ayrıldı**». Значит подставлять имя в общий
/// шаблон нельзя — расходится не подлежащее, а сказуемое.
///
/// Приём взят у `offerAuthorLine` (`core/job_offer/job_offer.dart`) вместе с
/// доводом и НЕ переписан своими словами: там ровно то же — «Sən təklif
/// etdin» против «Rafael təklif edir», две фразы, а не имя в шаблоне. Второго
/// словаря вежливости в проекте заводить нельзя: разойдутся (N49, N66).
///
/// --- ГДЕ ДАННЫХ НЕТ, СТРОКА МОЛЧИТ, И ЭТО НЕ ПРОБЕЛ ---
///
/// Молчат четыре случая, и каждый по своей причине:
///
///   • **`edited`** — правка, добавление в состав и исключение из состава
///     пишут ОДНО имя поступка (`event_edit.dart` кладёт `musicians` и
///     `lastActionType: 'edited'` одной записью), а ЧТО изменилось, документ
///     не помнит. Push это знает — `diffEvents(before, after)` считается в
///     триггере и выбрасывается. «Rafael dəyişdi» не сказало бы ничего,
///     «tarixi dəyişdi» было бы выдумкой;
///   • **`deleted`** — писателя нет и быть не может: документа после удаления
///     не существует, открыть его карточку нечем. Значение живёт только в
///     союзе типов на сервере;
///   • **неизвестное значение** — mugam-v2, правка руками в консоли, будущий
///     ход, которого мы ещё не знаем (I49: у документа три писателя).
///     Придумать поступок по незнакомому слову значило бы соврать;
///   • **поступок есть, а `lastActionBy` пуст** — сказать «кто-то ушёл» можно,
///     но это тот же класс, что `notAsked` против `waiting`: два незнания под
///     одним словом. В проде такого нет ни разу (`lastActionBy` есть ровно у
///     тех же 45 записей из 103, у которых есть `lastActionType`, замер
///     28.08), но писателей у документа трое.
///
/// **Ожидание записано ДО работы, находкой N178, и вот его суть:** строка
/// появится примерно у **45 вечеров из 103**, у 58 её не будет никогда —
/// поля нет вовсе. Молчание на трубке — известное, а не поломка.
library;

/// Слова поступков — литералами здесь, рядом с правилом, как у ответов
/// состава и у имён отмены. Проход по исходникам читает литералы, и вынос
/// значения за константу сделал бы его невидимым там, где он сторожит.
///
/// Порядок тот же, в каком они появляются в жизни вечера: рождение, уход,
/// четыре хода отмены, состояние от владельца, отмена и возврат.
const String kDeedCreated = 'created';
const String kDeedReplaced = 'replaced';
const String kDeedAgreed = 'agreed';
const String kDeedLeft = 'left';
const String kDeedMemberLeft = 'memberLeft';
const String kDeedCancelRequested = 'cancelRequested';
const String kDeedCancelConfirmed = 'cancelConfirmed';
const String kDeedCancelWithdrawn = 'cancelWithdrawn';
const String kDeedCancelDeclined = 'cancelDeclined';
const String kDeedOwnerFirm = 'ownerFirm';
const String kDeedOwnerDoubt = 'ownerDoubt';
const String kDeedOwnerCancelled = 'ownerCancelled';
const String kDeedWorkCancelled = 'workCancelled';
const String kDeedRestored = 'restored';
const String kDeedEdited = 'edited';

/// Имя, когда своего нет. То же слово и по той же причине, что в
/// `offerAuthorLine`: не знать действующего неприятно, но строка
/// «‌ ayrıldı» выглядела бы поломкой.
const String kUnknownActorName = 'Naməlum';

/// Что случилось с вечером последним. `null` — сказать нечего.
///
/// [lastActionType] и [lastActionBy] — как они лежат в документе;
/// [viewerUid] — кто смотрит; [actorName] — имя действующего, каким его знает
/// экран (пустое даёт [kUnknownActorName]).
///
/// **Про `memberLeft` отдельно:** его пишет сервер (`markEventUnsettled`)
/// патчем из двух ключей — `status` и `lastActionType`, — то есть
/// `lastActionBy` остаётся ОТ УШЕДШЕГО, и фраза у него та же, что у `left`.
/// Совпадение здесь настоящее, а не экономия: это один и тот же поступок,
/// названный сервером вторым именем.
///
/// **Про `agreed` отдельно, и это единственная безличная фраза.** Имя
/// поступка пишут ДВОЕ, и «кто» у них разное: клиент кладёт `initiatorUid`
/// (принял работодатель, `accept_batch.dart`), сервер — `recipientUid`
/// (согласился получатель, `index.ts`). Назвать действующего значило бы
/// назвать разных людей одним словом в зависимости от того, каким путём
/// родился вечер. Поэтому здесь говорится о самом факте, без лица.
String? eventDeedLine({
  required String? lastActionType,
  required String? lastActionBy,
  required String viewerUid,
  required String actorName,
}) {
  if (lastActionType == null) return null;

  // Безличные фразы решаются ДО проверки автора: им действующий не нужен, и
  // отказать им из-за пустого `lastActionBy` значило бы промолчать там, где
  // сказать есть что.
  switch (lastActionType) {
    case kDeedAgreed:
      return 'Tədbir razılaşma ilə yarandı';
    case kDeedWorkCancelled:
      // Писателя пока нет — придёт в Части 6 вместе с приглашениями своих.
      // Фраза стоит здесь заранее по тому же доводу, по которому имя
      // поступка заведено заранее: заведи один — он определит форму, а
      // второй придётся подгонять.
      return 'İş ləğv olundu';
  }

  // Дальше — только фразы с лицом. Пустой автор молчит: см. шапку.
  if (lastActionBy == null || lastActionBy.isEmpty) return null;
  final own = lastActionBy == viewerUid;
  final name = actorName.trim().isEmpty ? kUnknownActorName : actorName.trim();

  return switch (lastActionType) {
    kDeedCreated => own ? 'Tədbiri sən yaratdın' : '$name tədbiri yaratdı',
    kDeedReplaced => own ? 'Tədbiri sən əvəz etdin' : '$name tədbiri əvəz etdi',
    kDeedLeft || kDeedMemberLeft => own ? 'Sən ayrıldın' : '$name ayrıldı',
    kDeedCancelRequested =>
      own ? 'Ləğv etməyi sən təklif etdin' : '$name ləğv etməyi təklif edir',
    kDeedCancelConfirmed =>
      own ? 'Ləğvi sən təsdiqlədin' : '$name ləğvi təsdiqlədi',
    kDeedCancelWithdrawn =>
      own ? 'Təklifini sən geri götürdün' : '$name təklifini geri götürdü',
    kDeedCancelDeclined =>
      own ? 'Ləğvdən sən imtina etdin' : '$name ləğvdən imtina etdi',
    kDeedOwnerFirm =>
      own ? 'Sən «dəqiq» işarələdin' : '$name «dəqiq» işarələdi',
    kDeedOwnerDoubt => own ? 'Sən şübhə bildirdin' : '$name şübhə bildirdi',
    kDeedOwnerCancelled =>
      own ? 'Tədbiri sən ləğv etdin' : '$name tədbiri ləğv etdi',
    kDeedRestored =>
      own ? 'Tədbiri sən qaytardın' : '$name tədbiri qaytardı',
    // `edited`, `deleted` и всё незнакомое — молчание. Довод в шапке; здесь
    // одна ветвь на все три нарочно: они молчат по РАЗНЫМ причинам, но
    // одинаково, и разводить их значило бы завести три пустых ветви,
    // отличающихся только комментарием.
    _ => null,
  };
}
