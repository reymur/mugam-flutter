import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../core/theme/colors.dart';
import '../../navigation/app_tabs.dart';

// Состав и порядок панели живут в `navigation/app_tabs.dart` — там же, где
// их берёт роутер. Здесь только вид (N58).

class CustomTabBar extends StatelessWidget {
  const CustomTabBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
    this.unreadCount = 0,
  });

  final int currentIndex;
  final ValueChanged<int> onTap;
  final int unreadCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        // Это kBg с прозрачностью 0xF7 — не новый цвет (N83).
        color: kBg.withAlpha(0xF7),
        border: Border(top: BorderSide(color: kBorder)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: kNavH,
          // ПАНЕЛЬ БОЛЬШЕ НЕ ЛИСТАЕТСЯ (решение владельца 07.08). Прежде
          // тут был горизонтальный список с шириной 64 на вкладку: при
          // десяти вкладках они не помещались, и «PROFİL» уезжал за край
          // до свайпа. Вкладок шесть — помещаются на самом узком экране
          // (320 pt даёт по 53 pt на вкладку), и прятать от человека
          // половину панели больше незачем.
          //
          // `Expanded` вместо жёсткой ширины: вкладки делят экран поровну,
          // какой бы он ни был. Подпись при нехватке места ужимается сама
          // (`FittedBox` внутри `_TabItem`), а не обрезается многоточием.
          child: Row(
            children: [
              for (final (i, tab) in kAppTabs.indexed)
                Expanded(
                  child: GestureDetector(
                    onTap: () => onTap(i),
                    behavior: HitTestBehavior.opaque,
                    child: _TabItem(
                      emoji: tab.emoji,
                      label: tab.label,
                      isActive: i == currentIndex,
                      // По ИМЕНИ вкладки, а не по её номеру: номер
                      // меняется при первой же перестановке, и подмену
                      // нечем заметить, пока счётчик не показывается
                      // (N57).
                      badge: tab.id == kUnreadBadgeTabId ? unreadCount : 0,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  const _TabItem({
    required this.emoji,
    required this.label,
    required this.isActive,
    required this.badge,
  });

  final String emoji;
  final String label;
  final bool isActive;
  final int badge;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        AnimatedScale(
          scale: isActive ? 1.15 : 1.0,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          child: Opacity(
            opacity: isActive ? 1.0 : 0.45,
            child: badge > 0
                ? Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Text(emoji, style: const TextStyle(fontSize: 20)),
                      Positioned(
                        top: -4,
                        right: -8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: kRed,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            badge > 9 ? '9+' : '$badge',
                            // Бейдж залит kRed — значит kOnRed. Проход
                            // 08.08 искал BoxShape.circle, а тут
                            // скругление 10, и место не нашлось.
                            style: const TextStyle(
                              color: kOnRed,
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ],
                  )
                : Text(emoji, style: const TextStyle(fontSize: 20)),
          ),
        ),
        const SizedBox(height: 3),
        // Подпись ужимается, а не обрезается: на узком экране «TEZLİKLƏ»
        // длиннее своей доли, и многоточие превратило бы её в «TEZLİK…».
        // Панель больше не листается, поэтому уехать подписи некуда —
        // остаётся ужать.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              maxLines: 1,
              style: GoogleFonts.nunito(
                fontSize: 9,
                fontWeight: FontWeight.w800,
                color: isActive ? kGold : kMuted,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
