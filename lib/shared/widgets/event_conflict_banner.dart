import 'package:flutter/material.dart';

import '../../core/theme/colors.dart';
import '../../core/time/az_date_format.dart';
import '../../firebase/models.dart';

// Предупреждение о занятом времени — ОДИН виджет на оба места, где оно
// показывается: лист «İş təklif et» (job_offer_date_sheet.dart) и окно
// создания/правки мероприятия в календаре (agreements_screen.dart).
//
// Почему общий, а не по копии на экран. Это третий общий кусок между
// этими двумя окнами, после формы одежды (event_notes_picker.dart) и
// самого диалога конфликта (event_conflict_dialog.dart), и причина та же:
// вопрос у человека один и тот же, откуда бы он в него ни пришёл. Копии
// расходятся молча — ровно так календарь и остался с однострочным
// предупреждением через эмодзи ⚠️, когда лист уже переделали на две
// строки, и заметил это владелец глазами, а не код.
//
// Цвета предупреждения переехали в `core/theme/colors.dart` 08.08
// (работа 5б): они уже использовались ДВУМЯ файлами — этим и
// `event_conflict_dialog.dart`, — то есть общими были по факту, а
// лежали в одном из потребителей. Разбор, почему они именно такие,
// переехал вместе с ними: он объясняет цвета, а не этот виджет.

/// Строка мероприятия внутри предупреждения. Крупная и почти белая:
/// прежние 12,5 пункта приходилось разглядывать, а прочитать её нужно
/// одним взглядом — это единственное место, где сказано, ЧЕМ занято время.
const TextStyle kWarnFactStyle = TextStyle(
  color: kWarnFact,
  fontSize: 15,
  fontWeight: FontWeight.w700,
  height: 1.25,
);

/// «Toy · 17:20 · Bakı» — из того, что у мероприятия вообще заполнено.
/// Пустые части не оставляют висящих разделителей.
String eventConflictSummary(PersonalEvent e) => [
  if (e.type.isNotEmpty) e.type,
  if (fmtEventTime(e.date).isNotEmpty) fmtEventTime(e.date),
  if (e.location.isNotEmpty) e.location,
].join(' · ');

/// ЛЮДИ МЕРОПРИЯТИЯ — владелец И участники, без повторов.
///
/// Заведено 04.08 (N30). Поле `musicians` значит РАЗНОЕ у двух видов
/// записей, и это видно только в данных:
///
///   - мероприятие из календаря (`addPersonalEvent`) кладёт туда только
///     выбранных, БЕЗ владельца;
///   - договор из согласованного предложения (`onChatUpdated`) кладёт
///     владельца И вторую сторону.
///
/// Поэтому код, читающий `musicians` как «все люди мероприятия», верен на
/// договорах и молча теряет человека на календарных. Наступил на это
/// перенос участников при замене: переносил участников, а владельца
/// заменяемого мероприятия — нет (N31), заметил владелец проекта на
/// устройстве.
///
/// Чиним правилом ЧТЕНИЯ, а не переписыванием данных: миграция привела бы
/// сегодняшние записи к одному виду и никак не защитила бы от следующего
/// писателя. Одна функция на весь проект — защищает и будущие.
List<String> eventPeople(PersonalEvent e) {
  final out = <String>{};
  if (e.ownerUid.isNotEmpty) out.add(e.ownerUid);
  out.addAll(e.participantUids.where((u) => u.isNotEmpty));
  return out.toList();
}

/// Кого подмешать в форму из конфликтующего мероприятия — ЧИСТОЕ правило.
///
/// Вынесено из экрана 04.08, после того как дефект нашёлся глазами на
/// устройстве, а теста на него не было вовсе: правило жило внутри
/// состояния виджета и проверить его было нечем.
///
/// Три условия, и каждое куплено наблюдением:
///
/// 1. **Только при создании нового.** При правке существующего замены не
///    происходит вовсе, и подмешивать людей из соседнего мероприятия
///    нельзя. Наблюдалось: владелец открыл своё мероприятие карандашом и
///    увидел в участниках чужого человека, которого не добавлял.
///
/// 2. **Только когда конфликт ОДИН.** При нескольких мероприятиях в день
///    заменить можно лишь одно, а какое — человек скажет переключателем
///    позже. Подмешивать людей всех сразу значит собрать список из трёх
///    чужих мероприятий. Тот же класс, что B29: угадывать за человека,
///    какое из нескольких он имел в виду, нельзя.
///
/// 3. **Явно убранный не возвращается.** Иначе перенос отменял бы
///    действие человека, сделанное руками.
List<String> participantsToMerge({
  required List<PersonalEvent> conflicts,
  required List<String> current,
  required Set<String> explicitlyRemoved,
  required String currentUid,
  required bool isEditing,
}) {
  if (isEditing) return const [];
  if (conflicts.length != 1) return const [];
  return [
    for (final uid in eventPeople(conflicts.single))
      if (uid != currentUid &&
          !current.contains(uid) &&
          !explicitlyRemoved.contains(uid))
        uid,
  ];
}

