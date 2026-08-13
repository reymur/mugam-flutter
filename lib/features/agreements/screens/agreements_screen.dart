import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart' hide User;
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../../../core/agreements/agreement_card.dart';
import '../../../core/agreements/event_answer_reply.dart';
import '../../../core/agreements/event_answers.dart';
import '../../../core/agreements/event_status_view.dart';
import '../../../core/agreements/event_edit.dart';
import '../../../core/search/user_search_controller.dart';
import '../../../core/theme/colors.dart';
import '../../../core/agreements/day_buckets.dart';
import '../../../core/agreements/event_lookup.dart';
import '../../../core/agreements/day_role.dart';
import '../../../core/agreements/month_marks.dart';
import '../../../core/time/az_date_format.dart';
import '../../day/screens/day_screen.dart';
import '../../../firebase/firestore_service.dart';
import '../../../firebase/models.dart';
import '../../../shared/widgets/answer_conflict_dialog.dart';
import '../../../shared/widgets/avatar_ring.dart';
import '../../../core/presence/presence_service.dart';
import '../../../shared/widgets/event_conflict_banner.dart';
import '../../../shared/widgets/event_conflict_dialog.dart';
import '../../../shared/widgets/event_notes_picker.dart';
import '../../../shared/widgets/wheel_date_time_picker.dart';
import '../../../shared/widgets/zoomable_image_viewer.dart';
import '../../job_offer/job_offer_entry.dart';
import '../../../core/job_offer/offer_draft.dart';
import '../../search/screens/filter_sheet.dart';
import '../../status/screens/status_viewer_screen.dart';
import '../../user/screens/user_profile_screen.dart';

// ---------------------------------------------------------------------------
// Azerbaijani month names
// ---------------------------------------------------------------------------
// Сами таблица месяцев и разбор даты события переехали в
// core/time/az_date_format.dart: их читает ещё и общий диалог конфликта,
// который показывает и этот экран, и лист предложения работы. Здесь
// оставлены короткие псевдонимы, чтобы не править девять мест вызова —
// но реализация одна, и разойтись копиям негде.
String _azMonth(int month) => azMonthFull(month);
String _fmtDate(String iso) => fmtEventDate(iso);
String _fmtTime(String iso) => fmtEventTime(iso);

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

// Cross-tab navigation signal: chat_screen.dart sets this to 'outgoing' or
// 'incoming' right before context.go('/agreements') when a job offer gets
// accepted, then AgreementsScreen (kept alive in the bottom-nav's
// IndexedStack, never rebuilt from scratch by a plain route switch) reacts
// via ref.listen and jumps itself to the Müqavilələr tab's matching side —
// a normal navigation wouldn't otherwise touch this already-mounted
// widget's own _mainView/_activeTab state at all.
class AgreementsTabRequestNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? value) => state = value;
}

final agreementsTabRequestProvider =
    NotifierProvider<AgreementsTabRequestNotifier, String?>(
      AgreementsTabRequestNotifier.new,
    );

// ---------------------------------------------------------------------------
// AgreementsScreen
// ---------------------------------------------------------------------------
class AgreementsScreen extends ConsumerStatefulWidget {
  // Set by "İş yazdır" (chat_screen.dart's 1:1 chat menu) to jump straight
  // into creating a new tədbir/agreement with that specific person already
  // selected as participant, instead of landing on the normal tab view.
  // null for this screen's usual home (bottom-nav "/agreements" tab).
  final String? initialParticipantUid;

  const AgreementsScreen({super.key, this.initialParticipantUid});

  @override
  ConsumerState<AgreementsScreen> createState() => _AgreementsScreenState();
}

class _AgreementsScreenState extends ConsumerState<AgreementsScreen> {
  // ДЕНЬ — вид по умолчанию с 07.08 (пункт 5 docs/plan.md, вариант «А»).
  //
  // Врезка, а не разбор: `agreements_screen` разбирается на маршруты
  // отдельной работой, и трогать его устройство сейчас значило бы делать
  // её наполовину. (Прежде она звалась «работа 8»; в порядке
  // `docs/plan.md` отдельным пунктом её НЕТ — ближайшее место пункт 14,
  // переезд договоров в календарь, который этот файл и переписывает.
  // Соответствие не назначено, назначить должен владелец.) Здесь добавлены ровно две вещи — закладка и ветка вида.
  //
  // Почему день живёт ЗДЕСЬ, а не отдельной вкладкой: день и календарь
  // месяца — один вопрос «когда я занят», заданный на разном расстоянии.
  // Разведи их по вкладкам панели — и человек будет прыгать между ними,
  // чтобы сверить вечер с месяцем.
  String _mainView = 'calendar'; // 'agreements' | 'calendar' | 'tedbirler'

  /// ДЕНЬ И МЕСЯЦ — ОДНА ЗАКЛАДКА, а не две.
  ///
  /// Первая редакция 07.08 поставила день ЧЕТВЁРТОЙ закладкой в шапке —
  /// и на трубке сразу стало видно, что четыре подписи в строке теснятся
  /// и разъезжаются по высоте. Довод против четвёртой был у меня же и
  /// раньше: день и календарь месяца — **один вопрос «когда я занят»,
  /// заданный на разном расстоянии**. Значит им место не рядом, а внутри
  /// одного места, переключателем.
  String _calendarMode = 'gun'; // 'gun' | 'ay'

  /// ВЫБРАННЫЙ ЧЕЛОВЕК В СЧЁТЕ ПОД СЕТКОЙ — `null` значит «все».
  ///
  /// Нажатие на имя гасит чужие дни: месяц отвечает на вопрос «когда занят
  /// ИМЕННО ОН». Это то, чем стал фильтр после того, как переключатель
  /// «Hamısı | Müqavilələr» был снят: отбор идёт по ЧЕЛОВЕКУ, как в макете, а
  /// не по типу записи.
  String? _selectedOwnerUid;
  String _activeTab = 'outgoing';
  String _tedbirTab = 'hamisi';
  // Только id, а не сам объект (N23): карточка достаёт живую запись из
  // потока сама. Хранить здесь `PersonalEvent` — значит снова заморозить
  // снимок на всё время, пока карточка открыта.
  String? _selectedAgreementId;
  String? _tedbirDetailId;
  DateTime? _tedbirFilterDate;
  DateTime _currentCalendarMonth = DateTime(
    DateTime.now().year,
    DateTime.now().month,
    1,
  );
  int? _selectedCalendarDay;
  // Отметки «прочитано». Не состояние экрана, а СНИМОК ПОТОКА, положенный
  // сюда в начале build: читателей у него четыре (`_isUnread`,
  // `_sortedAgreements`, шапка, карточка), и протаскивать список через все
  // четыре ради чистоты значило бы больше правок в файле, который на шаге 5
  // разбирается на маршруты.
  //
  // Потоком, а не разовым чтением при открытии экрана: с N40 отметку
  // снимает ещё и сервер, у второй стороны, когда договор правят. Экран
  // живёт в `IndexedStack` и до конца сессии не пересоздаётся — разовое
  // чтение показало бы снятую отметку не раньше перезапуска приложения.
  List<String> _readAgreementIds = const [];
  bool _autoOpenedForPartner = false;

  static const int _kCalendarInitialPage = 1200;
  late final DateTime _calendarAnchorMonth;
  late final PageController _pageController;

  String get _uid => FirebaseAuth.instance.currentUser!.uid;

  @override
  void initState() {
    super.initState();
    _calendarAnchorMonth = DateTime(
      _currentCalendarMonth.year,
      _currentCalendarMonth.month,
      1,
    );
    _pageController = PageController(initialPage: _kCalendarInitialPage);
    // Covers the case where this screen is being built for the very FIRST
    // time (StatefulShellRoute.indexedStack builds each branch lazily, on
    // first visit) at the exact moment chat_screen.dart's accept-listener
    // sets agreementsTabRequestProvider right before context.go('/agreements')
    // — build()'s own ref.listen below only reacts to CHANGES from here on,
    // so a value already sitting in the provider before this widget's first
    // build would otherwise be silently missed (confirmed on-device: landed
    // on the default tab instead of Müqavilələr→Gələnlər; тогда видом по
    // умолчанию был «Təqvim», с 07.08 — «Bu gün», и на разбор это не
    // влияет: важно, что не тот, который просили).
    final pending = ref.read(agreementsTabRequestProvider);
    if (pending != null) {
      _mainView = 'agreements';
      _activeTab = pending;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(agreementsTabRequestProvider.notifier).set(null);
      });
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  int _pageForMonth(DateTime month) {
    return _kCalendarInitialPage +
        (month.year - _calendarAnchorMonth.year) * 12 +
        (month.month - _calendarAnchorMonth.month);
  }

  DateTime _monthForPage(int page) {
    final offset = page - _kCalendarInitialPage;
    return DateTime(
      _calendarAnchorMonth.year,
      _calendarAnchorMonth.month + offset,
      1,
    );
  }

  // Своего слепка состояния здесь больше нет: запись немедленно возвращается
  // тем же потоком (Firestore отдаёт локальную мутацию в снимок не дожидаясь
  // сервера), и второй источник той же правды был бы лишним — а главное,
  // пережил бы снятие отметки сервером и прятал бы рамку, которую тот
  // вернул.
  Future<void> _markRead(PersonalEvent e) async {
    if (_readAgreementIds.contains(e.id)) return;
    await ref.read(firestoreServiceProvider).saveReadAgreementId(_uid, e.id);
  }

  // -------------------------------------------------------------------------
  // Derived lists
  // -------------------------------------------------------------------------
  List<PersonalEvent> _agreeEvents(List<PersonalEvent> personalEvents) =>
      personalEvents.where((e) => e.isAgree).toList();

  List<PersonalEvent> _outgoing(List<PersonalEvent> agree) => agree
      .where((e) => e.ownerUid == _uid && e.status != 'cancelled')
      .toList();

  List<PersonalEvent> _incoming(List<PersonalEvent> agree) => agree
      .where((e) => e.ownerUid != _uid && e.status != 'cancelled')
      .toList();

  List<PersonalEvent> _cancelled(List<PersonalEvent> agree) =>
      agree.where((e) => e.status == 'cancelled').toList();

  bool _isUnread(PersonalEvent e) => !_readAgreementIds.contains(e.id);

  /// Один порядок: новое сверху, и ничего кроме (решение владельца 07.08).
  ///
  /// Прежде список шёл в два этажа — непрочитанные, потом прочитанные, —
  /// то есть менял порядок сам по себе: стоило открыть карточку, и она
  /// уезжала вниз, а человек искал её там, где видел. Правило нигде не
  /// было ни объяснено, ни закреплено тестом, и владелец принял его за
  /// поломку — что и есть цена необъяснённого решения (N55).
  List<PersonalEvent> _sortedAgreements(List<PersonalEvent> list) =>
      list.toList()..sort(compareAgreementsByStamp);

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    ref.listen(agreementsTabRequestProvider, (previous, next) {
      if (next == null) return;
      setState(() {
        _mainView = 'agreements';
        _activeTab = next;
      });
      // One-shot signal — clear it so re-entering this tab normally
      // afterwards doesn't keep forcing the same sub-tab.
      Future.microtask(
        () => ref.read(agreementsTabRequestProvider.notifier).set(null),
      );
    });
    final uid = _uid;
    // Снимок потока отметок — см. поле. Пока он не пришёл, список пуст, то
    // есть всё выглядит непрочитанным: сомнение здесь безопаснее в эту
    // сторону — лишняя рамка снимается открытием карточки, недостающая не
    // замечается никем.
    _readAgreementIds =
        ref.watch(readAgreementIdsProvider(uid)).value ?? const <String>[];
    final personalEventsAsync = ref.watch(personalEventsProvider(uid));
    final eventsAsParticipantAsync = ref.watch(
      eventsAsParticipantProvider(uid),
    );

    final personalEvents = personalEventsAsync.asData?.value ?? [];
    final eventsAsParticipant = eventsAsParticipantAsync.asData?.value ?? [];
    final allUsersAsync = ref.watch(allUsersProvider);
    final allUsers = allUsersAsync.asData?.value ?? [];

    // Müqavilələr's Göndərilən/Gələnlər split (_outgoing/_incoming below)
    // needs BOTH: personalEvents alone only ever has ownerUid == uid, so
    // "Gələnlər" (events someone else owns, this uid just participates in —
    // e.g. an accepted "İş təklif et") could never show anything from that
    // list alone. Deduped by id since an owner also appears in their own
    // musicians array, so their own events come back from
    // eventsAsParticipantProvider too.
    final agreementEventsById = <String, PersonalEvent>{
      for (final e in personalEvents) e.id: e,
      for (final e in eventsAsParticipant) e.id: e,
    };
    final agreeEvents = _agreeEvents(agreementEventsById.values.toList());
    final hasUnread = agreeEvents.any(_isUnread);

