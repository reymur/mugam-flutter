import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../core/theme/colors.dart';
import '../../../core/time/az_date_format.dart';
import '../../../firebase/firestore_service.dart';
import '../../../firebase/models.dart';
import '../../../shared/widgets/event_conflict_banner.dart';
import '../../../shared/widgets/event_conflict_dialog.dart';
import '../../../shared/widgets/event_notes_picker.dart';
import '../../../shared/widgets/wheel_date_time_picker.dart';
import '../../agreements/screens/agreements_screen.dart';

// Лист «İş təklif et» / «Tarix dəyiş» из плашки переговоров
// (chat_screen.dart): дата, тип, место и заметки предложенной работы,
// уходящие ОДНОЙ записью в документ чата (FirestoreService.setJobOffer /
// saveChatEventDate) через onSave. Настоящего `personalEvent` здесь ещё
// нет — он появляется только когда получатель согласится (Cloud Function
// onChatUpdated).
//
// Лист служит ДВУМ моментам, и различает их только подписями (пункт 3
// плана):
//   - создание предложения — «İş təklifi» / «Təklifi göndər»;
//   - правка уже отправленного — «Tədbir tarixi» / «Yadda saxla».
// Разными виджетами их разводить нечего: поля, умолчания и проверки
// совпадают полностью, различается только то, что человек делает этим
// действием. Подписи обязаны быть разными: «сохранить дату» и «отправить
// предложение» — не одно и то же, и во втором случае человек должен
// понимать, что нажатие уйдёт другому человеку.
//
// ---------------------------------------------------------------------------
// ЧЕМ ЭТОТ ЛИСТ ОТЛИЧАЕТСЯ ОТ КАЛЕНДАРНОГО ОКНА И ПОЧЕМУ
// ---------------------------------------------------------------------------
// Прежняя редакция этого комментария говорила только, что лист «намеренно
// не построен на _EventFormModal из-за участников и проверки конфликтов».
// Обоснование покрывало две вещи из десяти, а по факту разошлось почти
// всё: у листа не было ни формы одежды, ни заголовков разделов, ни
// закреплённых шапки и кнопок. Отличия были не решением, а недосмотром, и
// **выглядели** намеренными ровно потому, что рядом стояло слово
// «намеренно». Отсюда правило для этого файла: расхождение с календарным
// окном либо перечислено ниже с причиной, либо считается ошибкой.
//
// Сегодня разошлось ровно две вещи, обе с причиной:
//
// 1. УЧАСТНИКОВ НЕТ. В календаре мероприятие можно раздать кому угодно, и
//    там есть поиск с чипами. Здесь стороны заданы самим чатом: один на
//    один их ровно двое, выбирать некого и добавить некого. Пустой раздел
//    «İŞTİRAKÇILAR» с единственным неудаляемым чипом был бы хуже, чем его
//    отсутствие.
//
// 2. МЕСТО НЕОБЯЗАТЕЛЬНО. В календаре без места не сохранить, и это верно
//    там: туда записывают уже состоявшуюся договорённость. Предложение же
//    часто уходит РАНЬШЕ, чем известна площадка, и требование заполнить
//    поле заставляло бы человека выдумывать значение. Поэтому «Yer» и
//    «Qeydlər» подписаны «vacib deyil» прямым текстом — раньше о том, что
//    их можно пропустить, не было сказано нигде.
//
// Всё остальное общее и обязано таким остаться:
//
// - ФОРМА ОДЕЖДЫ и склейка заметок — общий виджет
//   (shared/widgets/event_notes_picker.dart). Не «похожий список», а тот
//   же самый: заметки лежат в базе одной строкой через `', '`, договор
//   создаётся ИЗ ЭТОГО ЛИСТА, а правится в календарной карточке. Разойдись
//   список пунктов хоть на символ — выбранное здесь перестало бы
//   опознаваться там и молча уехало бы в свободный текст, без единой
//   ошибки. Тот же класс, что дублирование превью (B16).
// - ПРОВЕРКА КОНФЛИКТА и её диалог — общий
//   (shared/widgets/event_conflict_dialog.dart). Причина, по которой она
//   тут нужна не меньше, чем в календаре: музыкант предлагает дату, на
//   которой у него уже стоит мероприятие, вторая сторона соглашается — и
//   он оказывается в двух местах разом, а выясняется это в день события.
//   Прежнее обоснование («конфликты не осмысленны для переговоров двоих»)
//   было неверным: осмысленны, и именно здесь.
// - РАЗМЕТКА — во весь экран, с закреплёнными шапкой и кнопками и
//   скроллящейся серединой. Лист по высоте содержимого выглядел урезанной
//   версией того же окна, и человек читал это как «мне дали что-то
//   неполное».
//
// Список событий берётся ПРОВАЙДЕРАМИ, а не копией в конструкторе: копия
// на момент открытия листа устарела бы ровно так же, как устаревала
// карточка договора до N23, а тут цена ошибки выше — пропущенный конфликт
// это два мероприятия на одно время.
// ---------------------------------------------------------------------------
// ЧАС ПО УМОЛЧАНИЮ — ОДНО ИМЯ НА ДВА ВЫЗОВА
// ---------------------------------------------------------------------------
// Лист, открытый без даты, ставит «завтра в 19:00». Вход из календаря даёт
// ДЕНЬ и не даёт часа — час ему надо откуда-то взять.
//
// Взять его «тоже 19:00» в общей точке вызова значило бы записать одно
// решение двумя числами. Они совпадают сегодня и разойдутся в тот день,
// когда умолчание листа поправят: календарь продолжит слать 19:00, и никто
// не заметит — оба значения останутся законными числами. Это I22 дословно
// (связанные значения получают ОДНО имя) и родня N74, где два места
// считали одно и то же по-своему.
//
// Поэтому час объявлен здесь, рядом с листом, чьё это умолчание, а
// календарь зовёт `jobOfferDateOnDay` и своего числа не имеет вовсе.
const int kJobOfferDefaultHour = 19;
const int kJobOfferDefaultMinute = 0;