/// Что остаётся в списке, когда человек ответил «Yeni tədbir».
///
/// Ответ означает «это отдельное мероприятие», значит подмешанные из
/// конфликтующего люди ему не нужны. Убираются РОВНО подмешанные: тех,
/// кого человек выбрал сам, трогать нельзя, даже если он выбрал того же
/// человека руками.
///
/// Вынесено чистой функцией по той же причине, что и сам перенос: правило
/// внутри состояния виджета непроверяемо, а проверять здесь надо именно
/// отрицательный случай — что НИКТО не остался.
List<String> participantsAfterUnmerge({
  required List<String> current,
  required Set<String> merged,
}) =>
    [for (final uid in current) if (!merged.contains(uid)) uid];

/// Состав после СМЕНЫ НАБОРА КОНФЛИКТОВ — то есть после того, как человек
/// покрутил колесо (N38).
///
/// Прежде подмешанные снимались ровно из одной точки — ответа «Yeni
/// tədbir», — а смену даты не отслеживало ничто. Наблюдалось дважды, 04.08
/// и 06.08: человек прокрутил дату через день, где мероприятие стоит
/// минута в минуту, состав того мероприятия подмешался, человек вернул дату
/// обратно — подмешанные остались от дня, который он уже не выбирает. Люди
/// при этом стоят в списке ровно так же, как поставленные руками, и
/// сохраняются в мероприятие вместе с ним.
///
/// Правило целиком, а не «снять и пусть build подмешает заново»: снятие и
/// подмешивание — две половины одного хода, и проверять их надо вместе.
/// Иначе тест на возврат покрывает половину, а вторая живёт в `build`, где
/// её нечем взять.
///
/// [conflicts] — мешающие мероприятия УЖЕ ДЛЯ НОВОЙ даты.
ConflictParticipantsChange participantsAfterConflictChange({
  required List<String> current,
  required Set<String> merged,
  required List<PersonalEvent> conflicts,
  required Set<String> explicitlyRemoved,
  required String currentUid,
  required bool isEditing,
}) {
  // Сначала снимаем подмешанное прежним конфликтом — целиком, потому что
  // прежнего конфликта больше нет ни в каком виде. Выбранное руками
  // остаётся: `participantsAfterUnmerge` трогает ровно подмешанных.
  final base = participantsAfterUnmerge(current: current, merged: merged);
  // Затем подмешиваем состав НОВОГО конфликта — тем же правилом, что и при
  // первом появлении предупреждения. Второго правила здесь нет: разойдись
  // они, состав после смены даты отличался бы от состава при том же
  // конфликте, выбранном сразу.
  final add = participantsToMerge(
    conflicts: conflicts,
    current: base,
    explicitlyRemoved: explicitlyRemoved,
    currentUid: currentUid,
    isEditing: isEditing,
  );
  return ConflictParticipantsChange(
    participants: [...base, ...add],
    merged: add.toSet(),
  );
}

/// Состав и отметка «кто из них подмешан» — возвращаются парой.
///
/// Пара, а не один список: забыть обновить `merged` значит оставить в нём
/// людей прошлого конфликта, и следующее снятие промахнётся мимо них — тот
/// же дефект, только на ход позже.
class ConflictParticipantsChange {
  final List<String> participants;
  final Set<String> merged;

  const ConflictParticipantsChange({
    required this.participants,
    required this.merged,
  });
}

