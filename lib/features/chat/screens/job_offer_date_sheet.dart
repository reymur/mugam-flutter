import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../core/theme/colors.dart';
import '../../../core/time/az_date_format.dart';
import '../../../firebase/firestore_service.dart';
import '../../../firebase/models.dart';
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
  // Два поля, а не одно, потому что и конфликты бывают двух видов: точное
  // совпадение минуты и занятый день. Ответив «Yeni tədbir» на занятый
  // день, человек просит другой ДЕНЬ — снимать такой запрет сдвигом
  // времени внутри того же дня было бы подменой его ответа.
  DateTime? _blockedTime;
  DateTime? _blockedDay;

  final _scrollController = ScrollController();
  final _warningKey = GlobalKey();

  // Снимок начального состояния — по нему и только по нему решается,
  // спрашивать ли при закрытии. Хранится отдельно от widget.initial*,
  // потому что там половина значений null, а сравнивать надо с тем, что
  // человек реально увидел открытым, включая умолчания.
  late final DateTime _openedWithDate;
  late final String _openedWithType;
  late final String _openedWithNotes;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _selectedDate =
        widget.initialDate ??
        DateTime(now.year, now.month, now.day + 1, 19, 0);
    _selectedType = widget.initialType ?? _eventTypes.first;
    _notes = EventNotesValue.parse(widget.initialNotes ?? '');
    _locationController = TextEditingController(
      text: widget.initialLocation ?? '',
    );
    _openedWithDate = _selectedDate;
    _openedWithType = _selectedType;
    _openedWithNotes = _notes.joined;
  }

  @override
  void dispose() {
    _locationController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // «Лист трогали» — любое отличие от того, с чем он открылся. Пустой
  // лист закрывается молча: вопрос на пустом месте раздражает не меньше,
  // чем потеря введённого, и быстро приучает жать «да» не глядя.
  bool get _isDirty =>
      _selectedDate != _openedWithDate ||
      _selectedType != _openedWithType ||
      _notes.joined != _openedWithNotes ||
      _locationController.text.trim() != (widget.initialLocation ?? '').trim();

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
      _blockedTime != null &&
      _selectedDate.hour == _blockedTime!.hour &&
      _selectedDate.minute == _blockedTime!.minute;

  bool get _isDayBlocked =>
      _blockedDay != null && _sameDay(_selectedDate, _blockedDay!);

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

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

  /// Все свои мероприятия на выбранный ДЕНЬ, по возрастанию времени.
  /// Отменённые не считаются: договор со статусом `cancelled` времени
  /// человека уже не занимает, и предупреждать о нём значило бы держать
  /// день занятым навсегда.
  ///
  /// Почему проверяется день, а не только минута. В календаре человек
  /// видит дату целиком и сам понимает, занята она или нет. Здесь он видит
  /// только колесо — и о том, что на этот день у него уже что-то есть,
  /// не узнаёт вовсе, пока не совпадёт минута в минуту. А совпадения минут
  /// в жизни почти не бывает: мешает не одинаковое время, а второй тədbir
  /// в тот же день.
  List<PersonalEvent> _eventsOnDay(DateTime when, List<PersonalEvent> events) {
    final out = <({PersonalEvent event, DateTime at})>[];
    for (final e in events) {
      if (e.date.isEmpty) continue;
      if (e.status == 'cancelled') continue;
      try {
        final d = DateTime.parse(e.date);
        if (_sameDay(d, when)) out.add((event: e, at: d));
      } catch (_) {
        continue;
      }
    }
    out.sort((a, b) => a.at.compareTo(b.at));
    return out.map((x) => x.event).toList();
  }

  /// Совпадение с точностью до минуты — то же правило, что в календаре.
  PersonalEvent? _conflictAt(DateTime when, List<PersonalEvent> events) {
    for (final e in _eventsOnDay(when, events)) {
      try {
        final d = DateTime.parse(e.date);
        if (d.hour == when.hour && d.minute == when.minute) return e;
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  Future<bool> _confirmDiscard() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: kBg2,
        title: const Text(
          'Dəyişikliklər itəcək',
          style: TextStyle(color: kText),
        ),
        content: const Text(
          'Yazdıqlarınız saxlanılmayacaq. Çıxmaq istəyirsiniz?',
          style: TextStyle(color: kMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Geri', style: TextStyle(color: kMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Çıx', style: TextStyle(color: kRed)),
          ),
        ],
      ),
    );
    return ok == true;
  }

  /// Ровно тот же круг, что в календаре (`_showConflictFlow`): посмотреть
  /// мероприятие → вернуться и снова спросить; заменить → отправить как
  /// есть; новое → заблокировать это время и заставить выбрать другое.
  /// Второй диалог не изобретается намеренно — вопрос у человека один и
  /// тот же, откуда бы он в него ни пришёл.
  Future<void> _showConflictFlow(
    PersonalEvent conflict, {
    required bool exactTime,
  }) async {
    if (!mounted) return;
    final answer = await showDialog<String>(
      context: context,
      builder: (_) => EventConflictDialog(conflict: conflict),
    );
    if (!mounted) return;
    if (answer == 'replace') {
      _commit();
    } else if (answer == 'new') {
      // Запрет ставится ровно на то, о чём спрашивали: совпала минута —
      // занята минута, занят день — занят день. Иначе ответ «выберу
      // другое» снимался бы действием, которого человек не делал.
      setState(() {
        if (exactTime) {
          _blockedTime = _selectedDate;
        } else {
          _blockedDay = _selectedDate;
        }
      });
      await _scrollToWarning();
    } else if (answer == 'view') {
      final allUsers = ref.read(allUsersProvider).asData?.value ?? const <User>[];
      await Navigator.of(context).push(
        agreementConflictEventRoute(
          event: conflict,
          currentUid: widget.currentUid,
          allUsers: allUsers,
        ),
      );
      // Человек вернулся — вопрос остался, спрашиваем снова.
      await _showConflictFlow(conflict, exactTime: exactTime);
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
    if (_isTimeBlocked || _isDayBlocked) {
      await _scrollToWarning();
      return;
    }
    final events = _myEvents;
    // Точное совпадение спрашивается первым: оно строже и говорит человеку
    // больше, чем «на этот день что-то есть».
    final exact = _conflictAt(_selectedDate, events);
    if (exact != null) {
      await _showConflictFlow(exact, exactTime: true);
      return;
    }
    final sameDay = _eventsOnDay(_selectedDate, events);
    if (sameDay.isNotEmpty) {
      await _showConflictFlow(sameDay.first, exactTime: false);
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

  // Предупреждение о занятом времени. Две строки, а не одна: заголовок
  // отвечает «что не так», подпись — «чем именно занято». Одной строкой
  // это читалось сплошняком и на узком экране переносилось посреди
  // названия мероприятия.
  //
  // Значок вынесен в свой кружок слева, а не приклеен к тексту эмодзи:
  // эмодзи внутри строки уезжает вместе с переносом и теряет смысл
  // «отметка на полях».
  Widget _warningBanner({
    required Key key,
    required String title,
    required String detail,
  }) => Container(
    key: key,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: kRed.withAlpha(22),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: kRed.withAlpha(90)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: kRed.withAlpha(45),
            shape: BoxShape.circle,
          ),
          child: const Text('!', style: TextStyle(
            color: kRed,
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
                  color: kRed,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  height: 1.25,
                ),
              ),
              if (detail.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  detail,
                  style: TextStyle(
                    color: kRed.withAlpha(200),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    height: 1.3,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    ),
  );

  /// «Toy · 17:20 · Bakı» — из того, что у мероприятия вообще заполнено.
  /// Пустые части не оставляют висящих разделителей.
  String _eventSummary(PersonalEvent e) => [
    if (e.type.isNotEmpty) e.type,
    if (fmtEventTime(e.date).isNotEmpty) fmtEventTime(e.date),
    if (e.location.isNotEmpty) e.location,
  ].join(' · ');

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    // Живой конфликт на выбранное время — считается на каждой перерисовке,
    // то есть предупреждение появляется ПРИ ВЫБОРЕ даты, а не только после
    // нажатия «отправить». Диалог при этом не всплывает: он спрашивает, что
    // делать, и на каждый щелчок колеса такой вопрос был бы издевательством.
    // Что показать над «MƏKAN». Четыре случая, и они не равнозначны:
    // запреты («я сам попросил другое») старше находок, а точное
    // совпадение минуты старше занятого дня — оно говорит больше.
    final events = _myEvents;
    final exact = _conflictAt(_selectedDate, events);
    final onDay = _eventsOnDay(_selectedDate, events);
    final ({String title, String detail})? banner;
    if (_isTimeBlocked) {
      banner = (
        title:
            '${_blockedTime!.hour.toString().padLeft(2, '0')}:'
            '${_blockedTime!.minute.toString().padLeft(2, '0')} artıq məşğuldur',
        detail: 'Zəhmət olmasa başqa vaxt seçin',
      );
    } else if (_isDayBlocked) {
      banner = (
        title: 'Bu gün məşğuldur',
        detail: 'Zəhmət olmasa başqa gün seçin',
      );
    } else if (exact != null) {
      banner = (
        title: 'Bu vaxtda sizin tədbiriniz var',
        detail: _eventSummary(exact),
      );
    } else if (onDay.isNotEmpty) {
      // Занятый день — то, чего в листе не было видно вовсе: совпадение
      // минута в минуту в жизни почти не случается, мешает второй тədbir
      // в тот же день. В календаре это видно самой сеткой, здесь — нет.
      banner = (
        title: onDay.length == 1
            ? 'Bu gün sizin tədbiriniz var'
            : 'Bu gün sizin ${onDay.length} tədbiriniz var',
        detail: onDay.map(_eventSummary).join('\n'),
      );
    } else {
      banner = null;
    }

    // canPop: false плюс ручной pop — единственный способ перехватить и
    // свайп вниз, и системную «назад» одинаково. Без этого свайп уносит
    // введённое молча, что и записано в плане как отдельное раздражение.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        // Навигатор берётся ДО await: после диалога ссылаться на context
        // этого build уже нельзя, а State.mounted про него ничего не
        // говорит.
        final navigator = Navigator.of(context);
        if (_isDirty && !await _confirmDiscard()) return;
        if (mounted) navigator.pop();
      },
      child: Container(
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
                              color: sel ? const Color(0xFF1A0E00) : kMuted,
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
                        if (_blockedDay != null &&
                            !_sameDay(d, _blockedDay!)) {
                          _blockedDay = null;
                        }
                      }),
                    ),
                    if (banner != null) ...[
                      const SizedBox(height: 8),
                      _warningBanner(
                        key: _warningKey,
                        title: banner.title,
                        detail: banner.detail,
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
                          color: Colors.black,
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
      ),
    );
  }
}
