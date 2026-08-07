import 'dart:async';
import 'dart:ui' as ui;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' hide User;
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../../../core/agreements/agreement_cancel.dart';
import '../../../core/agreements/agreement_card.dart';
import '../../../core/agreements/event_edit.dart';
import '../../../core/search/user_search_controller.dart';
import '../../../core/theme/colors.dart';
import '../../../core/agreements/day_buckets.dart';
import '../../../core/time/az_date_format.dart';
import '../../day/screens/day_screen.dart';
import '../../../firebase/firestore_service.dart';
import '../../../firebase/models.dart';
import '../../../shared/widgets/avatar_ring.dart';
import '../../../core/presence/presence_service.dart';
import '../../../shared/widgets/event_conflict_banner.dart';
import '../../../shared/widgets/event_conflict_dialog.dart';
import '../../../shared/widgets/event_notes_picker.dart';
import '../../../shared/widgets/wheel_date_time_picker.dart';
import '../../../shared/widgets/zoomable_image_viewer.dart';
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

String _fmtCreatedAt(dynamic ts) {
  if (ts == null) return '';
  try {
    DateTime d;
    if (ts is Timestamp) {
      d = ts.toDate();
    } else {
      return '';
    }
    return DateFormat('d MMMM yyyy HH:mm', 'az').format(d);
  } catch (_) {
    if (ts is Timestamp) {
      final d = ts.toDate();
      return '${d.day} ${_azMonth(d.month)} ${d.year} '
          '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    }
    return '';
  }
}

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
  // ДЕНЬ — вид по умолчанию с 07.08 (работа 6, вариант «А»).
  //
  // Врезка, а не разбор: `agreements_screen` разбирается на маршруты
  // работой 8, и трогать его устройство сейчас значило бы делать её
  // наполовину. Здесь добавлены ровно две вещи — закладка и ветка вида.
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

  List<PersonalEvent> _outgoing(List<PersonalEvent> agree) =>
      agree.where((e) => e.ownerUid == _uid && e.status != 'cancelled').toList();

  List<PersonalEvent> _incoming(List<PersonalEvent> agree) =>
      agree.where((e) => e.ownerUid != _uid && e.status != 'cancelled').toList();

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
    _readAgreementIds = ref.watch(readAgreementIdsProvider(uid)).value ??
        const <String>[];
    final personalEventsAsync = ref.watch(personalEventsProvider(uid));
    final eventsAsParticipantAsync = ref.watch(eventsAsParticipantProvider(uid));

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
    if (_selectedAgreementId != null) {
      return _AgreementDetailScreen(
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
                      ? _buildCalendarTab(personalEvents, eventsAsParticipant, allUsers)
                      : _buildTedbirlerTab(personalEvents, eventsAsParticipant, allUsers),
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
                    : DateTime(_currentCalendarMonth.year, _currentCalendarMonth.month, 1, 12),
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
                    BoxShadow(
                      color: kGold2.withAlpha(170),
                      blurRadius: 18,
                    ),
                  ],
                ),
                child: const Icon(Icons.add, color: Color(0xFF1A0E00), size: 28),
              ),
            )
          : null,
    );
  }

  bool _isSameMonth(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month;

  // -------------------------------------------------------------------------
  // Top header with three tabs
  // -------------------------------------------------------------------------
  Widget _buildTopHeader(List<PersonalEvent> agreeEvents, bool hasUnread) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: kBorder)),
      ),
      child: Row(
        children: [
          // Only shown when this screen was pushed standalone (e.g. "İş
          // yazdır") rather than reached via its usual bottom-nav "/agreements"
          // tab — that tab has no back destination and never sets
          // initialParticipantUid, so this stays absent there exactly like
          // before this button existed.
          if (widget.initialParticipantUid != null)
            IconButton(
              icon: const Icon(Icons.arrow_back, color: kGold),
              onPressed: () => Navigator.of(context).pop(),
            ),
          _buildHeaderTab(
            label: '📋 Müqavilələr',
            view: 'agreements',
            badge: agreeEvents.length,
            badgeRed: hasUnread,
          ),
          _buildHeaderTab(label: '📅 Təqvim', view: 'calendar'),
          _buildHeaderTab(label: '🎪 Tədbirlər', view: 'tedbirler'),
        ],
      ),
    );
  }

  Widget _buildHeaderTab({
    required String label,
    required String view,
    int badge = 0,
    bool badgeRed = false,
  }) {
    final active = _mainView == view;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _mainView = view),
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
          child: Stack(
            alignment: Alignment.center,
            children: [
              Text(
                label,
                textAlign: TextAlign.center,
                style: GoogleFonts.nunito(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: active ? kText : kMuted,
                ),
              ),
              if (badge > 0)
                Positioned(
                  top: 0,
                  right: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: badgeRed ? const Color(0xFFFF3B30) : kGold,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '$badge',
                      style: const TextStyle(
                        fontSize: 10,
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // =========================================================================
  // AGREEMENTS TAB
  // =========================================================================
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
        _buildAgreementSubTabs(outgoing.length, incoming.length, cancelled.length),
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
                      itemBuilder: (_, i) =>
                          _buildAgreementCard(currentList[i]),
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
          _subTab('Göndərilən ($outCount)', 'outgoing', kGold, const Color(0xFF1A0E00)),
          _subTab('Gələnlər ($inCount)', 'incoming', kGold, const Color(0xFF1A0E00)),
          _subTab('Ləğv edilən ($canCount)', 'cancelled', kRed, Colors.white),
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
    final at = cancelled
        ? agreementCancelledValue(e)
        : agreementSignedValue(e);
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

    Color? borderColor;
    Color? bgColor;
    if (cancelled && unread) {
      borderColor = kRed;
      bgColor = kRed.withAlpha(20);
    } else if (cancelled) {
      borderColor = kRed.withAlpha(77);
      bgColor = Colors.white.withAlpha(3);
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
    } else {
      roleText = e.ownerUid == _uid ? 'Siz göndərdiniz' : 'Sizə göndərildi';
    }
    final roleColor = cancelled ? kRed : unread ? kGold2 : kMuted;

    String? eventLine;
    if (!cancelled && e.type.isNotEmpty && e.date.isNotEmpty) {
      eventLine = '📅 ${e.type} — ${_fmtDate(e.date)}${e.location.isNotEmpty ? ' · ${e.location}' : ''}';
    }

    return GestureDetector(
      onTap: () async {
        await _markRead(e);
        setState(() => _selectedAgreementId = e.id);
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
      return Column(
        children: [
          _buildCalendarModeSwitch(),
          const Expanded(child: DayScreen()),
        ],
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          _buildCalendarModeSwitch(),
          const SizedBox(height: 12),
          _buildMonthHeader(),
          const SizedBox(height: 16),
          _buildDayOfWeekRow(),
          const SizedBox(height: 8),
          _buildCalendarPageView(personalEvents, eventsAsParticipant, allUsers),
          // Содержимое выбранного дня — ПОД СЕТКОЙ, а не на другой
          // закладке. Сетка остаётся на экране: в разговоре спрашивают
          // про несколько дат подряд, и каждая следующая — одно касание,
          // а не новый заход.
          _buildSelectedDayAnswer(personalEvents, eventsAsParticipant),
          const SizedBox(height: 80),
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
              Builder(builder: (_) {
                final m = DateTime(base.year, base.month + i, 1);
                final active = m.year == _currentCalendarMonth.year &&
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
              }),
          ],
        ),
      ),
    );
  }

  Widget _buildCalendarModeSwitch() {
    Widget seg(String mode, String label) {
      final active = _calendarMode == mode;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _calendarMode = mode),
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 9),
            decoration: BoxDecoration(
              color: active ? kGoldDim : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: active ? kGold : Colors.transparent),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: active ? kGold : kMuted,
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Row(children: [seg('gun', 'Gün'), const SizedBox(width: 8), seg('ay', 'Ay')]),
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

    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            fmtDayHeader(date),
            style: const TextStyle(fontSize: 13, letterSpacing: 1.2, color: kMuted),
          ),
          const SizedBox(height: 10),
          if (events.isEmpty)
            const Text(
              'Boşsunuz',
              style: TextStyle(fontSize: 19, color: kTextSecondary),
            )
          else
            for (final e in events)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.only(left: 16, top: 2, bottom: 2),
                decoration: const BoxDecoration(
                  border: Border(left: BorderSide(color: kGold, width: 4)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      fmtEventTime(e.date),
                      style: const TextStyle(fontSize: 21, color: kText),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      [e.type, if (e.location.isNotEmpty) e.location].join(' · '),
                      style: const TextStyle(fontSize: 16, color: kTextSecondary),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  Widget _buildMonthHeader() {
    final monthName = _azMonth(_currentCalendarMonth.month);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _calNavBtn('‹', () {
          final newMonth = DateTime(
            _currentCalendarMonth.year,
            _currentCalendarMonth.month - 1,
            1,
          );
          setState(() {
            _currentCalendarMonth = newMonth;
            _selectedCalendarDay = null;
          });
          _pageController.animateToPage(
            _pageForMonth(newMonth),
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          );
        }),
        // Заголовок — дорога к далёкой дате БЕЗ ЛИСТАНИЯ МЕСЯЦЕВ.
        //
        // Набора числа с клавиатуры здесь нет и не будет (решение
        // владельца 07.08): второй путь к той же операции — это ровно то
        // место, где правило потом оказывается применено к одному из
        // двух. Список месяцев закрывает далёкие даты, и клавиатура для
        // этого не нужна ни разу.
        GestureDetector(
          onTap: _openMonthJump,
          behavior: HitTestBehavior.opaque,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$monthName ${_currentCalendarMonth.year}',
                style: GoogleFonts.nunito(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: kGold2,
                  shadows: [
                    Shadow(color: kGold2.withAlpha(170), blurRadius: 12),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.expand_more, color: kGold2, size: 22),
            ],
          ),
        ),
        _calNavBtn('›', () {
          final newMonth = DateTime(
            _currentCalendarMonth.year,
            _currentCalendarMonth.month + 1,
            1,
          );
          setState(() {
            _currentCalendarMonth = newMonth;
            _selectedCalendarDay = null;
          });
          _pageController.animateToPage(
            _pageForMonth(newMonth),
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          );
        }),
      ],
    );
  }

  // Glass rounded-square (approved preview design) rather than flat kBg3 —
  // same onTap/behavior as before, just BackdropFilter + translucent fill +
  // thin gold border instead of a solid background.
  Widget _calNavBtn(String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      // Glow lives on this outer, unclipped Container — a BoxShadow inside
      // the ClipRRect below would just get clipped away at its rounded
      // edge (same lesson as chat_screen.dart's "İş yazdır" menu glow).
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(13),
          boxShadow: [
            BoxShadow(color: kGold2.withAlpha(70), blurRadius: 12),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(13),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(20),
                borderRadius: BorderRadius.circular(13),
                border: Border.all(color: kGold.withAlpha(60)),
              ),
              child: Center(
                child: Text(label, style: const TextStyle(fontSize: 22, color: kGold2)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDayOfWeekRow() {
    const days = ['B.e', 'Ç.a', 'Ç', 'C.a', 'C', 'Ş', 'B'];
    return Row(
      children: days
          .map((d) => Expanded(
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
              ))
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
    final allEvents = [...personalEvents, ...eventsAsParticipant];
    final year = month.year;
    final monthNum = month.month;
    final firstWeekday = DateTime(year, monthNum, 1).weekday; // 1=Mon
    final startOffset = (firstWeekday - 1) % 7; // Mon=0
    final daysInMonth = DateTime(year, monthNum + 1, 0).day;
    final today = DateTime.now();

    final cells = <Widget>[];
    for (int i = 0; i < startOffset; i++) {
      cells.add(const SizedBox());
    }
    for (int day = 1; day <= daysInMonth; day++) {
      final dayDate = DateTime(year, monthNum, day);
      final dayEvents = allEvents.where((e) {
        if (e.date.isEmpty) return false;
        try {
          final d = DateTime.parse(e.date);
          return d.year == year && d.month == monthNum && d.day == day;
        } catch (_) {
          return false;
        }
      }).toList();
      final isSelected = _selectedCalendarDay == day &&
          _currentCalendarMonth.year == year &&
          _currentCalendarMonth.month == monthNum;
      final isToday = _sameDay(dayDate, today);
      final hasEvents = dayEvents.isNotEmpty;

      cells.add(_buildDayCell(
        day: day,
        weekday: dayDate.weekday,
        isSelected: isSelected,
        isToday: isToday,
        hasEvents: hasEvents,
        eventCount: dayEvents.length,
        onTap: () => _onDayTap(day, dayDate, dayEvents, personalEvents, eventsAsParticipant),
        onLongPress: () => _onDayLongPress(day, dayDate, personalEvents, eventsAsParticipant, allUsers),
      ));
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
  Widget _buildDayCell({
    required int day,
    required int weekday,
    required bool isSelected,
    required bool isToday,
    required bool hasEvents,
    required int eventCount,
    required VoidCallback onTap,
    required VoidCallback onLongPress,
  }) {
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
      textColor = const Color(0xFF1A0E00);
    } else if (hasEvents) {
      bgColor = kGold.withAlpha(28);
      textColor = kGold2;
      glow = [
        BoxShadow(color: kGold2.withAlpha(120), blurRadius: 10),
      ];
    }
    if (isToday && !isSelected) {
      border = Border.all(color: kGold, width: 1.2);
    }

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      // Glass tile behind every cell (not just selected/event/today ones,
      // which is all the previous version drew) — a plain day used to have
      // no background at all, so the grid only looked "glassy" wherever a
      // special state already added its own circle.
      child: Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(16),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withAlpha(28)),
        ),
        child: Center(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: bgColor,
                  shape: BoxShape.circle,
                  border: border,
                  boxShadow: glow,
                ),
                child: Center(
                  child: Text(
                    '$day',
                    style: TextStyle(
                      fontSize: 16,
                      color: textColor,
                      fontWeight: isSelected || hasEvents ? FontWeight.bold : FontWeight.normal,
                      shadows: textGlow,
                    ),
                  ),
                ),
              ),
              if (hasEvents && !isSelected)
                Positioned(
                  top: -4,
                  right: -6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [kGold2, kGold],
                      ),
                      borderRadius: BorderRadius.circular(999),
                      boxShadow: [
                        BoxShadow(color: kGold.withAlpha(140), blurRadius: 6),
                      ],
                    ),
                    child: Center(
                      child: Text(
                        '$eventCount',
                        style: const TextStyle(
                          fontSize: 10,
                          color: Color(0xFF1A0E00),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
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
        initialParticipantUids: seed?.participantUids ??
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
    final ownEvents = personalEvents.where((e) => e.ownerUid == _uid).map((e) => _TaggedEvent(e, true)).toList();
    final invitedEvents = eventsAsParticipant.where((e) => e.ownerUid != _uid).map((e) => _TaggedEvent(e, false)).toList();

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
                  child: Text('Heç bir tədbir yoxdur', style: TextStyle(color: kMuted)),
                )
              : tagged.isEmpty
                  ? const Center(
                      child: Text('Bu filterdə tədbir yoxdur', style: TextStyle(color: kMuted)),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: tagged.length,
                      itemBuilder: (_, i) {
                        final t = tagged[i];
                        final allUsersList = ref.watch(allUsersProvider).asData?.value ?? [];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _EventCard(
                            event: t.event,
                            isOwn: t.isOwn,
                            currentUid: _uid,
                            allUsers: allUsersList,
                            onTap: () => setState(() => _tedbirDetailId = t.event.id),
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
      decoration: BoxDecoration(color: kBg3, borderRadius: BorderRadius.circular(14)),
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
              color: active ? const Color(0xFF1A0E00) : kMuted,
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
                  child: const Text('✕', style: TextStyle(color: kGold, fontSize: 13)),
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
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: kGold.withAlpha(56),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    children: [
                      Text(
                        initiatorName,
                        style: GoogleFonts.nunito(
                          fontSize: 16,
                          color: kGold,
                        ),
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
                  return GestureDetector(
                    onTap: () => _openUserProfile(context, mUid),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: isMe ? kGold.withAlpha(38) : kBg3,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: isMe ? kGold : kBorder),
                      ),
                      child: Text(
                        '${m?.emoji ?? '🎵'} $name${instr.isNotEmpty ? ' · $instr' : ''}',
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

// ---------------------------------------------------------------------------
// Row widget for detail screens
// ---------------------------------------------------------------------------
class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  final bool last;
  // Строка только что изменилась чужой правкой (см. _RemoteChangeFlash).
  final bool flash;

  const _DetailRow({
    required this.label,
    required this.value,
    this.last = false,
    this.flash = false,
  });

  @override
  Widget build(BuildContext context) {
    // Заливка, а не мигание: мигание в списке из пяти строк читается как
    // сбой отрисовки. Гаснет плавно — момент, когда подсветка сходит на
    // нет, сам по себе показывает, что изменение уже не новое.
    return AnimatedContainer(
      duration: const Duration(milliseconds: 600),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(
        color: flash ? kGold.withAlpha(46) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: last
            ? null
            : const Border(bottom: BorderSide(color: kBorder)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 90,
            child: Text(label, style: const TextStyle(fontSize: 13, color: kMuted)),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 13,
                color: kText,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PartyRow extends StatelessWidget {
  final String name;
  final String label;
  final bool highlighted;
  final VoidCallback onTap;

  const _PartyRow({
    required this.name,
    required this.label,
    required this.highlighted,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: highlighted ? kGold.withAlpha(20) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: kBg3,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Center(child: Text('👤', style: TextStyle(fontSize: 18))),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      style: const TextStyle(
                          fontSize: 14, color: kText, fontWeight: FontWeight.w600)),
                  Text(label, style: const TextStyle(fontSize: 12, color: kMuted)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: kMuted, size: 20),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// AgreementDetail screen
// ---------------------------------------------------------------------------
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
PersonalEvent? _findEvent(
  String id,
  List<PersonalEvent> own,
  List<PersonalEvent> asParticipant,
) {
  for (final e in own) {
    if (e.id == id) return e;
  }
  for (final e in asParticipant) {
    if (e.id == id) return e;
  }
  return null;
}

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
      child: Text('Bu qeyd artıq mövcud deyil',
          style: TextStyle(color: Colors.white70)),
    ),
  );
}

// Принимает **id договора, а не сам договор** — намеренно (N23). Прежняя
// подпись брала `PersonalEvent event` копией из конструктора, и экран
// показывал снимок, с которым его открыли: правка сохранялась в базу
// верно, но на экране оставалось прежнее значение до выхода и повторного
// захода. Провайдер при этом всё время был живым — не слушала его сама
// карточка.
//
// Поэтому чинится не «добавить обновление после сохранения», а так, чтобы
// копию сюда нельзя было передать вообще: договор ищется по id в потоке
// на каждой перерисовке. Четвёртая точка входа, если появится, не сможет
// повторить дефект — передать нечего, кроме id.
//
// Лишней подписки это не создаёт: `personalEventsProvider(uid)` уже
// слушает родительский экран, а Riverpod на одинаковый аргумент семейства
// отдаёт ту же самую.
class _AgreementDetailScreen extends ConsumerStatefulWidget {
  final String eventId;
  final String currentUid;
  final VoidCallback onBack;

  const _AgreementDetailScreen({
    required this.eventId,
    required this.currentUid,
    required this.onBack,
  });

  @override
  ConsumerState<_AgreementDetailScreen> createState() =>
      _AgreementDetailScreenState();
}

// Состояние здесь ровно одно и служит одной цели — подсветке чужой
// правки. Само событие по-прежнему берётся из потока на каждой
// перерисовке, копии в состоянии нет (N23).
class _AgreementDetailScreenState extends ConsumerState<_AgreementDetailScreen> {
  final _flash = _RemoteChangeFlash();

  // Идёт запись отмены — гасим кнопки, чтобы второй тап не ушёл поверх
  // первого. Только это; само состояние договора по-прежнему берётся из
  // потока, копии здесь нет (N23).
  bool _cancelBusy = false;

  /// Один ход отмены: выполнить и, если сервер отказал, СКАЗАТЬ ОБ ЭТОМ.
  ///
  /// `permission-denied` здесь не поломка, а осмысленный ответ: правила
  /// устроены так, что при одновременности проходит тот, кто записал
  /// первым, а второму отказывают. Кто именно опередил — известно заранее
  /// по самому ходу, поэтому [raceMessage] у каждого свой и говорит
  /// правду, а не «Xəta».
  ///
  /// **Глотать этот отказ нельзя.** Он детерминированный: повтор даст тот
  /// же результат, потому что состояние на сервере уже другое. Молчание
  /// превратило бы «не сработает никогда» в «сработало» — класс «перехват
  /// без последствий делает поломку невидимой», а человек остался бы с
  /// кнопкой, которая на вид нажимается и ничего не меняет.
  ///
  /// Кнопка при отказе оживает: экран перерисуется от потока, и набор
  /// кнопок станет тем, который соответствует НОВОМУ состоянию договора.
  /// До этого мгновения локальный кеш успевает показать несостоявшийся
  /// исход и откатить его — поэтому слова важнее вида кнопок.
  Future<void> _cancelStep(
    Future<void> Function() step, {
    // Ход, который совершается: по нему разбирается отказ (N45).
    required String deed,
    required String eventId,
    // Что сказать, если состояние отказ ОБЪЯСНЯЕТ, — то есть при гонке.
    required String raceMessage,
  }) async {
    if (_cancelBusy) return;
    setState(() => _cancelBusy = true);
    try {
      await step();
    } on FirebaseException catch (e, st) {
      if (e.code != 'permission-denied') {
        if (mounted) _say('Xəta: ${e.message ?? e.code}');
        FirebaseCrashlytics.instance.recordError(
          e,
          st,
          reason: 'agreements_screen: cancel step failed',
        );
        return;
      }
      // ОТКАЗ ПО ПРАВАМ — причин ДВЕ, и сама ошибка их не различает
      // (N45). Спрашиваем состояние С СЕРВЕРА и разбираем правилом:
      // объясняет ли оно отказ. Из кэша спрашивать бессмысленно — там
      // лежит картина, из которой мы решили, что ход законен.
      final fresh = await ref
          .read(firestoreServiceProvider)
          .fetchPersonalEventFromServer(eventId);
      final verdict = fresh == null
          // Прочитать не удалось — сказать нечего. Считаем причину
          // неизвестной: додумывать её здесь значит вернуть тот самый
          // дефект, ради которого правило заведено.
          ? CancelDenial.unknown
          : explainCancelDenial(
              deed: deed,
              status: fresh.status,
              cancelRequestedBy: fresh.cancelRequestedBy,
              currentUid: widget.currentUid,
            );
      if (!mounted) return;
      if (verdict == CancelDenial.race) {
        // Законный исход: вторая сторона успела раньше. В Crashlytics не
        // сообщаем — это не поломка, а жизнь.
        _say(raceMessage);
        return;
      }
      // Состояние отказ НЕ объясняет: правила не выложены, разошлись
      // имена поступков, испорчены данные — что угодно, кроме гонки.
      // Осторожные слова вместо выдуманной причины, и обязательно в
      // Crashlytics: сегодня этот случай не виден нигде.
      _say('Əməliyyat alınmadı, yenidən yoxlayın');
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'agreements_screen: отказ по правам, состояние его не '
            'объясняет (ход $deed, статус ${fresh?.status ?? 'не прочитан'})',
      );
    } catch (e, st) {
      if (!mounted) return;
      // Сюда попадает и таймаут записи. Он НЕ значит «не прошло»: запись
      // могла уйти и подтвердиться позже. Поэтому слова осторожные, а не
      // «не получилось».
      _say('Əməliyyat tamamlanmadı, yenidən yoxlayın');
      FirebaseCrashlytics.instance.recordError(
        e,
        st,
        reason: 'agreements_screen: cancel step failed',
      );
    } finally {
      if (mounted) setState(() => _cancelBusy = false);
    }
  }

  void _say(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: kBg3,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  /// Отмена по согласию — ОДНА дорога к каждому ходу, только отсюда.
  ///
  /// Однопутно намеренно. Гарантия «по согласию» держится на сервере
  /// (`requestsCancel`/`confirmsCancel` и две дороги снятия), поэтому
  /// вторая дорога в интерфейсе ничего бы не добавила к безопасности, а
  /// добавила бы ещё одно место, где забудут (правило «клиентское
  /// состояние без сервера за спиной не размножать по путям» —
  /// применённое к его второй половине: даже при живом правиле лишняя
  /// дорога это лишний повод разойтись в словах и в `lastActionType`).
  ///
  /// Отзыв и отказ РАЗЛИЧИМЫ ЗДЕСЬ, а не только в данных. Кнопка у
  /// запросившего одна — «Geri götür», у второй стороны их две —
  /// «Razıyam» и «Razı deyiləm». Одна кнопка на оба смысла записала бы
  /// неверный `lastActionType`, и уведомление ушло бы не тому человеку:
  /// поступка два, и назвать их одним словом нельзя.
  Widget _cancelSection(
    PersonalEvent event,
    String currentUid,
    FirestoreService svc,
    // Имя называет вызывающий: правило имён не знает, а взять их из
    // документа нельзя — там лежит одно, и на экране получателя оно
    // превращается в его собственное (N53).
    String Function(String? uid) nameOf,
  ) {
    // Само правило — в чистой функции (core/agreements/agreement_cancel.dart),
    // здесь только применение. Так же, как у плашки конфликта: правило
    // обязано быть проверяемо тестом, а внутри состояния виджета проверить
    // его нечем.
    final stage = resolveCancelStage(
      status: event.status,
      cancelRequestedBy: event.cancelRequestedBy,
      currentUid: currentUid,
    );
    // Кто ИМЕННО просит отмену — по `cancelRequestedBy`, а не «вторая
    // сторона» из документа. Прежде здесь стоял `partnerName`, и на
    // экране получателя строка называла его самого: «Teymur Orucov
    // müqavilənin ləğvini təklif edir» — Теймуру (N53, снято 07.08 на
    // двух устройствах одновременно).
    final requester = nameOf(event.cancelRequestedBy);

    if (stage == CancelStage.cancelled) return const SizedBox.shrink();

    if (stage == CancelStage.none) {
      return _cancelBox(
        children: [
          _cancelButton(
            label: 'Müqaviləni ləğv et',
            color: kRed,
            filled: false,
            onTap: () async {
              final ok = await _ask(
                title: 'Müqaviləni ləğv etmək?',
                body: 'Qarşı tərəfə ləğv təklifi göndəriləcək. Müqavilə '
                    'yalnız o razılaşdıqdan sonra ləğv olunacaq.',
                confirmLabel: 'Təklif göndər',
              );
              if (!ok) return;
              await _cancelStep(
                () => svc.requestAgreementCancel(event.id, currentUid),
                deed: kCancelRequested,
                eventId: event.id,
                raceMessage: 'Qarşı tərəf artıq ləğv təklifi göndərib',
              );
            },
          ),
        ],
      );
    }

    if (stage == CancelStage.requestedByMe) {
      // Своя просьба ждёт ответа. Дорога отсюда одна — отозвать.
      return _cancelBox(
        note: '⏳ Ləğv təklifi göndərildi — cavab gözlənilir',
        noteColor: kGold,
        children: [
          _cancelButton(
            label: 'Geri götür',
            color: kGold,
            filled: false,
            onTap: () async {
              final ok = await _ask(
                title: 'Təklifi geri götürmək?',
                body: 'Müqavilə qüvvədə qalacaq.',
                confirmLabel: 'Geri götür',
                confirmColor: kGold,
              );
              if (!ok) return;
              await _cancelStep(
                () => svc.withdrawAgreementCancel(event.id, currentUid),
                deed: kCancelWithdrawn,
                eventId: event.id,
                // Проиграл гонку — значит вторая сторона успела
                // подтвердить. Это и есть те самые слова вместо молчания.
                raceMessage: 'Qarşı tərəf ləğvi artıq təsdiqlədi',
              );
            },
          ),
        ],
      );
    }

    // Просит второй — у меня два разных ответа, и они не одно и то же.
    return _cancelBox(
      note: '$requester müqavilənin ləğvini təklif edir',
      noteColor: kRed,
      children: [
        _cancelButton(
          label: 'Razıyam, ləğv edilsin',
          color: kRed,
          filled: true,
          onTap: () async {
            final ok = await _ask(
              title: 'Müqaviləni ləğv etmək?',
              body: 'Müqavilə ləğv olunacaq. Bunu geri qaytarmaq mümkün deyil.',
              confirmLabel: 'Ləğv et',
            );
            if (!ok) return;
            await _cancelStep(
              () => svc.confirmAgreementCancel(event.id, currentUid),
              deed: kCancelConfirmed,
              eventId: event.id,
              raceMessage: 'Təklif artıq geri götürülüb',
            );
          },
        ),
        const SizedBox(height: 8),
        _cancelButton(
          label: 'Razı deyiləm',
          color: kMuted,
          filled: false,
          onTap: () async {
            final ok = await _ask(
              title: 'Ləğvə etiraz etmək?',
              body: 'Müqavilə qüvvədə qalacaq, qarşı tərəfə bildiriş '
                  'göndəriləcək.',
              confirmLabel: 'Razı deyiləm',
              confirmColor: kGold,
            );
            if (!ok) return;
            await _cancelStep(
              () => svc.declineAgreementCancel(event.id, currentUid),
              deed: kCancelDeclined,
              eventId: event.id,
              raceMessage: 'Təklif artıq geri götürülüb',
            );
          },
        ),
      ],
    );
  }

  Widget _cancelBox({
    String? note,
    Color noteColor = kMuted,
    required List<Widget> children,
  }) {
    return Container(
      margin: const EdgeInsets.only(top: 20),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kBg3,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (note != null) ...[
            Text(
              note,
              style: TextStyle(
                color: noteColor,
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                height: 1.35,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
          ],
          ...children,
        ],
      ),
    );
  }

  Widget _cancelButton({
    required String label,
    required Color color,
    required bool filled,
    required VoidCallback onTap,
  }) {
    final onPressed = _cancelBusy ? null : onTap;
    if (filled) {
      return ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        child: Text(label,
            style: const TextStyle(fontWeight: FontWeight.bold)),
      );
    }
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color.withAlpha(140)),
        padding: const EdgeInsets.symmetric(vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
      child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
    );
  }

  /// Спросить перед необратимым. Отмена договора касается второго
  /// человека, и о ней он узнает уведомлением — такое не делают тапом без
  /// вопроса.
  Future<bool> _ask({
    required String title,
    required String body,
    required String confirmLabel,
    Color confirmColor = kRed,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: kBg2,
        title: Text(title,
            style: GoogleFonts.nunito(
                color: kGold, fontSize: 17, fontWeight: FontWeight.bold)),
        content: Text(body, style: const TextStyle(color: kText, height: 1.4)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('İmtina', style: TextStyle(color: kMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(confirmLabel, style: TextStyle(color: confirmColor)),
          ),
        ],
      ),
    );
    return ok == true;
  }

  // Отметка «смотрю в эту карточку» — тот же механизм присутствия, что у
  // чата, но своим полем (`activeEventId`). Пока карточка открыта, сервер
  // не шлёт уведомлений об ЭТОМ мероприятии: человек и так видит правку
  // своими глазами, а пуш поверх открытого экрана раздражает.
  //
  // Снимается в dispose, а протухает сама вместе с сердцебиением — свернул
  // приложение, и отметка перестаёт быть свежей без всякой уборки. Ровно
  // это и чинил N19: признак без срока годности глушил уведомления
  // навсегда.
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

  /// Ярлык стороны на отменённом договоре: кто предложил, кто согласился.
  ///
  /// Прежде у обоих стояло «İmtina etdi» — то есть отказавшимся называли и
  /// того, кто СОГЛАСИЛСЯ (N54). Отказ и согласие противоположны, одним
  /// словом их не назвать.
  String _partyLabel(
    AgreementCardState card, {
    required String? uid,
    required String base,
  }) {
    if (card.outcome != AgreementOutcome.cancelledByAgreement || uid == null) {
      return base;
    }
    // Причастия, как у соседних «Göndərən» и «Qəbul edən»: ярлык —
    // подпись под именем, и лица в нём нет ни у кого.
    if (uid == card.proposedByUid) return 'Ləğvi təklif edən';
    if (uid == card.confirmedByUid) return 'Ləğvə razılaşan';
    return base;
  }

  User? _findUser(List<User> allUsers, String uid) {
    try {
      return allUsers.firstWhere((m) => m.id == uid);
    } catch (_) {
      return null;
    }
  }

  void _openUserProfile(BuildContext context, List<User> allUsers, String? uid) {
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

    final event = _findEvent(widget.eventId, personalEvents, eventsAsParticipant);
    if (event == null) return _eventGoneScaffold('Müqavilə', onBack);

    _flash.sync(event, () {
      if (mounted) setState(() {});
    });

    final isCancelled = event.status == 'cancelled';
    final isOwner = event.ownerUid == currentUid;

    // Что карточка говорит о судьбе договора — одно правило на все исходы
    // (`core/agreements/agreement_card.dart`, N53/N54). Здесь только
    // подстановка имён: правило имён не знает и знать не должно.
    final card = agreementCardState(
      status: event.status,
      cancelRequestedBy: event.cancelRequestedBy,
      cancelConfirmedBy: event.cancelConfirmedBy,
      lastActionBy: event.lastActionBy,
      lastActionType: event.lastActionType,
    );
    // Имя ЛЮБОЙ стороны берётся по uid из списка пользователей, а не из
    // `partnerName` документа: то поле означает «вторая сторона глазами
    // владельца», и на экране получателя превращалось в его собственное
    // имя. Список на экране уже есть — рядом по нему открываются профили.
    String nameOf(String? uid) {
      if (uid == null) return 'Naməlum';
      if (uid == currentUid) return 'Siz';
      final u = _findUser(allUsers, uid);
      if (u != null && u.name.isNotEmpty) return u.name;
      // Запасной путь ровно для одного случая: человека нет в списке
      // (удалён, ещё не загрузился). Имя владельца в документе не лежит
      // вовсе, поэтому здесь честнее «Naməlum», чем чужое имя.
      return uid == event.partnerUid ? (event.partnerName ?? 'Naməlum') : 'Naməlum';
    }

    // «кто» + глагол в нужном лице. Слова — в правиле
    // (`deedText`), здесь только сборка: «Siz təklif etdi» верно ровно
    // наполовину, и неверная половина — про самого смотрящего.
    String deed(String? uid, AgreementDeed what) =>
        '${nameOf(uid)} ${deedText(what, byViewer: uid == currentUid)}';

    Widget statusBadge;
    if (isCancelled) {
      statusBadge = Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: kRed.withAlpha(30),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kRed.withAlpha(100)),
        ),
        // «Müqavilə ləğv edildi», а не «{кто-то} imtina etdi»: отказа как
        // ИСХОДА не существует вовсе — `declinesCancelRequest` очищает
        // поля запроса и оставляет договор в силе. Слово «imtina»
        // переехало сюда из чатового раунда, где отказ действительно
        // исход, и здесь называло согласие отказом (N54).
        child: const Text('✖ Müqavilə ləğv edildi',
            style: TextStyle(color: kRed, fontWeight: FontWeight.w600)),
      );
    } else {
      statusBadge = Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: kGreen.withAlpha(30),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kGreen.withAlpha(100)),
        ),
        child: const Text('✅ Razılaşma qəbul edildi',
            style: TextStyle(color: kGreen, fontWeight: FontWeight.w600)),
      );
    }

    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg2,
        title: Text('Müqavilə',
            style: GoogleFonts.nunito(color: kGold, fontSize: 18)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: kGold),
          onPressed: onBack,
        ),
        actions: [
          if (isOwner)
            IconButton(
              icon: const Text('✏️', style: TextStyle(fontSize: 20)),
              onPressed: () {
                DateTime initialDate;
                try {
                  initialDate = DateTime.parse(event.date);
                } catch (_) {
                  initialDate = DateTime.now();
                }
                showModalBottomSheet(
                  // Тап по затемнённому фону не закрывает: по нему легко попасть,
                  // целясь в поле формы, и терять введённое из-за промаха обидно.
                  // Свайп и кнопка отмены закрывают как обычно — они делаются
                  // намеренно. Одно правило на все листы С ВВОДОМ (N28).
                  isDismissible: false,
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: Colors.transparent,
                  builder: (_) => _EventFormModal(
                    mode: 'full',
                    initialDate: initialDate,
                    initialType: event.type,
                    initialLocation: event.location,
                    initialNotes: event.notes,
                    initialParticipantUids: event.participantUids,
                    allUsers: allUsers,
                    existingEvent: event,
                    allCombinedEvents: [...personalEvents, ...eventsAsParticipant],
                    currentUid: currentUid,
                    firestoreService: firestoreService,
                    onWillSave: _flash.rememberSelfSave,
                  ),
                );
              },
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(child: statusBadge),
            if (event.createdAt != null) ...[
              const SizedBox(height: 8),
              Center(
                child: Text(
                  // Под красным бейджем — когда ОТМЕНЁН, под зелёным —
                  // когда заключён. Прежде под обоими стояла дата
                  // создания, и под красным она читалась как время
                  // отмены (N53).
                  card.stamp == AgreementStamp.cancelled
                      ? '${_fmtCreatedAt(event.cancelledAt)} — ləğv edildi'
                      : '${_fmtCreatedAt(event.createdAt)} — bağlandı',
                  style: const TextStyle(fontSize: 12, color: kMuted),
                ),
              ),
            ],
            // Отмена по согласию — поступок ДВОИХ, и названы оба. Одного
            // имени у этого исхода не бывает: один предложил, второй
            // согласился, и без второго строка врёт умолчанием.
            if (card.outcome == AgreementOutcome.cancelledByAgreement) ...[
              const SizedBox(height: 6),
              Center(
                child: Text(
                  '${deed(card.proposedByUid, AgreementDeed.proposedCancel)} · '
                  '${deed(card.confirmedByUid, AgreementDeed.agreedToCancel)}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, color: kMuted),
                ),
              ),
            ],
            // СЛЕД ЖИВЫХ ИСХОДОВ (N53, пункт 4). Отзыв и отказ не меняют
            // ничего, кроме имени поступка: договор остаётся в силе, поля
            // запроса очищены. До 07.08 экран об этом молчал вовсе, а push
            // на iOS не работает (N25-push) — то есть человек не узнавал
            // исход НИКАК. Строка нейтральная, не красная: договор жив.
            if (card.outcome == AgreementOutcome.requestWithdrawn ||
                card.outcome == AgreementOutcome.requestDeclined) ...[
              const SizedBox(height: 10),
              Center(
                child: Text(
                  deed(
                    card.actedByUid,
                    card.outcome == AgreementOutcome.requestWithdrawn
                        ? AgreementDeed.withdrewRequest
                        : AgreementDeed.refusedCancel,
                  ),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, color: kMuted),
                ),
              ),
            ],
            if (!isCancelled && event.type.isNotEmpty && event.date.isNotEmpty) ...[
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: kBg3,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: kBorder),
                ),
                child: Column(
                  children: [
                    _DetailRow(
                        label: 'Növ',
                        value: event.type,
                        flash: _flash.flashing.contains('type')),
                    _DetailRow(
                        label: 'Tarix',
                        value: _fmtDate(event.date),
                        flash: _flash.flashing.contains('date')),
                    _DetailRow(
                        label: 'Vaxt',
                        value: _fmtTime(event.date),
                        flash: _flash.flashing.contains('date')),
                    _DetailRow(
                        label: 'Yer',
                        value: event.location,
                        flash: _flash.flashing.contains('location')),
                    _DetailRow(
                        label: 'Əlavələr',
                        value: event.notes,
                        last: true,
                        flash: _flash.flashing.contains('notes')),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 20),
            Text('Tərəflər',
                style: GoogleFonts.nunito(
                    fontSize: 16, fontWeight: FontWeight.bold, color: kText)),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: kBg3,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: kBorder),
              ),
              child: Column(
                children: [
                  // Имя каждой стороны — по её uid. Прежде вторая строка
                  // брала `partnerName`, и на экране получателя первая
                  // строка называла его самого отправителем договора
                  // (N53): имени владельца в документе нет вовсе.
                  _PartyRow(
                    name: nameOf(event.ownerUid),
                    label: _partyLabel(card,
                        uid: event.ownerUid, base: 'Göndərən (Təklif edən)'),
                    highlighted: event.ownerUid == currentUid,
                    onTap: () => _openUserProfile(context, allUsers, event.ownerUid),
                  ),
                  const Divider(color: kBorder, height: 1),
                  _PartyRow(
                    name: nameOf(event.partnerUid),
                    label: _partyLabel(card,
                        uid: event.partnerUid, base: 'Qəbul edən'),
                    highlighted: event.ownerUid != currentUid,
                    onTap: () => _openUserProfile(context, allUsers, event.partnerUid),
                  ),
                ],
              ),
            ),
            // TODO: Chat history section — depends on chat messages not yet ported
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: kBg3,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: kBorder),
              ),
              child: Text(
                // СЕДЬМОЕ место того же корня, найдено 07.08 снимком со
                // ВТОРОГО телефона, а не чтением кода (N53). Предыдущий
                // проход искал строки сторон и тексты про отмену — обычное
                // предложение под ними мимо него и прошло. У получателя
                // здесь стояло его собственное имя дважды: «Bu müqavilə
                // Teymur Orucov və Siz arasında…».
                'Bu müqavilə ${nameOf(event.ownerUid)} '
                'və ${nameOf(event.partnerUid)} '
                'arasında qarşılıqlı razılıq əsasında bağlanmışdır.',
                style: const TextStyle(
                  fontSize: 13,
                  color: kMuted,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
            // Отмена по согласию — единственная дорога к ней во всём
            // приложении. Внизу карточки намеренно: это последнее, что
            // человек должен встретить, прочитав договор целиком.
            _cancelSection(event, currentUid, firestoreService, nameOf),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
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

  User? _findUser(List<User> allUsers, String uid) {
    try {
      return allUsers.firstWhere((m) => m.id == uid);
    } catch (_) {
      return null;
    }
  }

  void _openUserProfile(BuildContext context, List<User> allUsers, String? uid) {
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

    final event = _findEvent(widget.eventId, personalEvents, eventsAsParticipant);
    if (event == null) return _eventGoneScaffold('Tədbir', onBack);

    _flash.sync(event, () {
      if (mounted) setState(() {});
    });

    final isOwner = event.ownerUid == currentUid;
    final initiatorUid = isOwner ? currentUid : event.ownerUid;
    final initiator = _findUser(allUsers, initiatorUid);
    // То же правило, что и в карточке списка (N53).
    final initiatorName = initiator?.name ?? (isOwner ? 'Siz' : 'Naməlum');
    final initiatorInstrument = initiator?.instrument ?? '';

    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg2,
        title: Text('Tədbir',
            style: GoogleFonts.nunito(color: kGold, fontSize: 18)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: kGold),
          onPressed: onBack,
        ),
        actions: [
          if (isOwner)
            IconButton(
              icon: const Text('✏️', style: TextStyle(fontSize: 20)),
              onPressed: () {
                DateTime initialDate;
                try {
                  initialDate = DateTime.parse(event.date);
                } catch (_) {
                  initialDate = DateTime.now();
                }
                showModalBottomSheet(
                  // Тап по затемнённому фону не закрывает: по нему легко попасть,
                  // целясь в поле формы, и терять введённое из-за промаха обидно.
                  // Свайп и кнопка отмены закрывают как обычно — они делаются
                  // намеренно. Одно правило на все листы С ВВОДОМ (N28).
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
                    currentUid: currentUid,
                    firestoreService: firestoreService,
                    onWillSave: _flash.rememberSelfSave,
                  ),
                );
              },
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Initiator pill
            Center(
              child: GestureDetector(
                onTap: () => _openUserProfile(context, allUsers, initiatorUid),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: kGold.withAlpha(56),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    children: [
                      Text(initiatorName,
                          style: GoogleFonts.nunito(fontSize: 16, color: kGold)),
                      if (initiatorInstrument.isNotEmpty)
                        Text(initiatorInstrument,
                            style: TextStyle(fontSize: 11, color: kGold.withAlpha(204))),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            // Details card
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: kBg3,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: kBorder),
              ),
              child: Column(
                children: [
                  _DetailRow(
                      label: 'Növ',
                      value: event.type,
                      flash: _flash.flashing.contains('type')),
                  _DetailRow(
                      label: 'Yer',
                      value: event.location,
                      flash: _flash.flashing.contains('location')),
                  _DetailRow(
                      label: 'Tarix',
                      value: _fmtDate(event.date),
                      flash: _flash.flashing.contains('date')),
                  _DetailRow(
                      label: 'Saat',
                      value: _fmtTime(event.date),
                      flash: _flash.flashing.contains('date')),
                  _DetailRow(
                      label: 'Qeyd',
                      value: event.notes,
                      last: true,
                      flash: _flash.flashing.contains('notes')),
                ],
              ),
            ),
            // Organiser card (if invited)
            if (!isOwner && event.ownerUid.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text('Təşkilatçı',
                  style: GoogleFonts.nunito(
                      fontSize: 16, fontWeight: FontWeight.bold, color: kText)),
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                  color: kBg3,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: kBorder),
                ),
                child: _PartyRow(
                  // Запасным именем владельца НЕ может быть `partnerName`:
                  // это имя второй стороны, и на её же экране оно назвало
                  // бы её саму хозяином чужого мероприятия (N53).
                  name: _findUser(allUsers, event.ownerUid)?.name ?? 'Naməlum',
                  label: 'Təşkilatçı',
                  highlighted: false,
                  onTap: () => _openUserProfile(context, allUsers, event.ownerUid),
                ),
              ),
            ],
            // Participants card
            if (event.participantUids.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text('İştirakçılar',
                  style: GoogleFonts.nunito(
                      fontSize: 16, fontWeight: FontWeight.bold, color: kText)),
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                  color: kBg3,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: kBorder),
                ),
                child: Column(
                  children: [
                    for (int i = 0; i < event.participantUids.length; i++) ...[
                      if (i > 0) const Divider(color: kBorder, height: 1),
                      _PartyRow(
                        name: _findUser(allUsers, event.participantUids[i])?.name ?? event.participantUids[i],
                        label: _findUser(allUsers, event.participantUids[i])?.instrument ?? 'İştirakçı',
                        highlighted: event.participantUids[i] == currentUid,
                        onTap: () => _openUserProfile(context, allUsers, event.participantUids[i]),
                      ),
                    ],
                  ],
                ),
              ),
            ],
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _ConflictEventScreen
// ---------------------------------------------------------------------------
// Публичная точка входа: лист предложения работы (chat/screens/
// job_offer_date_sheet.dart) показывает тот же общий диалог конфликта, и
// по ответу «Bax» обязан открыть ровно этот экран, а не свой похожий.
//
// Экран остаётся приватным намеренно: он тянет за собой карточку события
// (`_EventCard`) и экран подробностей (`_PersonalEventDetailScreen`), и
// вытаскивать их наружу ради одного вызова значило бы разобрать половину
// этого файла. Наружу отдан только маршрут.
Route<void> agreementConflictEventRoute({
  required PersonalEvent event,
  required String currentUid,
  required List<User> allUsers,
}) => MaterialPageRoute(
  builder: (_) => _ConflictEventScreen(
    event: event,
    categoryTitle: event.ownerUid == currentUid
        ? 'Şəxsi tədbir'
        : 'Dəvətli tədbir',
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
      if (_blinkCount >= 6) { // 3 full blinks = 6 toggles
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
                    ? [BoxShadow(
                        color: kGold.withAlpha(60),
                        blurRadius: 12,
                        spreadRadius: 2,
                      )]
                    : [],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(13),
                child: _EventCard(
                  event: widget.event,
                  isOwn: widget.event.ownerUid == widget.currentUid,
                  currentUid: widget.currentUid,
                  allUsers: widget.allUsers,
                  onTap: () {
                    Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => _PersonalEventDetailScreen(
                        eventId: widget.event.id,
                        currentUid: widget.currentUid,
                        onBack: () => Navigator.of(context).pop(),
                      ),
                    ));
                  },
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

  bool get _isTimeBlocked =>
      isConflictTimeBlocked(_selectedDate, _blockedTime);

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
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _ConflictEventScreen(
        event: conflict,
        categoryTitle: categoryTitle,
        currentUid: widget.currentUid,
        allUsers: widget.allUsers,
      ),
    ));
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
    final exact = exactConflictsAt(_selectedDate, events,
        excludeEventId: _excludeEventId, resolvedIds: _resolvedConflictIds);

    if (editing) {
      final answers = conflictAnswers(
        isEditing: true,
        exactTime: exact.isNotEmpty,
        // Владение мешающего мероприятия к правке отношения не имеет:
        // подмена этого вопроса и давала N39. Передаётся ради полноты
        // вызова — правило его при правке не читает. Берём первое из
        // занявших минуту: при правке ответ от этого не зависит вовсе.
        targetIsMine: exact.isNotEmpty &&
            exact.first.ownerUid == widget.currentUid,
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
    final sameDay = conflictEventsOnDay(_selectedDate, events,
            excludeEventId: _excludeEventId)
        .where((e) => !_resolvedConflictIds.contains(e.id))
        .toList();
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
        await widget.firestoreService.updatePersonalEvent(
          widget.existingEvent!.id,
          eventEditUpdate(
            date: dateIso,
            type: _type,
            location: _location,
            notes: notes,
            musicians: _selectedParticipantUids,
            actorUid: widget.currentUid,
          ),
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
      await widget.firestoreService
          .leavePersonalEvent(target.id, widget.currentUid);
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
                    widget.existingEvent != null ? 'Tədbiri Redaktə et' : 'Yeni Tədbir',
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
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
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
                    blockedTime: _blockedTime,
                    excludeEventId: _excludeEventId,
                    // Считается для НОВОЙ даты, а не через `_pastDatePicked`:
                    // тот смотрит на `_selectedDate`, и на прошлой дате
                    // предупреждение о занятости не поднимается вовсе —
                    // значит и конфликтов в нём не будет.
                    pastDate: d != _openedWithDate && d.isBefore(DateTime.now()),
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
              const Text('İŞTİRAKÇILAR',
                  style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 0.8,
                      color: kMuted,
                      fontWeight: FontWeight.w600)),
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
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
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
                                    builder: (_) => UserProfileScreen(user: m!),
                                  ),
                                ),
                          child: Text(
                            '${m?.emoji ?? '🎵'} ${m?.name ?? uid}',
                            style: const TextStyle(color: kGold, fontSize: 12),
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
                          child: const Text('×',
                              style: TextStyle(color: kRed, fontSize: 16)),
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
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: kBg3,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: kBorder),
                    ),
                    child: const Text('+ Əlavə et',
                        style: TextStyle(color: kMuted, fontSize: 12)),
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
                  const Text('MƏKAN',
                      style: TextStyle(
                          fontSize: 11,
                          letterSpacing: 0.8,
                          color: kMuted,
                          fontWeight: FontWeight.w600)),
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
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                          borderRadius: BorderRadius.circular(14)),
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
                          borderRadius: BorderRadius.circular(14)),
                      elevation: 0,
                    ),
                    child: _saving
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Color(0xFF1A0E00),
                            ),
                          )
                        : const Text(
                            'Saxla',
                            style: TextStyle(
                              color: Color(0xFF1A0E00),
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
    if (!_searchCtrl.hasMore || _searchCtrl.isLoading || _searchCtrl.isLoadingMore) {
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
                                  ? const Color(0xFF1A0E00)
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
                                    color: Colors.white,
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
                      child: Text(_searchCtrl.error!, style: const TextStyle(color: kMuted)),
                    );
                  }

                  final filtered = _searchCtrl.results;
                  return ListView.builder(
                    controller: _scrollController,
                    itemCount: filtered.length + (_searchCtrl.isLoadingMore ? 1 : 0),
                    itemBuilder: (_, i) {
                      if (i >= filtered.length) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Center(child: CircularProgressIndicator(color: kGold)),
                        );
                      }
                      final m = filtered[i];
                      final sel = _selected.contains(m.id);
                  final hasActiveStatus = m.hasActiveStatus;
                  final viewerUser = hasActiveStatus
                      ? ref.watch(currentUserProvider(widget.currentUid)).value
                      : null;
                  final hasUnviewed = hasActiveStatus &&
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
                                  ? () => showFullImage(context, m.photoURL!)
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
                                        child: Text(m.emoji, style: const TextStyle(fontSize: 18)),
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
                    title: Text(m.name,
                        style: TextStyle(
                            color: sel ? kGold : kText, fontSize: 14)),
                    subtitle: Text(m.instrument,
                        style: const TextStyle(color: kMuted, fontSize: 12)),
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
                  foregroundColor: const Color(0xFF1A0E00),
                  minimumSize: const Size.fromHeight(44),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Təsdiqlə',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