/// Что создаётся, когда человек ответил «Təqvimimdən sil» на ЧУЖОМ
/// мероприятии (N47).
///
/// Правило переноса состава выводилось для замены СВОЕГО: там мы
/// переписываем `musicians` целиком, и без переноса участники заменяемого
/// молча выпали бы. На чужом пути этого довода нет и быть не может —
/// заменяемого не существует: человек уходит из одного мероприятия и
/// создаёт другое, своё. Наблюдалось 06.08 на устройстве: в новое
/// мероприятие попали владелец покинутого и второй его участник, а
/// `replacedEventId` указал на чужой и ЖИВОЙ документ, отчего сервер
/// разослал обоим «Tədbir əvəz edildi» — рассказ о поступке, которого не
/// было.
///
/// Поэтому здесь три отрицания сразу, и каждое проверяется отдельно:
/// состав — только выбранный человеком; `replacedEventId` — пусто;
/// `lastActionType` — `created`, а не `replaced`.
///
/// Живёт рядом с правилом переноса, а не в `event_edit.dart`, потому что
/// читает `participantsAfterUnmerge`: правило и его отмена должны лежать в
/// одном файле, иначе отмену однажды напишут заново и по-другому.
ForeignLeaveCreation foreignLeaveCreation({
  required List<String> current,
  required Set<String> mergedFromConflict,
}) =>
    ForeignLeaveCreation(
      participantUids:
          participantsAfterUnmerge(current: current, merged: mergedFromConflict),
      replacedEventId: null,
      // `addPersonalEvent` выводит имя поступка из `replacedEventId`
      // (пусто → `created`). Названо здесь вслух, чтобы проверялось само
      // имя, а не только пустая ссылка: вернись одно без другого — и
      // участники снова услышат про замену.
      lastActionType: 'created',
    );

/// Что записывается при выходе из чужого мероприятия.
class ForeignLeaveCreation {
  final List<String> participantUids;
  final String? replacedEventId;
  final String lastActionType;

  const ForeignLeaveCreation({
    required this.participantUids,
    required this.replacedEventId,
    required this.lastActionType,
  });
}

// ---------------------------------------------------------------------------
// ЛОГИКА КОНФЛИКТА — тоже общая, а не только вид
// ---------------------------------------------------------------------------
// Требование владельца 03.08: «пусть будет одно и то же в обоих местах».
// Одного общего виджета для этого мало — он отвечает лишь за то, КАК
// плашка выглядит, а разойтись экраны могут в том, КОГДА она появляется и
// что считается конфликтом. Ровно так они и разошлись в прошлый раз:
// лист предупреждал живьём при выборе времени, а календарь молчал до
// самого сохранения, и заметить это можно было только глазами.
//
// Поэтому здесь лежат и правила: что считать занятым, в каком порядке
// показывать и когда запрет снимается.

bool sameCalendarDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// Все мероприятия на выбранный ДЕНЬ, по возрастанию времени.
///
/// [excludeEventId] — мероприятие, которое сейчас правят: само с собой оно
/// конфликтовать не может. Нужно календарю (там правят существующее) и не
/// нужно листу предложения (он всегда создаёт новое).
///
/// Отменённые не считаются: договор со статусом `cancelled` времени
/// человека уже не занимает, и предупреждать о нём значило бы держать день
/// занятым навсегда.
///
/// ДЕДУП ПО ID ОБЯЗАТЕЛЕН, и он здесь, а не у вызывающего. Владелец
/// числится и в собственном массиве участников, поэтому его мероприятия
/// приходят ОБОИМИ потоками — «свои» и «где я участник», — и склеенный
/// список содержит каждое дважды.
///
/// Наблюдалось на устройстве 03.08: на одну и ту же дату календарь
/// показывал «6 tədbiriniz var», а лист предложения — «3», ровно вдвое.
/// Лист дедуплицировал у себя, календарь склеивал списки как есть
/// (`[...personalEvents, ...eventsAsParticipant]`, три места в
/// `agreements_screen.dart`).
///
/// Чинится именно тут, а не в календаре: правило обязано давать один и тот
/// же ответ, что бы ему ни передали. Иначе следующий экран, собравший
/// список так же, разойдётся с остальными — и опять молча, потому что
/// дубль не ошибка, а просто неверное число.
List<PersonalEvent> conflictEventsOnDay(
  DateTime when,
  List<PersonalEvent> events, {
  String? excludeEventId,
}) {
  final out = <({PersonalEvent event, DateTime at})>[];
  final seen = <String>{};
  for (final e in events) {
    if (e.id == excludeEventId) continue;
    if (!seen.add(e.id)) continue;
    if (e.date.isEmpty) continue;
    if (e.status == 'cancelled') continue;
    try {
      final d = DateTime.parse(e.date);
      if (sameCalendarDay(d, when)) out.add((event: e, at: d));
    } catch (_) {
      continue;
    }
  }
  out.sort((a, b) => a.at.compareTo(b.at));
  return out.map((x) => x.event).toList();
}

