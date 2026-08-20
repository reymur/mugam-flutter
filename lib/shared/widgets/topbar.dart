import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../core/theme/colors.dart';

class Topbar extends StatelessWidget {
  const Topbar({
    super.key,
    this.notificationCount = 0,
    this.onNotificationTap,
    this.onLanguageTap,
  });

  final int notificationCount;
  final VoidCallback? onNotificationTap;
  final VoidCallback? onLanguageTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kBg,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: const Color(0xFF8B5A00),
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: const Text('🎵', style: TextStyle(fontSize: 18)),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Muğam Club',
                    style: GoogleFonts.nunito(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: kGold2,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const Text(
                    'AZƏRBAYCAN MUSİQİSİ',
                    style: TextStyle(
                      fontSize: 10,
                      color: kMuted,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ],
          ),
          Row(
            children: [
              // КНОПКА БЕЗ АДРЕСАТА НЕ РИСУЕТСЯ — то же правило, что в
              // `job_offer_card.dart` у ответа, приёма, отзыва и записи
              // голоса. Заведено сюда 20.08 обходом N147, а не догадкой:
              // `Topbar` рисуется в приложении РОВНО ОДИН РАЗ
              // (`home_screen.dart:34`), и там `onLanguageTap` передан
              // `null` явно, а `onNotificationTap` не передан вовсе — то
              // есть на главном экране висели ДВЕ кнопки, не делавшие
              // ничего.
              //
              // Прямое продолжение N64: тогда сняли вшитый бейдж «3», а
              // кнопку под ним оставили.
              //
              // СНИМАЕТСЯ `Stack` ЦЕЛИКОМ, ВМЕСТЕ С БЕЙДЖЕМ. Бейдж стоит на
              // своём условии (`notificationCount > 0`) и об обработчике не
              // знает; оставить число висеть без кнопки значило бы
              // повторить N64 наизнанку.
              if (onNotificationTap != null) ...[
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    GestureDetector(
                      key: const ValueKey('topbar-notifications'),
                      onTap: onNotificationTap,
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: const BoxDecoration(
                          color: kCard,
                          shape: BoxShape.circle,
                        ),
                        alignment: Alignment.center,
                        child: const Icon(
                          Icons.notifications_none_rounded,
                          color: kMuted,
                          size: 19,
                        ),
                      ),
                    ),
                    if (notificationCount > 0)
                      Positioned(
                        top: -4,
                        right: -4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: kRed,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: kBg, width: 2),
                          ),
                          constraints: const BoxConstraints(
                            minWidth: 16,
                            minHeight: 16,
                          ),
                          child: Text(
                            notificationCount > 9 ? '9+' : '$notificationCount',
                            style: const TextStyle(
                              fontSize: 9,
                              // kRed со скруглением, а не круг — тот же
                              // пропуск, что в custom_tab_bar.
                              color: kOnRed,
                              fontWeight: FontWeight.bold,
                              height: 1,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 8),
              ],
              // ТО ЖЕ САМОЕ И ДЛЯ ФИШКИ ЯЗЫКА, И ЭТО НЕ КОПИЯ ПО НЕДОСМОТРУ.
              // Выбора языка в приложении нет вовсе, `home_screen.dart:34`
              // передаёт сюда `null` явным словом — значит нарисованная
              // «AZ» обещает переключатель, которого не существует.
              if (onLanguageTap != null)
                GestureDetector(
                  key: const ValueKey('topbar-language'),
                  onTap: onLanguageTap,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: kCard,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: const Text(
                      'AZ',
                      style: TextStyle(
                        fontSize: 12,
                        color: kText,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
