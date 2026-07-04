import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' hide User;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/colors.dart';
import '../../../firebase/firestore_service.dart';
import '../../../firebase/models.dart';

// ---------------------------------------------------------------------------
// Azerbaijani month names
// ---------------------------------------------------------------------------
const _azMonths = [
  'Yanvar', 'Fevral', 'Mart', 'Aprel', 'May', 'İyun',
  'İyul', 'Avqust', 'Sentyabr', 'Oktyabr', 'Noyabr', 'Dekabr',
];

const _azMonthsShort = [
  'Yan', 'Fev', 'Mar', 'Apr', 'May', 'İyn',
  'İyl', 'Avq', 'Sen', 'Okt', 'Noy', 'Dek',
];

String _azMonth(int month) => _azMonths[month - 1];

String _fmtDate(String iso) {
  if (iso.isEmpty) return '';
  try {
    final d = DateTime.parse(iso);
    return '${d.day} ${_azMonth(d.month)} ${d.year}';
  } catch (_) {
    return iso;
  }
}

String _fmtTime(String iso) {
  if (iso.isEmpty) return '';
  try {
    final d = DateTime.parse(iso);
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  } catch (_) {
    return '';
  }
}

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

// ---------------------------------------------------------------------------
// AgreementsScreen
// ---------------------------------------------------------------------------
class AgreementsScreen extends ConsumerStatefulWidget {
  const AgreementsScreen({super.key});

  @override
  ConsumerState<AgreementsScreen> createState() => _AgreementsScreenState();
}

class _AgreementsScreenState extends ConsumerState<AgreementsScreen> {
  String _mainView = 'calendar'; // 'agreements' | 'calendar' | 'tedbirler'
  String _activeTab = 'outgoing';
  String _tedbirTab = 'hamisi';
  PersonalEvent? _selectedAgreement;
  PersonalEvent? _tedbirDetail;
  DateTime? _tedbirFilterDate;
  DateTime _currentCalendarMonth = DateTime(
    DateTime.now().year,
    DateTime.now().month,
    1,
  );
  int? _selectedCalendarDay;
  List<String> _readAgreementIds = [];

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
    _loadReadIds();
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

  Future<void> _loadReadIds() async {
    final ids = await ref.read(firestoreServiceProvider).loadReadAgreementIds(_uid);
    if (mounted) setState(() => _readAgreementIds = ids);
  }

  Future<void> _markRead(PersonalEvent e) async {
    if (_readAgreementIds.contains(e.id)) return;
    setState(() => _readAgreementIds = [..._readAgreementIds, e.id]);
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

  List<PersonalEvent> _sortedAgreements(List<PersonalEvent> list) {
    final unread = list.where(_isUnread).toList()
      ..sort((a, b) => _compareCreatedAt(b.createdAt, a.createdAt));
    final read = list.where((e) => !_isUnread(e)).toList()
      ..sort((a, b) => _compareCreatedAt(b.createdAt, a.createdAt));
    return [...unread, ...read];
  }

  int _compareCreatedAt(dynamic a, dynamic b) {
    if (a is Timestamp && b is Timestamp) {
      return a.compareTo(b);
    }
    return 0;
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final uid = _uid;
    final personalEventsAsync = ref.watch(personalEventsProvider(uid));
    final eventsAsMusicianAsync = ref.watch(eventsAsParticipantProvider(uid));

    final personalEvents = personalEventsAsync.asData?.value ?? [];
    final eventsAsMusician = eventsAsMusicianAsync.asData?.value ?? [];
    final allMusicians = ref.watch(musiciansProvider).asData?.value ?? [];

    final agreeEvents = _agreeEvents(personalEvents);
    final hasUnread = agreeEvents.any(_isUnread);

    // If a detail screen is showing, render it on top
    if (_selectedAgreement != null) {
      return _AgreementDetailScreen(
        event: _selectedAgreement!,
        currentUid: uid,
        personalEvents: personalEvents,
        eventsAsMusician: eventsAsMusician,
        allMusicians: allMusicians,
        firestoreService: ref.read(firestoreServiceProvider),
        onBack: () => setState(() => _selectedAgreement = null),
      );
    }
    if (_tedbirDetail != null) {
      return _PersonalEventDetailScreen(
        event: _tedbirDetail!,
        currentUid: uid,
        personalEvents: personalEvents,
        eventsAsMusician: eventsAsMusician,
        allMusicians: allMusicians,
        firestoreService: ref.read(firestoreServiceProvider),
        onBack: () => setState(() => _tedbirDetail = null),
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
                      ? _buildCalendarTab(personalEvents, eventsAsMusician, allMusicians)
                      : _buildTedbirlerTab(personalEvents, eventsAsMusician, allMusicians),
            ),
          ],
        ),
      ),
      floatingActionButton: _mainView == 'calendar'
          ? FloatingActionButton(
              backgroundColor: kGold,
              foregroundColor: const Color(0xFF1A0E00),
              onPressed: () => _openAddModal(
                context,
                initialDate: _isSameMonth(_currentCalendarMonth, DateTime.now())
                    ? DateTime.now()
                    : DateTime(_currentCalendarMonth.year, _currentCalendarMonth.month, 1, 12),
                personalEvents: personalEvents,
                eventsAsMusician: eventsAsMusician,
                allMusicians: allMusicians,
                mode: 'time-only',
              ),
              child: const Icon(Icons.add),
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
                style: GoogleFonts.playfairDisplay(
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
            style: GoogleFonts.playfairDisplay(
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
      roleText = e.cancelledBy == _uid ? 'Siz imtina etdiniz' : '${e.partnerName ?? ''} imtina etdi';
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
        setState(() => _selectedAgreement = e);
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
                    e.partnerName ?? 'Naməlum',
                    style: GoogleFonts.playfairDisplay(
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
                  const SizedBox(height: 2),
                  Text(
                    _fmtCreatedAt(e.createdAt),
                    style: const TextStyle(fontSize: 11, color: kMuted),
                  ),
                  if (eventLine != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      eventLine,
                      style: const TextStyle(fontSize: 12, color: kGold),
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
    List<PersonalEvent> eventsAsMusician,
    List<User> allMusicians,
  ) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          _buildMonthHeader(),
          const SizedBox(height: 16),
          _buildDayOfWeekRow(),
          const SizedBox(height: 8),
          _buildCalendarPageView(personalEvents, eventsAsMusician, allMusicians),
          const SizedBox(height: 80),
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
        Text(
          '$monthName ${_currentCalendarMonth.year}',
          style: GoogleFonts.playfairDisplay(
            fontSize: 26,
            fontWeight: FontWeight.bold,
            color: kText,
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

  Widget _calNavBtn(String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: kBg3,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Text(label, style: const TextStyle(fontSize: 28, color: kGold)),
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
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: kMuted,
                    ),
                  ),
                ),
              ))
          .toList(),
    );
  }