/// Совпадение с точностью до минуты — ВСЕ, а не первое (N51).
///
/// Прежняя редакция возвращала `PersonalEvent?`, то есть одно мероприятие
/// **по сигнатуре**. Вызывающему нечего было решать: он получал
/// единственное и заворачивал его в список из одного элемента прямо в
/// строке вызова. Наблюдалось 07.08 на устройстве: на 18:00 стояли своё
/// мероприятие и чужое, где человек участник, — окно назвало одно и
/// промолчало про второе.
///
/// **Скрывалось систематически ЧУЖОЕ.** Порядок задаёт сортировка по
/// времени, а при равном времени Dart стабильность не обещает; на
/// практике выигрывает тот, кто раньше в исходном перечне, а перечень
/// собирается как `[...свои, ...где я участник]`. То есть пряталось
/// ровно то мероприятие, где человека ждёт кто-то другой, — худший из
/// возможных выборов, и не случайный.
///
/// Тот же класс уже был найден и починен рядом — в дневной ветке, где
/// диалогу передавался `.first` (см. шапку `EventConflictDialog`). Здесь
/// он пережил починку, потому что прятался за типом: `PersonalEvent?` не
/// выглядит как `.first`, хотя значит то же самое (правило I11).
///
/// [resolvedIds] — мероприятия, с которыми человек уже разобрался в этом
/// же заходе (вышел из чужого). Список данных о них ещё не знает: он
/// снят при открытии формы и живёт в ней до закрытия.
List<PersonalEvent> exactConflictsAt(
  DateTime when,
  List<PersonalEvent> events, {
  String? excludeEventId,
  Set<String> resolvedIds = const <String>{},
}) {
  final out = <PersonalEvent>[];
  for (final e in conflictEventsOnDay(when, events,
      excludeEventId: excludeEventId)) {
    if (resolvedIds.contains(e.id)) continue;
    try {
      final d = DateTime.parse(e.date);
      if (d.hour == when.hour && d.minute == when.minute) out.add(e);
    } catch (_) {
      continue;
    }
  }
  return out;
}

/// Что показать при текущем выборе — или `null`, если показывать нечего.
class ConflictBannerSpec {
  const ConflictBannerSpec({
    required this.title,
    required this.detail,
    required this.events,
  });

  final String title;
  final String detail;
  final List<PersonalEvent> events;
}

/// Случаи не равнозначны: прошлая дата старше всего, затем собственный
/// запрет человека, затем точное совпадение минуты, и последним занятый
/// день — точное совпадение говорит больше.
///
/// [blockedTime] — время, которое человек сам объявил занятым, ответив
/// «Yeni tədbir» на ТОЧНОЕ совпадение минуты. Запрета на целый день нет:
/// «Yeni tədbir» при занятом лишь дне просто сохраняет — два мероприятия
/// в одну дату это обычная жизнь (решение владельца 03.08).
ConflictBannerSpec? resolveConflictBanner({
  required DateTime selectedDate,
  required List<PersonalEvent> events,
  DateTime? blockedTime,
  String? excludeEventId,
  bool pastDate = false,
  // Разобранные в этом же заходе — плашка обязана перестать про них
  // говорить сразу, не дожидаясь, пока список данных обновится (N51).
  Set<String> resolvedIds = const <String>{},
}) {
  // Прошлая дата — раньше всех остальных случаев: при ней нельзя ни
  // сохранить, ни отправить, и говорить в этот момент про занятость
  // значило бы называть не ту причину отказа.
  //
  // До 03.08 про прошлую дату человек узнавал только после нажатия
  // «отправить», всплывающей строчкой, а в календаре не узнавал вовсе.
  // Теперь предупреждение живое, как и остальные.
  if (pastDate) {
    return const ConflictBannerSpec(
      title: 'Keçmiş tarix seçilə bilməz',
      detail: 'Zəhmət olmasa gələcək bir vaxt seçin',
      events: <PersonalEvent>[],
    );
  }

  final onDay = conflictEventsOnDay(selectedDate, events,
          excludeEventId: excludeEventId)
      .where((e) => !resolvedIds.contains(e.id))
      .toList();
  final exact = exactConflictsAt(selectedDate, events,
      excludeEventId: excludeEventId, resolvedIds: resolvedIds);

  if (isConflictTimeBlocked(selectedDate, blockedTime)) {
    return ConflictBannerSpec(
      title:
          '${blockedTime!.hour.toString().padLeft(2, '0')}:'
          '${blockedTime.minute.toString().padLeft(2, '0')} artıq məşğuldur',
      detail: 'Zəhmət olmasa başqa vaxt seçin',
      events: exact,
    );
  }
  if (exact.isNotEmpty) {
    // Число называется так же, как у занятого дня. Прежде минутная ветка
    // не говорила о количестве вовсе, и человек уходил с экрана уверенным,
    // что на этой минуте у него одно дело (N51).
    return ConflictBannerSpec(
      title: exact.length == 1
          ? 'Bu vaxtda sizin tədbiriniz var'
          : 'Bu vaxtda sizin ${exact.length} tədbiriniz var',
      detail: '',
      events: exact,
    );
  }
  if (onDay.isNotEmpty) {
    // Занятый день — то, чего в листе не было видно вовсе: совпадение
    // минута в минуту в жизни почти не случается, мешает второй тədbir в
    // тот же день.
    return ConflictBannerSpec(
      title: onDay.length == 1
          ? 'Bu gün sizin tədbiriniz var'
          : 'Bu gün sizin ${onDay.length} tədbiriniz var',
      detail: '',
      events: onDay,
    );
  }
  return null;
}

