import 'package:firebase_auth/firebase_auth.dart' hide User;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/agreements/day_buckets.dart';
import '../../../core/theme/colors.dart';
import '../../../core/time/az_date_format.dart';
import '../../../core/time/event_local_time.dart';
import '../../../firebase/firestore_service.dart';
import '../../../firebase/models.dart';
import '../../agreements/screens/agreements_screen.dart';
import '../../job_offer/job_offer_entry.dart';
import '../../job_offer/screens/job_offer_date_sheet.dart';

/// Дневной экран — «что у меня сегодня».
///
/// Решение владельца, записанное в плане: сегодня и завтра сверху, неделя
/// ниже. **Открыл — увидел свой вечер за секунду, не листая.**
///
/// Что здесь было до 07.08: баннер «RƏSMİ KLUB» с двумя кнопками, ни одна
/// из которых ничего не делала, две секции с вшитыми майскими концертами
/// (в проде обе коллекции пусты — N61), вшитый бейдж «3» на колокольчике
/// (N64) и карточки музыкантов. Ушло всё, кроме музыкантов, а они уехали
/// на «Klub»: день отвечает на «что у меня», а не «кто есть в клубе».
///
/// **Форма — по макету `docs/design/mugam-1-esas.html`.** Из него взяты
/// раскладка и правило выделения: одна поверхность, карточек с заливкой
/// нет вовсе, важное отмечено вертикальной полоской слева. Цвета —
/// НЫНЕШНИЕ (решение владельца 07.08, вариант «в»): взять из макета его
/// нейтрально-серую палитру значило бы сделать один экран из тридцати
/// семи холоднее и светлее остальных до самой работы 7б.
class DayScreen extends ConsumerWidget {
  const DayScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final own = ref.watch(personalEventsProvider(uid)).asData?.value;
    final asParticipant = ref
        .watch(eventsAsParticipantProvider(uid))
        .asData
        ?.value;

    // Пока хоть один поток молчит — ждём. Показать «Bu gün boşsunuz» по
    // недошедшим данным значит соврать ровно тем ответом, ради честности
    // которого экран и переписан: пустота из кэша — это молчание, а не
    // ответ (N14, то же правило стоит в самих потоках).
    if (own == null || asParticipant == null) {
      return const Scaffold(
        backgroundColor: kBg,
        body: Center(child: CircularProgressIndicator(color: kGold)),
      );
    }

    final now = DateTime.now();
    final buckets = buildDayBuckets(
      own: own,
      asParticipant: asParticipant,
      now: now,
    );

    // СЕГОДНЯШНИЙ ДЕНЬ ЗАКРЕПЛЁН, ПРОКРУЧИВАЕТСЯ ТО, ЧТО ПОСЛЕ «BU HƏFTƏ»
    // (решение владельца 12.08).
    //
    // Прежде весь экран был одним списком: стоило посмотреть неделю, и
    // сегодняшний вечер уезжал вверх — а он здесь главный, ради него экран и
    // открывают («что у меня сегодня»). Теперь он и завтрашний блок стоят
    // неподвижно, а неделя живёт в своей прокрутке.
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 32, 22, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                fmtDayHeader(now),
                style: const TextStyle(fontSize: 15, color: kMuted),
              ),
              const SizedBox(height: 8),
              const Text(
                'Bu gün',
                style: TextStyle(
                  fontSize: 33,
                  color: kText,
                  fontWeight: FontWeight.w400,
                ),
              ),
              const SizedBox(height: 22),
              ..._todayBlock(buckets),
              // ВХОД В ПРЕДЛОЖЕНИЕ РАБОТЫ С ДНЕВНОГО ЭКРАНА (пункт 6,
              // `docs/plan.md`). Заведён вместе с календарным, а не после
              // него, по доводу владельца 09.08: «Bu gün» — первое, что
              // человек видит при запуске, и разговор «свободен девятого»
              // разбирается именно здесь. Отложенный вход появился бы через
              // неделю ВТОРЫМ путём к той же операции.
              //
              // Контекст тот же, что у календаря, — ОДНА ДАТА и ничего
              // больше. Экран знает и мероприятия дня вместе с их
              // участниками, но их сюда не передаётся ни одного: человек в
              // мероприятии — это не тот, кому предлагают работу, и стоило
              // бы взять его отсюда «раз уж он есть», как оба входа
              // перестали бы звать одну точку одинаково.
              // Кнопка исчезает, когда сегодняшний час умолчания уже
              // позади: иначе она вела бы в тупик — точка вызова законно
              // отказала бы «прошлой датой». Своего числа экран не знает,
              // вопрос задаётся тому, кто знает час (`canOfferOnDay`).
              if (canOfferOnDay(now, now)) ...[
                const SizedBox(height: 10),
                _OfferForTodayButton(day: now),
              ],
              ..._tomorrowBlock(buckets),
              // Неделя — в своей прокрутке. Всё выше остаётся на экране.
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 32),
                  children: _weekBlock(buckets),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _todayBlock(DayBuckets b) {
    if (b.today.isNotEmpty) {
      return [for (final e in b.today) _EventBar(event: e, accented: true)];
    }
    // Пустой день ОТВЕЧАЕТ. Экран, промолчавший в ответ на «что у меня
    // сегодня», читается как сломанный, а не как свободный.
    return [_EmptyAnswer(answer: emptyDayAnswer(b), next: b.next)];
  }

  List<Widget> _tomorrowBlock(DayBuckets b) {
    if (b.tomorrow.isEmpty) return const [];
    return [
      const _SectionLabel('SABAH'),
      // Полоска серая, а не золотая: завтра — не сегодня. Разница в
      // цвете полоски и есть вся разметка важности на этом экране.
      for (final e in b.tomorrow) _EventBar(event: e, accented: false),
    ];
  }

  List<Widget> _weekBlock(DayBuckets b) {
    // Семь строк «boş» подряд — не ответ, а семикратно повторённое
    // молчание. Поэтому пустая неделя целиком не рисуется вовсе: про неё
    // уже сказано выше, в ответе про пустой день.
    if (b.weekHasNothing) return const [];
    return [
      const _SectionLabel('BU HƏFTƏ'),
      for (final row in b.week) _WeekRow(row: row),
    ];
  }
}

