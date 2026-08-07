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
///
/// ШЕСТЬ ВКЛАДОК вместо десяти (решение владельца 07.08). Пять экранов —
/// Elanlar, Sifariş, Bazar, Hekayə, Video — из панели убраны, но НЕ
/// удалены: они остаются маршрутами верхнего уровня (`app_router.dart`) и
/// открываются по прямому пути. Готовый экран переезжает в панель одной
/// строкой здесь — и тем же движением уходит из «Tezliklə».
///
/// «Kalendar» первой намеренно: она же стартовая ([kStartPath]).
const List<AppTab> kAppTabs = [
  AppTab(id: 'agreements', emoji: '📅', label: 'KALENDAR', path: '/agreements'),
  AppTab(id: 'home', emoji: '🏠', label: 'KLUB', path: '/home'),
  AppTab(id: 'search', emoji: '🔍', label: 'AXTAR', path: '/search'),
  AppTab(id: 'chats', emoji: '💬', label: 'MESAJ', path: '/chats'),
  AppTab(id: 'profile', emoji: '👤', label: 'PROFİL', path: '/profile'),
  AppTab(id: 'soon', emoji: '✨', label: 'TEZLİKLƏ', path: '/soon'),
];

/// Куда попадает человек после входа и куда возвращается из звонка.
///
/// Берётся из списка, а не пишется строкой: перестановка первой вкладки
/// иначе разошлась бы со стартовым экраном молча — тот же класс, что N58.
final String kStartPath = kAppTabs.first.path;

/// Вкладка, на которой висит счётчик непрочитанных сообщений.
///
/// Именем, а не числом. Прежде стояло `_kChatsIndex = 8`, и указывало оно
/// на вкладку, у которой **нет наблюдаемого поведения**: `MainShell` не
/// передавал `unreadCount` вовсе, поэтому бейдж не рисовался никогда.
/// Перестановка вкладок увела бы это число на «PROFİL», и заметить
/// подмену было бы нечем — ломаться было нечему (N57).
const String kUnreadBadgeTabId = 'chats';

/// Экран, который вот-вот появится в приложении: строка «Tezliklə».
class SoonFeature {
  final String emoji;
  final String title;

  /// Одной фразой: что человек сможет здесь делать. Не «раздел такой-то»,
  /// а его дело — иначе список читается как оглавление к пустоте.
  final String note;

  /// Путь, по которому экран уже открывается. Он живёт и работает, просто
  /// не показан в панели: `null` — если экрана ещё нет вовсе.
  final String? path;

  const SoonFeature({
    required this.emoji,
    required this.title,
    required this.note,
    this.path,
  });
}

/// Пять убранных из панели — и ровно то, чего каждый ждёт.
///
/// Список ЖИВОЙ, а не подпись к экрану: экран переехал в панель — строка
/// уходит отсюда. Тест держит, что путь каждой строки существует в
/// роутере, иначе «Tezliklə» однажды пообещает то, чего нет.
const List<SoonFeature> kSoonFeatures = [
  SoonFeature(
    emoji: '📢',
    title: 'Elanlar',
    note: 'Elanlar lenti: kim musiqiçi axtarır, kim işə hazırdır.',
    path: '/board',
  ),
  SoonFeature(
    emoji: '🎼',
    title: 'Sifariş',
    note: 'Tədbirə kollektiv sifarişi — bir yerdə, danışıqsız.',
    path: '/gigs',
  ),
  SoonFeature(
    emoji: '🛍',
    title: 'Bazar',
    note: 'Alət və avadanlıq: al, sat, kirayə ver.',
    path: '/market',
  ),
  SoonFeature(
    emoji: '😄',
    title: 'Hekayə',
    note: '24 saatlıq hekayələr — tədbirdən birbaşa.',
    path: '/stories',
  ),
  SoonFeature(
    emoji: '🎬',
    title: 'Video',
    note: 'Çıxış videoları: özünü göstər, başqasını tap.',
    path: '/video',
  ),
];
