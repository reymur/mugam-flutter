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
  DateTime? _blockedTime;

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

  /// Совпадение с точностью до минуты — то же правило, что в календаре.
  /// Отменённые не считаются: договор со статусом `cancelled` времени
  /// человека уже не занимает, и предупреждать о нём значило бы держать
  /// его занятым навсегда.
  PersonalEvent? _conflictAt(DateTime when, List<PersonalEvent> events) {
    for (final e in events) {
      if (e.date.isEmpty) continue;
      if (e.status == 'cancelled') continue;
      try {
        final d = DateTime.parse(e.date);
        if (d.year == when.year &&
            d.month == when.month &&
            d.day == when.day &&
            d.hour == when.hour &&
            d.minute == when.minute) {
          return e;
        }
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
  Future<void> _showConflictFlow(PersonalEvent conflict) async {
    if (!mounted) return;
    final answer = await showDialog<String>(
      context: context,
      builder: (_) => EventConflictDialog(conflict: conflict),
    );
    if (!mounted) return;
    if (answer == 'replace') {
      _commit();
    } else if (answer == 'new') {
      setState(() => _blockedTime = _selectedDate);
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
      await _showConflictFlow(conflict);
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
    // Человек сам сказал «выберу другое время» — пока не сдвинул, отправка
    // молчит и показывает, почему.
    if (_isTimeBlocked) {
      await _scrollToWarning();
      return;
    }
    final conflict = _conflictAt(_selectedDate, _myEvents);
    if (conflict != null) {
      await _showConflictFlow(conflict);
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

  Widget _warningBanner({required Key key, required String text}) => Container(
    key: key,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: kRed.withAlpha(25),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: kRed.withAlpha(80)),
    ),
    child: Text(
      text,
      style: const TextStyle(
        color: kRed,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    // Живой конфликт на выбранное время — считается на каждой перерисовке,
    // то есть предупреждение появляется ПРИ ВЫБОРЕ даты, а не только после
    // нажатия «отправить». Диалог при этом не всплывает: он спрашивает, что
    // делать, и на каждый щелчок колеса такой вопрос был бы издевательством.
    final liveConflict = _conflictAt(_selectedDate, _myEvents);

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
                        // Человек сдвинул время — его же просьба «дай
                        // выбрать другое» исполнена, запрет снимается сам.
                        if (_blockedTime != null &&
                            (d.hour != _blockedTime!.hour ||
                                d.minute != _blockedTime!.minute)) {
                          _blockedTime = null;
                        }
                      }),
                    ),
                    if (_isTimeBlocked) ...[
                      const SizedBox(height: 8),
                      _warningBanner(
                        key: _warningKey,
                        text:
                            '⚠️ ${_blockedTime!.hour.toString().padLeft(2, '0')}:'
                            '${_blockedTime!.minute.toString().padLeft(2, '0')} '
                            'artıq məşğuldur — zəhmət olmasa başqa vaxt seçin',
                      ),
                    ] else if (liveConflict != null) ...[
                      const SizedBox(height: 8),
                      _warningBanner(
                        key: _warningKey,
                        text: '⚠️ Bu vaxtda sizin tədbiriniz var'
                            '${liveConflict.type.isNotEmpty ? ' — ${liveConflict.type}' : ''}',
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