/// «Предложить работу на сегодня» — вход, и только вход.
///
/// Отдельным виджетом, потому что `DayScreen` — `ConsumerWidget` без
/// состояния, а `ref` для вызова нужен здесь же; заодно кнопка не
/// перерисовывает список при нажатии.
class _OfferForTodayButton extends ConsumerWidget {
  const _OfferForTodayButton({required this.day});

  final DateTime day;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton(
        onPressed: () => proposeJobOffer(context, ref, onDay: day),
        style: TextButton.styleFrom(
          foregroundColor: kGold,
          padding: EdgeInsets.zero,
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: const Text(
          '📅 Bu günə iş təklif et',
          style: TextStyle(color: kGold, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 26, bottom: 12),
      child: Text(
        text,
        style: const TextStyle(fontSize: 13, letterSpacing: 1.5, color: kMuted),
      ),
    );
  }
}

/// Мероприятие карточкой с полоской слева.
///
/// **Что показывается и почему именно это** (требование владельца 07.08):
/// то, что нужно за секунду, — время, место, с кем. Не всё, что есть в
/// документе. Не хватит — человек откроет карточку; будет лишнее — он
/// начнёт читать экран вместо того, чтобы смотреть на него.
///
/// Поэтому здесь нет ни заметок, ни состояния договора, ни дат
/// согласования: они есть на самой карточке мероприятия.
class _EventBar extends ConsumerWidget {
  const _EventBar({required this.event, required this.accented});

  final PersonalEvent event;
  final bool accented;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final time = eventLocalDateTime(event.date);
    final names = _participantNames(ref, event);