/// Умолчание листа, открытого без даты: завтра в тот самый час.
DateTime jobOfferDefaultDate(DateTime now) => DateTime(
      now.year,
      now.month,
      now.day + 1,
      kJobOfferDefaultHour,
      kJobOfferDefaultMinute,
    );

/// Тот же час, но на дне, который назвал вход (вкладка «Təqvim» или
/// дневной экран). Дата приходит целиком, время из неё не берётся: у дня
/// в календаре часа нет, а полночь означала бы «мероприятие в 00:00».
DateTime jobOfferDateOnDay(DateTime day) => DateTime(
      day.year,
      day.month,
      day.day,
      kJobOfferDefaultHour,
      kJobOfferDefaultMinute,
    );

/// Можно ли ещё предложить работу НА ЭТОТ ДЕНЬ.
///
/// Спрашивают экраны, у которых вход привязан к дню: календарь (там день
/// бывает прошлым — месяцы листаются назад) и дневной экран (там день
/// сегодняшний, но час умолчания к вечеру уже позади).
///
/// **Правило живёт здесь, а не на экранах, по той же причине, что и сам
/// час:** оно СЧИТАЕТСЯ из него. Спроси экран «а не прошло ли 19:00»
/// своим числом — и получится третье место, где записано одно решение.
/// Экран задаёт вопрос, ответ считает тот, кто знает час.
///
/// Точка вызова предложения проверяет то же самое ещё раз и отказывает
/// словами. Это не дубль по недосмотру: экран прячет кнопку, чтобы не
/// вести в тупик, а проверка в точке вызова защищает ВСЕ входы, включая
/// те, которых ещё нет.
bool canOfferOnDay(DateTime day, DateTime now) =>
    !jobOfferDateOnDay(day).isBefore(now);