  Widget _buildCalendarPageView(
    List<PersonalEvent> personalEvents,
    List<PersonalEvent> eventsAsMusician,
    List<User> allMusicians,
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
              eventsAsMusician: eventsAsMusician,
              allMusicians: allMusicians,
            ),
          ),
        );
      },
    );
  }

  Widget _buildCalendarGridForMonth({
    required DateTime month,
    required List<PersonalEvent> personalEvents,
    required List<PersonalEvent> eventsAsMusician,
    required List<User> allMusicians,
  }) {
    final allEvents = [...personalEvents, ...eventsAsMusician];
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
        isSelected: isSelected,
        isToday: isToday,
        hasEvents: hasEvents,
        eventCount: dayEvents.length,
        onTap: () => _onDayTap(day, dayDate, dayEvents, personalEvents, eventsAsMusician),
        onLongPress: () => _onDayLongPress(day, dayDate, personalEvents, eventsAsMusician, allMusicians),
      ));
    }

    return GridView.count(
      crossAxisCount: 7,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      children: cells,
    );
  }

  Widget _buildDayCell({
    required int day,
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

    if (isSelected) {
      bgColor = kGold;
      textColor = const Color(0xFF1A0E00);
    } else if (hasEvents) {
      bgColor = kGold.withAlpha(38);
      textColor = kGold;
    }
    if (isToday && !isSelected) {
      border = Border.all(color: kGold, width: 1);
    }

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Center(
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: bgColor,
                shape: BoxShape.circle,
                border: border,
              ),
              child: Center(
                child: Text(
                  '$day',
                  style: TextStyle(
                    fontSize: 16,
                    color: textColor,
                    fontWeight: isSelected || hasEvents ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ),
            ),
            if (hasEvents && !isSelected)
              Positioned(
                top: -2,
                right: -4,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: kGold,
                    borderRadius: BorderRadius.circular(8),
                  ),
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
    List<PersonalEvent> eventsAsMusician,
  ) {
    if (_selectedCalendarDay == day) {
      setState(() => _selectedCalendarDay = null);
      return;
    }
    setState(() => _selectedCalendarDay = day);
    if (dayEvents.isNotEmpty) {
      final ownEvents = dayEvents.where((e) => e.ownerUid == _uid).toList();
      final invitedEvents = dayEvents.where((e) => e.ownerUid != _uid).toList();
      String newTedbirTab;
      if (ownEvents.isNotEmpty && invitedEvents.isNotEmpty) {
        newTedbirTab = 'hamisi';
      } else if (ownEvents.isNotEmpty) {
        newTedbirTab = 'sexsi';
      } else {
        newTedbirTab = 'dəvətli';
      }
      setState(() {
        _tedbirTab = newTedbirTab;
        _tedbirFilterDate = dayDate;
        _mainView = 'tedbirler';
      });
    }
  }

  void _onDayLongPress(
    int day,
    DateTime dayDate,
    List<PersonalEvent> personalEvents,
    List<PersonalEvent> eventsAsMusician,
    List<User> allMusicians,
  ) {
    setState(() => _selectedCalendarDay = day);
    final initialDate = DateTime(dayDate.year, dayDate.month, dayDate.day, 12);
    _openAddModal(
      context,
      initialDate: initialDate,
      personalEvents: personalEvents,
      eventsAsMusician: eventsAsMusician,
      allMusicians: allMusicians,
      mode: 'time-only',
    );
  }

  Future<void> _openAddModal(
    BuildContext context, {
    required DateTime initialDate,
    required List<PersonalEvent> personalEvents,
    required List<PersonalEvent> eventsAsMusician,
    required List<User> allMusicians,
    PersonalEvent? existingEvent,
    String mode = 'time-only',
  }) async {
    final allCombined = [...personalEvents, ...eventsAsMusician];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _EventFormModal(
        mode: mode,
        initialDate: initialDate,
        initialType: existingEvent?.type ?? '',
        initialLocation: existingEvent?.location ?? '',
        initialNotes: existingEvent?.notes ?? '',
        initialMusicians: existingEvent?.musicians ?? [],
        allMusicians: allMusicians,
        existingEvent: existingEvent,
        allCombinedEvents: allCombined,
        currentUid: _uid,
        firestoreService: ref.read(firestoreServiceProvider),
        onSaved: () {},
      ),
    );
  }

  // =========================================================================
  // TEDBIRLER TAB
  // =========================================================================
  Widget _buildTedbirlerTab(
    List<PersonalEvent> personalEvents,
    List<PersonalEvent> eventsAsMusician,
    List<User> allMusicians,
  ) {
    List<_TaggedEvent> tagged = [];
    final ownEvents = personalEvents.where((e) => e.ownerUid == _uid).map((e) => _TaggedEvent(e, true)).toList();
    final invitedEvents = eventsAsMusician.where((e) => e.ownerUid != _uid).map((e) => _TaggedEvent(e, false)).toList();

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

    final isEmpty = personalEvents.isEmpty && eventsAsMusician.isEmpty;

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
                        final musicians = ref.watch(musiciansProvider).asData?.value ?? [];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _EventCard(
                            event: t.event,
                            isOwn: t.isOwn,
                            currentUid: _uid,
                            allMusicians: musicians,
                            onTap: () => setState(() => _tedbirDetail = t.event),
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
  final List<User> allMusicians;
  final VoidCallback onTap;

  const _EventCard({
    required this.event,
    required this.isOwn,
    required this.currentUid,
    required this.allMusicians,
    required this.onTap,
  });

  User? _findMusician(String uid) {
    try {
      return allMusicians.firstWhere((m) => m.id == uid);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final initiatorUid = isOwn ? currentUid : event.ownerUid;
    final initiator = _findMusician(initiatorUid);
    final initiatorName = initiator?.name ?? (isOwn ? 'Siz' : event.partnerName ?? 'Naməlum');
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
                onTap: () {
                  // TODO: Open MusicianProfileScreen for initiatorUid
                  debugPrint('TODO: Open musician profile for $initiatorUid');
                },
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
                        style: GoogleFonts.playfairDisplay(
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
            // Musicians chips
            if (event.musicians.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Divider(color: kBorder, height: 1),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: event.musicians.map((mUid) {
                  final m = _findMusician(mUid);
                  final name = m?.name ?? mUid;
                  final instr = m?.instrument ?? '';
                  final isMe = mUid == currentUid;
                  return GestureDetector(
                    onTap: () {
                      // TODO: Open MusicianProfileScreen for mUid
                      debugPrint('TODO: Open musician profile for $mUid');
                    },
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

  const _DetailRow({required this.label, required this.value, this.last = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
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
class _AgreementDetailScreen extends StatelessWidget {
  final PersonalEvent event;
  final String currentUid;
  final List<PersonalEvent> personalEvents;
  final List<PersonalEvent> eventsAsMusician;
  final List<User> allMusicians;
  final FirestoreService firestoreService;
  final VoidCallback onBack;

  const _AgreementDetailScreen({
    required this.event,
    required this.currentUid,
    required this.personalEvents,
    required this.eventsAsMusician,
    required this.allMusicians,
    required this.firestoreService,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final isCancelled = event.status == 'cancelled';
    final isOwner = event.ownerUid == currentUid;

    Widget statusBadge;
    if (isCancelled) {
      final who = event.cancelledBy == currentUid
          ? 'Siz imtina etdiniz'
          : '${event.partnerName ?? ''} imtina etdi';
      statusBadge = Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: kRed.withAlpha(30),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kRed.withAlpha(100)),
        ),
        child: Text('✖ $who',
            style: const TextStyle(color: kRed, fontWeight: FontWeight.w600)),
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
            style: GoogleFonts.playfairDisplay(color: kGold, fontSize: 18)),
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
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: Colors.transparent,
                  builder: (_) => _EventFormModal(
                    mode: 'full',
                    initialDate: initialDate,
                    initialType: event.type,
                    initialLocation: event.location,
                    initialNotes: event.notes,
                    initialMusicians: event.musicians,
                    allMusicians: allMusicians,
                    existingEvent: event,
                    allCombinedEvents: [...personalEvents, ...eventsAsMusician],
                    currentUid: currentUid,
                    firestoreService: firestoreService,
                    onSaved: () {},
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
                  _fmtCreatedAt(event.createdAt),
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
                    _DetailRow(label: 'Növ', value: event.type),
                    _DetailRow(label: 'Tarix', value: _fmtDate(event.date)),
                    _DetailRow(label: 'Vaxt', value: _fmtTime(event.date)),
                    _DetailRow(label: 'Yer', value: event.location),
                    _DetailRow(label: 'Əlavələr', value: event.notes, last: true),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 20),
            Text('Tərəflər',
                style: GoogleFonts.playfairDisplay(
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
                  _PartyRow(
                    name: event.ownerUid == currentUid ? 'Siz' : (event.partnerName ?? 'Naməlum'),
                    label: isCancelled && event.cancelledBy == event.ownerUid
                        ? 'İmtina etdi'
                        : 'Göndərən (Təklif edən)',
                    highlighted: event.ownerUid == currentUid,
                    onTap: () {
                      // TODO: Open MusicianProfileScreen for event.ownerUid
                      debugPrint('TODO: Open musician profile for ${event.ownerUid}');
                    },
                  ),
                  const Divider(color: kBorder, height: 1),
                  _PartyRow(
                    name: event.ownerUid != currentUid ? 'Siz' : (event.partnerName ?? 'Naməlum'),
                    label: isCancelled && event.cancelledBy == event.partnerUid
                        ? 'İmtina etdi'
                        : 'Qəbul edən',
                    highlighted: event.ownerUid != currentUid,
                    onTap: () {
                      // TODO: Open MusicianProfileScreen for event.partnerUid
                      debugPrint('TODO: Open musician profile for ${event.partnerUid}');
                    },
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
                'Bu müqavilə ${event.ownerUid == currentUid ? 'Siz' : (event.partnerName ?? 'Naməlum')} '
                'və ${event.ownerUid != currentUid ? 'Siz' : (event.partnerName ?? 'Naməlum')} '
                'arasında qarşılıqlı razılıq əsasında bağlanmışdır.',
                style: const TextStyle(
                  fontSize: 13,
                  color: kMuted,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
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
class _PersonalEventDetailScreen extends StatelessWidget {
  final PersonalEvent event;
  final String currentUid;
  final List<PersonalEvent> personalEvents;
  final List<PersonalEvent> eventsAsMusician;
  final List<User> allMusicians;
  final FirestoreService firestoreService;
  final VoidCallback onBack;

  const _PersonalEventDetailScreen({
    required this.event,
    required this.currentUid,
    required this.personalEvents,
    required this.eventsAsMusician,
    required this.allMusicians,
    required this.firestoreService,
    required this.onBack,
  });

  User? _findMusician(String uid) {
    try {
      return allMusicians.firstWhere((m) => m.id == uid);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isOwner = event.ownerUid == currentUid;
    final initiatorUid = isOwner ? currentUid : event.ownerUid;
    final initiator = _findMusician(initiatorUid);
    final initiatorName = initiator?.name ?? (isOwner ? 'Siz' : event.partnerName ?? 'Naməlum');
    final initiatorInstrument = initiator?.instrument ?? '';

    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg2,
        title: Text('Tədbir',
            style: GoogleFonts.playfairDisplay(color: kGold, fontSize: 18)),
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
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: Colors.transparent,
                  builder: (_) => _EventFormModal(
                    mode: 'time-only',
                    initialDate: initialDate,
                    initialType: event.type,
                    initialLocation: event.location,
                    initialNotes: event.notes,
                    initialMusicians: event.musicians,
                    allMusicians: allMusicians,
                    existingEvent: event,
                    allCombinedEvents: [...personalEvents, ...eventsAsMusician],
                    currentUid: currentUid,
                    firestoreService: firestoreService,
                    onSaved: () {},
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
                onTap: () {
                  // TODO: Open MusicianProfileScreen for initiatorUid
                  debugPrint('TODO: Open musician profile for $initiatorUid');
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: kGold.withAlpha(56),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    children: [
                      Text(initiatorName,
                          style: GoogleFonts.playfairDisplay(fontSize: 16, color: kGold)),
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
                  _DetailRow(label: 'Növ', value: event.type),
                  _DetailRow(label: 'Yer', value: event.location),
                  _DetailRow(label: 'Tarix', value: _fmtDate(event.date)),
                  _DetailRow(label: 'Saat', value: _fmtTime(event.date)),
                  _DetailRow(label: 'Qeyd', value: event.notes, last: true),
                ],
              ),
            ),
            // Organiser card (if invited)
            if (!isOwner && event.ownerUid.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text('Təşkilatçı',
                  style: GoogleFonts.playfairDisplay(
                      fontSize: 16, fontWeight: FontWeight.bold, color: kText)),
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                  color: kBg3,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: kBorder),
                ),
                child: _PartyRow(
                  name: _findMusician(event.ownerUid)?.name ?? event.partnerName ?? 'Naməlum',
                  label: 'Təşkilatçı',
                  highlighted: false,
                  onTap: () {
                    // TODO: Open MusicianProfileScreen for event.ownerUid
                    debugPrint('TODO: Open musician profile for ${event.ownerUid}');
                  },
                ),
              ),
            ],
            // Musicians card
            if (event.musicians.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text('Musiqiçilər',
                  style: GoogleFonts.playfairDisplay(
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
                    for (int i = 0; i < event.musicians.length; i++) ...[
                      if (i > 0) const Divider(color: kBorder, height: 1),
                      _PartyRow(
                        name: _findMusician(event.musicians[i])?.name ?? event.musicians[i],
                        label: _findMusician(event.musicians[i])?.instrument ?? 'Musiqiçi',
                        highlighted: event.musicians[i] == currentUid,
                        onTap: () {
                          // TODO: Open MusicianProfileScreen for event.musicians[i]
                          debugPrint('TODO: Open musician profile for ${event.musicians[i]}');
                        },
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
class _ConflictEventScreen extends StatefulWidget {
  final PersonalEvent event;
  final String categoryTitle;
  final String currentUid;
  final List<PersonalEvent> personalEvents;
  final List<PersonalEvent> eventsAsMusician;
  final List<User> allMusicians;
  final FirestoreService firestoreService;

  const _ConflictEventScreen({
    required this.event,
    required this.categoryTitle,
    required this.currentUid,
    required this.personalEvents,
    required this.eventsAsMusician,
    required this.allMusicians,
    required this.firestoreService,
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
          style: GoogleFonts.playfairDisplay(fontSize: 18, color: kGold),
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
                  allMusicians: widget.allMusicians,
                  onTap: () {
                    Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => _PersonalEventDetailScreen(
                        event: widget.event,
                        currentUid: widget.currentUid,
                        personalEvents: widget.personalEvents,
                        eventsAsMusician: widget.eventsAsMusician,
                        allMusicians: widget.allMusicians,
                        firestoreService: widget.firestoreService,
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
// _WheelDateTimePicker
// ---------------------------------------------------------------------------
class _WheelDateTimePicker extends StatefulWidget {
  final DateTime value;
  final ValueChanged<DateTime> onChanged;

  const _WheelDateTimePicker({required this.value, required this.onChanged});

  @override
  State<_WheelDateTimePicker> createState() => _WheelDateTimePickerState();
}

class _WheelDateTimePickerState extends State<_WheelDateTimePicker> {
  static const _yearStart = 2024;
  static const _yearEnd = 2030;
  static const _itemExtent = 44.0;

  late final FixedExtentScrollController _dayController;
  late final FixedExtentScrollController _monthController;
  late final FixedExtentScrollController _yearController;
  late final FixedExtentScrollController _hourController;
  late final FixedExtentScrollController _minuteController;

  @override
  void initState() {
    super.initState();
    _dayController = FixedExtentScrollController(initialItem: widget.value.day - 1);
    _monthController = FixedExtentScrollController(initialItem: widget.value.month - 1);
    _yearController = FixedExtentScrollController(initialItem: widget.value.year - _yearStart);
    _hourController = FixedExtentScrollController(initialItem: widget.value.hour);
    _minuteController = FixedExtentScrollController(initialItem: widget.value.minute);
  }

  @override
  void dispose() {
    _dayController.dispose();
    _monthController.dispose();
    _yearController.dispose();
    _hourController.dispose();
    _minuteController.dispose();
    super.dispose();
  }

  int _daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

  void _update({int? day, int? month, int? year, int? hour, int? minute}) {
    final newYear = year ?? widget.value.year;
    final newMonth = month ?? widget.value.month;
    final maxDay = _daysInMonth(newYear, newMonth);
    var newDay = day ?? widget.value.day;
    if (newDay > maxDay) {
      newDay = maxDay;
      _dayController.jumpToItem(newDay - 1);
    }
    final newHour = hour ?? widget.value.hour;
    final newMinute = minute ?? widget.value.minute;
    widget.onChanged(DateTime(newYear, newMonth, newDay, newHour, newMinute));
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: _itemExtent * 3,
      decoration: BoxDecoration(
        color: const Color(0xFF161210),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withAlpha(15)),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          IgnorePointer(
            child: Container(
              height: _itemExtent,
              margin: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(18),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: kGold.withAlpha(128)),
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                flex: 1,
                child: _wheel(
                  controller: _dayController,
                  itemCount: 31,
                  labelBuilder: (i) => (i + 1).toString().padLeft(2, '0'),
                  onChanged: (i) => _update(day: i + 1),
                ),
              ),
              Expanded(
                flex: 2,
                child: _wheel(
                  controller: _monthController,
                  itemCount: 12,
                  labelBuilder: (i) => _azMonthsShort[i],
                  onChanged: (i) => _update(month: i + 1),
                ),
              ),
              Expanded(
                flex: 2,
                child: _wheel(
                  controller: _yearController,
                  itemCount: _yearEnd - _yearStart + 1,
                  labelBuilder: (i) => (_yearStart + i).toString(),
                  onChanged: (i) => _update(year: _yearStart + i),
                ),
              ),
              const Text(
                ':',
                style: TextStyle(color: kGold, fontSize: 28, fontWeight: FontWeight.bold),
              ),
              Expanded(
                flex: 1,
                child: _wheel(
                  controller: _hourController,
                  itemCount: 24,
                  labelBuilder: (i) => i.toString().padLeft(2, '0'),
                  onChanged: (i) => _update(hour: i),
                ),
              ),
              Expanded(
                flex: 1,
                child: _wheel(
                  controller: _minuteController,
                  itemCount: 60,
                  labelBuilder: (i) => i.toString().padLeft(2, '0'),
                  onChanged: (i) => _update(minute: i),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _wheel({
    required FixedExtentScrollController controller,
    required int itemCount,
    required String Function(int) labelBuilder,
    required ValueChanged<int> onChanged,
  }) {
    return ListWheelScrollView.useDelegate(
      controller: controller,
      itemExtent: _itemExtent,
      diameterRatio: 1.5,
      physics: const FixedExtentScrollPhysics(),
      squeeze: 1.0,
      overAndUnderCenterOpacity: 0.4,
      perspective: 0.003,
      onSelectedItemChanged: onChanged,
      childDelegate: ListWheelChildBuilderDelegate(
        childCount: itemCount,
        builder: (context, index) {
          final selected = controller.selectedItem == index;
          return Center(
            child: Text(
              labelBuilder(index),
              style: TextStyle(
                color: selected ? Colors.white : kMuted,
                fontSize: selected ? 20 : 15,
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _EventFormModal
// ---------------------------------------------------------------------------
class _EventFormModal extends StatefulWidget {
  final String mode; // 'full' | 'time-only'
  final DateTime initialDate;
  final String initialType;
  final String initialLocation;
  final String initialNotes;
  final List<String> initialMusicians;
  final List<User> allMusicians;
  final PersonalEvent? existingEvent;
  final List<PersonalEvent> allCombinedEvents;
  final String currentUid;
  final FirestoreService firestoreService;
  final VoidCallback onSaved;

  const _EventFormModal({
    required this.mode,
    required this.initialDate,
    required this.initialType,
    required this.initialLocation,
    required this.initialNotes,
    required this.initialMusicians,
    required this.allMusicians,
    required this.existingEvent,
    required this.allCombinedEvents,
    required this.currentUid,
    required this.firestoreService,
    required this.onSaved,
  });

  @override
  State<_EventFormModal> createState() => _EventFormModalState();
}

class _EventFormModalState extends State<_EventFormModal> {
  late String _type;
  late DateTime _selectedDate;
  late String _location;
  late List<String> _selectedMusicianUids;
  late List<String> _noteOptions;
  String _otherNote = '';
  bool _otherExpanded = false;
  String _freeNote = '';
  bool _saving = false;
  DateTime? _blockedTime;
  final _scrollController = ScrollController();
  final _warningKey = GlobalKey();
  final _locationKey = GlobalKey();
  bool _showLocationError = false;

  static const _eventTypes = ['Toy', 'Konsert', 'Bayram', 'Digər'];
  static const _noteChoices = [
    'Qara kostyum və ağ köynək',
    'Qara köynək sərbəst',
    'Qalstuk',
    'Baboçka',
    'Yumru boğaz köynək sərbəst',
    'Digər...',
  ];

  final _locationController = TextEditingController();
  final _otherNoteController = TextEditingController();
  final _freeNoteController = TextEditingController();
  final _musicianSearchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _type = widget.initialType.isNotEmpty ? widget.initialType : 'Toy';
    _selectedDate = widget.initialDate;
    _location = widget.initialLocation;
    _locationController.text = _location;
    _selectedMusicianUids = List<String>.from(widget.initialMusicians);

    // Parse existing notes into checkboxes + free text
    _noteOptions = [];
    _freeNote = '';
    if (widget.initialNotes.isNotEmpty) {
      final parts = widget.initialNotes.split(', ');
      for (final p in parts) {
        if (_noteChoices.sublist(0, 5).contains(p)) {
          _noteOptions.add(p);
        } else if (p.isNotEmpty) {
          _freeNote = (_freeNote.isEmpty) ? p : '$_freeNote, $p';
        }
      }
      _freeNoteController.text = _freeNote;
    }
  }

  @override
  void dispose() {
    _locationController.dispose();
    _otherNoteController.dispose();
    _freeNoteController.dispose();
    _musicianSearchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  String get _computedNotes {
    final parts = List<String>.from(_noteOptions);
    if (_otherExpanded && _otherNote.isNotEmpty) parts.add(_otherNote);
    if (_freeNote.isNotEmpty) parts.add(_freeNote);
    return parts.join(', ');
  }

  bool get _isTimeBlocked {
    if (_blockedTime == null) return false;
    return _selectedDate.hour == _blockedTime!.hour &&
        _selectedDate.minute == _blockedTime!.minute;
  }

  Future<void> _showConflictFlow(PersonalEvent conflict) async {
    if (!mounted) return;
    final dialogResult = await showDialog<String>(
      context: context,
      builder: (_) => _ConflictDialog(conflict: conflict),
    );
    if (!mounted) return;
    if (dialogResult == 'replace') {
      await _doSave();
    } else if (dialogResult == 'new') {
      try {
        setState(() => _blockedTime = DateTime.parse(conflict.date));
      } catch (_) {}
    } else if (dialogResult == 'view') {
      final isOwn = conflict.ownerUid == widget.currentUid;
      final categoryTitle = isOwn ? 'Şəxsi tədbir' : 'Dəvətli tədbir';
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => _ConflictEventScreen(
          event: conflict,
          categoryTitle: categoryTitle,
          currentUid: widget.currentUid,
          personalEvents: widget.allCombinedEvents
              .where((e) => e.ownerUid == widget.currentUid)
              .toList(),
          eventsAsMusician: widget.allCombinedEvents
              .where((e) => e.ownerUid != widget.currentUid)
              .toList(),
          allMusicians: widget.allMusicians,
          firestoreService: widget.firestoreService,
        ),
      ));
      // User returned back — re-show conflict dialog recursively
      await _showConflictFlow(conflict);
    }
  }

  Future<void> _handleSave() async {
    if (_saving) return;
    if (_isTimeBlocked) {
      await Future.delayed(const Duration(milliseconds: 50));
      if (_warningKey.currentContext != null) {
        Scrollable.ensureVisible(
          _warningKey.currentContext!,
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeInOut,
          alignment: 0.5,
        );
      }
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

    final conflicts = widget.allCombinedEvents.where((e) {
      if (widget.existingEvent != null && e.id == widget.existingEvent!.id) return false;
      if (e.date.isEmpty) return false;
      try {
        final d = DateTime.parse(e.date);
        return _sameDay(d, _selectedDate) &&
            d.hour == _selectedDate.hour &&
            d.minute == _selectedDate.minute;
      } catch (_) {
        return false;
      }
    }).toList();

    if (conflicts.isNotEmpty) {
      final conflict = conflicts.first;
      await _showConflictFlow(conflict);
      return;
    }
    await _doSave();
  }

  Future<void> _doSave() async {
    setState(() => _saving = true);
    try {
      final dateIso = _selectedDate.toIso8601String();
      final notes = _computedNotes;
      if (widget.existingEvent != null) {
        await widget.firestoreService.updatePersonalEvent(widget.existingEvent!.id, {
          'date': dateIso,
          'type': _type,
          'location': _location,
          'notes': notes,
          'musicians': _selectedMusicianUids,
        });
      } else {
        await widget.firestoreService.addPersonalEvent(
          ownerUid: widget.currentUid,
          date: dateIso,
          type: _type,
          location: _location,
          notes: notes,
          musicians: _selectedMusicianUids,
        );
      }
      widget.onSaved();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Xəta: $e'), backgroundColor: kRed),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openMusicianPicker() async {
    await showDialog(
      context: context,
      builder: (_) => _MusicianPickerDialog(
        allMusicians: widget.allMusicians,
        selectedUids: _selectedMusicianUids,
        onChanged: (uids) => setState(() => _selectedMusicianUids = uids),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      margin: EdgeInsets.only(top: 60, bottom: bottomInset),
      decoration: const BoxDecoration(
        color: kBg2,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SingleChildScrollView(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Text(
                widget.existingEvent != null ? 'Tədbiri Redaktə et' : 'Yeni Tədbir',
                style: GoogleFonts.playfairDisplay(
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
                  onTap: () => setState(() => _type = t),
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
            const SizedBox(height: 12),
            // Inline wheel date/time picker
            _WheelDateTimePicker(
              value: _selectedDate,
              onChanged: (d) {
                setState(() {
                  _selectedDate = d;
                  if (_blockedTime != null &&
                      (d.hour != _blockedTime!.hour || d.minute != _blockedTime!.minute)) {
                    _blockedTime = null;
                  }
                });
              },
            ),
            if (_isTimeBlocked) ...[
              const SizedBox(height: 8),
              Container(
                key: _warningKey,
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
                        '⚠️ ${_blockedTime!.hour.toString().padLeft(2, '0')}:${_blockedTime!.minute.toString().padLeft(2, '0')} '
                        'artıq məşğuldur — zəhmət olmasa başqa vaxt seçin',
                        style: const TextStyle(color: kRed, fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (widget.mode == 'time-only') ...[
              const SizedBox(height: 16),
              // Musicians
              const Text('MUSİQİÇİLƏR',
                  style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 0.8,
                      color: kMuted,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  ..._selectedMusicianUids.map((uid) {
                    User? m;
                    try {
                      m = widget.allMusicians.firstWhere((x) => x.id == uid);
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
                          Text(
                            '${m?.emoji ?? '🎵'} ${m?.name ?? uid}',
                            style: const TextStyle(color: kGold, fontSize: 12),
                          ),
                          const SizedBox(width: 6),
                          GestureDetector(
                            onTap: () => setState(
                                () => _selectedMusicianUids.remove(uid)),
                            child: const Text('×',
                                style: TextStyle(color: kRed, fontSize: 16)),
                          ),
                        ],
                      ),
                    );
                  }),
                  GestureDetector(
                    onTap: _openMusicianPicker,
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
                ],
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
            // Notes checklist
            const Text('GEYİM',
                style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 0.8,
                    color: kMuted,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            ..._noteChoices.sublist(0, 5).map((choice) {
              final sel = _noteOptions.contains(choice);
              return GestureDetector(
                onTap: () => setState(() {
                  if (_noteOptions.contains(choice)) {
                    _noteOptions.remove(choice);
                  } else {
                    _noteOptions.add(choice);
                  }
                }),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
                  decoration: BoxDecoration(
                    color: _noteOptions.contains(choice)
                        ? kGold.withAlpha(25)
                        : kBg3,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: _noteOptions.contains(choice) ? kGold : kBorder,
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        choice,
                        style: TextStyle(
                          color: sel ? kGold : kText,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (sel)
                        const Text('✓', style: TextStyle(color: kGold, fontSize: 14)),
                    ],
                  ),
                ),
              );
            }),
            // "Digər..." toggle
            GestureDetector(
              onTap: () => setState(() => _otherExpanded = !_otherExpanded),
              child: Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
                decoration: BoxDecoration(
                  color: _otherExpanded ? kGold.withAlpha(25) : kBg3,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: _otherExpanded ? kGold : kBorder),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Digər...',
                      style: TextStyle(
                        color: _otherExpanded ? kGold : kText,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (_otherExpanded)
                      const Text('✓', style: TextStyle(color: kGold, fontSize: 14)),
                  ],
                ),
              ),
            ),
            if (_otherExpanded) ...[
              const SizedBox(height: 6),
              TextField(
                controller: _otherNoteController,
                onChanged: (v) => _otherNote = v,
                style: const TextStyle(color: kText, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Digər əlavə...',
                  hintStyle: const TextStyle(color: kMuted),
                  filled: true,
                  fillColor: kBg3,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
            ],
            if (widget.mode == 'time-only') ...[
              const SizedBox(height: 16),
              const Text('ƏLAVƏ QEYDLƏR',
                  style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 0.8,
                      color: kMuted,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              TextField(
                controller: _freeNoteController,
                onChanged: (v) => _freeNote = v,
                maxLines: 3,
                style: const TextStyle(color: kText, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Əlavə qeydlər...',
                  hintStyle: const TextStyle(color: kMuted),
                  filled: true,
                  fillColor: kBg3,
                  contentPadding: const EdgeInsets.all(14),
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
                ),
              ),
            ],
            const SizedBox(height: 24),
            Row(
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
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _ConflictDialog
// ---------------------------------------------------------------------------
class _ConflictDialog extends StatelessWidget {
  final PersonalEvent conflict;

  const _ConflictDialog({
    required this.conflict,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: kBg2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '⚠️ Bu tarixdə tədbir var',
              style: GoogleFonts.playfairDisplay(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: kRed,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: kBg3,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: kGold.withAlpha(60)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (conflict.type.isNotEmpty) ...[
                    Text(
                      conflict.type,
                      style: GoogleFonts.playfairDisplay(
                        color: kGold,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 10),
                    const Divider(color: kBorder, height: 1),
                    const SizedBox(height: 10),
                  ],
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (conflict.location.isNotEmpty) ...[
                        const Text('📍', style: TextStyle(fontSize: 13)),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            conflict.location,
                            style: const TextStyle(
                              color: kText,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (conflict.date.isNotEmpty)
                          const SizedBox(width: 12),
                      ],
                      if (conflict.date.isNotEmpty) ...[
                        const Text('🕐', style: TextStyle(fontSize: 13)),
                        const SizedBox(width: 4),
                        Text(
                          '${_fmtDate(conflict.date)}  ${_fmtTime(conflict.date)}',
                          style: const TextStyle(
                            color: kText,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop('view'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: kGold,
                      side: const BorderSide(color: kGold),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    child: const Text('Bax'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).pop('replace'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kGold,
                      foregroundColor: const Color(0xFF1A0E00),
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    child: const Text('Əvəz et',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).pop('new'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kBg3,
                      foregroundColor: kMuted,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                          side: const BorderSide(color: kBorder)),
                    ),
                    child: const Text('Yeni tədbir'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _MusicianPickerDialog
// ---------------------------------------------------------------------------
class _MusicianPickerDialog extends StatefulWidget {
  final List<User> allMusicians;
  final List<String> selectedUids;
  final ValueChanged<List<String>> onChanged;

  const _MusicianPickerDialog({
    required this.allMusicians,
    required this.selectedUids,
    required this.onChanged,
  });

  @override
  State<_MusicianPickerDialog> createState() => _MusicianPickerDialogState();
}

class _MusicianPickerDialogState extends State<_MusicianPickerDialog> {
  late List<String> _selected;
  String _search = '';
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _selected = List<String>.from(widget.selectedUids);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = widget.allMusicians
        .where((m) =>
            _search.isEmpty ||
            m.name.toLowerCase().contains(_search.toLowerCase()) ||
            m.instrument.toLowerCase().contains(_search.toLowerCase()))
        .toList();

    return Dialog(
      backgroundColor: kBg2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        height: 500,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: TextField(
                controller: _searchController,
                onChanged: (v) => setState(() => _search = v),
                style: const TextStyle(color: kText, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Axtar...',
                  hintStyle: const TextStyle(color: kMuted),
                  filled: true,
                  fillColor: kBg3,
                  prefixIcon: const Icon(Icons.search, color: kMuted),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
            Expanded(
              child: ListView.builder(
                itemCount: filtered.length,
                itemBuilder: (_, i) {
                  final m = filtered[i];
                  final sel = _selected.contains(m.id);
                  return ListTile(
                    leading: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: kBg3,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Center(
                        child: Text(m.emoji, style: const TextStyle(fontSize: 18)),
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