    // ТАП ОТКРЫВАЕТ КАРТОЧКУ (N90). До этого он не делал НИЧЕГО:
    // обработчика не было вовсе, а карточка с полоской, временем и
    // именами читается как кнопка — и молчащий тап человек читает как
    // поломку, а не как «здесь ничего нет». Тот же довод, по которому
    // 07.08 сняли баннер с двумя мёртвыми кнопками (N65).
    //
    // Дверь общая (`eventDetailRoute`): она сама решает по документу,
    // договор это или мероприятие, и показывает нужную карточку. Экран
    // дня знает только id и себя — как и все входы этого захода.
    //
    // «Назад» ничего не требует: маршрут ПУШИТСЯ, и `Navigator.pop`
    // внутри карточки возвращает сюда же, на дневной экран. Возврат
    // сбросом поля состояния родителя остаётся только у той дороги, что
    // живёт внутри экрана договоров.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).push(
        eventDetailRoute(
          eventId: event.id,
          currentUid: FirebaseAuth.instance.currentUser?.uid ?? '',
        ),
      ),
      child: Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.only(left: 16, top: 2, bottom: 2),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: accented ? kGold : kBarOff, width: 4),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              time == null ? '' : fmtEventTime(event.date),
              style: TextStyle(fontSize: accented ? 23 : 21, color: kText),
            ),
            const SizedBox(height: 6),
            Text(
              // Тип и место одной строкой. Место — ОДНИМ полем: в макете
              // зал и город разведены («Toy · İnci Qarayev» / «Bakı ·
              // …»), а в данных это одна строка `location`, и в самой
              // форме правки она заполняется целиком — «İnci Qarayev,
              // Bakı». Разделять показом то, что не разделено в данных,
              // значит выдумывать.
              [
                event.type,
                if (event.location.isNotEmpty) event.location,
              ].join(' · '),
              style: TextStyle(
                fontSize: 17,
                color: accented ? kText : kTextSecondary,
              ),
            ),
            if (accented && names.isNotEmpty) ...[
              const SizedBox(height: 7),
              Text(names, style: const TextStyle(fontSize: 16, color: kMuted)),
            ],
          ],
        ),
      ),
    );
  }

  /// Имена участников, а не их uid-ы.
  ///
  /// Читаются по одному через `userByIdProvider` — семейство Riverpod,
  /// поэтому один и тот же человек в двух мероприятиях стоит одного
  /// чтения, а не двух. Имя не дошло — строка просто короче; ждать
  /// профили ради подписи под временем незачем.
  String _participantNames(WidgetRef ref, PersonalEvent e) {
    final me = FirebaseAuth.instance.currentUser?.uid;
    final others = e.participantUids.where((u) => u != me).toList();
    if (others.isEmpty) return '';
    final names = <String>[];
    for (final uid in others) {
      final user = ref.watch(userByIdProvider(uid)).asData?.value;
      if (user != null && user.name.isNotEmpty) names.add(user.name);
    }
    return names.join(', ');
  }
}

/// Строка недельного списка: дата слева, содержимое справа.
class _WeekRow extends StatelessWidget {
  const _WeekRow({required this.row});

  final DayRow row;

  @override
  Widget build(BuildContext context) {
    // Пустой день приглушён, но НЕ спрятан: спрятанный день заставил бы
    // человека считать даты в уме, чтобы понять, что 11-е свободно.
    final dim = row.isEmpty;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 13),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: kBg3, width: 1)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            fmtWeekRowDate(row.day),
            style: TextStyle(fontSize: 16, color: dim ? kTextDim : kText),
          ),
          Text(
            _content(row),
            style: TextStyle(
              fontSize: 16,
              color: dim ? kTextDim : kTextSecondary,
            ),
          ),
        ],
      ),
    );
  }

  /// Один — называется по имени, несколько — считаются числом.
  ///
  /// Перечислять три типа в строке шириной в треть экрана нечем, а
  /// «4 tədbir» отвечает на вопрос строки целиком: занят ли день и
  /// насколько.
  String _content(DayRow row) {
    if (row.events.isEmpty) return 'boş';
    if (row.events.length == 1) return row.events.first.type;
    return '${row.events.length} tədbir';
  }
}

/// Ответ на пустой день — три состояния, а не одно молчание.
class _EmptyAnswer extends StatelessWidget {
  const _EmptyAnswer({required this.answer, required this.next});

  final EmptyDayAnswer answer;
  final PersonalEvent? next;

  @override
  Widget build(BuildContext context) {
    final (title, note) = switch (answer) {
      EmptyDayAnswer.freeToday => ('Bu gün boşsunuz', null),
      EmptyDayAnswer.freeBothDays => ('Bu gün və sabah boşsunuz', _nextLine()),
      EmptyDayAnswer.calendarEmpty => ('Təqvim boşdur', null),
      // Сюда не приходит: блок зовётся только при пустом сегодня.
      EmptyDayAnswer.hasEventsToday => ('', null),
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 19, color: kTextSecondary),
          ),
          if (note != null) ...[
            const SizedBox(height: 8),
            Text(note, style: const TextStyle(fontSize: 16, color: kMuted)),
          ],
        ],
      ),
    );
  }

  String? _nextLine() {
    final e = next;
    if (e == null) return null;
    final day = eventDay(e.date);
    if (day == null) return null;
    return 'Növbəti: ${fmtWeekRowDate(day)}, ${e.type}';
  }
}