class JobOfferDateSheet extends ConsumerStatefulWidget {
  final DateTime? initialDate;
  final String? initialType;
  final String? initialLocation;
  final String? initialNotes;
  final String title;
  final String submitLabel;

  /// Чей календарь проверяется на занятость — тот, кто предлагает работу.
  /// Второй стороны здесь нет намеренно: её события нам не видны, и
  /// обещать «у него свободно» мы не вправе.
  final String currentUid;

  final void Function(
    DateTime date,
    String type,
    String location,
    String notes,
  )
  onSave;

  const JobOfferDateSheet({
    super.key,
    this.initialDate,
    this.initialType,
    this.initialLocation,
    this.initialNotes,
    this.title = 'Tədbir tarixi',
    this.submitLabel = 'Yadda saxla',
    required this.currentUid,
    required this.onSave,
  });

  @override
  ConsumerState<JobOfferDateSheet> createState() => _JobOfferDateSheetState();
}

class _JobOfferDateSheetState extends ConsumerState<JobOfferDateSheet> {
  static const _eventTypes = ['Toy', 'Konsert', 'Bayram', 'Digər'];

  late DateTime _selectedDate;
  late String _selectedType;
  late EventNotesValue _notes;
  late final TextEditingController _locationController;

  // Время, которое человек сам объявил занятым, нажав «Yeni tədbir» в
  // диалоге конфликта. До тех пор, пока он не сдвинет колесо, отправка
  // заблокирована: он попросил выбрать другое время, и «всё равно
  // отправить» противоречило бы его же ответу.
  //
  // Поле ОДНО, и только на минуту. Запрета на целый день больше нет:
  // владелец 03.08 переиграл прежнее правило — «Yeni tədbir» на занятый
  // ДЕНЬ теперь просто отправляет, потому что дневное мероприятие и
  // вечерний той в одну дату это обычная жизнь, а не ошибка. Запирать
  // остаётся только точное совпадение минуты, где человек оказался бы в
  // двух местах разом.
  //
  // Прежнее поле `_blockedDay` удалено, а не оставлено «на будущее»: его
  // никто больше не выставлял бы, а читаемое-но-никогда-не-записываемое
  // поле — ровно та ловушка, что уже выпалывалась дважды (`completed`,
  // `readBy`).
  DateTime? _blockedTime;

  final _scrollController = ScrollController();
  final _warningKey = GlobalKey();

