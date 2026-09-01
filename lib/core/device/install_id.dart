import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

// Ключ НЕ МЕНЯТЬ И НЕ ПЕРЕИМЕНОВЫВАТЬ. Под ним уже лежат идентификаторы на
// живых установках; смена ключа выдала бы каждому телефону новый
// идентификатор, а прежний документ токена остался бы сиротой навсегда — то
// есть ровно та поломка, ради которой этот идентификатор и заведён (разбор —
// в PushNotificationService, случай прода 02.08). Имя ключа говорит «push»,
// потому что там он и появился; переезд сюда имени не меняет по этой же
// причине.
const String installIdPrefsKey = 'mugam_push_device_id_v1';

// Идентификатор УСТАНОВКИ приложения — не модели, не сборки ОС и не железа.
//
// ВЫНЕСЕН СЮДА ИЗ PushNotificationService, ЧТОБЫ У ДВУХ КОЛЛЕКЦИЙ АДРЕСОВ БЫЛ
// ОДИН ИДЕНТИФИКАТОР, А НЕ ДВА ПОХОЖИХ. `users/{uid}/pushTokens/{deviceId}`
// (FCM, обычные уведомления) и `users/{uid}/voipPushTokens/{deviceId}`
// (PushKit, звонок в убитое приложение) описывают ОДНУ И ТУ ЖЕ установку с
// двух сторон, поэтому и делятся по задаче, а не по совпадению вида (I58):
// одна установка — одна строка в каждой из двух коллекций, и выход из
// аккаунта снимает обе одним и тем же ключом.
//
// Собственное правило для второй коллекции выглядело бы безобидно и стоило
// бы дорого: два идентификатора у одного телефона означают, что удаление по
// одному из них оставляет второй документ жить — а живой документ адреса у
// покинутого аккаунта это и есть та самая утечка, которую чинили 02.08.
Future<String> installId() async {
  final prefs = await SharedPreferences.getInstance();
  final existing = prefs.getString(installIdPrefsKey);
  if (existing != null) return existing;
  final random = Random.secure();
  final id = List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  await prefs.setString(installIdPrefsKey, id);
  return id;
}
