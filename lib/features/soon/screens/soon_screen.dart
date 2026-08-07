import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/colors.dart';
import '../../../navigation/app_tabs.dart';

/// «Tezliklə» — вкладка о том, что приложение растёт.
///
/// Заведена 07.08 вместе с сокращением панели с десяти вкладок до шести.
/// Пять экранов ушли из панели, но не из приложения: они открываются по
/// прямому пути, и каждый назван здесь строкой о том, ЧТО человек сможет
/// делать, — не «раздел Bazar», а «инструменты: купить, продать, сдать».
/// Оглавление к пустоте читается как обман, обещание дела — нет.
///
/// Список берётся из `kSoonFeatures` (`navigation/app_tabs.dart`), там же,
/// где состав панели: экран, переехавший в панель, уходит отсюда тем же
/// движением. Разойтись им негде — это одно место, а не два (N58).
class SoonScreen extends StatelessWidget {
  const SoonScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg2,
        elevation: 0,
        title: const Text(
          'Tezliklə',
          style: TextStyle(color: kGold, fontSize: 18, fontWeight: FontWeight.w700),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 18),
            child: Text(
              'Bunlar hazırlanır. Hər biri hazır olanda aşağıdakı zolağa əlavə olunacaq.',
              style: TextStyle(color: kMuted, fontSize: 13, height: 1.45),
            ),
          ),
          for (final f in kSoonFeatures) _SoonRow(feature: f),
        ],
      ),
    );
  }
}

class _SoonRow extends StatelessWidget {
  const _SoonRow({required this.feature});

  final SoonFeature feature;

  @override
  Widget build(BuildContext context) {
    final path = feature.path;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kBorder),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          // Открывается то, что уже написано. Экран не готов — строка не
          // ведёт никуда, и лучше глухая строка, чем экран, притворяющийся
          // готовым.
          onTap: path == null ? null : () => context.push(path),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Text(feature.emoji, style: const TextStyle(fontSize: 22)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        feature.title,
                        style: const TextStyle(
                          color: kText,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        feature.note,
                        style: const TextStyle(
                          color: kMuted,
                          fontSize: 12.5,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
                if (path != null)
                  const Icon(Icons.chevron_right, color: kMuted, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
