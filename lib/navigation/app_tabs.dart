/// Состав и ПОРЯДОК нижней панели — в одном месте на весь проект.
///
/// До 07.08 порядок был записан дважды: список `_kTabs` в
/// `custom_tab_bar.dart` и порядок веток `StatefulShellBranch` в
/// `app_router.dart`. Связаны они были ничем, кроме совпадения: панель
/// отдаёт `navigationShell.currentIndex` в подсветку, тап отдаёт индекс
/// обратно в `goBranch(index)`, и **обе стороны верны только пока порядки
/// совпадают**. Перестановка вкладки в одном месте увела бы человека не на
/// тот экран, и ни один тест этого не ловил (N58).
///
/// Отсюда правило: **порядок описан здесь и только здесь**. Панель берёт
/// вид, роутер — пути, бейдж непрочитанного — [AppTab.id], а не номер.
library;

/// Одна вкладка панели.
class AppTab {
  /// Устойчивое имя. По нему вешаются признаки вроде бейджа: номер
  /// вкладки меняется при первой же перестановке, имя — нет (N57).
  final String id;
  final String emoji;
  final String label;

  /// Путь ветки роутера. Он же связывает вкладку с её экраном — ни панель,
  /// ни роутер номерами больше не обмениваются.
  final String path;

  const AppTab({
    required this.id,
    required this.emoji,
    required this.label,
    required this.path,
  });
}

/// Порядок панели. Менять состав — здесь, и больше нигде.
const List<AppTab> kAppTabs = [
  AppTab(id: 'home', emoji: '🏠', label: 'KLUB', path: '/home'),
  AppTab(id: 'agreements', emoji: '📅', label: 'KALENDAR', path: '/agreements'),
  AppTab(id: 'search', emoji: '🔍', label: 'AXTAR', path: '/search'),
  AppTab(id: 'board', emoji: '📢', label: 'ELANLAR', path: '/board'),
  AppTab(id: 'gigs', emoji: '🎼', label: 'SİFARİŞ', path: '/gigs'),
  AppTab(id: 'market', emoji: '🛍', label: 'BAZAR', path: '/market'),
  AppTab(id: 'stories', emoji: '😄', label: 'HEKAYƏ', path: '/stories'),
  AppTab(id: 'video', emoji: '🎬', label: 'VİDEO', path: '/video'),
  AppTab(id: 'chats', emoji: '💬', label: 'MESAJ', path: '/chats'),
  AppTab(id: 'profile', emoji: '👤', label: 'PROFİL', path: '/profile'),
];

/// Вкладка, на которой висит счётчик непрочитанных сообщений.
///
/// Именем, а не числом. Прежде стояло `_kChatsIndex = 8`, и указывало оно
/// на вкладку, у которой **нет наблюдаемого поведения**: `MainShell` не
/// передавал `unreadCount` вовсе, поэтому бейдж не рисовался никогда.
/// Перестановка вкладок увела бы это число на «PROFİL», и заметить
/// подмену было бы нечем — ломаться было нечему (N57).
const String kUnreadBadgeTabId = 'chats';
