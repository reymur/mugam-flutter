import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../../core/theme/colors.dart';
import 'zoomable_image_viewer.dart';

// Presentational only — no tap handling. The parent (feed bar) wires onTap.
class AvatarRing extends StatelessWidget {
  final String? photoURL;
  // Matches the app's existing avatar-fallback convention (_ContactAvatar,
  // profile_screen.dart both fall back to the user's own emoji field on a
  // null photo) instead of diverging from it — purely additive/optional so
  // this widget still doesn't need to fetch any User data itself, callers
  // just pass along whatever emoji they already have on hand.
  final String? fallbackEmoji;
  final bool hasUnviewed;
  final double size;

  /// ЦВЕТ ОБОДКА, КОГДА ОН НЕ ПРО СТАТУС (свёртка 16.09).
  ///
  /// **Дан — рисуется он, и `hasUnviewed` НЕ СПРАШИВАЕТСЯ вовсе.** Это
  /// записано здесь нарочно: два способа задать одно и то же — известная
  /// беда (I47), и следующий, увидев, что флаг иногда не действует, должен
  /// найти причину рядом, а не искать её.
  ///
  /// **Почему это всё-таки не два написания одного, а два разных дела.**
  /// `hasUnviewed` — факт О ДАННЫХ: есть непросмотренный статус. `ringColor`
  /// — выбор ПОКАЗА: обычная рамка, золотая у отмеченного человека, красная
  /// у ошибки. До свёртки эти «другие» рамки жили рукописными копиями в
  /// двенадцати экранах, и ободок там значил не статус.
  final Color? ringColor;

  /// Толщина ободка. Умолчание 2.5 — то, что было прибито в виджете и с чем
  /// живут шестнадцать мест, звавших его до свёртки: у них ничего не
  /// меняется. **Ноль означает «ободка нет»** — так свёрнуты пять ветвей,
  /// у которых рамки не было вовсе.
  final double ringWidth;

  /// Размер запасного эмодзи. Умолчание — `size * 0.45`, как было.
  ///
  /// **Понадобился при свёртке 16.09 и назван третьим параметром нарочно.**
  /// В рукописных ветвях размер эмодзи прибит числом на каждом экране: 13,
  /// 16, 18, 20, 22, 24, 38, 48, 64. Доли при этом разные — 0.38 у
  /// `about_contact`, 0.40 у `group_info`, 0.44 у `profile`, — и подогнать
  /// их все под 0.45 значило бы **молча изменить вид** там, где владелец
  /// этого не просил.
  ///
  /// **Виджет копит параметры, и это признак, а не удобство.** Принято
  /// здесь потому, что все три — `ringColor`, `ringWidth`, `fallbackFontSize`
  /// — про ПОКАЗ одной и той же вещи, а не про разные дела (I58). Стань их
  /// больше либо появись среди них поведение — виджет надо будет делить.
  final double? fallbackFontSize;

  const AvatarRing({
    super.key,
    required this.photoURL,
    this.fallbackEmoji,
    required this.hasUnviewed,
    this.size = 64,
    this.ringColor,
    this.ringWidth = 2.5,
    this.fallbackFontSize,
  });

  @override
  Widget build(BuildContext context) {
    // kGold for "at least one unviewed status in this ring" (WhatsApp's own
    // gold-vs-gray distinction), kMuted rather than kBorder for the viewed
    // state — kBorder is a near-invisible ~15%-alpha wash already used
    // elsewhere as every avatar's plain resting border (_ContactAvatar,
    // chats_screen.dart's chat-list avatar), so reusing it here would make
    // "viewed" read as no ring at all instead of a distinct, deliberately
    // muted state.
    // Явно заданный цвет сильнее флага статуса — разбор у самого поля.
    final color = ringColor ?? (hasUnviewed ? kGold : kMuted);

    return Container(
      width: size,
      height: size,
      // Отступ равен толщине: ободок рисуется рамкой, а отступ отодвигает от
      // него картинку. Разойдись они — рамка налезет на фото либо повиснет в
      // пустоте. Ноль даёт кружок без ободка и без отступа, то есть ровно то,
      // что было у пяти ветвей без рамки.
      padding: EdgeInsets.all(ringWidth),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: ringWidth > 0
            ? Border.all(color: color, width: ringWidth)
            : null,
      ),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: const BoxDecoration(shape: BoxShape.circle, color: kBg3),
        child: photoURL != null
            ? CachedNetworkImage(
                imageUrl: photoURL!,
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
                placeholder: (context, url) =>
                    const Center(child: CircularProgressIndicator(color: kGold)),
              )
            : fallbackEmoji != null
            ? Center(
                // _ContactAvatar uses fontSize: 64 on a 140px avatar (ratio
                // ~0.457) — profile_screen.dart's 86px avatar uses fontSize:
                // 38 (ratio ~0.442), same proportion. Scaled by `size` here
                // rather than hardcoding either literal value, since this
                // widget (unlike those two) is reused at variable sizes.
                child: Text(
                  fallbackEmoji!,
                  style: TextStyle(fontSize: fallbackFontSize ?? size * 0.45),
                ),
              )
            // Last resort only, when the caller has neither a photo nor an
            // emoji to fall back to.
            : const Center(child: Icon(Icons.person, color: kMuted)),
      ),
    );
  }
}

// Long-press menu for a status-ring avatar — every one of the 11
// avatar-ring sites wires this identically, so it lives here once rather
// than being copy-pasted 11 times. A plain tap on a ring avatar is
// UNCHANGED (still opens the status viewer directly, per each site's own
// existing onTap) — this only fires on long-press, offering the same
// showFullImage(...) already used everywhere else in the app a photo can
// be zoomed, as a second option alongside "view status". photoURL is
// nullable because a fallback-emoji-only avatar has no photo to zoom —
// the "Şəkli göstər" option simply no-ops in that case rather than being
// hidden outright, keeping the menu shape identical across every avatar
// regardless of whether this particular user has uploaded a photo.
// Navigator.of(sheetContext).pop() happens before acting, not after, so
// onViewStatus()/showFullImage() run against the caller's own screen
// context (still valid) rather than the already-popped sheet's.
Future<void> showAvatarLongPressMenu(
  BuildContext context, {
  required String? photoURL,
  required VoidCallback onViewStatus,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: kBg2,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.image_outlined, color: kGold),
            title: const Text('Şəkli göstər', style: TextStyle(color: kText)),
            onTap: () {
              Navigator.of(sheetContext).pop();
              if (photoURL != null) showFullImage(context, photoURL);
            },
          ),
          ListTile(
            leading: const Icon(Icons.visibility_outlined, color: kGold),
            title: const Text('Statusu göstər', style: TextStyle(color: kText)),
            onTap: () {
              Navigator.of(sheetContext).pop();
              onViewStatus();
            },
          ),
        ],
      ),
    ),
  );
}
