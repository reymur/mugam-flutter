import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../navigation/app_tabs.dart';
import 'image_quality_settings.dart' show sharedPreferencesProvider;

const startTabKey = 'start_tab_id';

/// С какой вкладки открывается приложение — «Tətbiq açılır…».
///
/// **Хранится на трубке, а не в `users/{uid}`**, и доводов три. Настройка
/// про ЭТО устройство: на двух телефонах одного человека она может быть
/// разной. Она нужна ДО входа в аккаунт, когда `uid` ещё нет вовсе.
/// И запись в документ пользователя поднимает `onUserWritten` — с 07.08
/// он больше не переписывает Algolia (N43), но вызов всё равно платный,
/// а платить за настройку, которую некому читать с другого устройства,
/// незачем.
///
/// **Только фиксированная вкладка. «Последняя открытая» отвергнута** — не
/// «пока», а по записанному в плане: приложение должно открываться
/// одинаково, иначе ощущается сломанным. Плюс её цена: запись при каждом
/// переключении вкладки и удивление человека, закрывшего приложение в
/// чужом профиле.
///
/// **Откат — главная опасность этой настройки, а не мелочь.**
/// Сохранённый `id` переживает обновление приложения, а состав панели
/// меняется: вкладка уезжает в «Tezliklə» и обратно (N60). Человек при
/// этом ничего не делал — он просто обновился, и без отката получил бы
/// пустой экран в тот момент, когда сам ни на что не нажимал.
String resolveStartPath(String? savedTabId) {
  if (savedTabId == null || savedTabId.isEmpty) return kStartPath;
  for (final tab in kAppTabs) {
    if (tab.id == savedTabId) return tab.path;
  }
  // Вкладки с таким именем в панели больше нет. Первая вкладка — не
  // «что-нибудь», а тот же путь, что у человека, который настройку не
  // трогал вовсе.
  return kStartPath;
}

class StartTabNotifier extends Notifier<String> {
  @override
  String build() {
    final saved = ref.watch(sharedPreferencesProvider).getString(startTabKey);
    // Хранится ИМЯ вкладки, а не её номер. Номер пережил бы перестановку
    // панели молча и увёл бы человека не туда — ровно дефект N57/N58,
    // только на настройке.
    for (final tab in kAppTabs) {
      if (tab.id == saved) return tab.id;
    }
    return kAppTabs.first.id;
  }

  Future<void> setTab(String tabId) async {
    state = tabId;
    await ref.read(sharedPreferencesProvider).setString(startTabKey, tabId);
  }
}

final startTabProvider =
    NotifierProvider<StartTabNotifier, String>(StartTabNotifier.new);