bool isConflictTimeBlocked(DateTime selected, DateTime? blockedTime) =>
    blockedTime != null &&
    selected.hour == blockedTime.hour &&
    selected.minute == blockedTime.minute;


/// Плашка предупреждения о конфликте.
///
/// [title] — «что не так», [detail] — необязательная подпись «что делать».
/// [events] — мероприятия, о которых предупреждение и говорит; каждое
/// открывается через [onOpenEvent]. Пустой список допустим: тогда плашка
/// только предупреждает и ни на что не ведёт.
class EventConflictBanner extends StatelessWidget {
  const EventConflictBanner({
    super.key,
    required this.title,
    this.detail = '',
    this.events = const <PersonalEvent>[],
    this.onOpenEvent,
  });

  final String title;
  final String detail;
  final List<PersonalEvent> events;
  final void Function(PersonalEvent event)? onOpenEvent;

  @override
  Widget build(BuildContext context) {
    // Одно мероприятие — нажимается ВСЯ плашка, и стрелка одна, большая,
    // во всю её высоту. Несколько — плашка целиком не нажимается, у
    // каждого своя строка со своей стрелкой.
    //
    // Разводится это не ради красоты. Общая кнопка на всю панель при
    // нескольких мероприятиях обязана выбрать одно из них — то есть
    // угадать за человека. Это тот же класс, что B29 (галочки показывали
    // случайного участника, потому что бралось `firstWhere`), и цена та
    // же: ошибки не возникает нигде, просто открывается не то.
    final openable = onOpenEvent != null;
    final single = openable && events.length == 1;

    final panel = Container(
      padding: const EdgeInsets.fromLTRB(12, 11, 10, 11),
      decoration: BoxDecoration(
        color: kWarnBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kWarnBorder),
      ),
      child: Row(
        crossAxisAlignment:
            single ? CrossAxisAlignment.center : CrossAxisAlignment.start,
        children: [
          // Значок в своём кружке, а не эмодзи внутри строки: эмодзи
          // уезжает вместе с переносом и теряет смысл отметки на полях.
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: kWarnIconBg,
              shape: BoxShape.circle,
            ),
            child: const Text('!', style: TextStyle(
              color: kWarnTitle,
              fontSize: 13,
              fontWeight: FontWeight.w900,
              height: 1.1,
            )),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: kWarnTitle,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                  ),
                ),
                if (detail.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    detail,
                    style: const TextStyle(
                      color: kWarnHint,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      height: 1.3,
                    ),
                  ),
                ],
                if (single)
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Text(
                      eventConflictSummary(events.first),
                      style: kWarnFactStyle,
                    ),
                  )
                else
                  for (final e in events) _row(e, openable),
              ],
            ),
          ),
          if (single) ...[
            const SizedBox(width: 6),
            const Icon(Icons.chevron_right, size: 34, color: kWarnTitle),
          ],
        ],
      ),
    );

    if (!single) return panel;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onOpenEvent!(events.first),
      child: panel,
    );
  }

  /// Строка мероприятия — для случая, когда их несколько, либо когда
  /// переход не задан вовсе (тогда без стрелки и без нажатия).
  ///
  /// Нажимается вся строка, не одна стрелка: попасть в мелкую цель на ходу
  /// трудно, а промах здесь ничего не портит — экран мероприятия
  /// открывается и закрывается без последствий.
  Widget _row(PersonalEvent e, bool openable) {
    final line = Row(
      children: [
        Expanded(child: Text(eventConflictSummary(e), style: kWarnFactStyle)),
        if (openable) ...[
          const SizedBox(width: 8),
          const Icon(Icons.chevron_right, size: 26, color: kWarnTitle),
        ],
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(top: 7),
      child: openable
          ? GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onOpenEvent!(e),
              child: line,
            )
          : line,
    );
  }
}