    // "İş yazdır" entry point (chat_screen.dart) — open the same
    // create-event sheet the calendar tab's own FAB uses (_openAddModal,
    // mode: 'time-only', which is what shows the participant picker — see
    // its own comment), pre-selecting this specific partner. Scheduled via
    // addPostFrameCallback (can't show a bottom sheet mid-build) and guarded
    // by _autoOpenedForPartner so it only fires once per push, not on every
    // rebuild this screen goes through afterward (filter/tab changes, etc.).
    //
    // Also gated on allUsersAsync.hasValue — on a cold app start,
    // allUsersProvider's Firestore stream hasn't delivered its first
    // snapshot yet by the time this first build runs, so allUsers would
    // still be [] here. Without this guard, the modal opened immediately
    // with that empty list baked in (a StatefulWidget's constructor param,
    // never rebuilt afterward), so the pre-selected participant chip showed
    // uid instead of name until the sheet was closed and reopened. Waiting
    // for hasValue lets this rerun (build() reruns on every allUsersProvider
    // emission, same as always) once real data is actually in.
    if (widget.initialParticipantUid != null &&
        !_autoOpenedForPartner &&
        allUsersAsync.hasValue) {
      _autoOpenedForPartner = true;
      final partnerUid = widget.initialParticipantUid!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _openAddModal(
          context,
          initialDate: DateTime.now(),
          personalEvents: personalEvents,
          eventsAsParticipant: eventsAsParticipant,
          allUsers: allUsers,
          mode: 'time-only',
          initialParticipantUids: [partnerUid],
        );
      });
    }

    // If a detail screen is showing, render it on top
    //
    // СТАРЫЙ ЭКРАН КАРТОЧКИ ДОГОВОРА СНЯТ 13.08 вместе со вторым набором
    // кнопок отмены по согласию. Договорённость перестала быть отдельной
    // вещью, значит и отдельной карточки у неё нет.
    //
    // Договорённости открываются ТОЙ ЖЕ дорогой, что и вечера, — через
    // `_PersonalEventDetailScreen` ниже. Это и было целью шага 6: одна
    // карточка на всё.
    if (_selectedAgreementId != null) {
      return _PersonalEventDetailScreen(
        eventId: _selectedAgreementId!,
        currentUid: uid,
        onBack: () => setState(() => _selectedAgreementId = null),
      );
    }
    if (_tedbirDetailId != null) {
      return _PersonalEventDetailScreen(
        eventId: _tedbirDetailId!,
        currentUid: uid,
        onBack: () => setState(() => _tedbirDetailId = null),
      );
    }

    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopHeader(agreeEvents, hasUnread),
            Expanded(
              child: _mainView == 'agreements'
                  ? _buildAgreementsTab(agreeEvents)
                  : _mainView == 'calendar'
                  ? _buildCalendarTab(
                      personalEvents,
                      eventsAsParticipant,
                      allUsers,
                    )
                  : _buildTedbirlerTab(
                      personalEvents,
                      eventsAsParticipant,
                      allUsers,
                    ),
            ),
          ],
        ),
      ),
      // Rounded-square gold-gradient glow button (approved preview design,
      // see agreements_screen.dart's own "Təqvim" restyle) rather than the
      // default circular FloatingActionButton — same onPressed/behavior,
      // just a custom shape/decoration wrapped around a GestureDetector.
      floatingActionButton: _mainView == 'calendar' && _calendarMode == 'ay'
          ? GestureDetector(
              onTap: () => _openAddModal(
                context,
                initialDate: _isSameMonth(_currentCalendarMonth, DateTime.now())
                    ? DateTime.now()
                    : DateTime(
                        _currentCalendarMonth.year,
                        _currentCalendarMonth.month,
                        1,
                        12,
                      ),
                personalEvents: personalEvents,
                eventsAsParticipant: eventsAsParticipant,
                allUsers: allUsers,
                mode: 'time-only',
              ),
              child: Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [kGold2, kGold],
                  ),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: Colors.white.withAlpha(38)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha(100),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                    BoxShadow(color: kGold2.withAlpha(170), blurRadius: 18),
                  ],
                ),
                child: const Icon(Icons.add, color: kOnGold, size: 28),
              ),
            )
          : null,
    );
  }

  bool _isSameMonth(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month;

  // -------------------------------------------------------------------------
  // Верхняя полоса — переключатель «Gün | Ay»
  // -------------------------------------------------------------------------
  // ТРИ ВКЛАДКИ УБРАНЫ (решение владельца 12.08): «Müqavilələr», «Təqvim»,
  // «Tədbirlər» больше нет, их место занял переключатель дня и месяца.
  //
  // ЧТО ЭТИМ ПОТЕРЯНО, названо прямо: у списков договоров и мероприятий
  // больше нет входа. Экран остаётся один — календарь, и он показывает всё.
  // Это и есть направление, утверждённое 10.08 («договора как отдельной вещи
  // больше нет»), но фильтра в календаре сейчас тоже нет — он был снят
  // 11.08 как не предусмотренный макетом. Значит до появления нового входа
  // договоры видны только клетками месяца.
  Widget _buildTopHeader(List<PersonalEvent> agreeEvents, bool hasUnread) {
    Widget seg(String mode, String label) {
      final active = _calendarMode == mode;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _calendarMode = mode),
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: active ? kGold : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: GoogleFonts.nunito(
                // 18pt: прежние 14 плюс четыре — решение владельца 12.08 по
                // виду на устройстве.
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: active ? kText : kMuted,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: kBorder)),
      ),
      child: Row(
        children: [
          // Кнопка возврата остаётся: экран открывают и отдельно («İş
          // yazdır»), и тогда уйти с него больше нечем.
          if (widget.initialParticipantUid != null)
            IconButton(
              icon: const Icon(Icons.arrow_back, color: kGold),
              onPressed: () => Navigator.of(context).pop(),
            ),
          seg('gun', 'Gün'),
          seg('ay', 'Ay'),
        ],
      ),
    );
  }

  Widget _buildAgreementsTab(List<PersonalEvent> agreeEvents) {
    final outgoing = _sortedAgreements(_outgoing(agreeEvents));
    final incoming = _sortedAgreements(_incoming(agreeEvents));
    final cancelled = _sortedAgreements(_cancelled(agreeEvents));

    List<PersonalEvent> currentList;
    switch (_activeTab) {
      case 'incoming':
        currentList = incoming;
        break;
      case 'cancelled':
        currentList = cancelled;
        break;
      default:
        currentList = outgoing;
    }

    return Column(
      children: [
        _buildAgreementSubTabs(
          outgoing.length,
          incoming.length,
          cancelled.length,
        ),
        Expanded(
          child: agreeEvents.isEmpty
              ? _buildAgreementsEmpty()
              : currentList.isEmpty
              ? Center(
                  child: Text('Boşdur', style: const TextStyle(color: kMuted)),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: currentList.length,
                  itemBuilder: (_, i) => _buildAgreementCard(currentList[i]),
                ),
        ),
      ],
    );
  }

  Widget _buildAgreementSubTabs(int outCount, int inCount, int canCount) {
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: kBg3,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          _subTab('Göndərilən ($outCount)', 'outgoing', kGold, kOnGold),
          _subTab('Gələnlər ($inCount)', 'incoming', kGold, kOnGold),
          _subTab('Ləğv edilən ($canCount)', 'cancelled', kRed, kOnRed),
        ],
      ),
    );
  }

  Widget _subTab(String label, String tab, Color activeBg, Color activeText) {
    final active = _activeTab == tab;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _activeTab = tab),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: active ? activeBg : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: active ? activeText : kMuted,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAgreementsEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('📋', style: TextStyle(fontSize: 52)),
          const SizedBox(height: 12),
          Text(
            'Hələ müqavilə yoxdur',
            style: GoogleFonts.nunito(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: kText,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Musiqiçi ilə razılaşdıqda\nmüqavilə burada görünəcək',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: kMuted),
          ),
        ],
      ),
    );
  }

  /// Имя второй стороны договора — по её uid.
  ///
  /// `partnerName` из документа значит «вторая сторона глазами
  /// ВЛАДЕЛЬЦА»: на входящем договоре это имя самого смотрящего (N53).
  /// Оставлено только запасным путём и только там, где называют именно
  /// `partnerUid`.
  String _nameOfParty(PersonalEvent e) {
    final otherUid = e.ownerUid == _uid ? e.partnerUid : e.ownerUid;
    final users = ref.read(allUsersProvider).asData?.value ?? const <User>[];
    for (final u in users) {
      if (u.id == otherUid && u.name.isNotEmpty) return u.name;
    }
    return otherUid == e.partnerUid ? (e.partnerName ?? 'Naməlum') : 'Naməlum';
  }

  /// Дата под именем: когда пришло (или ушло), а у отменённых — когда
  /// отменено. Подписана словом — без подписи её читают как дату
  /// мероприятия (N55).
  String _stampLine(PersonalEvent e) {
    // Главная дата: у действующего — когда договор состоялся, у
    // отменённого — когда отменён (решение владельца 07.08). Дата прихода
    // к ней не подмешивается, она живёт своей строкой внизу справа.
    final cancelled = agreementStamp(e.status) == AgreementStamp.cancelled;
    final at = cancelled ? agreementCancelledValue(e) : agreementSignedValue(e);
    if (at == null) return '';
    // Без слов: владелец 07.08 — «убери тексты». Что за дата, читается
    // из места: под мероприятием соглашение, внизу справа приход.
    return DateFormat('d MMMM yyyy HH:mm', 'az').format(at);
  }

  /// Дата ПРИХОДА — отдельной строкой внизу справа, мелко (решение
  /// владельца 07.08). Пусто, если предложение не датировано: подставить
  /// сюда дату сделки значило бы выдать одно событие за другое.
  String _arrivalLine(PersonalEvent e) {
    final at = agreementArrivalValue(e);
    if (at == null) return '';
    return DateFormat('d MMM yyyy HH:mm', 'az').format(at);
  }

  Widget _buildAgreementCard(PersonalEvent e) {
    final unread = _isUnread(e);
    final cancelled = e.status == 'cancelled';
    // ПОД ВОПРОСОМ ВИДНО И В СПИСКЕ (Часть 6а `docs/plan.md`). Список — то
    // самое место, где решают, что делать: человек открывает его, чтобы
    // понять, что у него на руках. Неотличимый от живого договор под
    // вопросом означает, что список ВРЁТ про то, чем занят вечер.
    //
    // ВКЛАДКА НЕ МЕНЯЕТСЯ, и это решение, а не экономия. Вкладки делят по
    // РОЛИ («вы отправили» / «вам отправили»), и «отменённые» —
    // единственное исключение по состоянию. Оно оправдано тем, что у
    // отменённого роль больше ничего не решает: действий нет. У «под
    // вопросом» роль решает всё — владелец определяет судьбу договора,
    // вторая сторона либо ждёт, либо отменяет. Унеси его на свою вкладку —
    // и это различие пропадёт.
    final unsettled = e.status == kEventStatusUnsettled;

    Color? borderColor;
    Color? bgColor;
    if (cancelled && unread) {
      borderColor = kRed;
      bgColor = kRed.withAlpha(20);
    } else if (cancelled) {
      borderColor = kRed.withAlpha(77);
      bgColor = Colors.white.withAlpha(3);
    } else if (unsettled) {
      // Не золотая рамка и не красная: договор ни «свежий», ни отменённый.
      // Тот же набор `kWarn*`, что у отметки на самой карточке и у
      // предупреждения о занятом времени, — один смысл, один вид.
      borderColor = kWarnBorder;
      bgColor = kWarnBg;
    } else if (unread) {
      borderColor = kGold;
      bgColor = kGold.withAlpha(20);
    } else {
      borderColor = null;
      bgColor = Colors.white.withAlpha(8);
    }

    String roleText;
    if (cancelled) {
      // «Отменён по согласию», а не «{кто-то} отказался» (N54). Прежний
      // текст был неверен дважды: отказа как исхода не существует
      // (`declinesCancelRequest` оставляет договор в силе), а имя бралось
      // из `partnerName` — на экране получателя это его собственное имя
      // (N53). Комментарий, стоявший здесь, честно называл первую половину
      // («кто отменил» — вопрос без единственного ответа) и откладывал её
      // до Этапа II; второй половины — что само слово ложное — он не
      // увидел. Комментарий защищает строку, а не класс.
      roleText = 'Razılıqla ləğv edildi';
    } else if (unsettled) {
      // Роль НЕ теряется: она и есть то, что решает следующий ход. Строка
      // говорит и роль, и состояние — «вы отправили · под вопросом».
      final role = e.ownerUid == _uid ? 'Siz göndərdiniz' : 'Sizə göndərildi';
      roleText = '$role · şübhə altında';
    } else {
      roleText = e.ownerUid == _uid ? 'Siz göndərdiniz' : 'Sizə göndərildi';
    }
    final roleColor = cancelled
        ? kRed
        : unsettled
        ? kWarnTitle
        : unread
        ? kGold2
        : kMuted;

    String? eventLine;
    if (!cancelled && e.type.isNotEmpty && e.date.isNotEmpty) {
      eventLine =
          '📅 ${e.type} — ${_fmtDate(e.date)}${e.location.isNotEmpty ? ' · ${e.location}' : ''}';
    }

    return GestureDetector(
      onTap: () async {
        await _markRead(e);
        if (!context.mounted) return;
        // ЧЕРЕЗ ОБЩУЮ ДВЕРЬ (N117). Здесь стояло собственное открытие
        // карточки договора — третья дорога к тому же экрану, живая через
        // `agreementsTabRequestProvider` (уведомление просит открыть список).
        // Пока карточек было две, она вела в свою; переключи главную дверь и
        // забудь эту — и человек из уведомления попадал бы на старый экран.
        Navigator.of(
          context,
        ).push(eventDetailRoute(eventId: e.id, currentUid: _uid));
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(16),
          border: borderColor != null ? Border.all(color: borderColor) : null,
        ),
        child: Row(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: kBg3,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: kBorder),
                  ),
                  child: Center(
                    child: Text(
                      cancelled ? '✖️' : '📋',
                      style: const TextStyle(fontSize: 20),
                    ),
                  ),
                ),
                if (unread)
                  Positioned(
                    top: -3,
                    right: -3,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: cancelled ? kRed : kGold,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    // Имя ВТОРОЙ СТОРОНЫ по её uid, а не `partnerName`
                    // (N53): на входящем договоре это поле означает имя
                    // самого смотрящего, и список показывал бы человеку
                    // его собственное имя вместо имени напарника.
                    _nameOfParty(e),
                    style: GoogleFonts.nunito(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: unread ? kText : kMuted,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    roleText,
                    style: TextStyle(fontSize: 12, color: roleColor),
                  ),
                  if (eventLine != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      eventLine,
                      style: const TextStyle(fontSize: 12, color: kGold),
                    ),
                  ],
                  // ДАТА СОГЛАШЕНИЯ — строкой СРАЗУ ПОД мероприятием
                  // (решение владельца 07.08). У отменённого здесь дата
                  // отмены: когда договора уже нет, она важнее.
                  const SizedBox(height: 2),
                  Text(
                    _stampLine(e),
                    style: const TextStyle(fontSize: 11, color: kMuted),
                  ),
                  // Дата ПРИХОДА — внизу справа, мельче остального
                  // (решение владельца 07.08). Наверху у имени стоит дата
                  // договора, здесь — когда он появился у человека; это
                  // разные события, и на одной строке их не свести.
                  if (_arrivalLine(e).isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        _arrivalLine(e),
                        style: const TextStyle(fontSize: 10, color: kMuted),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (unread)
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: cancelled ? kRed : kGreen,
                  shape: BoxShape.circle,
                ),
              ),
          ],
        ),
      ),
    );
  }

  // =========================================================================
  // CALENDAR TAB
  // =========================================================================
  Widget _buildCalendarTab(
    List<PersonalEvent> personalEvents,
    List<PersonalEvent> eventsAsParticipant,
    List<User> allUsers,
  ) {
    if (_calendarMode == 'gun') {
      return const DayScreen();
    }
    // СЕТКА ЗАКРЕПЛЕНА, ПРОКРУЧИВАЕТСЯ ТОЛЬКО НИЗ (решение владельца 12.08).
    //
    // Прежде весь экран лежал в одном `SingleChildScrollView`: стоило
    // посмотреть список дня, и сетка уезжала вверх. А сетка — это то, ради
    // чего экран открывают: в разговоре спрашивают про несколько дат подряд,
    // и каждая следующая должна стоить одно касание, а не «проскроллить
    // обратно и попасть в клетку».
    //
    // Поэтому заголовок, дни недели и сам месяц стоят неподвижно, а счёт по
    // людям и содержимое выбранного дня живут в своей прокрутке под ними.
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          _buildMonthHeader(),
          const SizedBox(height: 16),
          _buildDayOfWeekRow(),
          const SizedBox(height: 8),
          _buildCalendarPageView(personalEvents, eventsAsParticipant, allUsers),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  _buildMonthTally(
                    personalEvents,
                    eventsAsParticipant,
                    allUsers,
                  ),
                  // Содержимое выбранного дня — ПОД СЕТКОЙ, а не на другой
                  // закладке. Сетка остаётся на экране: в разговоре
                  // спрашивают про несколько дат подряд, и каждая следующая —
                  // одно касание, а не новый заход.
                  _buildSelectedDayAnswer(personalEvents, eventsAsParticipant),
                  const SizedBox(height: 80),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Переключатель «Gün | Ay» — день и месяц в одном месте.
  /// Список месяцев — прыжок к далёкой дате.
  ///
  /// Двенадцать месяцев вперёд от текущего: этого хватает на вопрос
  /// «свободен в сентябре?», а дальше года вперёд договоров не заключают.
  /// Считаем касания честно: заголовок — месяц — день, **три** внутри
  /// «Ay»; если начинать с «Gün», то четыре, потому что первое уходит на
  /// сам переключатель.
  void _openMonthJump() {
    final base = DateTime(DateTime.now().year, DateTime.now().month, 1);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kBg2,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 10),
          children: [
            for (var i = 0; i < 12; i++)
              Builder(
                builder: (_) {
                  final m = DateTime(base.year, base.month + i, 1);
                  final active =
                      m.year == _currentCalendarMonth.year &&
                      m.month == _currentCalendarMonth.month;
                  return ListTile(
                    title: Text(
                      '${_azMonth(m.month)} ${m.year}',
                      style: TextStyle(color: active ? kGold : kText),
                    ),
                    trailing: active
                        ? const Icon(Icons.check, color: kGold, size: 20)
                        : null,
                    onTap: () {
                      setState(() {
                        _currentCalendarMonth = m;
                        _selectedCalendarDay = null;
                      });
                      _pageController.jumpToPage(_pageForMonth(m));
                      Navigator.pop(sheetContext);
                    },
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  /// СЧЁТ ПОД СЕТКОЙ — из макета `docs/design/mugam-8-teqvim.html`.
  ///
  /// Отвечает на вопрос, ради которого календарь и открывают: «кто занял этот
  /// месяц и сколько осталось». Строки — по людям, затем «под вопросом», затем
  /// отдельной чертой «свободно».
  ///
  /// **«Şübhəli» — ПОДМНОЖЕСТВО занятых, а не отдельная доля.** В самом макете
  /// 8 + 6 + 2 + 17 даёт 33 при 31 дне августа; сходится только так: два дня
  /// под вопросом уже посчитаны у своих владельцев. Сложи их отдельно — счёт
  /// соврёт на два дня, и заметить это будет нечем.
  Widget _buildMonthTally(
    List<PersonalEvent> personalEvents,
    List<PersonalEvent> eventsAsParticipant,
    List<User> allUsers,
  ) {
    final month = _currentCalendarMonth;
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final byDay = eventsByDay(
      own: personalEvents,
      asParticipant: eventsAsParticipant,
    );
    final names = {for (final u in allUsers) u.id: u.name};
    // ПРОСМОТРЕННЫЕ ПРИГЛАШЕНИЯ. Пока набор не доехал — `{}`, то есть числа
    // показываются ПОЛНЫЕ. Сторона ошибки выбрана нарочно: лучше позвать
    // смотреть туда, где всё разобрано, чем промолчать о живом приглашении
    // (I14, разбор при `watchSeenInvitations`).
    final seen = ref.watch(seenInvitationsProvider(_uid)).value ?? const <String>{};
    final marks = <int, DayMark>{};
    for (int day = 1; day <= daysInMonth; day++) {
      final events = byDay[DateTime(month.year, month.month, day)];
      if (events == null || events.isEmpty) continue;
      final mark = dayMarkOf(events, names,
          currentUid: _uid, seenInvitationIds: seen);
      if (mark != null) marks[day] = mark;
    }
    final tally = monthTally(marks: marks, daysInMonth: daysInMonth);
    if (tally.busyDays == 0) return const SizedBox.shrink();

    // СТРОКА ИМЕНИ — НАЖИМАЕМАЯ: она и есть фильтр месяца по человеку
    // (решение владельца 12.08). Нажал имя — на сетке остались его дни, чужие
    // погасли до одного числа.
    //
    // Выбранная строка ВЫХОДИТ ВПЕРЁД: заливка цветом человека и рамка тем
    // же цветом, имя жирнее. Не галочка сбоку — её на тёмном экране ищут
    // глазами, а заливка сразу говорит, что именно выбрано.
    //
    // Второе нажатие снимает выбор. Отдельной кнопки «показать всех» нет
    // намеренно: это был бы второй путь к тому же действию, а такие пары
    // расходятся молча.
    //
    // Строка «Şübhəli» не нажимается: она не человек, а срез по всем, и
    // фильтровать по ней значило бы завести второй смысл у одного места.
    Widget line(
      String label,
      Color color,
      int days, {
      bool hollow = false,
      String? ownerUid,
    }) {
      final picked = ownerUid != null && ownerUid == _selectedOwnerUid;
      return GestureDetector(
        onTap: ownerUid == null
            ? null
            : () =>
                  setState(() => _selectedOwnerUid = picked ? null : ownerUid),
        behavior: HitTestBehavior.opaque,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: picked ? color.withValues(alpha: 0.18) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: picked ? color : Colors.transparent),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${hollow ? '○' : '●'} $label',
                style: TextStyle(
                  fontSize: 14,
                  color: color,
                  fontWeight: picked ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
              Text(
                '$days gün',
                style: const TextStyle(fontSize: 14, color: kTextSecondary),
              ),
            ],
          ),
        ),
      );
    }

    // Порядок строк — по числу дней, чтобы самый занятый стоял первым.
    final owners = tally.byOwner.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 0),
      child: Column(
        children: [
          for (final e in owners)
            line(
              names[e.key] ?? '—',
              e.key == _uid ? kGold : kOwnerOther,
              e.value,
              ownerUid: e.key,
            ),
          if (tally.unsettledDays > 0)
            line('Şübhəli', kMuted, tally.unsettledDays, hollow: true),
          Container(
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.only(top: 9),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: kBorder)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Boş',
                  style: TextStyle(fontSize: 14, color: kMuted),
                ),
                Text(
                  '${tally.freeDays} gün',
                  style: const TextStyle(fontSize: 14, color: kTextSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// СТРОКА ПРИГЛАШЕНИЯ под сеткой — «Rafael səni çağırır · 20:00».
  ///
  /// Заведена 12.08 работой «показ приглашений в календаре» (N126). Отдельным
  /// методом, а не веткой внутри карточки вечера: **это разные вещи, и
  /// одинаковыми они быть не должны.** Карточка говорит «у меня в этот день
  /// вот что», строка — «меня спрашивают». Слить их в один виджет с
  /// переключателем значило бы объединить два действия (I58).
  ///
  /// **Полоска слева взята та же**, и это не лень: она отвечает за «прошлое
  /// или будущее» ([barColor] гасится на прошедшем дне), а этот вопрос у
  /// приглашения и у вечера общий.
  ///
  /// **Куда ведёт нажатие.** Пока — в общую карточку вечера, через ту же
  /// дверь `eventDetailRoute`, что и всё остальное (N90, N117): там сейчас
  /// живёт блок «Cavabınız», то есть ответить человек может. Когда будет
  /// написан экран `DƏVƏT` (экран 2 макета `mugam-6-kart.html`), дверь
  /// останется той же — поменяется то, что она открывает, и **ровно в одном
  /// месте**.
  Widget _invitationRow(PersonalEvent e, Color barColor) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        // «ПРОСМОТРЕЛ» ПИШЕТСЯ ПРИ ОТКРЫТИИ, и открытие от этого НЕ зависит.
        //
        // Запись не ждётся и её отказ не мешает уйти на карточку: пометка о
        // просмотре — удобство, а попасть в приглашение человек должен даже
        // при мёртвой сети. Обратный порядок (сперва дождаться записи) отдал
        // бы вход в приглашение во власть связи.
        //
        // **Отказ здесь молчаливый, и это названо, а не забыто.** Худшее, что
        // случится, — число на клетке не убавится, и человек нажмёт ещё раз.
        // Ошибка в безопасную сторону: лишний зов смотреть, а не спрятанное
        // приглашение (I14).
        unawaited(
          ref.read(firestoreServiceProvider).markInvitationSeen(_uid, e.id),
        );
        Navigator.of(
          context,
        ).push(eventDetailRoute(eventId: e.id, currentUid: _uid));
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.only(left: 16, top: 2, bottom: 2),
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: barColor, width: 4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ИМЯ ЗОВУЩЕГО ПЕРВЫМ, а не время: у приглашения главное — КТО
            // зовёт. У своего вечера главное «во сколько», и там время стоит
            // первым; здесь порядок другой, потому что и вопрос другой.
            Text(
              '${_nameOfParty(e)} səni çağırır · ${fmtEventTime(e.date)}',
              style: const TextStyle(fontSize: 19, color: kText),
            ),
            if ([e.type, if (e.location.isNotEmpty) e.location]
                .join(' · ')
                .isNotEmpty) ...[
              const SizedBox(height: 5),
              Text(
                [e.type, if (e.location.isNotEmpty) e.location].join(' · '),
                style: const TextStyle(fontSize: 16, color: kTextSecondary),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Ответ на выбранный день — прямо под сеткой.
  ///
  /// **Пустой день отвечает СЛОВАМИ.** Прежде нажатие на день без
  /// мероприятий не делало ничего видимого, и это был не «пустой
  /// результат», а молчание: человек не знал, ответило ему приложение или
  /// он промахнулся мимо клетки (N68). А спрашивают чаще всего именно
  /// про свободен — «свободен 9-го?» по телефону.
  Widget _buildSelectedDayAnswer(
    List<PersonalEvent> personalEvents,
    List<PersonalEvent> eventsAsParticipant,
  ) {
    final day = _selectedCalendarDay;
    if (day == null) return const SizedBox.shrink();
    final date = DateTime(
      _currentCalendarMonth.year,
      _currentCalendarMonth.month,
      day,
    );
    final buckets = buildDayBuckets(
      own: personalEvents,
      asParticipant: eventsAsParticipant,
      now: date,
    );
    // Раскладка считает от «сегодня» переданной даты — значит её `today`
    // и есть выбранный день. Правило одно и то же с дневным экраном: два
    // разбора одной даты разошлись бы молча (N58).
    final events = buckets.today;

    // ПРОШЕДШИЙ ДЕНЬ ПОКАЗЫВАЕТСЯ ПРИГЛУШЁННО, А НЕ ПУСТО.
    //
    // Довод владельца: музыкант часто смотрит НАЗАД — вспомнить, когда
    // играл у этого человека, сколько было работы в июле, с кем. Перепись
    // прода 09.08 его подтвердила числом: из 72 мероприятий **60 старше
    // сегодня**, то есть календарь на 83% состоит из того, что уже было.
    // Прятать эту массу значит делать календарь полезным наполовину.
    //
    // Приглушение решает ровно одну задачу: отличить «было» от «будет» с
    // одного взгляда. Оно НЕ должно делать текст нечитаемым — иначе
    // пропадает то, ради чего работа делается.
    //
    // ЦВЕТА ВЗЯТЫ СУЩЕСТВУЮЩИЕ И ПРОВЕРЕНЫ КОНТРАСТОМ, а не на глаз
    // (измерено 09.08 к фону `kBg`):
    //   kTextSecondary 9.27 — отлично;
    //   kMuted         4.74 — годен для обычного текста;
    //   kTextDim       2.75 — НЕ ЧИТАЕМ, ниже порога даже для крупного.
    // Первая редакция этой правки ставила на «тип · место» именно
    // `kTextDim` — он и есть «приглушённый» по имени. Замер это отменил:
    // строка «Toy · İnci qarayev» — то самое, что человек пришёл
    // вспомнить, и читаться она обязана. `kTextDim` остаётся там, где
    // стоит сегодня: слово «boş» у пустого дня недели, которое читать не
    // нужно.
    //
    // Полоска гасится в `kBarOff` — тем же цветом, которым на дневном
    // экране погашена полоска ЗАВТРАШНЕГО дела. Это не совпадение и не
    // экономия имени: и там и там она значит «не сейчас».
    final selectedDay = DateTime(date.year, date.month, date.day);
    final todayDay = DateTime.now();
    final isPast = selectedDay.isBefore(
      DateTime(todayDay.year, todayDay.month, todayDay.day),
    );
    final barColor = isPast ? kBarOff : kGold;
    final timeColor = isPast ? kTextSecondary : kText;
    final lineColor = isPast ? kMuted : kTextSecondary;

    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            fmtDayHeader(date),
            style: const TextStyle(
              fontSize: 13,
              letterSpacing: 1.2,
              color: kMuted,
            ),
          ),
          const SizedBox(height: 10),
          if (events.isEmpty)
            // `const` снят: текст теперь зависит от того, прошёл ли день.
            Text(
              // Прошедший день говорит о себе в ПРОШЕДШЕМ времени.
              // «Boşsunuz» — «вы свободны», и про вчера это звучит так,
              // будто вчерашний вечер ещё можно занять. Слово выбрано
              // автором 09.08, язык его.
              isPast ? 'Boş idi' : 'Boşsunuz',
              style: const TextStyle(fontSize: 19, color: kTextSecondary),
            )
          else
            for (final e in events)
              // ПРИГЛАШЕНИЕ — СТРОКОЙ, А НЕ КАРТОЧКОЙ ВЕЧЕРА (решение автора
              // 12.08, N126). Карточка отвечает на вопрос «что у меня в этот
              // день», а приглашение — это не «у меня», это вопрос ко мне.
              //
              // **ОТКАЗАННЫЕ ВЕЧЕРА ОТСЮДА НЕ УБРАНЫ, и это решение, а не
              // недосмотр.** На сетке их нет — там ответ на «занят ли день»,
              // и он «нет». Здесь ответ на «что в этот день», и убрать их
              // значило бы отнять единственную дорогу назад: человек,
              // отказавшийся по ошибке, не смог бы передумать. Строка
              // остаётся, а день при этом свободен — это не противоречие, а
              // два разных вопроса (I47).
              //
              // **И ОСТАЁТСЯ ИМЕННО СТРОКОЙ, а не карточкой вечера** —
              // поправлено 12.08 по виду на трубке. Прежде условие
              // спрашивало ровно `DayRole.invited`, и любой ответ выводил
              // вечер из этого состояния: после «Bacarmıram» на экране
              // вставала обычная карточка, то есть человеку показывали чужую
              // работу как своё дело — при том что он от неё отказался.
              // Правило вынесено в `showsAsInvitation` и покрыто тестом:
              // внутри виджета его проверить было нечем (I32, N125).
              if (showsAsInvitation(e, _uid))
                _invitationRow(e, barColor)
              else
              // ТАП ОТКРЫВАЕТ КАРТОЧКУ — через ту же дверь, что и дневной
              // экран (N90/N93). До этого строка выбранного дня молчала:
              // человек видел своё мероприятие, нажимал и не получал
              // ответа.
              //
              // Это ВТОРОЕ немое место, найденное в тот же день, что и
              // первое, — и здесь оно дороже: в календаре видно ПРОШЛОЕ,
              // а дневной экран показывает только сегодня и вперёд.
              // Значит до этой правки к прошедшему мероприятию не вело
              // ни одной дороги, кроме списка «Tədbirlər».
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(
                  context,
                ).push(eventDetailRoute(eventId: e.id, currentUid: _uid)),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.only(left: 16, top: 2, bottom: 2),
                  decoration: BoxDecoration(
                    border: Border(left: BorderSide(color: barColor, width: 4)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        fmtEventTime(e.date),
                        style: TextStyle(fontSize: 21, color: timeColor),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        [
                          e.type,
                          if (e.location.isNotEmpty) e.location,
                        ].join(' · '),
                        style: TextStyle(fontSize: 16, color: lineColor),
                      ),
                    ],
                  ),
                ),
              ),
          // ВХОД В ПРЕДЛОЖЕНИЕ РАБОТЫ ИЗ ДНЯ КАЛЕНДАРЯ (пункт 6,
          // `docs/plan.md`). Календарь знает ровно одно — какой день
          // выбран, — и передаёт только его. Часа у дня нет: его
          // подставляет лист своим умолчанием (`jobOfferDateOnDay`), и
          // своего числа здесь нет намеренно (I22).
          //
          // Кнопка стоит и на занятом дне, и на пустом. Занятый день не
          // повод молчать: два мероприятия в одну дату — обычная жизнь, а
          // не ошибка, и лист сам покажет предупреждение о совпадении.
          // Прятать её на занятом дне значило бы решить за человека то,
          // что решает он.
          // Прошлый день кнопки не получает: месяцы листаются назад, и
          // предложить работу на вчера нельзя. Правило спрашивается у
          // того, кто знает час умолчания, — своего числа здесь нет.
          if (canOfferOnDay(date, DateTime.now())) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => proposeJobOffer(context, ref, onDay: date),
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
            ),
          ],
        ],
      ),
    );
  }

  /// ЗАГОЛОВОК МЕСЯЦА — ТОЧНО ПО МАКЕТУ (`docs/design/mugam-8-teqvim.html`,
  /// класс `.cap`): `AVQUST 2026` заглавными, 14pt, разрядка 1.8, цвет
  /// `#E09A2B`, по левому краю.
  ///
  /// **Стрелки «‹ ›» убраны — решение владельца 12.08.** Месяц листается
  /// свайпом сетки, и он же остаётся единственной дорогой к соседнему месяцу;
  /// заголовок по-прежнему открывает список месяцев для далёкой даты, но
  /// **без значка «⌄»** — в макете его нет.
  ///
  /// Названо вслух, потому что это потеря подсказки: дорога к списку месяцев
  /// теперь ничем не помечена. Понадобится — вернём знак, но уже как решение
  /// о виде, а не как остаток прежнего заголовка.
  Widget _buildMonthHeader() {
    final monthName = _azMonth(_currentCalendarMonth.month);
    return Align(
      alignment: Alignment.centerLeft,
      child: GestureDetector(
        onTap: _openMonthJump,
        behavior: HitTestBehavior.opaque,
        child: Text(
          azUpperCase('$monthName ${_currentCalendarMonth.year}'),
          style: const TextStyle(
            // 19pt: макетные 14 плюс пять — решение владельца 12.08 по виду
            // на устройстве. Разрядка и цвет остаются макетными.
            fontSize: 19,
            letterSpacing: 1.8,
            color: kMonthCap,
          ),
        ),
      ),
    );
  }

  // Glass rounded-square (approved preview design) rather than flat kBg3 —
  // same onTap/behavior as before, just BackdropFilter + translucent fill +
  // thin gold border instead of a solid background.

  Widget _buildDayOfWeekRow() {
    const days = ['B.e', 'Ç.a', 'Ç', 'C.a', 'C', 'Ş', 'B'];
    return Row(
      children: days
          .map(
            (d) => Expanded(
              child: Center(
                child: Text(
                  d,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: kMuted,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
            ),
          )
          .toList(),
    );
  }

  Widget _buildCalendarPageView(
    List<PersonalEvent> personalEvents,
    List<PersonalEvent> eventsAsParticipant,
    List<User> allUsers,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cellSize = constraints.maxWidth / 7;
        final gridHeight = cellSize * 6;
        return SizedBox(
          height: gridHeight,
          child: PageView.builder(
            controller: _pageController,
            onPageChanged: (page) {
              setState(() {
                _currentCalendarMonth = _monthForPage(page);
                _selectedCalendarDay = null;
              });
            },
            itemBuilder: (_, page) => _buildCalendarGridForMonth(
              month: _monthForPage(page),
              personalEvents: personalEvents,
              eventsAsParticipant: eventsAsParticipant,
              allUsers: allUsers,
            ),
          ),
        );
      },
    );
  }

  Widget _buildCalendarGridForMonth({
    required DateTime month,
    required List<PersonalEvent> personalEvents,
    required List<PersonalEvent> eventsAsParticipant,
    required List<User> allUsers,
  }) {
    final year = month.year;
    final monthNum = month.month;
    final firstWeekday = DateTime(year, monthNum, 1).weekday; // 1=Mon
    final startOffset = (firstWeekday - 1) % 7; // Mon=0
    final daysInMonth = DateTime(year, monthNum + 1, 0).day;
    final today = DateTime.now();

    // ОДИН проход вместо прохода на каждую из 42 ячеек. Прежде сетка
    // спрашивала `eventsOfDay` на каждый день, и каждый вопрос перебирал
    // ВЕСЬ список: на 300 мероприятиях это 12 600 сравнений на одну
    // перерисовку, на 3000 — 126 000, и повторяется при каждом листании
    // месяца. Правило то же самое (`eventsByDay` и `eventsOfDay` —
    // одна функция), меняется только число проходов.
    final byDay = eventsByDay(
      own: personalEvents,
      asParticipant: eventsAsParticipant,
    );

    // Имена для трёх букв — одним справочником, а не поиском на каждую
    // клетку: 42 клетки против списка пользователей это тот же счёт, что
    // чинили в `eventsByDay` выше.
    final names = {for (final u in allUsers) u.id: u.name};
    // ПРОСМОТРЕННЫЕ ПРИГЛАШЕНИЯ. Пока набор не доехал — `{}`, то есть числа
    // показываются ПОЛНЫЕ. Сторона ошибки выбрана нарочно: лучше позвать
    // смотреть туда, где всё разобрано, чем промолчать о живом приглашении
    // (I14, разбор при `watchSeenInvitations`).
    final seen = ref.watch(seenInvitationsProvider(_uid)).value ?? const <String>{};

    final cells = <Widget>[];
    for (int i = 0; i < startOffset; i++) {
      cells.add(const SizedBox());
    }
    for (int day = 1; day <= daysInMonth; day++) {
      final dayDate = DateTime(year, monthNum, day);
      // N74: кружок на числе и ответ, который открывается по нажатию на это
      // же число, обязаны считать ОДНИМ правилом. Здесь стоял свой счёт —
      // оба списка подряд, фильтр по дате, `.length`, — и он не знал ни про
      // отменённые, ни про повторы. На 9 avqust это дало «4» при трёх.
      final dayEvents = byDay[dayDate] ?? const <PersonalEvent>[];
      final isSelected =
          _selectedCalendarDay == day &&
          _currentCalendarMonth.year == year &&
          _currentCalendarMonth.month == monthNum;
      final isToday = _sameDay(dayDate, today);
      // ПОМЕТКА СЧИТАЕТСЯ ОДИН РАЗ. Нужна она трижды — самой ячейке, признаку
      // «есть что показать» и приглушению при выборе человека. Прежде правило
      // звалось дважды прямо здесь; с 12.08 оно ещё и разбирает ответы по
      // каждому вечеру, то есть повтор стал не только лишней работой на
      // каждой из 42 клеток, но и вторым местом, которое может разойтись.
      final mark = dayMarkOf(dayEvents, names,
          currentUid: _uid, seenInvitationIds: seen);

      cells.add(
        _buildDayCell(
          day: day,
          weekday: dayDate.weekday,
          isSelected: isSelected,
          isToday: isToday,
          // «ЕСТЬ ЧТО ПОКАЗАТЬ МНЕ», а не «в этот день есть документы».
          // Прежде здесь стояло `dayEvents.isNotEmpty`, и вечер, от которого
          // человек ОТКАЗАЛСЯ, продолжал делать число дня жирным и гасить
          // подсветку выходного — день, которого у него нет, выглядел
          // занятым (N126, вторая половина).
          hasEvents: mark != null,
          eventCount: dayEvents.length,
          mark: mark,
          currentUid: _uid,
          dimmed:
              _selectedOwnerUid != null &&
              mark?.ownerUid != _selectedOwnerUid,
          onTap: () => _onDayTap(
            day,
            dayDate,
            dayEvents,
            personalEvents,
            eventsAsParticipant,
          ),
          onLongPress: () => _onDayLongPress(
            day,
            dayDate,
            personalEvents,
            eventsAsParticipant,
            allUsers,
          ),
        ),
      );
    }

    return GridView.count(
      crossAxisCount: 7,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      children: cells,
    );
  }

  // Glass/glow restyle (approved preview design) — same isSelected/isToday/
  // hasEvents inputs and onTap/onLongPress behavior as before, just: a
  // filled gold circle stays for isSelected (still needs to read as a
  // clear, strong "this one's picked" state), hasEvents gets a soft
  // outward gold glow instead of a flat tinted fill, and the count badge
  // gets a gradient + small glow instead of a flat gold pill.
  /// ЯЧЕЙКА ДНЯ. Занятые дни рисуются ПО МАКЕТУ
  /// (`docs/design/mugam-8-teqvim.html`): цвет владельца, три буквы его имени,
  /// **залито — в силе, рамка — под вопросом**.
  ///
  /// **Пустые дни, выходные и подложка НЕ ТРОНУТЫ, и это граница, а не
  /// недоделка.** Макет утверждает только про занятые дни: у него пустой день
  /// — просто число. Про подсветку выходных и стеклянную плитку он не говорит
  /// ничего, а они утверждены раньше; снять их «заодно» значило бы отменить
  /// решение, которого макет не отменял.
  ///
  /// Кружок со счётом событий убран: его место заняли три буквы. Число дел
  /// человек читает в списке под сеткой, а на клетке важнее, ЧЕЙ это вечер.
  Widget _buildDayCell({
    required int day,
    required int weekday,
    required bool isSelected,
    required bool isToday,
    required bool hasEvents,
    required int eventCount,
    required DayMark? mark,
    required String currentUid,

    /// Выбран другой человек — этот день гасится почти до фона. Не
    /// скрывается совсем: число дня обязано остаться читаемым, иначе месяц
    /// перестанет быть календарём и станет списком одного человека.
    required bool dimmed,
    required VoidCallback onTap,
    required VoidCallback onLongPress,
  }) {
    // Цвет человека: свой вечер золотой, чужой — синий из макета. Третьего
    // цвета макет не даёт, и придумывать его здесь нельзя: при третьем
    // владельце он совпадёт с чужим, и это названо вслух, а не скрыто.
    final markColor = mark == null
        ? kGold
        : (mark.ownerUid == currentUid ? kGold : kOwnerOther);
    Color bgColor = Colors.transparent;
    Color textColor = kText;
    Border? border;
    List<BoxShadow>? glow;
    // Weekend NUMBER glow (approved preview) — text-only, never touches the
    // cell's own bgColor/glow above. Sunday brighter than Saturday. Only
    // applies to a "plain" day: isSelected/hasEvents already pick their own
    // definitive textColor above and take priority over this.
    List<Shadow>? textGlow;
    if (!isSelected && !hasEvents) {
      if (weekday == DateTime.sunday) {
        textColor = kGold2;
        textGlow = [Shadow(color: kGold2.withAlpha(200), blurRadius: 10)];
      } else if (weekday == DateTime.saturday) {
        textColor = kGold;
        textGlow = [Shadow(color: kGold.withAlpha(140), blurRadius: 6)];
      }
    }

    if (isSelected) {
      bgColor = kGold;
      textColor = kOnGold;
    } else if (mark != null && mark.occupied && !dimmed) {
      // Залито — в силе; рамка — под вопросом. Заливка альфой 0.18 от цвета
      // человека, как в макете (`.bgT`/`.bgR` против `.brT`/`.brR`).
      //
      // **ТОЛЬКО ПРИ `occupied`, и это не перестраховка.** У дня, на котором
      // одни приглашения, `shape` равен `null` — а `null != filled`, значит
      // без этого условия сюда попала бы ветвь «рамка», и приглашение
      // нарисовалось бы СИНЕЙ РАМКОЙ, то есть «чужой вечер под вопросом».
      // Ровно то, от чего работа и заводилась: день выглядел бы занятым.
      if (mark.shape == DayMarkShape.filled) {
        bgColor = markColor.withValues(alpha: 0.18);
      } else {
        border = Border.all(color: markColor, width: 1.5);
      }
      textColor = kText;
    } else if (dimmed) {
      // Чужой день при выбранном человеке: пометки нет вовсе, число
      // приглушено. Так на сетке остаются видны РОВНО его дни.
      textColor = kMuted.withValues(alpha: 0.45);
    }
    if (isToday && !isSelected) {
      border = Border.all(color: kGold, width: 1.2);
    }

    // ЦВЕТ ТОЧКИ — ПО СМЫСЛУ, А НЕ ПО ФОНУ (поправка 12.08, по виду на
    // трубке). Золотая значит «меня зовут, я не разобрал»; серая — «уже
    // разобрано». Разобранным считается и отказ, и **день, на который человек
    // смотрит прямо сейчас**: выбрал день — значит увидел вопрос.
    //
    // **СЕРЫЙ НА ВЫБРАННОМ ДНЕ ТЕМНЕЕ, и это не разнобой.** Фон выбранного
    // дня — сплошной `kGold`, и `kMuted` на нём почти сливается; на тёмной
    // клетке наоборот тонет тёмный. Одного значения на оба фона нет, и
    // выбирать пришлось между двумя тонами одного смысла и одним тоном,
    // невидимым в половине случаев.
    //
    // Прошлый заход поставил здесь `kOnGold` (почти чёрный) на выбранный
    // день — и автор увидел ровно то, что и должен был: точка «пропала».
    // Чёрная соринка 6px в углу золотой клетки пометкой не читается.
    // ЗОЛОТОЕ ЧИСЛО — сколько приглашений ждёт просмотра. Серая точка
    // остаётся следом разобранного, когда числа уже нет.
    final int unseen = (mark == null || dimmed) ? 0 : mark.unseenInvitations;
    final bool showTrace =
        mark != null && !dimmed && unseen == 0 && mark.handledTrace;
    final Color? traceColor = showTrace ? (isSelected ? kBarOff : kMuted) : null;

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      // ПОМЕТКА ЗАНИМАЕТ ВСЮ ЯЧЕЙКУ, а не кружок внутри неё (решение
      // владельца 12.08, по виду на устройстве). В макете клетка — это
      // прямоугольник со скруглением 8, залитый целиком; кружок внутри
      // квадратной плитки читался как две разные фигуры, вложенные друг в
      // друга, и цвет человека доставался меньшей из них.
      //
      // Стеклянная подложка осталась ТОЛЬКО у непомеченных дней: у
      // помеченного её место занимает заливка пометки, иначе поверх
      // подложки лёг бы второй фон и цвет поехал бы.
      child: Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: bgColor == Colors.transparent
              ? Colors.white.withAlpha(16)
              : bgColor,
          borderRadius: BorderRadius.circular(12),
          border: border ?? Border.all(color: Colors.white.withAlpha(28)),
          boxShadow: glow,
        ),
        child: Stack(
          children: [
            // ЗОЛОТАЯ ТОЧКА — «на этот день меня зовут» (решение автора
            // 12.08, N126). Стоит УГЛОМ, а не под числом, нарочно: под числом
            // живут три буквы имени, и день, где приглашение стоит рядом со
            // своим вечером, показывает и буквы, и точку. Столбец пришлось бы
            // делить между ними, и одно вытесняло бы другое.
            //
            // **ЦВЕТ ВЗЯТ ПРОЕКТНЫЙ, А НЕ ИЗ МАКЕТА, и это надо сказать
            // прямо.** В `mugam-8-teqvim.html` класс `.dot` объявлен
            // (`#E09A2B` при «включено») и **нигде не использован** — то есть
            // точки приглашения макет не даёт вовсе. Взять оттуда цвет
            // значило бы сослаться на решение, которого никто не принимал.
            // Здесь `kGold` — тот же золотой, которым проект говорит «моё».
            //
            // ЧИСЛО НЕПРОСМОТРЕННЫХ ПРИГЛАШЕНИЙ (решение автора 12.08,
            // заменило точку). Считано выше, здесь только показ.
            //
            // **ЧИСЛО БЕЗ КРУЖКА-ПОДЛОЖКИ.** Кружок со счётом на этой сетке
            // уже был и был снят — его место заняли три буквы имени
            // владельца (довод в шапке `_buildDayCell`). Вернуть его сюда
            // значило бы отменить то решение задним числом; цифра стоит тем
            // же углом, где стояла точка, и не спорит с буквами за место.
            //
            // **НА ВЫБРАННОМ ДНЕ ЦИФРА ТЁМНАЯ** — фон там сплошной `kGold`, и
            // золотое по золотому пропадает. Та же ловушка, что была с
            // точкой, и лечится тем же.
            if (unseen > 0)
              Positioned(
                top: 2,
                right: 4,
                child: Text(
                  '$unseen',
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.0,
                    fontWeight: FontWeight.w700,
                    color: isSelected ? kBarOff : kGold,
                  ),
                ),
              ),
            // СЛЕД РАЗОБРАННОГО — серая точка там же, где стояло бы число.
            // Показывается только когда числа нет: пока есть непросмотренные,
            // говорить надо о них.
            if (traceColor != null)
              Positioned(
                top: 4,
                right: 4,
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: traceColor,
                  ),
                ),
              ),
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$day',
                    style: TextStyle(
                      fontSize: 16,
                      color: textColor,
                      fontWeight: isSelected || hasEvents
                          ? FontWeight.bold
                          : FontWeight.normal,
                      shadows: textGlow,
                      height: 1.05,
                    ),
                  ),
                  // ТРИ БУКВЫ ИМЕНИ ВЛАДЕЛЬЦА — из макета. Мелко (9pt) и
                  // тем же цветом, что пометка: подпись отвечает на
                  // вопрос «чей это день», а не спорит с числом за
                  // внимание.
                  if (mark != null &&
                      mark.initials.isNotEmpty &&
                      !isSelected)
                    Text(
                      mark.initials,
                      style: TextStyle(
                        fontSize: 9,
                        letterSpacing: 0.4,
                        height: 1.1,
                        color: markColor,
                        fontWeight: FontWeight.w600,
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

  void _onDayTap(
    int day,
    DateTime dayDate,
    List<PersonalEvent> dayEvents,
    List<PersonalEvent> personalEvents,
    List<PersonalEvent> eventsAsParticipant,
  ) {
    if (_selectedCalendarDay == day) {
      setState(() => _selectedCalendarDay = null);
      return;
    }
    // Ответ показывается ПОД СЕТКОЙ (`_buildSelectedDayAnswer`), а сетка
    // остаётся на экране.
    //
    // Прежде нажатие на день с мероприятиями уводило на закладку
    // «Tədbirlər» с фильтром по дате, а нажатие на ПУСТОЙ день не делало
    // ничего видимого. Оба поведения мешали одному и тому же — вопросу
    // «свободен 9-го?», заданному по телефону: первое уносило с сетки,
    // так что следующий вопрос «а 10-го?» начинался заново, второе
    // молчало ровно в том случае, ради которого спрашивают (N68).
    setState(() => _selectedCalendarDay = day);
  }

  void _onDayLongPress(
    int day,
    DateTime dayDate,
    List<PersonalEvent> personalEvents,
    List<PersonalEvent> eventsAsParticipant,
    List<User> allUsers,
  ) {
    setState(() => _selectedCalendarDay = day);
    final initialDate = DateTime(dayDate.year, dayDate.month, dayDate.day, 12);
    _openAddModal(
      context,
      initialDate: initialDate,
      personalEvents: personalEvents,
      eventsAsParticipant: eventsAsParticipant,
      allUsers: allUsers,
      mode: 'time-only',
    );
  }

  /// Просьба формы СОЗДАНИЯ открыть вместо себя форму правки (N46).
  ///
  /// Возвращается из листа как результат, а не зовётся из него напрямую:
  /// лист закрывается вместе со своим контекстом, и открывать следующий
  /// экран из умирающего — способ получить исчезающие формы. Открывает
  /// тот, кто открывал первую.
  Future<void> _openAddModal(
    BuildContext context, {
    required DateTime initialDate,
    required List<PersonalEvent> personalEvents,
    required List<PersonalEvent> eventsAsParticipant,
    required List<User> allUsers,
    PersonalEvent? existingEvent,
    String mode = 'time-only',
    // Чем заполнить форму, когда её открывают по ответу «Mövcud tədbiri
    // dəyiş»: дата из колеса, остальное из цели (`seedForEdit`).
    EventEditSeed? seed,
    // Pre-selects a participant when creating a brand-new event (e.g. "İş
    // yazdır" from a 1:1 chat's menu, chat_screen.dart) — ignored for
    // existingEvent != null, which always shows that event's own already-
    // saved participantUids instead.
    List<String> initialParticipantUids = const [],
  }) async {
    final allCombined = [...personalEvents, ...eventsAsParticipant];
    final request = await showModalBottomSheet<_EventEditRequest>(
      // Тап по затемнённому фону не закрывает: по нему легко попасть,
      // целясь в поле формы, и терять введённое из-за промаха обидно.
      // Свайп и кнопка отмены закрывают как обычно — они делаются
      // намеренно. Одно правило на все листы С ВВОДОМ (N28).
      isDismissible: false,
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _EventFormModal(
        mode: mode,
        initialDate: seed?.date ?? initialDate,
        initialType: seed?.type ?? existingEvent?.type ?? '',
        initialLocation: seed?.location ?? existingEvent?.location ?? '',
        initialNotes: seed?.notes ?? existingEvent?.notes ?? '',
        initialParticipantUids:
            seed?.participantUids ??
            existingEvent?.participantUids ??
            initialParticipantUids,
        allUsers: allUsers,
        existingEvent: existingEvent,
        allCombinedEvents: allCombined,
        currentUid: _uid,
        firestoreService: ref.read(firestoreServiceProvider),
      ),
    );
    if (request == null || !context.mounted) return;
    // Второй шаг ответа «Mövcud tədbiri dəyiş»: та же форма, но правкой
    // цели — со своим заголовком, своей кнопкой и УЖЕ ЗАПОЛНЕННЫМИ
    // полями цели. Отсюда же берётся и то, что при правке окна конфликта
    // не бывает вовсе (N39): `existingEvent` больше не null.
    await _openAddModal(
      context,
      initialDate: request.seed.date,
      personalEvents: personalEvents,
      eventsAsParticipant: eventsAsParticipant,
      allUsers: allUsers,
      existingEvent: request.target,
      mode: mode,
      seed: request.seed,
    );
  }

  // =========================================================================
  // TEDBIRLER TAB
  // =========================================================================
  Widget _buildTedbirlerTab(
    List<PersonalEvent> personalEvents,
    List<PersonalEvent> eventsAsParticipant,
    List<User> allUsers,
  ) {
    List<_TaggedEvent> tagged = [];
    final ownEvents = personalEvents
        .where((e) => e.ownerUid == _uid)
        .map((e) => _TaggedEvent(e, true))
        .toList();
    final invitedEvents = eventsAsParticipant
        .where((e) => e.ownerUid != _uid)
        .map((e) => _TaggedEvent(e, false))
        .toList();

    switch (_tedbirTab) {
      case 'sexsi':
        tagged = ownEvents;
        break;
      case 'dəvətli':
        tagged = invitedEvents;
        break;
      default:
        tagged = [...ownEvents, ...invitedEvents];
    }

    // Filter by date
    if (_tedbirFilterDate != null) {
      final fd = _tedbirFilterDate!;
      tagged = tagged.where((t) {
        if (t.event.date.isEmpty) return false;
        try {
          final d = DateTime.parse(t.event.date);
          return d.year == fd.year && d.month == fd.month && d.day == fd.day;
        } catch (_) {
          return false;
        }
      }).toList();
    }

    tagged.sort((a, b) {
      try {
        final da = DateTime.parse(a.event.date);
        final db = DateTime.parse(b.event.date);
        return da.compareTo(db);
      } catch (_) {
        return 0;
      }
    });

    final isEmpty = personalEvents.isEmpty && eventsAsParticipant.isEmpty;

    return Column(
      children: [
        _buildTedbirSubTabs(),
        if (_tedbirFilterDate != null) _buildFilterChip(),
        Expanded(
          child: isEmpty
              ? const Center(
                  child: Text(
                    'Heç bir tədbir yoxdur',
                    style: TextStyle(color: kMuted),
                  ),
                )
              : tagged.isEmpty
              ? const Center(
                  child: Text(
                    'Bu filterdə tədbir yoxdur',
                    style: TextStyle(color: kMuted),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: tagged.length,
                  itemBuilder: (_, i) {
                    final t = tagged[i];
                    final allUsersList =
                        ref.watch(allUsersProvider).asData?.value ?? [];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _EventCard(
                        event: t.event,
                        isOwn: t.isOwn,
                        currentUid: _uid,
                        allUsers: allUsersList,
                        // Через общую дверь, по той же причине (N117).
                        onTap: () => Navigator.of(context).push(
                          eventDetailRoute(
                            eventId: t.event.id,
                            currentUid: _uid,
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildTedbirSubTabs() {
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: kBg3,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          _tedbirSubTab('Hamısı', 'hamisi'),
          _tedbirSubTab('Şəxsi', 'sexsi'),
          _tedbirSubTab('Dəvətli', 'dəvətli'),
        ],
      ),
    );
  }

  Widget _tedbirSubTab(String label, String tab) {
    final active = _tedbirTab == tab;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _tedbirTab = tab),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: active ? kGold : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: active ? kOnGold : kMuted,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFilterChip() {
    final fd = _tedbirFilterDate!;
    final label = '📅 ${fd.day} ${_azMonth(fd.month)} ${fd.year}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: kGold.withAlpha(56),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label, style: const TextStyle(color: kGold, fontSize: 13)),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => setState(() => _tedbirFilterDate = null),
                  child: const Text(
                    '✕',
                    style: TextStyle(color: kGold, fontSize: 13),
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

// ---------------------------------------------------------------------------
// Tagged event helper
// ---------------------------------------------------------------------------
class _TaggedEvent {
  final PersonalEvent event;
  final bool isOwn;
  _TaggedEvent(this.event, this.isOwn);
}

// ---------------------------------------------------------------------------
// _EventCard
// ---------------------------------------------------------------------------
class _EventCard extends StatelessWidget {
  final PersonalEvent event;
  final bool isOwn;
  final String currentUid;
  final List<User> allUsers;
  final VoidCallback onTap;

  const _EventCard({
    required this.event,
    required this.isOwn,
    required this.currentUid,
    required this.allUsers,
    required this.onTap,
  });

  User? _findUser(String uid) {
    try {
      return allUsers.firstWhere((m) => m.id == uid);
    } catch (_) {
      return null;
    }
  }

  // No-op if uid isn't in allUsers (e.g. stale/removed account) — same
  // silent-skip other callers of _findUser already tolerate (see the ??
  // fallbacks around it) rather than pushing a screen with no User to show.
  void _openUserProfile(BuildContext context, String? uid) {
    final u = uid == null ? null : _findUser(uid);
    if (u == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => UserProfileScreen(user: u)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final initiatorUid = isOwn ? currentUid : event.ownerUid;
    final initiator = _findUser(initiatorUid);
    // Запасное имя — только «Naməlum»: `partnerName` тут значит имя
    // смотрящего, и на входящем договоре назвало бы его самого
    // инициатором (N53).
    final initiatorName = initiator?.name ?? (isOwn ? 'Siz' : 'Naməlum');
    final initiatorInstrument = initiator?.instrument ?? '';

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kBorder),
        ),
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Initiator pill
            Center(
              child: GestureDetector(
                onTap: () => _openUserProfile(context, initiatorUid),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: kGold.withAlpha(56),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    children: [
                      Text(
                        initiatorName,
                        style: GoogleFonts.nunito(fontSize: 16, color: kGold),
                      ),
                      if (initiatorInstrument.isNotEmpty)
                        Text(
                          initiatorInstrument,
                          style: TextStyle(
                            fontSize: 11,
                            color: kGold.withAlpha(204),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            // Header row
            Row(
              children: [
                if (event.type.isNotEmpty)
                  Text(
                    event.type,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: kGold,
                    ),
                  ),
                const Spacer(),
              ],
            ),
            if (event.location.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '📍 ${event.location}',
                style: const TextStyle(fontSize: 13, color: kMuted),
              ),
            ],
            if (event.date.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '🕐 ${_fmtTime(event.date)}',
                style: const TextStyle(fontSize: 13, color: kMuted),
              ),
            ],
            if (event.notes.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                '📝 ${event.notes}',
                style: const TextStyle(fontSize: 12, color: kMuted),
              ),
            ],
            // Participant chips
            if (event.participantUids.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Divider(color: kBorder, height: 1),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: event.participantUids.map((mUid) {
                  final m = _findUser(mUid);
                  final name = m?.name ?? mUid;
                  final instr = m?.instrument ?? '';
                  final isMe = mUid == currentUid;
                  // Ответ участника (шаг 4, пункт 2). В фишке он идёт ПОСЛЕ
                  // инструмента и тем же разделителем: строка узкая, второй
                  // ярус в неё не помещается, а различать нужно всё равно —
                  // иначе неответивший выглядит согласившимся.
                  final answer = participantAnswerLabel(event.answerFor(mUid));
                  return GestureDetector(
                    onTap: () => _openUserProfile(context, mUid),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: isMe ? kGold.withAlpha(38) : kBg3,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: isMe ? kGold : kBorder),
                      ),
                      child: Text(
                        '${m?.emoji ?? '🎵'} $name'
                        '${instr.isNotEmpty ? ' · $instr' : ''}'
                        '${answer.isNotEmpty ? ' · $answer' : ''}',
                        style: TextStyle(
                          fontSize: 12,
                          color: isMe ? kGold : kMuted,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }
}


/// МОЙ ОТВЕТ НА ПРИГЛАШЕНИЕ — шаг 4, пункт 3 (`docs/plan.md`).
///
/// Ответ становится ПОСТУПКОМ: до этого он существовал только как значение,
/// которое писал владелец, правя состав. Отсюда и вопрос о занятости — он
/// задаётся в момент согласия и больше нигде.
/// ДВЕ ФОРМЫ ОДНОГО ОТВЕТА — заведено 13.08 вместе с экраном `DƏVƏT`.
///
/// **Это НЕ два действия, склеенных переключателем (I58), и различие тут
/// принципиальное.** Признак склейки — когда вызывающему приходится сказать
/// «а этому не делать»: тогда за общим именем прячутся два дела. Здесь дело
/// одно и то же от первой строки до последней — человек отвечает на
/// приглашение, и весь путь (разбор занятого дня, вопрос при совпадении
/// минуты, запись ответа) общий. Расходится **только раскладка**: в карточке
/// вечера ответ стоит блоком среди прочего, на экране приглашения — двумя
/// кнопками в подвале, потому что там он единственное, за чем пришли.
///
/// Обратная проверка тем же правилом: развести это на два виджета значило бы
/// **сводить по совпадению вида наоборот — разводить по нему же**, и первая
/// же правка разбора конфликта легла бы в одну копию из двух.
enum _AnswerCardForm {
  /// Рамка с подписью «Cavabınız» и двумя кнопками в строку — в карточке
  /// вечера, где ответ соседствует с составом, голосовыми и договорённостью.
  boxed,

  /// Две кнопки во всю ширину, одна под другой, без рамки и подписи — подвал
  /// экрана `DƏVƏT` (макет `mugam-6-kart.html`, строки 128–131).
  footer,
}

class _MyAnswerCard extends StatefulWidget {
  const _MyAnswerCard({
    required this.event,
    required this.currentUid,
    required this.myEvents,
    required this.firestoreService,
    this.form = _AnswerCardForm.boxed,
  });

  /// Раскладка — разбор у [_AnswerCardForm]. Умолчание `boxed`, потому что
  /// карточка вечера была первой и её вызывающие про формы не знают.
  final _AnswerCardForm form;

  final PersonalEvent event;
  final String currentUid;

  /// Свои плюс те, где я участник. Дедуп и отсев отменённых делает
  /// `conflictEventsOnDay` внутри правила — здесь список отдаётся как есть,
  /// чтобы не завести четвёртую сшивку (N75).
  final List<PersonalEvent> myEvents;
  final FirestoreService firestoreService;

  @override
  State<_MyAnswerCard> createState() => _MyAnswerCardState();
}

class _MyAnswerCardState extends State<_MyAnswerCard> {
  bool _saving = false;

  /// Записать ответ. Отказ НЕ ГЛОТАЕТСЯ: до выкладки правил шага 4 участнику
  /// нельзя писать в чужой документ вовсе, и молчаливый провал выглядел бы
  /// как «ответ принят».
  Future<void> _write(String answer) async {
    setState(() => _saving = true);
    try {
      await widget.firestoreService.setEventAnswer(
        widget.event.id,
        widget.currentUid,
        answer,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Cavab yazılmadı: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// «Иду» — единственный ответ, у которого есть вопрос перед записью.
  Future<void> _sayGoing() async {
    final conflicts = answerConflicts(
      target: widget.event,
      myEvents: widget.myEvents,
      currentUid: widget.currentUid,
      answer: kAnswerGoing,
    );
    if (conflicts.isEmpty) {
      await _write(kAnswerGoing);
      return;
    }
    if (!mounted) return;
    final choice = await showDialog<AnswerConflictChoice>(
      context: context,
      builder: (_) => AnswerConflictDialog(conflicts: conflicts),
    );
    // Что писать — решает ПРАВИЛО, а не экран (`answerAfterConflict`). Там же
    // записано, почему закрытие окна и «посмотреть» не пишут ничего: закрыл —
    // поступка не было, и записать за человека отказ значило бы ответить
    // вместо него (I47).
    final toWrite = answerAfterConflict(choice);
    if (toWrite != null) {
      await _write(toWrite);
      return;
    }
    if (choice == AnswerConflictChoice.view) {
      if (!mounted) return;
      // Открывается ТА карточка, а эта остаётся под ней: вернувшись,
      // человек продолжает с того же места и с тем же вопросом.
      //
      // ЧЕРЕЗ ОБЩУЮ ДВЕРЬ (N90, N117), а не своим `MaterialPageRoute`: здесь
      // стоял прямой вызов карточки, то есть вторая дорога к тому же экрану.
      // Пока карточек было две, она открывала не ту при договорённости; и
      // даже теперь, когда карточка одна, прямой вызов остаётся местом, где
      // следующее изменение двери обойдёт стороной.
      Navigator.push(
        context,
        eventDetailRoute(
          eventId: conflicts.first.id,
          currentUid: widget.currentUid,
        ),
      );
    }
  }

  /// Мероприятия того же дня, кроме занявших ту же минуту, — их показывает
  /// плашка. Считается в `build`, а не в состоянии: список мероприятий живой,
  /// и снятый однажды ответ устарел бы молча.
  List<PersonalEvent> get _dayNotice => answerDayNotice(
    target: widget.event,
    myEvents: widget.myEvents,
    currentUid: widget.currentUid,
  );

  /// ЗАНЯТЫЙ ДЕНЬ — ПЛАШКОЙ, ДО НАЖАТИЯ (макет `mugam-6-kart.html`).
  ///
  /// Не вопрос: два мероприятия в один день — обычная жизнь, и вопрос,
  /// который задают всегда, перестают читать. Вопрос остаётся у минуты в
  /// минуту, где человек оказался бы в двух местах разом.
  ///
  /// **Вынесено в метод 13.08, когда форм стало две.** Оставь плашку внутри
  /// каждой раскладки — и получишь две копии одного предупреждения, которые
  /// разойдутся в первой же правке. Это то самое место, где сводить надо по
  /// задаче: задача у них общая (сказать, что день занят), и потому у них
  /// один код.
  Widget _dayNoticeBox() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: kWarnBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kWarnBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Bu gün artıq tədbirin var',
            style: TextStyle(fontSize: 14, color: kText),
          ),
          const SizedBox(height: 4),
          // Чем именно занят день — иначе «занято» не отличает важное от
          // проходного.
          for (final e in _dayNotice)
            Text(
              eventConflictSummary(e),
              style: const TextStyle(fontSize: 13, color: kMuted),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mine = widget.event.answerFor(widget.currentUid);

    // ПОДВАЛЬНАЯ ФОРМА — экран `DƏVƏT`. Ни рамки, ни подписи «Cavabınız»:
    // там ответ не соседствует ни с чем, и называть его отдельно значит
    // объяснять человеку, зачем он открыл экран приглашения.
    //
    // Плашка занятого дня остаётся — она предупреждение, а не украшение, и
    // теряться от смены раскладки не должна.
    if (widget.form == _AnswerCardForm.footer) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_dayNotice.isNotEmpty) ...[
            _dayNoticeBox(),
            const SizedBox(height: 14),
          ],
          // КНОПКИ ТЕ ЖЕ, ЧТО В КАРТОЧКЕ, — вместе с состоянием «выбрано», и
          // ради него они сюда и взяты.
          //
          // Первая редакция ставила здесь `_CardButton` (просто рамка), и
          // экран получился немым: «Bacarmıram» ответ ЗАПИСЫВАЛА, но после
          // неё роль становится `declined` — то есть по-прежнему приглашение,
          // чтобы человек мог передумать, — экран оставался тем же, и НИ ОДИН
          // пиксель не менялся. Автор нажал и сказал «кнопка не работает»,
          // и был прав: для него не работает то, что не отвечает.
          //
          // У «Gəlirəm» дефекта не было видно: там роль становится
          // «занят», карточка сменяется сама, и изменение заметно.
          // **Немой оказалась не кнопка, а состояние, у которого не было
          // показа** — и заметно это стало только на том ответе, который
          // экрана не меняет.
          _answerButton(
            label: 'Gəlirəm',
            selected: mine == kAnswerGoing,
            onTap: _saving ? null : _sayGoing,
            big: true,
          ),
          const SizedBox(height: 11),
          _answerButton(
            label: 'Bacarmıram',
            selected: mine == kAnswerCant,
            onTap: _saving ? null : () => _write(kAnswerCant),
            big: true,
          ),
        ],
      );
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kBg3,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Cavabınız',
            style: GoogleFonts.nunito(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: kText,
            ),
          ),
          const SizedBox(height: 4),
          // Текущий ответ называется словом, тем же, что в составе: два места
          // об одном обязаны говорить одинаково.
          Text(
            participantAnswerLabel(mine),
            style: const TextStyle(fontSize: 13, color: kTextSecondary),
          ),
          // ЗАНЯТЫЙ ДЕНЬ — ПЛАШКОЙ, ДО НАЖАТИЯ (макет `mugam-6-kart.html`).
          // Не вопрос: два мероприятия в один день — обычная жизнь, и вопрос,
          // который задают всегда, перестают читать. Вопрос остаётся у минуты
          // в минуту, где человек оказался бы в двух местах разом.
          if (_dayNotice.isNotEmpty) ...[
            const SizedBox(height: 10),
            _dayNoticeBox(),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _answerButton(
                  label: 'Gəlirəm',
                  selected: mine == kAnswerGoing,
                  onTap: _saving ? null : _sayGoing,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _answerButton(
                  // Слово из макета (`mugam-6-kart.html`), а не своё:
                  // «Bacarmıram», не «Gələ bilmirəm».
                  label: 'Bacarmıram',
                  selected: mine == kAnswerCant,
                  // У отказа вопроса нет: человек освобождает время, а не
                  // занимает его, и мешать ему нечем.
                  onTap: _saving ? null : () => _write(kAnswerCant),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// [big] — подвальная форма экрана `DƏVƏT`: отступ 15 и шрифт крупнее, как
  /// в макете. Отличие только в размере, потому что **кнопка та же самая** —
  /// вместе с состоянием «выбрано», ради которого она сюда и взята.
  Widget _answerButton({
    required String label,
    required bool selected,
    required VoidCallback? onTap,
    bool big = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: EdgeInsets.symmetric(vertical: big ? 15 : 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          // Выбранный ответ залит, невыбранный — рамкой. Цвет один и тот же:
          // «не могу» красным здесь означало бы то же, что отмена вечера
          // (N110), а это разные вещи.
          color: selected ? kGold.withAlpha(38) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: selected ? kGold : kBorder),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: big ? 16 : 13,
            color: selected ? kGold : kMuted,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

// Подсветка изменения, ПРИЕХАВШЕГО ИЗВНЕ.
//
// Зачем. После N23 чужая правка доезжает до открытой карточки и молча
// подменяет значение. Человек смотрит на экран, дата меняется — и если он
// в этот момент моргнул, он не узнает, что договор вообще трогали, и
// продолжит помнить старую дату. Живое обновление без признака хуже
// устаревшего экрана: устаревший хотя бы честно показывает одно и то же.
//
// Почему только чужое. Своё сохранение человек только что сделал руками,
// мигать ему незачем. А главное — признак, который загорается всегда,
// перестают замечать за неделю, и тогда он не сработает там, где нужен.
// Отличаем по значению, а не по флагу «я только что сохранял»: лист
// возвращает то, что записал, и если пришедшее значение совпало с ним —
// это наша собственная запись вернулась через поток. Флаг «подавить
// следующее изменение» проглотил бы чужую правку, случившуюся в ту же
// секунду; сравнение по значению — нет.
class _RemoteChangeFlash {
  static const _duration = Duration(seconds: 4);

  Map<String, String>? _prev;
  Map<String, String>? _selfSaved;
  Timer? _timer;
  Set<String> flashing = const {};

  // Ключи — имена ПОЛЕЙ, а не подписи строк. Подписи у двух карточек
  // разные («Vaxt» против «Saat», «Əlavələr» против «Qeyd»), и ключ по
  // подписи молча перестал бы совпадать на второй из них. Дата с временем
  // живут в одном поле, поэтому обе строки, нарисованные из него, просят
  // один и тот же ключ и загораются вместе — это правда: сдвиг времени и
  // есть изменение даты.
  static Map<String, String> _fieldsOf(PersonalEvent e) => {
    'type': e.type,
    'date': e.date,
    'location': e.location,
    'notes': e.notes,
  };

  void rememberSelfSave(Map<String, String>? saved) => _selfSaved = saved;

  // Вызывается в начале build. Значение flashing выставляется синхронно,
  // поэтому текущая же перерисовка уже покажет подсветку; setState нужен
  // только на её гашение, и он приходит из таймера — вне build.
  void sync(PersonalEvent event, void Function() onExpire) {
    final now = _fieldsOf(event);
    final prev = _prev;
    _prev = now;
    // Первый кадр карточки: сравнивать не с чем, и подсвечивать при
    // открытии нечего — иначе загоралось бы всё подряд на каждом входе.
    if (prev == null) return;

    final changed = now.keys.where((k) => now[k] != prev[k]).toSet();
    if (changed.isEmpty) return;

    final self = _selfSaved;
    if (self != null) {
      changed.removeWhere((k) => now[k] == self[k]);
      // Своё сохранение засчитывается ровно один раз: следующее изменение
      // тех же полей уже чужое.
      _selfSaved = null;
    }
    if (changed.isEmpty) return;

    flashing = changed;
    _timer?.cancel();
    _timer = Timer(_duration, () {
      flashing = const {};
      onExpire();
    });
  }

  void dispose() => _timer?.cancel();
}

// Обе карточки ниже ищут своё событие так: сначала среди собственных, потом
// среди тех, где человек участник. Дедупликация не нужна — берём первое
// совпадение, а id уникален на всю базу.
// Поиск переехал в `core/agreements/event_lookup.dart` — здесь остался
// вызов. С публичной дверью по `eventId` у правила «искать в своих и в
// тех, где я участник» появился ТРЕТИЙ читатель, а три места, ищущие
// по-своему, разойдутся молча (I23).
PersonalEvent? _findEvent(
  String id,
  List<PersonalEvent> own,
  List<PersonalEvent> asParticipant,
) => findEventById(id, own, asParticipant);

// Событие исчезло, пока карточка открыта: владелец удалил его с другого
// устройства. Отменённое сюда не попадает — у отменённого документ на
// месте, меняется только `status`. Пустой экран с рабочей кнопкой «назад»
// честнее, чем последний снимок: показывать нечего, а держать на экране
// то, чего в базе уже нет, — ровно тот дефект, который здесь чинится.
Widget _eventGoneScaffold(String title, VoidCallback onBack) {
  return Scaffold(
    backgroundColor: kBg,
    appBar: AppBar(
      backgroundColor: kBg2,
      title: Text(title, style: GoogleFonts.nunito(color: kGold, fontSize: 18)),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, color: kGold),
        onPressed: onBack,
      ),
    ),
    body: const Center(
      child: Text(
        'Bu qeyd artıq mövcud deyil',
        style: TextStyle(color: kMuted),
      ),
    ),
  );
}
// ---------------------------------------------------------------------------
// PersonalEventDetail screen
// ---------------------------------------------------------------------------
// По id, а не копией, — по той же причине, что и карточка договора выше
// (N23). У этого экрана дефект был тот же и вдобавок шире: через
// `Navigator.push` (единственная точка входа, где карточка живёт своим
// маршрутом) в него уезжали копиями ещё и `allUsers` с обоими списками
// событий, то есть устаревали не только поля события, но и имена
// участников.
class _PersonalEventDetailScreen extends ConsumerStatefulWidget {
  final String eventId;
  final String currentUid;
  final VoidCallback onBack;

  const _PersonalEventDetailScreen({
    required this.eventId,
    required this.currentUid,
    required this.onBack,
  });

  @override
  ConsumerState<_PersonalEventDetailScreen> createState() =>
      _PersonalEventDetailScreenState();
}

class _PersonalEventDetailScreenState
    extends ConsumerState<_PersonalEventDetailScreen> {
  final _flash = _RemoteChangeFlash();

  // Отметка «смотрю в эту карточку» — тот же механизм присутствия, что у
  // чата, но своим полем (`activeEventId`). Пока карточка открыта, сервер
  // не шлёт уведомлений об ЭТОМ мероприятии: человек и так видит правку
  // своими глазами, а пуш поверх открытого экрана раздражает.
  //
  // Снимается в dispose, а протухает сама вместе с сердцебиением — свернул
  // приложение, и отметка перестаёт быть свежей без всякой уборки. Ровно
  // это и чинил N19: признак без срока годности глушил уведомления
  // навсегда.
  /// «ONSUZ DAVAM EDİRƏM» — возврат вечера в силу после ухода участника.
  ///
  /// **Спрашивает подтверждение, потому что ход НЕОБРАТИМ** (I29): в отличие
  /// от отмены, которая лишь задаёт вопрос второй стороне, этот немедленно
  /// даёт обещание прийти без ушедшего.
  ///
  /// Отказ не глотается: правило `restoresEvent()` пускает только владельца,
  /// только из `unsettled` и только по поводу `memberLeft`, и если состояние
  /// успело измениться, человек обязан узнать об этом словами.
  /// «DƏYİŞİKLİK» — та же форма правки, что открывалась карандашом в шапке.
  ///
  /// Кнопка внизу заведена по макету, а карандаш оставлен: это не второй путь
  /// к другому действию, а один и тот же вызов из двух мест экрана. Разойтись
  /// им нечем — обе строки зовут этот метод.
  void _openEdit(
    PersonalEvent event,
    List<User> allUsers,
    List<PersonalEvent> personalEvents,
    List<PersonalEvent> eventsAsParticipant,
    FirestoreService firestoreService,
  ) {
    DateTime initialDate;
    try {
      initialDate = DateTime.parse(event.date);
    } catch (_) {
      initialDate = DateTime.now();
    }
    showModalBottomSheet(
      isDismissible: false,
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _EventFormModal(
        mode: 'time-only',
        initialDate: initialDate,
        initialType: event.type,
        initialLocation: event.location,
        initialNotes: event.notes,
        initialParticipantUids: event.participantUids,
        allUsers: allUsers,
        existingEvent: event,
        allCombinedEvents: [...personalEvents, ...eventsAsParticipant],
        currentUid: widget.currentUid,
        firestoreService: firestoreService,
        onWillSave: _flash.rememberSelfSave,
      ),
    );
  }

  /// ОТВЕТ ЗАГЛУШКИ — «скоро».
  ///
  /// Стоит под кнопками, у которых механизма ещё нет: «Şübhə altına al»
  /// (третий повод под вопроса) и голосовое. Обе показаны потому, что их
  /// показывает макет; **говорить правду при нажатии — единственное, что
  /// делает такую кнопку честной.** Молчаливая кнопка хуже отсутствующей:
  /// человек решает, что действие сделано.
  void _soon(BuildContext context) => _soonSnack(context);

  /// Прошедший вечер состояние не меняет — плашка не нажимается (12.08).
  bool _isPast(PersonalEvent e) {
    try {
      return DateTime.parse(e.date).isBefore(DateTime.now());
    } catch (_) {
      return false;
    }
  }


  @override
  void initState() {
    super.initState();
    PresenceService.instance.setActiveEvent(widget.eventId);
  }

  @override
  void dispose() {
    PresenceService.instance.setActiveEvent(null);
    _flash.dispose();
    super.dispose();
  }

  /// ОТМЕНА СВОЕГО ВЕЧЕРА — один ход, без согласия второй стороны (13.08).
  ///
  /// **Ход в правилах уже есть и остаётся жить: `ownerCancelsOwnEvent`**,
  /// выложен 12.08. Из семи ходов отмены, которые эта работа делает мёртвыми,
  /// он единственный уцелел — и теперь он единственный способ отменить вечер
  /// вообще.
  ///
  /// **Договорённость отменяется ТЕМ ЖЕ ходом, что и личный вечер, и в этом
  /// вся правка.** Прежде у неё была своя дорога — «попросить согласия»; она
  /// снята вместе с самим различением. Владелец договорённости — такой же
  /// владелец вечера.
  ///
  /// Подтверждение спрашивается один раз. **Причина словами или голосом
  /// приедет отдельно**, вместе с окном «Gələ bilmirəm»: у них одно окно, и
  /// писать его дважды нельзя.
  Future<void> _cancelOwnEvent(
    PersonalEvent event,
    FirestoreService service,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: kBg2,
        title: const Text(
          'Tədbiri ləğv etmək?',
          style: TextStyle(color: kText, fontSize: 17),
        ),
        content: const Text(
          'Tədbir ləğv olunacaq və heyət bundan xəbər tutacaq.',
          style: TextStyle(color: kTextSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('İmtina', style: TextStyle(color: kMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Ləğv et', style: TextStyle(color: kRed)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await service.setEventStatus(
        event.id,
        widget.currentUid,
        kStatusCancelled,
        // Поступок называется своим именем: сервер берёт отсюда автора и
        // повод для уведомления, и «ownerCancelled» — единственный, который
        // теперь бывает.
        'ownerCancelled',
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Ləğv edilmədi: $e')),
      );
    }
  }

  User? _findUser(List<User> allUsers, String uid) {
    try {
      return allUsers.firstWhere((m) => m.id == uid);
    } catch (_) {
      return null;
    }
  }

  void _openUserProfile(
    BuildContext context,
    List<User> allUsers,
    String? uid,
  ) {
    final u = uid == null ? null : _findUser(allUsers, uid);
    if (u == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => UserProfileScreen(user: u)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentUid = widget.currentUid;
    final onBack = widget.onBack;
    final personalEvents =
        ref.watch(personalEventsProvider(currentUid)).asData?.value ?? [];
    final eventsAsParticipant =
        ref.watch(eventsAsParticipantProvider(currentUid)).asData?.value ?? [];
    final allUsers = ref.watch(allUsersProvider).asData?.value ?? [];
    final firestoreService = ref.read(firestoreServiceProvider);

    final event = _findEvent(
      widget.eventId,
      personalEvents,
      eventsAsParticipant,
    );
    if (event == null) return _eventGoneScaffold('Tədbir', onBack);

    _flash.sync(event, () {
      if (mounted) setState(() {});
    });

    final isOwner = event.ownerUid == currentUid;
    final initiatorUid = isOwner ? currentUid : event.ownerUid;
    final initiator = _findUser(allUsers, initiatorUid);
    // То же правило, что и в карточке списка (N53).
    final initiatorName = initiator?.name ?? (isOwner ? 'Siz' : 'Naməlum');

    return Scaffold(
      backgroundColor: kBg,
      // ШАПКИ НЕТ ВОВСЕ — по макету (`docs/design/mugam-6-kart`, левый экран):
      // там сверху только «← Geri» мелким серым, без заголовка и без
      // карандаша. Заголовок «Tədbir» повторял то, что и так написано первой
      // строкой крупно, а карандаш был вторым путём к правке — теперь она
      // одна, кнопкой «Dəyişiklik et» внизу.
      //
      // Прежняя редакция этого экрана заголовок оставила, хотя в отчёте было
      // сказано, что он убран: правка тела и правка шапки — разные места, и
      // сверять надо по экрану, а не по замыслу.
      // КНОПКИ ПРИЖАТЫ К НИЗУ — в макете подвал стоит на `margin-top: auto`.
      // Приём: высота содержимого не меньше экрана (`ConstrainedBox` по
      // `maxHeight` области), `IntrinsicHeight` делает её конечной, и тогда
      // `Spacer` разводит содержимое и кнопки по краям. Без него кнопки
      // липли к тексту, а под ними оставалась пустота в треть экрана.
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, viewport) => SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: viewport.maxHeight - 40),
              child: IntrinsicHeight(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // «← GERİ» — единственное, что осталось от шапки.
                    GestureDetector(
                      onTap: onBack,
                      behavior: HitTestBehavior.opaque,
                      child: const Padding(
                        padding: EdgeInsets.only(bottom: 14),
                        child: Text(
                          '← Geri',
                          style: TextStyle(fontSize: 15, color: kMuted),
                        ),
                      ),
                    ),
                    // ── КАРТОЧКА ВЕЧЕРА СОБРАНА ПО МАКЕТУ ──────────────────────
                    // `docs/design/mugam-6-kart` (левый экран), 12.08. Прежде здесь
                    // стоял прежний экран мероприятия, куда были ДОПИСАНЫ плашка и
                    // строка договорённости, — и порядок вышел свой: плашка
                    // организатора, таблица из пяти полей, где дата пятой строкой,
                    // крупные карточки участников со стрелками.
                    //
                    // Макет говорит другое, и разница не косметическая: **вечер
                    // отвечает на «когда», а не на «какие у него поля»**. Поэтому
                    // дата и время идут ПЕРВОЙ строкой и крупно, а тип с местом —
                    // одной строкой под ней.
                    //
                    // ПЛАШКА ОРГАНИЗАТОРА УБРАНА У ВЛАДЕЛЬЦА и оставлена
                    // приглашённому. Она отвечала на вопрос «чей это вечер» — у
                    // владельца такого вопроса нет, он свой вечер и открыл; а
                    // приглашённому это первое, что нужно знать, и в макете второго
                    // экрана ровно оно и стоит: «Rafael səni çağırır».
                    if (!isOwner) ...[
                      Center(
                        child: GestureDetector(
                          onTap: () =>
                              _openUserProfile(context, allUsers, initiatorUid),
                          child: Text(
                            '$initiatorName səni çağırır',
                            style: const TextStyle(
                              fontSize: 15,
                              color: kTextSecondary,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                    ],

                    // 1. ДАТА И ВРЕМЯ — первой строкой, крупно (макет: 26pt).
                    Text(
                      _fmtDayAndTime(event.date),
                      style: const TextStyle(fontSize: 26, color: kText),
                    ),

                    // 2. ТИП И МЕСТО — одной строкой под ней. Пустые части не
                    // оставляют висящих разделителей: у вечера может не быть места.
                    if (_typeAndPlace(event).isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        _typeAndPlace(event),
                        style: const TextStyle(
                          fontSize: 15,
                          color: kTextSecondary,
                        ),
                      ),
                    ],

                    // 3. ПЛАШКА СОСТОЯНИЯ СНЯТА ЦЕЛИКОМ (решение автора
                    // 13.08). Была: показывала «Dəqiq» и открывала окошко на
                    // три пункта — в силе, под вопросом, отменён.
                    //
                    // **Довод автора: «под вопросом» музыканту не нужно —
                    // вечер либо есть, либо отменён.** Третье состояние
                    // заводилось приложением для себя: оно давало данным
                    // сойтись, а человеку предлагало решение, которого он в
                    // жизни не принимает.
                    //
                    // Отмена не пропала — переехала в подвал отдельной
                    // кнопкой «Ləğv et», одним нажатием и без выбора из трёх.
                    //
                    // Значение `unsettled` в данных НЕ ТРОНУТО: в проде оно у
                    // одного документа из 91 (перепись 13.08), и он теперь
                    // покажется обычным. **Это решение, а не пропуск** —
                    // разбор в `docs/plan.md`.

                    // 4. СОСТАВ — компактными строками: кружок с двумя буквами в
                    // обводке по ответу, имя, под ним ответ. Без крупных карточек и
                    // без стрелок: стрелка обещает переход, а тут переход не главное.
                    if (event.participantUids.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      Text(
                        _partyHeader(event),
                        style: const TextStyle(
                          fontSize: 13,
                          letterSpacing: 1.5,
                          color: kMuted,
                        ),
                      ),
                      const SizedBox(height: 12),
                      for (final uid in event.participantUids)
                        _PartyMemberRow(
                          name: _findUser(allUsers, uid)?.name ?? uid,
                          answer: event.answerFor(uid),
                          onTap: () => _openUserProfile(context, allUsers, uid),
                          // КНОПКА «?» СНЯТА (решение автора 13.08). Была: у
                          // вышедшего участника, два выбора — «Dəqiqləşdir»
                          // (спросить в чате) и «Siyahıdan sil» (убрать из
                          // состава).
                          //
                          // **Довод автора: вышедший помечен «İşdən çıxdı»,
                          // этого достаточно, а спросить можно в чате.** То
                          // есть окошко предлагало дорогу, которая и так есть,
                          // и второй ход, которого никто не просил.
                          //
                          // Показать её всё равно было некому: значение
                          // `left` не пишет ни одно место в `lib` (N121), и
                          // условие показа кончалось на `answer == left`.
                          onAsk: null,
                        ),
                    ],

                    // ЗАМЕТКА — если она есть. В макете её нет вовсе, но поле живое
                    // («Qalstuk, qara kostyum») и молчать о нём нельзя: это то, что
                    // человек должен надеть, придя на вечер.
                    if (event.notes.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text(
                        event.notes,
                        style: const TextStyle(
                          fontSize: 14,
                          color: kTextSecondary,
                        ),
                      ),
                    ],

                    // ГОЛОСОВОЕ — ЗАГЛУШКА (решение владельца 12.08). Сама
                    // работа с голосом не написана (Часть 11 плана).
                    //
                    // **Длительности и волны здесь НЕТ намеренно.** В макете
                    // нарисованы «0:14» и столбики — но записи не
                    // существует, и показать её признаки значило бы
                    // нарисовать данные, которых нет. Заглушка честная:
                    // видно, что место для голоса задумано, и слышно при
                    // нажатии, что его пока нет.
                    const SizedBox(height: 16),
                    GestureDetector(
                      onTap: () => _soon(context),
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: kBorder, width: 1.5),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 28,
                              height: 28,
                              alignment: Alignment.center,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: kGoldDim,
                              ),
                              child: const Icon(
                                Icons.play_arrow,
                                size: 16,
                                color: kGold,
                              ),
                            ),
                            const SizedBox(width: 10),
                            const Text(
                              'Səsli qeyd',
                              style: TextStyle(fontSize: 14, color: kMuted),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // 4а. МОЙ ОТВЕТ — виден ТОЛЬКО тому, кого позвали: владелец
                    // согласия не даёт, он вечер создал (N112), а тот, кого нет
                    // в составе, отвечать не за что. `answerFor` возвращает
                    // `null` для не-участника, и это условие здесь единственное:
                    // спрашивать «есть ли он в составе» вторым способом значило
                    // бы завести второе место, где решается тот же вопрос.
                    //
                    // ВЕРНУТО 12.08 (N125). Вызов был снят при пересборке
                    // карточки по макету (`6741c49`), а сам класс остался —
                    // и участнику стало нечем ответить на приглашение. Пара
                    // «виджет + состояние» ссылается сама на себя, поэтому
                    // `unused_element` осиротевший `_MyAnswerCard` не увидел,
                    // а ни один тест не утверждает, что действие ПРЕДЛОЖЕНО
                    // (I32): 569 тестов из 569 остались зелёными.
                    //
                    // Место — по макету `mugam-6-kart.html`: после голосовых,
                    // до строки договорённости; плашку занятого дня виджет
                    // несёт в себе, и она встаёт туда же, где в макете.
                    // ВИД С МАКЕТОМ ПОКА НЕ СХОДИТСЯ и правится отдельно:
                    // там две кнопки во всю ширину, одна под другой, в подвале
                    // на `margin-top:auto` и без рамки с подписью «Cavabınız».
                    // Здесь возвращается ТОЛЬКО вызов: у починки поломки одна
                    // переменная, иначе не отличить, что именно её вылечило.
                    if (!isOwner && event.answerFor(currentUid) != null) ...[
                      const SizedBox(height: 20),
                      _MyAnswerCard(
                        event: event,
                        currentUid: currentUid,
                        myEvents: [...personalEvents, ...eventsAsParticipant],
                        firestoreService: firestoreService,
                      ),
                    ],

                    // 5. СТРОКА ДОГОВОРЁННОСТИ СНЯТА ЦЕЛИКОМ, вместе с
                    // раскрытием и отменой по согласию (решение автора 13.08).
                    //
                    // **Довод автора: в жизни нет взаимных подтверждений.**
                    // Занят на дату, потом не смог — звонишь и говоришь «не
                    // смогу»; работодатель либо ищет сам, либо просит найти
                    // замену. Договорённость И ЕСТЬ согласие: согласился —
                    // идёшь, не можешь — сказал.
                    //
                    // Снято отсюда: зелёная строка «Teymur razılaşdı · дата»,
                    // раскрытие с историей и четыре хода отмены по согласию
                    // («Müqaviləni ləğv et», «Razıyam ləğv edilsin», отзыв,
                    // отказ).
                    //
                    // **`isAgree` НЕ ТРОНУТ** — он уже не решает, что
                    // показывать, и 27 существующих договорённостей остаются
                    // обычными вечерами. Строка исчезает у всех.
                    //
                    // На смену придёт «Gələ bilmirəm» у согласившегося
                    // участника — ход односторонний, с ответом инициатора
                    // (`docs/plan.md`, работа 13.08). **Ходы отмены по
                    // согласию в правилах прода снимаются ОТДЕЛЬНОЙ выкладкой
                    // и только после того, как «Gələ bilmirəm» готово:**
                    // снять раньше значит оставить вечер, из которого не
                    // выйти никак.

                    // Распорка: всё выше остаётся у верхнего края, кнопки уезжают к
                    // нижнему — как подвал макета на `margin-top: auto`.
                    const Spacer(),

                    // 6. КНОПКИ — внизу, сразу видны, не внутри раскрытия. Разделение
                    // владельца 12.08: кнопки это действия с вечером, строка выше —
                    // память о нём.
                    if (isOwner) ...[
                      const SizedBox(height: 22),
                      _CardButton(
                        label: 'Dəyişiklik et',
                        tone: _CardButtonTone.gold,
                        onTap: () => _openEdit(
                          event,
                          allUsers,
                          personalEvents,
                          eventsAsParticipant,
                          firestoreService,
                        ),
                      ),
                      // ОТМЕНА — ОДНИМ НАЖАТИЕМ, БЕЗ СОГЛАСИЙ (13.08).
                      //
                      // Прежде отмена жила в окошке на плашке и у
                      // договорённости не отменяла, а ПРОСИЛА согласия второй
                      // стороны. Согласий больше нет: владелец отменяет свой
                      // вечер сам, как в жизни.
                      //
                      // **Причина словами или голосом сюда ещё не приделана** —
                      // она приедет вместе с окном «Gələ bilmirəm»
                      // (`docs/plan.md`, шаг 3 работы 13.08), у них одно и то
                      // же окно. Пока стоит подтверждение: отмена необратима
                      // для тех, кто уже согласился, и спросить один раз
                      // дешевле, чем объяснять потом.
                      if (!_isPast(event) && event.status != kStatusCancelled)
                        ...[
                          const SizedBox(height: 11),
                          _CardButton(
                            label: 'Ləğv et',
                            tone: _CardButtonTone.plain,
                            onTap: () => _cancelOwnEvent(
                              event,
                              firestoreService,
                            ),
                          ),
                        ],
                      // «Şübhə altına al» и «Onsuz davam edirəm» СНЯТЫ
                      // 12.08: первую заменило окошко выбора на плашке, вторую
                      // — «убрать из состава» у вышедшего. Обе делали то, что
                      // теперь делается там, где человек об этом и думает.
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _ConflictEventScreen
// ---------------------------------------------------------------------------
// Публичная точка входа: лист предложения работы (job_offer/screens/
// job_offer_date_sheet.dart) показывает тот же общий диалог конфликта, и
// по ответу «Bax» обязан открыть ровно этот экран, а не свой похожий.
//
// Экран остаётся приватным намеренно: он тянет за собой карточку события
// (`_EventCard`) и экран подробностей (`_PersonalEventDetailScreen`), и
// вытаскивать их наружу ради одного вызова значило бы разобрать половину
// этого файла. Наружу отдан только маршрут.
// ---------------------------------------------------------------------------
// ПУБЛИЧНЫЙ ВХОД В КАРТОЧКУ ПО `eventId` (N90)
// ---------------------------------------------------------------------------
// Дверь к карточке мероприятия или договора, открываемая ОТКУДА УГОДНО.
// До неё карточку можно было показать только изнутри этого экрана: обе
// приватны, а в главном потоке даже не пушатся — `build()` возвращает их
// вместо собственного тела по полю состояния.
//
// ПОЧЕМУ ФУНКЦИЯ ЖИВЁТ ЗДЕСЬ, а не в своём файле: обе карточки —
// приватные классы этого файла, и назвать их снаружи нельзя правилом
// языка, а не по договорённости. Сделать их публичными и вынести из
// четырёхтысячного файла — это пункт 14 (`docs/plan.md`), и начинать его
// под видом обёртки значило бы подменить работу. Прецедент рядом:
// `agreementConflictEventRoute` живёт тут же и зовётся из другой фичи.
//
// ТРИ СОСТОЯНИЯ, А НЕ ДВА, и это главное в этой двери (N92). Обе карточки
// ищут своё событие в списках, взятых как `asData?.value ?? []`, и на
// ненайденное отвечают «Bu qeyd artıq mövcud deyil». Пока карточку
// открывали изнутри экрана, данные всегда были уже на руках, и «пусто»
// означало «удалено». Дверь снаружи открывает её там, где потоки могут
// ещё грузиться, — и то же «пусто» означает «ещё не пришло». Поэтому
// здесь: грузится → ждём; пришло и нет → «удалено»; пришло и есть →
// карточка.
//
// ЧЕГО ЭТА ДВЕРЬ НЕ ЗАКРЫВАЕТ: путь роутера `/event/:id` и чтение
// `eventId` в `main.dart` (N59). Уведомлению нужен путь, а не функция:
// у него на руках нет `BuildContext` экрана. Таблица трёх поводов в N90
// закрывается этой работой на ОДНУ строку из трёх.
Route<void> eventDetailRoute({
  required String eventId,
  required String currentUid,
}) => MaterialPageRoute(
  builder: (_) => _EventDetailById(eventId: eventId, currentUid: currentUid),
);

/// ОТВЕТ ЗАГЛУШКИ — «скоро». Одно тело на весь файл.
///
/// Вынесено наверх 13.08, когда голосовые понадобились и на экране
/// приглашения. Копия здесь была бы не «лишними тремя строками», а вторым
/// местом, где решается, ЧТО говорить человеку при нажатии на кнопку без
/// механизма, — и они разошлись бы в первой же правке слова.
void _soonSnack(BuildContext context) {
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(const SnackBar(content: Text('Tezliklə əlavə olunacaq')));
}

/// ЭКРАН ПРИГЛАШЕНИЯ — второй экран макета `mugam-6-kart.html` (строка 101).
///
/// Написан 13.08. До него приглашённый попадал в **общую карточку вечера** —
/// в экран, сделанный для того, у кого этот вечер уже есть. Разница не в
/// красоте: карточка отвечает на «что у меня в этот день», а у приглашённого
/// в этот день пока НИЧЕГО нет, ему задан вопрос.
///
/// **Открывается через ту же дверь `eventDetailRoute`**, а не своим
/// маршрутом. Дверь одна, и решает она одним правилом — `showsAsInvitation`,
/// тем же, по которому строка под сеткой отличается от карточки дня. Второй
/// маршрут к тому же документу уже был дефектом дважды (N90, N117).
///
/// **Порядок сверху вниз взят у макета и не переставлен:** кто зовёт — когда
/// — что за вечер — где — голосовые — занятый день — две кнопки в подвале.
/// Имя стоит ПЕРВЫМ, раньше даты: у приглашения главное «кто», у своего
/// вечера — «во сколько», и это разные экраны именно поэтому.
class _InvitationScreen extends ConsumerWidget {
  const _InvitationScreen({
    required this.event,
    required this.currentUid,
    required this.onBack,
  });

  final PersonalEvent event;
  final String currentUid;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final users = ref.watch(allUsersProvider).asData?.value ?? const <User>[];
    // ИМЯ ЗОВУЩЕГО БЕРЁТСЯ ПО `ownerUid`, И ЗАПАСНОГО ИМЕНИ ЗДЕСЬ НЕТ.
    //
    // Первая редакция ставила запасным `event.partnerName` — и это была
    // готовая N53, пойманная сторожем в тот же заход. **`partnerName` значит
    // «вторая сторона ГЛАЗАМИ ВЛАДЕЛЬЦА»**: у приглашённого в этом поле лежит
    // его СОБСТВЕННОЕ имя, и экран сказал бы Teymur'у «Teymur səni çağırır».
    //
    // «Naməlum» вместо чужого имени — не бедность, а честность: не знать, кто
    // зовёт, неприятно, но назвать зовущим самого приглашённого — неправда.
    final owner = users.where((u) => u.id == event.ownerUid).firstOrNull;
    final ownerName =
        (owner?.name.isNotEmpty ?? false) ? owner!.name : 'Naməlum';

    final own = ref.watch(personalEventsProvider(currentUid)).asData?.value ??
        const <PersonalEvent>[];
    final asParticipant =
        ref.watch(eventsAsParticipantProvider(currentUid)).asData?.value ??
            const <PersonalEvent>[];

    final typeAndPlace = [
      if (event.location.isNotEmpty) event.location,
    ].join(' · ');

    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              GestureDetector(
                onTap: onBack,
                behavior: HitTestBehavior.opaque,
                child: const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '← Geri',
                    style: TextStyle(fontSize: 15, color: kMuted),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              // Заголовок экрана — `.cap` макета: золотой, с разрядкой. Тем же
              // стилем набрано «AVQUST 2026» над сеткой месяца.
              const Text(
                'DƏVƏT',
                style: TextStyle(
                  fontSize: 14,
                  letterSpacing: 1.8,
                  color: kGold,
                ),
              ),
              const SizedBox(height: 30),

              // КРУЖОК С ИНИЦИАЛАМИ ЗОВУЩЕГО — ДВЕ буквы, а не три.
              // Правило одно на проект (`initialsOf`), длина — параметр: в
              // клетке календаря под числом стоят три (`RAF`), в кружке —
              // две (`RA`). Это не разнобой, а два разных места макета.
              Center(
                child: Container(
                  width: 66,
                  height: 66,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: kGold, width: 1.5),
                  ),
                  child: Text(
                    initialsOf(ownerName, count: 2),
                    style: const TextStyle(fontSize: 20, color: kGold),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Center(
                child: Text(
                  '$ownerName səni çağırır',
                  style: const TextStyle(fontSize: 15, color: kTextSecondary),
                ),
              ),
              const SizedBox(height: 14),
              Center(
                child: Text(
                  fmtDayHeader(DateTime.tryParse(event.date) ?? DateTime.now()),
                  style: const TextStyle(fontSize: 29, color: kText),
                ),
              ),
              const SizedBox(height: 5),
              Center(
                child: Text(
                  [fmtEventTime(event.date), event.type]
                      .where((s) => s.isNotEmpty)
                      .join(' · '),
                  style: const TextStyle(fontSize: 17, color: kText),
                ),
              ),
              if (typeAndPlace.isNotEmpty) ...[
                const SizedBox(height: 5),
                Center(
                  child: Text(
                    typeAndPlace,
                    style: const TextStyle(fontSize: 14, color: kMuted),
                  ),
                ),
              ],

              const SizedBox(height: 22),
              const Text(
                'SƏSLİ QEYDLƏR',
                style: TextStyle(
                  fontSize: 12,
                  letterSpacing: 1.2,
                  color: kMuted,
                ),
              ),
              const SizedBox(height: 10),
              GestureDetector(
                onTap: () => _soonSnack(context),
                behavior: HitTestBehavior.opaque,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: kBorder, width: 1.5),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 28,
                        height: 28,
                        alignment: Alignment.center,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: kGoldDim,
                        ),
                        child: const Icon(
                          Icons.play_arrow,
                          size: 16,
                          color: kGold,
                        ),
                      ),
                      const SizedBox(width: 10),
                      const Text(
                        'Səsli qeyd',
                        style: TextStyle(fontSize: 14, color: kMuted),
                      ),
                    ],
                  ),
                ),
              ),

              // Подвал на `margin-top: auto` из макета — распоркой.
              const Spacer(),

              _MyAnswerCard(
                event: event,
                currentUid: currentUid,
                myEvents: [...own, ...asParticipant],
                firestoreService: ref.watch(firestoreServiceProvider),
                form: _AnswerCardForm.footer,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _CardButtonTone { gold, plain }

/// КНОПКА КАРТОЧКИ — по макету `mugam-6-kart` (класс `.btn`): рамка 1.5px,
/// скругление 10, padding 15, во всю ширину. Золотая — главное действие,
/// серая — второе.
class _CardButton extends StatelessWidget {
  const _CardButton({
    required this.label,
    required this.tone,
    required this.onTap,
  });

  final String label;
  final _CardButtonTone tone;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final gold = tone == _CardButtonTone.gold;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 11),
        padding: const EdgeInsets.symmetric(vertical: 15),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: gold ? kGold : kBorder, width: 1.5),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 16, color: gold ? kGold : kTextSecondary),
        ),
      ),
    );
  }
}


/// «11 avqust, 20:04» — дата и время одной строкой, как в макете
/// (`mugam-6-kart`: «14 avqust, 20:00»).
///
/// Год не показывается: вечер, до которого больше года, в этом приложении не
/// заводят, а лишнее слово в самой крупной строке экрана мешает прочесть
/// главное — когда.
String _fmtDayAndTime(String iso) {
  try {
    final d = DateTime.parse(iso);
    final time = fmtEventTime(iso);
    final day = fmtWeekRowDate(d);
    return time.isEmpty ? day : '$day, $time';
  } catch (_) {
    return '';
  }
}

/// «Toy · İnci Qarayev, Bakı» — тип и место одной строкой. Пустые части не
/// оставляют висящих разделителей: у вечера может не быть места.
String _typeAndPlace(PersonalEvent e) => [
  if (e.type.isNotEmpty) e.type,
  if (e.location.isNotEmpty) e.location,
].join(' · ');

/// «TOY HEYƏTİ · 3 NƏFƏR» — заголовок состава из макета.
///
/// **Собирается из ТИПА вечера, а не из имени группы.** Групп состава в
/// проекте нет вовсе (они в отдельной работе), и подставить сюда выдуманное
/// имя значило бы показать человеку то, чего он не заводил. Тип же у вечера
/// есть всегда: «Toy» → «TOY HEYƏTİ».
String _partyHeader(PersonalEvent e) {
  final n = e.participantUids.length;
  final head = e.type.isEmpty ? 'HEYƏT' : '${azUpperCase(e.type)} HEYƏTİ';
  return '$head · $n NƏFƏR';
}

/// СТРОКА УЧАСТНИКА — кружок с двумя буквами в обводке по ответу, имя, под
/// ним ответ. Из макета `mugam-6-kart` (классы `.av2`, `.st`).
///
/// **Обводка кружка и слово под именем говорят ОДНО И ТО ЖЕ разными
/// средствами, и это не избыточность:** слово читают, когда смотрят на
/// человека, а цвет — когда скользят по списку сверху вниз, чтобы понять,
/// собрался ли состав.
class _PartyMemberRow extends StatelessWidget {
  const _PartyMemberRow({
    required this.name,
    required this.answer,
    required this.onTap,
    this.onAsk,
  });

  final String name;
  final String? answer;
  final VoidCallback onTap;

  /// Кнопка «?» справа — есть только у вышедшего и только у владельца.
  ///
  /// **Показывать её решает не эта строка, а правило `offersLeftMemberMenu`**
  /// (`core/agreements/left_member_actions.dart`), и сюда приходит уже готовый
  /// ответ: `null` значит «не предлагать». Условие живёт там, потому что его
  /// можно прогнать тестом, а разметку — нет (I32).
  final VoidCallback? onAsk;

  @override
  Widget build(BuildContext context) {
    final (ring, word) = switch (answer) {
      kAnswerGoing => (kStatusFirmBorder, kStatusFirmText),
      kAnswerCant => (kAnswerCantBorder, kAnswerCantText),
      // «Ждём» и «не спрашивали» — серая обводка у обоих: разницу несёт
      // слово под именем, а цвета у макета на это состояние ровно один.
      _ => (kBorder, kAnswerWaitText),
    };
    final label = participantAnswerLabel(answer);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 13),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: ring, width: 1.5),
              ),
              child: Text(
                initialsOf(name, count: 2),
                style: TextStyle(fontSize: 12, color: word),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: const TextStyle(fontSize: 16, color: kText),
                  ),
                  if (label.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        label,
                        style: TextStyle(fontSize: 13, color: word),
                      ),
                    ),
                ],
              ),
            ),
            // «?» — отдельным нажатием, а не частью строки: нажатие на строку
            // ведёт в карточку человека, и подменять этот привычный ход у
            // одного участника из пяти значило бы завести две разные строки,
            // выглядящие одинаково.
            if (onAsk != null)
              GestureDetector(
                onTap: onAsk,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: kBorder, width: 1.5),
                  ),
                  child: const Text(
                    '?',
                    style: TextStyle(fontSize: 14, color: kMuted),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}




class _EventDetailById extends ConsumerWidget {
  const _EventDetailById({required this.eventId, required this.currentUid});

  final String eventId;
  final String currentUid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final own = ref.watch(personalEventsProvider(currentUid));
    final asParticipant = ref.watch(eventsAsParticipantProvider(currentUid));

    // ЖДЁМ, ПОКА ОБА ПОТОКА ОТВЕТЯТ. Ждать обоих обязательно: документ
    // договора приходит владельцу одним потоком, второй стороне — другим,
    // и решить «такого нет» по одному пришедшему значит соврать половине
    // людей.
    //
    // `allUsers` сюда НЕ входит намеренно: от него зависят только имена, и
    // ждать ради подписи под временем незачем — карточка дорисует их сама.
    if (own.asData == null || asParticipant.asData == null) {
      return const Scaffold(
        backgroundColor: kBg,
        body: Center(child: CircularProgressIndicator(color: kGold)),
      );
    }

    final event = findEventById(
      eventId,
      own.asData!.value,
      asParticipant.asData!.value,
    );
    void back() => Navigator.of(context).pop();
    // Заголовок у «этого больше нет» нейтральный: чем документ БЫЛ,
    // сказать уже нечем — его нет.
    if (event == null) return _eventGoneScaffold('Tədbir', back);

    // ОДНА КАРТОЧКА НА ВСЕ ВЕЧЕРА — шаг 6 (`docs/plan.md`), 12.08.
    //
    // Прежде здесь стояла развилка `eventCardKindOf` по `isAgree`: договор
    // открывался своей карточкой, мероприятие — своей. Развилка снята вместе
    // с самим различением: договорённость это часть вечера, а не отдельная
    // вещь, и **две карточки — это `isAgree` в новом месте**.
    //
    // `_AgreementDetailScreen` НЕ УДАЛЁН намеренно: он цел и возвращается
    // одной строкой, пока новая карточка не доказана на трубках (порядок
    // владельца: старое снимается после того, как новое доказано). Снятие
    // кода — отдельный шаг, а не побочный итог этого.
    // ПРИГЛАШЁННОМУ — ЭКРАН ПРИГЛАШЕНИЯ, а не карточка вечера (13.08).
    //
    // Развилка стоит ЗДЕСЬ, в единственной двери, а не у каждого
    // вызывающего: иначе «куда ведёт нажатие» решалось бы в календаре, в
    // уведомлении и в дневном экране порознь, и они разошлись бы молча — как
    // уже расходились дважды (N90, N117).
    //
    // Правило то же самое, что у строки под сеткой, — `showsAsInvitation`, и
    // это не совпадение: вопрос один и тот же («это ко мне зов или моё
    // дело»), значит и ответ обязан быть один. Два места, отвечающие на один
    // вопрос своими словами, — N49 в чистом виде.
    if (showsAsInvitation(event, currentUid)) {
      return _InvitationScreen(
        event: event,
        currentUid: currentUid,
        onBack: back,
      );
    }

    return _PersonalEventDetailScreen(
      eventId: eventId,
      currentUid: currentUid,
      onBack: back,
    );
  }
}

Route<void> agreementConflictEventRoute({
  required PersonalEvent event,
  required String currentUid,
  required List<User> allUsers,
}) => MaterialPageRoute(
  builder: (_) => _ConflictEventScreen(
    event: event,
    // ДОГОВОР НАЗЫВАЕТСЯ ДОГОВОРОМ (N94). Прежде здесь стояло только
    // «своё / где я гость», и мешающий ДОГОВОР подписывался как «Şəxsi
    // tədbir» — личное мероприятие. Снято владельцем на устройстве 09.08,
    // сразу после того, как та же путаница была вылечена этажом ниже: тап
    // по карточке открывал мероприятие вместо договора.
    //
    // Хвост дефекта уцелел ровно потому, что я поправил, КУДА ведёт тап, и
    // не посмотрел на подпись экраном выше. Одно и то же различение
    // выражено в двух местах — теперь оба зовут общее правило.
    categoryTitle: switch (eventCardKindOf(event)) {
      EventCardKind.agreement => 'Müqavilə',
      EventCardKind.personalEvent =>
        event.ownerUid == currentUid ? 'Şəxsi tədbir' : 'Dəvətli tədbir',
    },
    currentUid: currentUid,
    allUsers: allUsers,
  ),
);

class _ConflictEventScreen extends StatefulWidget {
  final PersonalEvent event;
  final String categoryTitle;
  final String currentUid;
  final List<User> allUsers;

  // Списки событий и FirestoreService отсюда убраны вместе с переводом
  // карточки на id (N23): они существовали только чтобы уехать копиями в
  // _PersonalEventDetailScreen, а тот теперь берёт всё из потока сам.
  const _ConflictEventScreen({
    required this.event,
    required this.categoryTitle,
    required this.currentUid,
    required this.allUsers,
  });

  @override
  State<_ConflictEventScreen> createState() => _ConflictEventScreenState();
}

class _ConflictEventScreenState extends State<_ConflictEventScreen> {
  bool _highlighted = true; // always highlighted after animation

  // Animate: blink 3 times in 3 seconds, then stay highlighted permanently
  // Use a simple timer-based blink: toggle off/on 3 times then leave on
  int _blinkCount = 0;
  late final _blinkTimer = _startBlink();

  Timer _startBlink() {
    return Timer.periodic(const Duration(milliseconds: 500), (t) {
      if (_blinkCount >= 6) {
        // 3 full blinks = 6 toggles
        t.cancel();
        if (mounted) setState(() => _highlighted = true); // ensure stays on
        return;
      }
      if (mounted) setState(() => _highlighted = !_highlighted);
      _blinkCount++;
    });
  }

  @override
  void dispose() {
    _blinkTimer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg2,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: kGold),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          widget.categoryTitle,
          style: GoogleFonts.nunito(fontSize: 18, color: kGold),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: _highlighted ? kGold : kBorder,
                  width: _highlighted ? 2.0 : 1.0,
                ),
                boxShadow: _highlighted
                    ? [
                        BoxShadow(
                          color: kGold.withAlpha(60),
                          blurRadius: 12,
                          spreadRadius: 2,
                        ),
                      ]
                    : [],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(13),
                child: _EventCard(
                  event: widget.event,
                  isOwn: widget.event.ownerUid == widget.currentUid,
                  currentUid: widget.currentUid,
                  allUsers: widget.allUsers,
                  // ТА ЖЕ ДВЕРЬ, что у дневного экрана (N90). Прежде здесь
                  // строилась карточка МЕРОПРИЯТИЯ, и строилась всегда —
                  // даже когда мешающее событие оказывалось договором.
                  // Человек видел не ту карточку, и заметить это было
                  // нечем: обе показывают время и место.
                  onTap: () => Navigator.of(context).push(
                    eventDetailRoute(
                      eventId: widget.event.id,
                      currentUid: widget.currentUid,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _EventFormModal
// ---------------------------------------------------------------------------
/// Что форма создания возвращает вызывающему, когда человек ответил
/// «Mövcud tədbiri dəyiş» на СВОЁМ мероприятии (N46).
///
/// Пара «цель + чем заполнить», а не один только id: заполнение считается
/// правилом (`seedForEdit`) в момент ответа, пока состояние формы ещё
/// живо, и уносится из неё готовым. Считай его открывающий — пришлось бы
/// заново узнавать, чего человек касался, а это ровно то знание, которое с
/// закрытой формой умирает.
/// ЗАПИСЬ ПРАВКИ МЕРОПРИЯТИЯ — единственное место, где берётся сырая карта
/// ответов.
///
/// **Заведено 12.08, когда у правки состава появился ВТОРОЙ путь** — удаление
/// вышедшего из окошка «?». Первая редакция того окошка собирала
/// `eventEditUpdate` своими руками и позвала `answersForRewrite()` вторым
/// вызовом; сторож `source_invariants_test` покраснел в тот же прогон и был
/// прав: карта ответов приватна нарочно, и второй сырой вызов обесценивает
/// приватность — читать сырьё становится так же легко, как через `answerFor`.
///
/// **Три параметра, которые здесь собраны, — те самые, которые второй
/// вызывающий забывает.** Каждый из них закрывает свою находку, и ни один не
/// виден по имени функции:
///
///   `previousAnswers`      — иначе правка места стирает данные ответы (шаг 4);
///   `ownerUid`             — владелец вечер создал, а не согласился (N112);
///   `previousParticipants` — иначе ушедший, приглашённый заново, вернётся уже
///                            согласившимся (N114).
///
/// Собрать их правильно с первого раза можно; собрать их правильно ДВАЖДЫ, в
/// двух местах, которые потом будут править порознь, — нельзя.
Future<void> _writeEventEdit(
  FirestoreService service,
  PersonalEvent event, {
  required String date,
  required String type,
  required String location,
  required String notes,
  required List<String> musicians,
  required String actorUid,
}) {
  return service.updatePersonalEvent(
    event.id,
    eventEditUpdate(
      date: date,
      type: type,
      location: location,
      notes: notes,
      musicians: musicians,
      actorUid: actorUid,
      // Сырая карта берётся единственным входом, заведённым для писателя, и
      // это ЕДИНСТВЕННОЕ место его вызова — держит сторож по исходникам.
      previousAnswers: event.answersForRewrite(),
      // Владелец ПРАВИМОГО, а не правящий: у договора правит любая из сторон,
      // и записать согласие правящему значило бы ответить за него (N112).
      ownerUid: event.ownerUid,
      // Состав ДО правки (N114).
      previousParticipants: event.participantUids,
    ),
  );
}

class _EventEditRequest {
  final PersonalEvent target;
  final EventEditSeed seed;

  const _EventEditRequest({required this.target, required this.seed});
}

class _EventFormModal extends StatefulWidget {
  final String mode; // 'full' | 'time-only'
  final DateTime initialDate;
  final String initialType;
  final String initialLocation;
  final String initialNotes;
  final List<String> initialParticipantUids;
  final List<User> allUsers;
  final PersonalEvent? existingEvent;
  final List<PersonalEvent> allCombinedEvents;
  final String currentUid;
  final FirestoreService firestoreService;
  // Вызывается перед записью и передаёт то, что будет записано. Читатель
  // ровно один — подсветка чужой правки в карточке; появись у него
  // читателей ноль, параметр надо удалять, как удалили `onSaved`.
  final void Function(Map<String, String> willSave)? onWillSave;

  const _EventFormModal({
    required this.mode,
    required this.initialDate,
    required this.initialType,
    required this.initialLocation,
    required this.initialNotes,
    required this.initialParticipantUids,
    required this.allUsers,
    required this.existingEvent,
    required this.allCombinedEvents,
    required this.currentUid,
    required this.firestoreService,
    this.onWillSave,
  });

  @override
  State<_EventFormModal> createState() => _EventFormModalState();
}

class _EventFormModalState extends State<_EventFormModal> {
  late String _type;
  late DateTime _selectedDate;
  late String _location;
  late List<String> _selectedParticipantUids;
  // Заметки целиком (галочки формы одежды + свободный текст) живут одним
  // разобранным значением из shared/widgets/event_notes_picker.dart. Ни
  // список пунктов, ни склейка строки здесь больше не повторяются: ту же
  // строку пишет лист предложения работы, а разбирает этот экран.
  late EventNotesValue _notes;

  // ЧЕГО ЧЕЛОВЕК КОСНУЛСЯ РУКАМИ (N46).
  //
  // Нужны ровно для одного: когда с формы СОЗДАНИЯ человек отвечает
  // «Mövcud tədbiri dəyiş», форма правки засевается целью, и только
  // тронутое переносится из формы поверх. Без этих признаков умолчание
  // «Toy» неотличимо от выбранного «Toy», а пустые заметки — от стёртых
  // намеренно; именно на таком совпадении находка и проехала мимо глаз.
  //
  // Выставляются в обработчиках ввода, и только там. Подмешивание
  // участников из конфликта их НЕ трогает: его делает форма, а не человек
  // (см. `_mergeConflictParticipants`).
  bool _touchedType = false;
  bool _touchedLocation = false;
  bool _touchedNotes = false;
  bool _touchedParticipants = false;

  EventFormTouched get _touched => EventFormTouched(
    type: _touchedType,
    location: _touchedLocation,
    notes: _touchedNotes,
    participants: _touchedParticipants,
  );

  bool _saving = false;
  // Время и день, которые человек сам объявил занятыми, ответив «Yeni
  // tədbir». Два поля, а не одно: ответив так на занятый ДЕНЬ, он просит
  // другой день, и снимать такой запрет сдвигом времени внутри того же дня
  // было бы подменой его ответа. Ровно как в листе «İş təklif et».
  DateTime? _blockedTime;

  /// Дата, с которой окно открылось. Прошлое запрещается именно ПРИ
  /// ВЫБОРЕ, а не вообще: если правят давнее мероприятие, чья дата уже
  /// прошла, и меняют в нём одно место — запрет на сохранение запер бы
  /// человека в углу, требуя сдвинуть дату ради правки соседнего поля.
  /// То же правило и в листе «İş təklif et».
  late final DateTime _openedWithDate;

  // ПЕРЕНОС УЧАСТНИКОВ ПРИ ЗАМЕНЕ.
  //
  // «Əvəz et» сносит старое мероприятие и создаёт новое. Без переноса
  // музыканты старого теряли бы его молча: ошибки нет нигде, просто
  // мероприятие исчезло. Это тот же класс, что выпалывается по всему
  // проекту — действие делает больше, чем обещает, и молчит об этом.
  //
  // Три требования владельца, и каждое отражено ниже:
  //   1. состав виден в форме ДО нажатия — поэтому подмешиваем сразу, как
  //      только появилось предупреждение, а не в момент записи;
  //   2. явно убранного перенос не возвращает — `_explicitlyRemoved`;
  //   3. участники узнают о замене — уведомление шлёт сервер.
  //
  // Ответ «Yeni tədbir» подмешанное снимает: там человек говорит «это
  // отдельное мероприятие», и чужой состав ему не нужен.
  final Set<String> _explicitlyRemoved = <String>{};
  final Set<String> _mergedFromConflict = <String>{};

  // Мероприятия, с которыми человек разобрался в этом же заходе — вышел из
  // чужого (N51). Список `allCombinedEvents` снят при открытии формы и до
  // её закрытия не обновляется, поэтому пересчёт конфликтов без этой
  // памяти снова спросил бы про уже покинутое.
  final Set<String> _resolvedConflictIds = <String>{};

  void _mergeConflictParticipants(List<PersonalEvent> conflicts) {
    // Само правило — в общей чистой функции (event_conflict_banner.dart),
    // здесь только применение: правило должно быть проверяемо тестом, а
    // не жить внутри состояния виджета. Дефект 04.08 нашёлся глазами
    // именно потому, что проверить его было нечем.
    final add = participantsToMerge(
      conflicts: conflicts,
      current: _selectedParticipantUids,
      explicitlyRemoved: _explicitlyRemoved,
      currentUid: widget.currentUid,
      isEditing: widget.existingEvent != null,
    );
    if (add.isEmpty) return;
    // Вне кадра отрисовки: зовётся из build при появлении предупреждения.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _selectedParticipantUids.addAll(add);
        _mergedFromConflict.addAll(add);
      });
    });
  }

  void _unmergeConflictParticipants() {
    if (_mergedFromConflict.isEmpty) return;
    setState(() {
      _selectedParticipantUids = participantsAfterUnmerge(
        current: _selectedParticipantUids,
        merged: _mergedFromConflict,
      );
      _mergedFromConflict.clear();
    });
  }

  bool get _pastDatePicked =>
      _selectedDate != _openedWithDate &&
      _selectedDate.isBefore(DateTime.now());

  final _scrollController = ScrollController();
  final _warningKey = GlobalKey();
  final _locationKey = GlobalKey();
  bool _showLocationError = false;

  static const _eventTypes = ['Toy', 'Konsert', 'Bayram', 'Digər'];

  final _locationController = TextEditingController();
  final _participantSearchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _type = widget.initialType.isNotEmpty ? widget.initialType : 'Toy';
    _selectedDate = widget.initialDate;
    _openedWithDate = widget.initialDate;
    _location = widget.initialLocation;
    _locationController.text = _location;
    _selectedParticipantUids = List<String>.from(widget.initialParticipantUids);

    _notes = EventNotesValue.parse(widget.initialNotes);
  }

  @override
  void dispose() {
    _locationController.dispose();
    _participantSearchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  String get _computedNotes => _notes.joined;

  bool get _isTimeBlocked => isConflictTimeBlocked(_selectedDate, _blockedTime);

  /// Мероприятие, которое сейчас правят, само с собой конфликтовать не
  /// может. У листа предложения такого нет — он всегда создаёт новое.
  String? get _excludeEventId => widget.existingEvent?.id;

  /// Передаются ВСЕ мешающие мероприятия, а не первое: при нескольких в
  /// дне диалог показывает их списком с переключателем, и «то самое»
  /// выбирает человек.
  ///
  /// ТОЛЬКО ПРИ СОЗДАНИИ (N39). Единственный вызывающий — `_handleSave`, и
  /// он до сюда не доходит, когда правят существующее. Утверждение стоит
  /// проверкой, а не комментарием: вернись сюда путь от правки, и «Əvəz
  /// et» снова начала бы сносить постороннее мероприятие — молча, потому
  /// что ошибки в этом нет нигде.
  Future<void> _showConflictFlow(
    List<PersonalEvent> conflicts, {
    required bool exactTime,
  }) async {
    assert(
      widget.existingEvent == null,
      'окно конфликта при правке не показывается (N39)',
    );
    if (!mounted) return;
    if (conflicts.isEmpty) return;
    final choice = await showDialog<EventConflictChoice>(
      context: context,
      builder: (_) => EventConflictDialog(
        conflicts: conflicts,
        currentUid: widget.currentUid,
        canReplace: true,
      ),
    );
    if (!mounted || choice == null) return;
    final dialogResult = choice.action;
    if (dialogResult == 'replace') {
      // Главное действие. У него ДВА разных смысла, и решает их владение
      // выбранного мероприятия — см. `_replaceEvent`. Диалог называет их
      // разными именами («Mövcud tədbiri dəyiş» / «Təqvimimdən sil»), но
      // ответом остаётся один: поступок совершает вызывающий, а не окно.
      await _replaceEvent(choice.event);
      // РАЗБОР ОДНОГО НЕ ОСВОБОЖДАЕТ МИНУТУ (N51). На минуте могло стоять
      // несколько: ушёл из чужого — своё на том же времени осталось, и
      // сохранить сейчас значило бы поставить человека в два места разом,
      // ровно то, ради чего запрет и заведён. Пока форма жива, спрашиваем
      // заново с тем, что осталось; раньше этот случай был недостижим,
      // потому что в диалог уходило одно мероприятие.
      if (!mounted) return;
      final left = exactConflictsAt(
        _selectedDate,
        widget.allCombinedEvents,
        currentUid: widget.currentUid,
        excludeEventId: _excludeEventId,
        resolvedIds: _resolvedConflictIds,
      );
      if (left.isNotEmpty) {
        await _showConflictFlow(left, exactTime: true);
        return;
      }
      // Минута освободилась — сохраняем то, ради чего человек сюда и
      // пришёл. Своё мероприятие создаётся здесь, а не в момент выхода из
      // чужого: до этой строки было неизвестно, свободна ли минута.
      await _doSave();
    } else if (dialogResult == 'new') {
      // «Yeni tədbir» — «это отдельное мероприятие, сохрани его как есть».
      //
      // Если минуты НЕ совпадают (занят лишь день), два мероприятия в один
      // день — обычное дело, и мешать нечему: сохраняем. Запрет остаётся
      // только на точное совпадение минуты — там два мероприятия в одну и
      // ту же минуту означали бы, что человек в двух местах разом.
      //
      // Прежнее правило («запрет ставится ровно на то, о чём спрашивали»,
      // то есть занят день → занят весь день) переигран владельцем 03.08:
      // на деле оно запирало обычный случай — вечерний той и дневное
      // мероприятие в одну дату.
      // «Это отдельное мероприятие» — значит и состав его собственный:
      // подмешанное из конфликтующего снимаем.
      _unmergeConflictParticipants();
      if (!exactTime) {
        await _doSave();
        return;
      }
      setState(() => _blockedTime = _selectedDate);
      await _scrollToWarning();
    } else if (dialogResult == 'view') {
      await _openConflictEvent(choice.event);
      if (!mounted) return;
      // Человек вернулся — вопрос остался, спрашиваем снова. Этим ответ
      // «Bax» и отличается от стрелки в самой плашке: там вопрос ещё не
      // задан, и возвращать человека не к чему.
      await _showConflictFlow(conflicts, exactTime: exactTime);
    }
  }

  /// Открыть экран мероприятия. Один путь и для ответа «Bax» в диалоге, и
  /// для стрелки в плашке — иначе два входа на один экран разъехались бы
  /// по составу данных, как уже случалось с копиями в пушевом маршруте
  /// (N23).
  Future<void> _openConflictEvent(PersonalEvent conflict) async {
    final isOwn = conflict.ownerUid == widget.currentUid;
    final categoryTitle = isOwn ? 'Şəxsi tədbir' : 'Dəvətli tədbir';
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _ConflictEventScreen(
          event: conflict,
          categoryTitle: categoryTitle,
          currentUid: widget.currentUid,
          allUsers: widget.allUsers,
        ),
      ),
    );
  }

  /// Прокрутить к предупреждению. Пауза — чтобы оно успело появиться в
  /// дереве: до setState его контекста ещё нет, и прокручивать не к чему.
  Future<void> _scrollToWarning() async {
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

  // Порядок проверок при сохранении — тот же, что в листе «İş təklif et»
  // (_submit): сначала собственный запрет человека, потом точное
  // совпадение минуты, потом занятый день. Точное совпадение спрашивается
  // раньше: оно строже и говорит больше, чем «на этот день что-то есть».
  //
  // ПРИ ПРАВКЕ ОКНА КОНФЛИКТА НЕТ ВОВСЕ (N39). Оно написано для создания и
  // отвечает на вопрос «у меня занято, что делать»; при правке этого
  // вопроса не существует — правимое мероприятие из конфликтов исключено
  // (`_excludeEventId`), значит окно поднимали ПОСТОРОННИЕ мероприятия
  // дня, а главным ответом в нём стояло их удаление. Человек приходил
  // снять участника, а интерфейс подталкивал снести чужой день.
  //
  // Разводится это не текстом кнопок, а самим случаем: правило — в
  // `conflictAnswers` (core/agreements/event_edit.dart), и там при правке
  // ни один допустимый ответ не пишет в чужой документ. Здесь только
  // применение.
  Future<void> _handleSave() async {
    if (_saving) return;
    // Прошлое — раньше всего: предупреждение о нём живое, и прокрутить к
    // нему честнее, чем показать всплывающую строчку поверх формы.
    if (_pastDatePicked) {
      await _scrollToWarning();
      return;
    }
    // Человек сам сказал «выберу другое» — пока не сдвинул, сохранение
    // молчит и показывает, почему.
    if (_isTimeBlocked) {
      await _scrollToWarning();
      return;
    }

    if (_location.trim().isEmpty) {
      setState(() => _showLocationError = true);
      await Future.delayed(const Duration(milliseconds: 50));
      if (_locationKey.currentContext != null) {
        Scrollable.ensureVisible(
          _locationKey.currentContext!,
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeInOut,
          alignment: 0.3,
        );
      }
      return;
    }

    final events = widget.allCombinedEvents;
    final editing = widget.existingEvent != null;
    final exact = exactConflictsAt(
      _selectedDate,
      events,
      currentUid: widget.currentUid,
      excludeEventId: _excludeEventId,
      resolvedIds: _resolvedConflictIds,
    );

    if (editing) {
      final answers = conflictAnswers(
        isEditing: true,
        exactTime: exact.isNotEmpty,
        // Владение мешающего мероприятия к правке отношения не имеет:
        // подмена этого вопроса и давала N39. Передаётся ради полноты
        // вызова — правило его при правке не читает. Берём первое из
        // занявших минуту: при правке ответ от этого не зависит вовсе.
        targetIsMine:
            exact.isNotEmpty && exact.first.ownerUid == widget.currentUid,
      );
      // Суть варианта А одной строкой: при правке ответ единственный, а
      // вопрос с единственным ответом это не вопрос, а задержка. Стоит
      // проверкой, чтобы правило и его применение не разошлись молча.
      assert(
        !conflictAsksHuman(answers),
        'при правке спрашивать не о чем (N39)',
      );
      if (answers.contains(ConflictAnswer.blockUntilMoved)) {
        // Минута в минуту — единственное настоящее затруднение при
        // правке: человек оказался бы в двух местах разом. Верный ответ на
        // него не «заменить», а «сдвиньте время», и говорит это живая
        // плашка, которую сейчас и покажем.
        setState(() => _blockedTime = _selectedDate);
        await _scrollToWarning();
        return;
      }
      // Занят лишь день — сохраняем молча. Решение владельца 03.08:
      // дневное мероприятие и вечерний той в одну дату это обычная жизнь,
      // а не ошибка; предупредила о ней плашка в форме, и вопрос сверх
      // неё был бы вопросом без ответа.
      await _doSave();
      return;
    }

    if (exact.isNotEmpty) {
      // ВСЕ, кто занял эту минуту, а не первый из них (N51). Их может быть
      // сколько угодно: своё и чужое, где человек участник, встают на одно
      // время свободно.
      await _showConflictFlow(exact, exactTime: true);
      return;
    }
    final sameDay = conflictEventsOnDay(
      _selectedDate,
      events,
      currentUid: widget.currentUid,
      excludeEventId: _excludeEventId,
    ).where((e) => !_resolvedConflictIds.contains(e.id)).toList();
    if (sameDay.isNotEmpty) {
      await _showConflictFlow(sameDay, exactTime: false);
      return;
    }
    await _doSave();
  }

  Future<void> _doSave() async {
    setState(() => _saving = true);
    try {
      // Объявляем, что собираемся записать, ДО самой записи — иначе
      // карточка подсветит собственную правку. Firestore отдаёт локальную
      // запись в поток немедленно, из кеша, не дожидаясь сервера; она
      // приходит РАНЬШЕ, чем лист успевает закрыться, поэтому вернуть эти
      // значения результатом маршрута — уже поздно.
      widget.onWillSave?.call(<String, String>{
        'type': _type,
        'date': _selectedDate.toIso8601String(),
        'location': _location,
        'notes': _computedNotes,
      });
      // «Плавающее» гражданское время — НЕ приводить к UTC вместе с
      // отметками момента (N4, тот же случай, что eventDate на чате):
      // время тədbir'а привязано к месту проведения, а не к поясу
      // смотрящего.
      final dateIso = _selectedDate.toIso8601String();
      final notes = _computedNotes;
      if (widget.existingEvent != null) {
        // Ровно семь ключей, и собирает их общее правило
        // (`eventEditUpdate`), а не эта строка. Причина — не экономия:
        // ниже, в `_replaceEvent`, та же самая запись делается второй раз,
        // и разойдись они хоть одним полем, одна дорога начала бы стирать
        // то, что другая бережёт. Тринадцать сохраняемых полей проверяет
        // тест, а не внимательность.
        // Прежние ответы, владелец правимого и прежний состав собраны НЕ
        // здесь, а в `_writeEventEdit`: у этой записи с 12.08 есть второй
        // вызывающий (удаление вышедшего из окошка «?»), и три параметра,
        // каждый из которых закрывает свою находку, нельзя собирать дважды.
        await _writeEventEdit(
          widget.firestoreService,
          widget.existingEvent!,
          date: dateIso,
          type: _type,
          location: _location,
          notes: notes,
          musicians: _selectedParticipantUids,
          actorUid: widget.currentUid,
        );
      } else {
        await widget.firestoreService.addPersonalEvent(
          ownerUid: widget.currentUid,
          date: dateIso,
          type: _type,
          location: _location,
          notes: notes,
          participantUids: _selectedParticipantUids,
        );
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e, st) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Xəta: $e'), backgroundColor: kRed),
        );
      }
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'agreements_screen: save agreement failed',
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Главное действие диалога конфликта. Два случая, и у каждого своё имя
  /// на кнопке, потому что поступки разные.
  ///
  /// СВОЁ — «Mövcud tədbiri dəyiş»: тот же документ переписывается тем, что
  /// человек ввёл. Ни удаления, ни второй записи рядом.
  ///
  /// Прежде здесь стояло удаление с созданием заново (N40), и слово
  /// «замена» это скрывало: id менялся, а вместе с ним пропадало всё, что
  /// жило в документе, — `createdAt`, `agreementChatId`, `partnerUid`,
  /// `jobOfferAt`, поля отмены, отметка прочтения. Тяжелейшее следствие:
  /// новый документ создавался с `isAgree: false`, и договор ИСЧЕЗАЛ из
  /// «Müqavilələr» у обеих сторон, оставаясь обычной записью календаря.
  /// Подтверждено данными прогона 05.08: `KvVo50W7…` исчез,
  /// `qANeGnDVh9…` появился — другой id.
  ///
  /// ЧУЖОЕ — «Təqvimimdən sil»: правка невозможна по правам (`update` в
  /// `personalEvents` разрешён только владельцу), поэтому единственное,
  /// что тут можно, — выйти из участников. Мероприятие остаётся у
  /// остальных и перестаёт занимать мой календарь; своё создаётся рядом,
  /// ради него человек сюда и пришёл.
  ///
  /// Правки существующего здесь больше нет как случая: до этого метода
  /// доходят только с пути создания (N39, см. `_handleSave`).
  Future<void> _replaceEvent(PersonalEvent target) async {
    assert(
      widget.existingEvent == null,
      'сюда приходят только с пути создания (N39)',
    );
    final mine = target.ownerUid == widget.currentUid;
    if (mine) {
      // СВОЁ — форма правки, а не запись втихую (N46, решение владельца
      // 06.08, вариант А).
      //
      // Прежде отсюда уходила запись, собранная из формы СОЗДАНИЯ: она о
      // цели не знает ничего, поэтому заметки договора затирались
      // пустотой, `musicians` менял соглашение, а `type` вставал
      // умолчанием. Ни одно из трёх на экране не видно — карточка рисует
      // владельца отдельной плашкой, пустой `Qeyd` выглядит как «заметок
      // не было», а тип совпал случайно.
      //
      // Теперь ответ означает ровно то, что говорит: «перенеси стоящее
      // сюда» — открыть его, показать человеку, что там уже есть, и дать
      // сохранить самому. Экран не меняет смысл под введёнными данными
      // (это был бы класс N39/N40), а сменяется на другой, со своим
      // заголовком и своей кнопкой.
      Navigator.of(context).pop(
        _EventEditRequest(
          target: target,
          seed: seedForEdit(
            pickedDate: _selectedDate,
            targetType: target.type,
            targetLocation: target.location,
            targetNotes: target.notes,
            targetParticipantUids: target.participantUids,
            formType: _type,
            formLocation: _location,
            formNotes: _computedNotes,
            formParticipantUids: _selectedParticipantUids,
            touched: _touched,
          ),
        ),
      );
      return;
    }
    // Подтверждение обязательно и отдельно от диалога конфликта: выход из
    // чужого мероприятия необратим — вернуть себя в него человек не может,
    // это умеет только владелец.
    final ok = await _confirmLeaveForeign(target);
    if (!ok || !mounted) return;
    setState(() => _saving = true);
    // ЧУЖОЕ — ничего оттуда не переносится (N47).
    //
    // Перенос состава выводился для замены СВОЕГО: там `musicians`
    // переписываются целиком, и без переноса участники заменяемого выпали
    // бы молча. Здесь заменяемого нет — человек уходит из одного
    // мероприятия и создаёт другое. Правило, применённое к пути, для
    // которого не выводилось, 06.08 записало в новый вечер Рафаэля
    // владельца покинутого мероприятия и второго его участника, а
    // `replacedEventId` указал на чужой и живой документ, отчего обоим
    // ушло «Tədbir əvəz edildi» — рассказ о поступке, которого не было.
    final plan = foreignLeaveCreation(
      current: _selectedParticipantUids,
      mergedFromConflict: _mergedFromConflict,
    );
    try {
      // ТОЛЬКО ВЫХОД, без создания своего (N51).
      //
      // Прежде здесь же создавалось и своё мероприятие — и это было верно,
      // пока минуту мог занимать ровно один конфликт. Их может быть
      // несколько: ушёл из чужого, а своё на том же времени осталось, и
      // созданное тут же поставило бы человека в два места разом — ровно
      // то, ради чего запрет на совпадение минуты и заведён. Создание
      // ушло в общий путь сохранения, который вызывающий позовёт, когда
      // минута действительно освободится.
      //
      // Уведомление о выходе шлёт сервер владельцу покинутого, и только
      // ему («İştirakçı ayrıldı», `planUpdatePushes` по
      // `lastActionType: 'left'`). Оно и есть единственное, что этот ход
      // порождает: до починки N47 уходило три, из них два ложных.
      await widget.firestoreService.leavePersonalEvent(
        target.id,
        widget.currentUid,
      );
      if (!mounted) return;
      setState(() {
        // Состав — только выбранный человеком: подмешанные пришли из того
        // самого мероприятия, из которого человек только что вышел (N47).
        _selectedParticipantUids = plan.participantUids;
        _mergedFromConflict.clear();
        // Это мероприятие разобрано. Список данных о выходе ещё не знает —
        // он снят при открытии формы, — поэтому помним сами, иначе
        // следующий же пересчёт снова спросит про него.
        _resolvedConflictIds.add(target.id);
      });
    } catch (e, st) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Xəta: $e'), backgroundColor: kRed),
        );
      }
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'agreements_screen: replace event failed',
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Подтверждение ВЫХОДА из чужого мероприятия.
  ///
  /// Прежний заголовок этого комментария говорил «подтверждение удаления
  /// чужого мероприятия» — и это было неправдой о собственном коде: под
  /// ним всегда стоял `leavePersonalEvent`, то есть выход из участников.
  /// Правится вместе с N39/N40 по тому же правилу, что и кнопки: имя
  /// обязано называть поступок, комментарий — тоже.
  ///
  /// Отдельным вопросом, а не строчкой в диалоге конфликта: там человек
  /// отвечает «что делать с моим временем», а здесь соглашается на
  /// необратимое — вернуть себя в чужое мероприятие он не сможет, это
  /// умеет только его владелец.
  ///
  /// Тот же вид, что у «Çatı təmizlə» и «İmtina» — в этом приложении так
  /// выглядят необратимые действия.
  Future<bool> _confirmLeaveForeign(PersonalEvent target) async {
    final owner = widget.allUsers
        .where((u) => u.id == target.ownerUid)
        .map((u) => u.name)
        .firstOrNull;
    final whose = (owner == null || owner.isEmpty)
        ? 'başqa istifadəçinin'
        : '$owner adlı istifadəçinin';
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: kBg2,
        title: const Text(
          'Bu tədbir sizin deyil',
          style: TextStyle(color: kText),
        ),
        content: Text(
          '«${eventConflictSummary(target)}» — $whose tədbiridir.\n\n'
          'Yalnız sizin təqvimdən silinəcək. Digər iştirakçılarda '
          'qalacaq.',
          style: const TextStyle(color: kMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Geri', style: TextStyle(color: kMuted)),
          ),
          TextButton(
            // То же слово, что на кнопке диалога конфликта, с которой сюда
            // пришли: подтверждение обязано называть тот же поступок, а не
            // голое «Sil» — оно обещало бы удаление мероприятия целиком.
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              conflictAnswerLabel(ConflictAnswer.leaveForeign),
              style: const TextStyle(color: kRed),
            ),
          ),
        ],
      ),
    );
    return ok == true;
  }

  // Единственная запись состава, который человек задаёт РУКАМИ. Дорог к
  // ней две — диалог выбора и крестик на фишке, — и обе обязаны идти
  // сюда: `_explicitlyRemoved` живёт только на клиенте, за ним нет
  // правила на сервере, которое отвергло бы неверный ход. Такое
  // состояние по путям не размножают (правило «клиентское состояние без
  // сервера за спиной», AUDIT_TODO.md): крестик писал только
  // `_selectedParticipantUids`, и перенос из конфликта возвращал
  // человека обратно внутри того же кадра — фишка исчезала и появлялась,
  // кнопка выглядела сломанной (N35).
  //
  // Третий путь дописать мимо не выйдет: сторож по исходникам
  // (test/source_invariants_test.dart) требует, чтобы `_explicitlyRemoved`
  // пополнялся ровно здесь.
  void _applyParticipantSelection(List<String> uids) {
    setState(() {
      // Состав тронут человеком — отсюда и только отсюда (N46). Оба пути
      // выбора участников, диалог и крестик на фишке, идут через эту
      // функцию (N35), поэтому признак ставится один раз на оба.
      _touchedParticipants = true;
      // Кого человек убрал руками — запоминаем: перенос из
      // конфликтующего мероприятия не должен возвращать его обратно.
      for (final gone in _selectedParticipantUids) {
        if (!uids.contains(gone)) _explicitlyRemoved.add(gone);
      }
      _explicitlyRemoved.removeAll(uids);
      _mergedFromConflict.removeWhere((u) => !uids.contains(u));
      _selectedParticipantUids = uids;
    });
  }

  Future<void> _openParticipantPicker() async {
    await showDialog(
      context: context,
      builder: (_) => _ParticipantPickerDialog(
        selectedUids: _selectedParticipantUids,
        onChanged: _applyParticipantSelection,
        currentUid: widget.currentUid,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    // Живой конфликт на выбранное время — считается на каждой перерисовке,
    // то есть предупреждение появляется ПРИ ВЫБОРЕ, а не только после
    // нажатия «сохранить». Диалог при этом не всплывает: он спрашивает,
    // что делать, и на каждый щелчок колеса такой вопрос был бы
    // издевательством.
    //
    // Правила «что показать и в каком порядке» — общие с листом
    // «İş təklif et» (shared/widgets/event_conflict_banner.dart).
    final banner = resolveConflictBanner(
      selectedDate: _selectedDate,
      events: widget.allCombinedEvents,
      currentUid: widget.currentUid,
      blockedTime: _blockedTime,
      excludeEventId: _excludeEventId,
      pastDate: _pastDatePicked,
      resolvedIds: _resolvedConflictIds,
    );
    // Состав конфликтующих мероприятий подмешивается в форму СРАЗУ, как
    // только появилось предупреждение: требование «виден до нажатия и
    // правится». Убранного руками не возвращает — см. _explicitlyRemoved.
    if (banner != null && banner.events.isNotEmpty) {
      _mergeConflictParticipants(banner.events);
    }
    return Container(
      margin: EdgeInsets.only(top: 60, bottom: bottomInset),
      decoration: const BoxDecoration(
        color: kBg2,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      // Header (title/type/date) and footer (Ləğv et/Saxla) are pinned —
      // only the middle (wheel picker through notes) scrolls, in its own
      // Expanded+SingleChildScrollView, instead of the previous single
      // SingleChildScrollView wrapping the entire form (which scrolled the
      // title and the save/cancel buttons out of view along with
      // everything else).
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Text(
                    widget.existingEvent != null
                        ? 'Tədbiri Redaktə et'
                        : 'Yeni Tədbir',
                    style: GoogleFonts.nunito(
                      fontSize: 18,
                      color: kText,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                // Event type pills
                Wrap(
                  spacing: 8,
                  children: _eventTypes.map((t) {
                    final sel = _type == t;
                    return GestureDetector(
                      onTap: () => setState(() {
                        _type = t;
                        _touchedType = true; // N46
                      }),
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
                    '${_selectedDate.day} ${_azMonth(_selectedDate.month)} ${_selectedDate.year}',
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
                  // Inline wheel date/time picker
                  WheelDateTimePicker(
                    value: _selectedDate,
                    onChanged: (d) {
                      setState(() {
                        _selectedDate = d;
                        // Человек сдвинул — его же просьба «дай выбрать другое»
                        // исполнена, запрет снимается сам. Каждый запрет
                        // снимается своим действием: запрет на минуту — сдвигом
                        // времени, запрет на день — сменой дня.
                        if (_blockedTime != null &&
                            (d.hour != _blockedTime!.hour ||
                                d.minute != _blockedTime!.minute)) {
                          _blockedTime = null;
                        }
                        // Сменился конфликт — сменился и подмешанный из него
                        // состав (N38). Подмешивание живёт в `build`, а снятия не
                        // было нигде, кроме ответа «Yeni tədbir»: человек
                        // прокручивал дату через занятую минуту, состав того дня
                        // налипал и оставался от даты, которую он уже не
                        // выбирает. Правило целиком — в
                        // `participantsAfterConflictChange`; здесь применение.
                        final next = resolveConflictBanner(
                          selectedDate: d,
                          events: widget.allCombinedEvents,
                          currentUid: widget.currentUid,
                          blockedTime: _blockedTime,
                          excludeEventId: _excludeEventId,
                          // Считается для НОВОЙ даты, а не через `_pastDatePicked`:
                          // тот смотрит на `_selectedDate`, и на прошлой дате
                          // предупреждение о занятости не поднимается вовсе —
                          // значит и конфликтов в нём не будет.
                          pastDate:
                              d != _openedWithDate &&
                              d.isBefore(DateTime.now()),
                          resolvedIds: _resolvedConflictIds,
                        );
                        final change = participantsAfterConflictChange(
                          current: _selectedParticipantUids,
                          merged: _mergedFromConflict,
                          conflicts: next?.events ?? const <PersonalEvent>[],
                          explicitlyRemoved: _explicitlyRemoved,
                          currentUid: widget.currentUid,
                          isEditing: widget.existingEvent != null,
                        );
                        _selectedParticipantUids = change.participants;
                        _mergedFromConflict
                          ..clear()
                          ..addAll(change.merged);
                      });
                    },
                  ),
                  // Предупреждение о занятом времени — общий виджет И общие
                  // правила с листом «İş təklif et»
                  // (shared/widgets/event_conflict_banner.dart).
                  //
                  // До 03.08 здесь стояла своя однострочная плашка с эмодзи ⚠️,
                  // и показывалась она только ПОСЛЕ ответа «Yeni tədbir»: пока
                  // человек крутил колесо, календарь про занятое время молчал.
                  // Лист к тому времени предупреждал живьём — то есть разошлись
                  // не только вид, но и момент появления, а заметить это можно
                  // было только глазами. Требование владельца 03.08: «пусть
                  // будет одно и то же в обоих местах».
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
                  if (widget.mode == 'time-only') ...[
                    const SizedBox(height: 16),
                    // Participants
                    const Text(
                      'İŞTİRAKÇILAR',
                      style: TextStyle(
                        fontSize: 11,
                        letterSpacing: 0.8,
                        color: kMuted,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    // "+ Əlavə et" deliberately lives in its own row below the
                    // chips' Wrap, not as the last item inside that same Wrap —
                    // as a Wrap child, it used to reflow to a new position every
                    // time a chip was added/removed (jumping up a line, sliding
                    // along the last row, etc.). A fixed row underneath keeps it
                    // in the same place regardless of how many chips there are or
                    // how they wrap.
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: _selectedParticipantUids.map((uid) {
                        User? m;
                        try {
                          m = widget.allUsers.firstWhere((x) => x.id == uid);
                        } catch (_) {}
                        return Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: kGold.withAlpha(38),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: kGold),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              GestureDetector(
                                // Pushed (not replaced) on top of this still-open
                                // sheet, so popping UserProfileScreen naturally
                                // lands back here with every field/participant
                                // exactly as left — no extra state to restore.
                                onTap: m == null
                                    ? null
                                    : () => Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) =>
                                              UserProfileScreen(user: m!),
                                        ),
                                      ),
                                child: Text(
                                  '${m?.emoji ?? '🎵'} ${m?.name ?? uid}',
                                  style: const TextStyle(
                                    color: kGold,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              GestureDetector(
                                // Второй путь к «убрать участника руками» — идёт
                                // той же записью, что и диалог выбора (N35).
                                onTap: () => _applyParticipantSelection(
                                  _selectedParticipantUids
                                      .where((u) => u != uid)
                                      .toList(),
                                ),
                                child: const Text(
                                  '×',
                                  style: TextStyle(color: kRed, fontSize: 16),
                                ),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: GestureDetector(
                        onTap: _openParticipantPicker,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: kBg3,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: kBorder),
                          ),
                          child: const Text(
                            '+ Əlavə et',
                            style: TextStyle(color: kMuted, fontSize: 12),
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  // Location
                  Container(
                    key: _locationKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'MƏKAN',
                          style: TextStyle(
                            fontSize: 11,
                            letterSpacing: 0.8,
                            color: kMuted,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _locationController,
                          onChanged: (v) {
                            _location = v;
                            _touchedLocation = true; // N46
                            if (_showLocationError && v.trim().isNotEmpty) {
                              setState(() => _showLocationError = false);
                            }
                          },
                          style: const TextStyle(color: kText, fontSize: 14),
                          decoration: InputDecoration(
                            hintText: 'Məkan daxil edin',
                            hintStyle: const TextStyle(color: kMuted),
                            filled: true,
                            fillColor: kBg3,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 14,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: _showLocationError ? kRed : kBorder,
                              ),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: _showLocationError ? kRed : kBorder,
                              ),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: const BorderSide(color: kGold),
                            ),
                          ),
                        ),
                        if (_showLocationError) ...[
                          const SizedBox(height: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: kRed.withAlpha(25),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: kRed.withAlpha(80)),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '⚠️ Məkanı daxil edin',
                                    style: const TextStyle(
                                      color: kRed,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Форма одежды и свободная заметка — общий виджет
                  // (shared/widgets/event_notes_picker.dart), тот же, что в листе
                  // предложения работы. Список пунктов и склейка строки живут
                  // там: договор создаётся из предложения, а правится здесь, то
                  // есть строку пишет один экран, а разбирает другой.
                  EventNotesPicker(
                    value: _notes,
                    onChanged: (v) => setState(() {
                      _notes = v;
                      _touchedNotes = true; // N46
                    }),
                    // Свободная заметка здесь показывается только в режиме с
                    // участниками — так было до выделения виджета, поведение
                    // сохранено как есть.
                    showFreeNote: widget.mode == 'time-only',
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
          // Footer — pinned as its own sibling of the Expanded scrollable
          // above, not part of the scrolling content.
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: kMuted,
                      side: const BorderSide(color: kBorder),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: const Text('Ləğv et'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _saving ? null : _handleSave,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kGold,
                      disabledBackgroundColor: kGold,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      elevation: 0,
                    ),
                    child: _saving
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: kOnGold,
                            ),
                          )
                        : const Text(
                            'Saxla',
                            style: TextStyle(
                              color: kOnGold,
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
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

// ---------------------------------------------------------------------------
// _ParticipantPickerDialog
// ---------------------------------------------------------------------------
class _ParticipantPickerDialog extends ConsumerStatefulWidget {
  final List<String> selectedUids;
  final ValueChanged<List<String>> onChanged;
  // Needed for hasUnviewedStatusFrom below — the picker rows now show a
  // status ring, which requires the VIEWER's own User doc (not just each
  // row's), so unlike before this dialog can no longer stay a plain
  // StatefulWidget with no Riverpod/uid access. Threaded in from the
  // caller's own widget.currentUid (_openParticipantPicker below) rather
  // than re-reading FirebaseAuth here, matching this dialog's own existing
  // convention of taking currentUid as a constructor param instead of
  // looking it up itself. Also doubles as the Algolia search's own
  // self-exclusion uid now that this dialog does its own search instead of
  // filtering the caller's widget.allUsers list (see UserSearchController).
  final String currentUid;

  const _ParticipantPickerDialog({
    required this.selectedUids,
    required this.onChanged,
    required this.currentUid,
  });

  @override
  ConsumerState<_ParticipantPickerDialog> createState() =>
      _ParticipantPickerDialogState();
}

class _ParticipantPickerDialogState
    extends ConsumerState<_ParticipantPickerDialog> {
  late List<String> _selected;
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  SearchFilters _filters = const SearchFilters();
  late final _searchCtrl = UserSearchController(
    filters: _filters.toAlgoliaFilters(widget.currentUid),
  );

  @override
  void initState() {
    super.initState();
    _selected = List<String>.from(widget.selectedUids);
    _searchCtrl.loadInitial();
    _scrollController.addListener(_onScroll);
  }

  Future<void> _openFilters() async {
    final result = await FilterSheet.show(
      context,
      initial: _filters,
      nameController: _searchController,
    );
    if (result != null) {
      setState(() => _filters = result);
      _searchCtrl.updateFilters(_filters.toAlgoliaFilters(widget.currentUid));
    }
  }

  void _onScroll() {
    if (!_searchCtrl.hasMore ||
        _searchCtrl.isLoading ||
        _searchCtrl.isLoadingMore) {
      return;
    }
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _searchCtrl.loadMore();
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchCtrl.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: kBg2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        height: 500,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      onChanged: _searchCtrl.search,
                      style: const TextStyle(color: kText, fontSize: 14),
                      decoration: InputDecoration(
                        hintText: 'Axtar...',
                        hintStyle: const TextStyle(color: kMuted),
                        filled: true,
                        fillColor: kBg3,
                        prefixIcon: const Icon(Icons.search, color: kMuted),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: kBorder),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: kBorder),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: kGold),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  InkWell(
                    onTap: _openFilters,
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: _filters.activeCount > 0 ? kGold : kBg3,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: _filters.activeCount > 0 ? kGold : kBorder,
                        ),
                      ),
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Center(
                            child: Icon(
                              Icons.tune_rounded,
                              size: 20,
                              color: _filters.activeCount > 0
                                  ? kOnGold
                                  : kMuted,
                            ),
                          ),
                          if (_filters.activeCount > 0)
                            Positioned(
                              right: -4,
                              top: -4,
                              child: Container(
                                padding: const EdgeInsets.all(3),
                                constraints: const BoxConstraints(
                                  minWidth: 16,
                                  minHeight: 16,
                                ),
                                decoration: const BoxDecoration(
                                  color: kRed,
                                  shape: BoxShape.circle,
                                ),
                                child: Text(
                                  '${_filters.activeCount}',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: kOnRed,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListenableBuilder(
                listenable: _searchCtrl,
                builder: (context, _) {
                  if (_searchCtrl.isLoading) {
                    return const Center(
                      child: CircularProgressIndicator(color: kGold),
                    );
                  }
                  if (_searchCtrl.error != null) {
                    return Center(
                      child: Text(
                        _searchCtrl.error!,
                        style: const TextStyle(color: kMuted),
                      ),
                    );
                  }

                  final filtered = _searchCtrl.results;
                  return ListView.builder(
                    controller: _scrollController,
                    itemCount:
                        filtered.length + (_searchCtrl.isLoadingMore ? 1 : 0),
                    itemBuilder: (_, i) {
                      if (i >= filtered.length) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Center(
                            child: CircularProgressIndicator(color: kGold),
                          ),
                        );
                      }
                      final m = filtered[i];
                      final sel = _selected.contains(m.id);
                      final hasActiveStatus = m.hasActiveStatus;
                      final viewerUser = hasActiveStatus
                          ? ref
                                .watch(currentUserProvider(widget.currentUid))
                                .value
                          : null;
                      final hasUnviewed =
                          hasActiveStatus &&
                          (viewerUser?.hasUnviewedStatusFrom(m) ?? false);
                      const avatarBaseSize = 36.0;
                      final avatarBoxSize = avatarBaseSize * 1.2;
                      void openStatusViewer() => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => UserStatusViewerScreen(
                            ownerUid: m.id,
                            currentUid: widget.currentUid,
                            initialUser: m,
                          ),
                        ),
                      );
                      return ListTile(
                        leading: SizedBox(
                          width: avatarBoxSize,
                          height: avatarBoxSize,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              if (hasActiveStatus)
                                GestureDetector(
                                  onTap: openStatusViewer,
                                  onLongPress: () => showAvatarLongPressMenu(
                                    context,
                                    photoURL: m.photoURL,
                                    onViewStatus: openStatusViewer,
                                  ),
                                  child: AvatarRing(
                                    photoURL: m.photoURL,
                                    fallbackEmoji: m.emoji,
                                    hasUnviewed: hasUnviewed,
                                    size: avatarBoxSize,
                                  ),
                                )
                              else
                                // Unified to a circle to match AvatarRing above
                                // and every other avatar in the app — this
                                // dialog's avatar was previously the one
                                // outlier still using a rounded-square shape
                                // (BorderRadius.circular(10)), which would have
                                // made rows visibly change shape depending on
                                // hasActiveStatus if left as-is. Everything
                                // else in this dialog (search field, dialog
                                // corners) keeps its own unrelated rounded-rect
                                // styling untouched.
                                GestureDetector(
                                  onTap: m.photoURL != null
                                      ? () =>
                                            showFullImage(context, m.photoURL!)
                                      : null,
                                  child: Container(
                                    width: avatarBoxSize,
                                    height: avatarBoxSize,
                                    decoration: BoxDecoration(
                                      color: kBg3,
                                      shape: BoxShape.circle,
                                      image: m.photoURL != null
                                          ? DecorationImage(
                                              image: NetworkImage(m.photoURL!),
                                              fit: BoxFit.cover,
                                            )
                                          : null,
                                    ),
                                    child: m.photoURL == null
                                        ? Center(
                                            child: Text(
                                              m.emoji,
                                              style: const TextStyle(
                                                fontSize: 18,
                                              ),
                                            ),
                                          )
                                        : null,
                                  ),
                                ),
                              Positioned(
                                bottom: 0,
                                right: 0,
                                child: Container(
                                  width: 12,
                                  height: 12,
                                  decoration: BoxDecoration(
                                    color: m.isActuallyOnline ? kGreen : kMuted,
                                    shape: BoxShape.circle,
                                    border: Border.all(color: kBg2, width: 2),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        title: Text(
                          m.name,
                          style: TextStyle(
                            color: sel ? kGold : kText,
                            fontSize: 14,
                          ),
                        ),
                        subtitle: Text(
                          m.instrument,
                          style: const TextStyle(color: kMuted, fontSize: 12),
                        ),
                        trailing: sel
                            ? const Icon(Icons.check_circle, color: kGold)
                            : const Icon(Icons.circle_outlined, color: kBorder),
                        onTap: () => setState(() {
                          if (sel) {
                            _selected.remove(m.id);
                          } else {
                            _selected.add(m.id);
                          }
                        }),
                      );
                    },
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: ElevatedButton(
                onPressed: () {
                  widget.onChanged(_selected);
                  Navigator.of(context).pop();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: kGold,
                  foregroundColor: kOnGold,
                  minimumSize: const Size.fromHeight(44),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text(
                  'Təsdiqlə',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