  // Дата, с которой лист открылся. Нужна ровно для одного — отличить
  // «человек ВЫБРАЛ прошлое» от «лист открыт на давнем предложении, чья
  // дата уже прошла»: во втором случае запрет запер бы его в углу,
  // требуя сдвинуть дату ради правки соседнего поля.
  late final DateTime _openedWithDate;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _selectedDate = widget.initialDate ?? jobOfferDefaultDate(now);
    _selectedType = widget.initialType ?? _eventTypes.first;
    _notes = EventNotesValue.parse(widget.initialNotes ?? '');
    _locationController = TextEditingController(
      text: widget.initialLocation ?? '',
    );
    _openedWithDate = _selectedDate;
  }

  @override
  void dispose() {
    _locationController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // Дата в прошлом. Проверка на отправке, а не запретом в колесе:
  // WheelDateTimePicker общий с календарём договоров, где прошлая дата
  // осмысленна (событие можно записать задним числом), и сужать его ради
  // этого экрана значило бы менять поведение там, куда мы не смотрим.
  //
  // Запрещается именно ВЫБОР прошлой даты, а не сохранение вообще: если
  // лист открыли на давно отправленном предложении, чья дата уже прошла,
  // и правят в нём только место — запрет на сохранение запер бы человека
  // в углу, требуя сдвинуть дату ради правки соседнего поля. Поэтому
  // сравнение с тем, с чем лист открылся, а не голое `isBefore(now)`.
  bool get _pastDatePicked =>
      _selectedDate != _openedWithDate && _selectedDate.isBefore(DateTime.now());

  bool get _isTimeBlocked =>
      isConflictTimeBlocked(_selectedDate, _blockedTime);

  /// Свои мероприятия — и те, где человек владелец, и те, куда его
  /// позвали. Дедуп по id обязателен: владелец числится и в собственном
  /// массиве участников, поэтому его события приходят обоими потоками.
  /// Ровно та же пара источников и то же правило, что на экране договоров
  /// (`agreementEventsById`).
  List<PersonalEvent> get _myEvents {
    final own = ref.watch(personalEventsProvider(widget.currentUid)).asData
            ?.value ??
        const <PersonalEvent>[];
    final invited = ref
            .watch(eventsAsParticipantProvider(widget.currentUid))
            .asData
            ?.value ??
        const <PersonalEvent>[];
    final byId = <String, PersonalEvent>{
      for (final e in own) e.id: e,
      for (final e in invited) e.id: e,
    };
    return byId.values.toList();
  }

  /// Правила «что считается занятым» — общие с календарём
  /// (`shared/widgets/event_conflict_banner.dart`). Здесь только вызовы:
  /// разойдись эти два экрана в самом правиле, одинаковый вид плашки уже
  /// ничего бы не значил.
  List<PersonalEvent> _eventsOnDay(DateTime when, List<PersonalEvent> events) =>
      conflictEventsOnDay(when, events);

  /// ВСЕ, кто занял эту минуту, а не первый из них (N51). Лист ничего не
  /// переписывает и не удаляет, поэтому пересчёта после разбора здесь нет
  /// — но показать человеку обязан всё: наблюдалось 07.08, что на одну
  /// минуту встают своё мероприятие и чужое, где он участник, а окно
  /// называло одно.
  List<PersonalEvent> _conflictsAt(DateTime when, List<PersonalEvent> events) =>
      exactConflictsAt(when, events);

  /// Ровно тот же круг, что в календаре (`_showConflictFlow`): посмотреть
  /// мероприятие → вернуться и снова спросить; заменить → отправить как
  /// есть; новое → заблокировать это время и заставить выбрать другое.
  /// Второй диалог не изобретается намеренно — вопрос у человека один и
  /// тот же, откуда бы он в него ни пришёл.
  ///
  /// Передаются ВСЕ мешающие мероприятия, а не первое: при нескольких в
  /// дне диалог показывает их списком с переключателем, и «то самое»
  /// выбирает человек. Раньше сюда уходил `.first`, то есть вопрос
  /// задавался про произвольное из них.
  Future<void> _showConflictFlow(
    List<PersonalEvent> conflicts, {
    required bool exactTime,
  }) async {
    if (!mounted) return;
    if (conflicts.isEmpty) return;
    final answer = await showDialog<EventConflictChoice>(
      context: context,
      builder: (_) => EventConflictDialog(
        conflicts: conflicts,
        currentUid: widget.currentUid,
      ),
    );
    if (!mounted || answer == null) return;
    if (answer.action == 'replace') {
      _commit();
    } else if (answer.action == 'new') {
      // «Yeni tədbir» — «это отдельное мероприятие, отправляй как есть».
      //
      // Минуты не совпадают (занят лишь день) — два мероприятия в один
      // день обычное дело, мешать нечему: отправляем. Запрет остаётся
      // только на точное совпадение минуты, где человек оказался бы в
      // двух местах разом.
      //
      // Прежнее правило («занят день → занят весь день») переиграно
      // владельцем 03.08: оно запирало обычный случай — дневное
      // мероприятие и вечерний той в одну дату.
      if (!exactTime) {
        _commit();
        return;
      }
      setState(() => _blockedTime = _selectedDate);
      await _scrollToWarning();
    } else if (answer.action == 'view') {
      await _openConflictEvent(answer.event);
      if (!mounted) return;
      // Человек вернулся — вопрос остался, спрашиваем снова. Этим ответ
      // «Bax» и отличается от стрелки в самом предупреждении: там вопрос
      // ещё не задан, и возвращать человека не к чему.
      await _showConflictFlow(conflicts, exactTime: exactTime);
    }
  }

  Future<void> _scrollToWarning() async {
    // Пауза — чтобы предупреждение успело появиться в дереве: до
    // setState его контекста ещё нет, и прокручивать не к чему.
    await Future.delayed(const Duration(milliseconds: 50));
    if (!mounted) return;
    final ctx = _warningKey.currentContext;
    // Проверяется живость ИМЕННО этого контекста, а не только State:
    // предупреждение могло уйти из дерева, пока мы ждали, — например
    // человек в те же миллисекунды сдвинул колесо и снял запрет.
    if (ctx == null || !ctx.mounted) return;
    await Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOut,
      alignment: 0.5,
    );
  }

  void _commit() {
    widget.onSave(
      _selectedDate,
      _selectedType,
      _locationController.text.trim(),
      _notes.joined,
    );
    Navigator.pop(context);
  }

  Future<void> _submit() async {
    if (_pastDatePicked) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Keçmiş tarix seçilə bilməz'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    // Человек сам сказал «выберу другое» — пока не сдвинул, отправка
    // молчит и показывает, почему.
    if (_isTimeBlocked) {
      await _scrollToWarning();
      return;
    }
    final events = _myEvents;
    // Точное совпадение спрашивается первым: оно строже и говорит человеку
    // больше, чем «на этот день что-то есть».
    final exact = _conflictsAt(_selectedDate, events);
    if (exact.isNotEmpty) {
      await _showConflictFlow(exact, exactTime: true);
      return;
    }
    final sameDay = _eventsOnDay(_selectedDate, events);
    if (sameDay.isNotEmpty) {
      await _showConflictFlow(sameDay, exactTime: false);
      return;
    }
    _commit();
  }

  InputDecoration _fieldDecoration(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(color: kMuted),
    filled: true,
    fillColor: kBg3,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: kBorder),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: kBorder),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: kGold),
    ),
  );

  static const _sectionLabel = TextStyle(
    fontSize: 11,
    letterSpacing: 0.8,
    color: kMuted,
    fontWeight: FontWeight.w600,
  );

  /// Открыть экран мероприятия. Один путь и для ответа «Bax» в диалоге, и
  /// для стрелки в предупреждении — иначе два входа на один экран
  /// разъехались бы по составу данных, как уже случалось с копиями в
  /// пушевом маршруте (N23).
  Future<void> _openConflictEvent(PersonalEvent e) async {
    final allUsers =
        ref.read(allUsersProvider).asData?.value ?? const <User>[];
    if (!mounted) return;
    await Navigator.of(context).push(
      agreementConflictEventRoute(
        event: e,
        currentUid: widget.currentUid,
        allUsers: allUsers,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    // Живой конфликт на выбранное время — считается на каждой
    // перерисовке, то есть предупреждение появляется ПРИ ВЫБОРЕ даты, а не
    // только после нажатия «отправить». Диалог при этом не всплывает: он
    // спрашивает, что делать, и на каждый щелчок колеса такой вопрос был
    // бы издевательством.
    //
    // Правила «что показать и в каком порядке» — общие с календарным окном
    // (shared/widgets/event_conflict_banner.dart). Здесь только вызов.
    final banner = resolveConflictBanner(
      selectedDate: _selectedDate,
      events: _myEvents,
      blockedTime: _blockedTime,
      pastDate: _pastDatePicked,
    );

    // Обёртки PopScope здесь больше нет, и это снятие целиком, а не
    // наполовину.
    //
    // Она существовала ради вопроса «Dəyişikliklər itəcək» при закрытии.
    // Вопрос снят решением владельца 04.08, а сама обёртка перехватывала
    // только СИСТЕМНЫЙ возврат: закрытие свайпом зовёт `Navigator.pop`
    // напрямую, и PopScope его не видит (разбор — в реестре, «PopScope не
    // видит программный pop»). Оставлять её значило бы держать код,
    // который ничего не делает, — то же, что уже выпалывалось с `onSaved`
    // и `cancelPending`.
    //
    // Случайную потерю введённого закрывает не вопрос, а запрет на
    // закрытие тапом по фону (`chat_screen.dart` → `isDismissible: false`).
    return Container(
        margin: EdgeInsets.only(top: 60, bottom: bottomInset),
        decoration: const BoxDecoration(
          color: kBg2,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        // Шапка (заголовок, типы, дата) и кнопки внизу закреплены, скроллится
        // только середина — иначе заголовок и кнопка отправки уезжают вверх
        // вместе с содержимым, и человек теряет из виду, что он вообще
        // делает. Один в один с календарным окном.
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Text(
                      widget.title,
                      style: GoogleFonts.nunito(
                        fontSize: 18,
                        color: kText,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _eventTypes.map((t) {
                      final sel = _selectedType == t;
                      return GestureDetector(
                        onTap: () => setState(() => _selectedType = t),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: sel ? kGold : kBg3,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: sel ? kGold : kBorder),
                          ),
                          child: Text(
                            t,
                            style: TextStyle(
                              color: sel ? kOnGold : kMuted,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 12),
                  Center(
                    child: Text(
                      '${_selectedDate.day} '
                      '${azMonthFull(_selectedDate.month)} '
                      '${_selectedDate.year}',
                      style: const TextStyle(
                        color: kGold,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    WheelDateTimePicker(
                      value: _selectedDate,
                      onChanged: (d) => setState(() {
                        _selectedDate = d;
                        // Человек сдвинул — его же просьба «дай выбрать
                        // другое» исполнена, запрет снимается сам. Каждый
                        // запрет снимается своим действием: запрет на
                        // минуту — сдвигом времени, запрет на день —
                        // сменой дня.
                        if (_blockedTime != null &&
                            (d.hour != _blockedTime!.hour ||
                                d.minute != _blockedTime!.minute)) {
                          _blockedTime = null;
                        }
                      }),
                    ),
                    if (banner != null) ...[
                      const SizedBox(height: 8),
                      EventConflictBanner(
                        key: _warningKey,
                        title: banner.title,
                        detail: banner.detail,
                        events: banner.events,
                        onOpenEvent: _openConflictEvent,
                      ),
                    ],
                    const SizedBox(height: 16),
                    const Text('MƏKAN', style: _sectionLabel),
                    const SizedBox(height: 8),
                    // «vacib deyil» в подсказке — прямым текстом. Раньше о
                    // том, что эти поля можно пропустить, не было сказано
                    // нигде, и человек не знал, обязан он их заполнить или
                    // нет. Дата и тип такой пометки не несут намеренно:
                    // пустыми они не бывают по устройству контролов, значит
                    // и вопроса не возникает.
                    TextField(
                      controller: _locationController,
                      style: const TextStyle(color: kText, fontSize: 14),
                      onChanged: (_) => setState(() {}),
                      decoration: _fieldDecoration('Yer (vacib deyil)'),
                    ),
                    const SizedBox(height: 16),
                    EventNotesPicker(
                      value: _notes,
                      onChanged: (v) => setState(() => _notes = v),
                    ),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      // maybePop, а не pop: иначе кнопка «отмена» унесла бы
                      // введённое мимо того же вопроса, который задаёт свайп.
                      onPressed: () => Navigator.maybePop(context),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: kMuted,
                        side: const BorderSide(color: kBorder),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text('Ləğv et'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: kGold,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: _submit,
                      child: Text(
                        widget.submitLabel,
                        style: const TextStyle(
                          // Кнопка залита kGold — значит kOnGold, как и
                          // все остальные золотые кнопки. Стоял чистый
                          // чёрный: проход 08.08 его пропустил, потому
                          // что заливка выше по коду и не попала в окно
                          // поиска.
                          color: kOnGold,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
    );
  }
}
