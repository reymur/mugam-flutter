import 'package:firebase_auth/firebase_auth.dart' hide User;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/chat/direct_chat_lookup.dart';
import '../../core/chat/job_offer_round.dart';
import '../../firebase/firestore_service.dart';
import 'screens/job_offer_date_sheet.dart';
import 'screens/pick_person_sheet.dart';

// ---------------------------------------------------------------------------
// ЕДИНСТВЕННАЯ ТОЧКА ВЫЗОВА ПРЕДЛОЖЕНИЯ РАБОТЫ (пункт 6 плана, `docs/plan.md`)
// ---------------------------------------------------------------------------
// Предложить работу можно из чата, из карточки музыканта, из дня в
// календаре и с главного экрана. Кода — один, и он здесь.
//
// ГДЕ ПРОХОДИТ ГРАНИЦА МЕЖДУ «ВХОДОМ» И ЭТОЙ ФУНКЦИЕЙ. Вход знает только
// КОНТЕКСТ: кого человек видит перед собой и, может быть, какой день он
// выбрал. Больше ничего. Всё остальное — чей это чат, есть ли он вообще,
// не идёт ли там уже переговор, какой лист показать, что и куда записать —
// принадлежит этой функции.
//
// Отсюда проверяемое правило, а не пожелание: **в файле входа не должно
// встречаться ни `chatId`, ни `setJobOffer`, ни `JobOfferDateSheet`.** Вход
// передаёт uid человека и, если знает, день.
//
// ПОЧЕМУ ФАЙЛ ЛЕЖИТ НЕ В `screens/`. В остальных фичах внутри лежат только
// `screens/` и `widgets/`, и это первый файл в корне фичи. Он не экран и не
// виджет: он ход, у которого нет своего изображения. Класть его в
// `screens/` значило бы назвать экраном то, что экраном не является, — а
// имя папки здесь единственное, что о нём скажет следующему.
//
// ПРАВКА ПРЕДЛОЖЕНИЯ СЮДА НЕ ВХОДИТ, и это не забывчивость. Правку
// (`saveChatEventDate`) делает только инициатор из плашки в чате, и
// сервер выводит её автора ИЗ ТОГО, ЧТО ДОРОГА ОДНА: правило Firestore
// разрешает писать поля события любому участнику чата. На единственность
// стоит сторож (`test/source_invariants_test.dart`). Свести создание и
// правку в одну функцию значило бы развязать этот вывод, ничего не сказав
// вслух.

/// Предложить работу человеку `toUid`.
///
/// **`toUid` необязателен, и это не послабление, а половина смысла
/// пункта 6.** Вход с главного экрана не знает НИЧЕГО — ни человека, ни
/// дня, — и «предложить можно откуда угодно» держится ровно на том, что
/// недостающее спрашивает эта функция, а не каждый вход по-своему. Дай
/// каждому входу спрашивать самому — и вопрос «кому?» будет задан
/// столькими способами, сколько входов.
///
/// `onDay` — день, выбранный входом (вкладка «Təqvim» или дневной экран);
/// час к нему добавляет сам лист своим умолчанием, см.
/// `jobOfferDateOnDay`. Вход, который дня не знает (чат, карточка
/// музыканта), не передаёт ничего, и лист открывается на своём обычном
/// «завтра».
Future<void> proposeJobOffer(
  BuildContext context,
  WidgetRef ref, {
  String? toUid,
  DateTime? onDay,
}) async {
  final myUid = FirebaseAuth.instance.currentUser?.uid;
  if (myUid == null) return;

  final service = ref.read(firestoreServiceProvider);

  // Кого не назвали — спрашиваем. Отказ от выбора (закрыл лист) — это
  // ответ «передумал», и он обязан остановить ход целиком: молча открыть
  // форму предложения без адресата значило бы продолжить разговор, из
  // которого человек вышел.
  final personUid = toUid ?? await pickPersonForJobOffer(context);
  if (personUid == null || !context.mounted) return;

  // ПРОШЛЫЙ ДЕНЬ — ОТКАЗ, И ДО СОЗДАНИЯ ЧАТА.
  //
  // Вкладка «Təqvim» даёт листать месяцы назад и выбирать вчерашний день:
  // для просмотра это законно, для предложения работы — нет.
  //
  // Сам лист этот случай НЕ ловит, и не по недосмотру: он запрещает
  // ВЫБОР прошлой даты (`_selectedDate != _openedWithDate`), а не
  // сохранение вообще — иначе человек, открывший старое предложение ради
  // правки места, оказался бы заперт требованием сдвинуть дату. Открой мы
  // лист сразу на прошлом дне — человек ничего не менял бы, запрет не
  // сработал бы, и предложение ушло бы задним числом.
  //
  // Проверка стоит ДО `getOrCreateDirectChat`, и порядок здесь не
  // косметика: тот при отсутствии чата СОЗДАЁТ документ. Откажи мы после
  // него — в базе оставался бы пустой чат, заведённый ходом, который не
  // состоялся.
  final proposedDate = onDay == null ? null : jobOfferDateOnDay(onDay);
  if (proposedDate != null && proposedDate.isBefore(DateTime.now())) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Keçmiş tarixə təklif göndərilə bilməz'),
        behavior: SnackBarBehavior.floating,
      ),
    );
    return;
  }

  // Чат ищется сперва в уже загруженном списке — там же, где его нашёл бы
  // экран «Mesaj», и по тому же правилу (`directChatIn`). Полный поиск с
  // созданием зовётся только как запасной путь: он делает несколько
  // обращений подряд и на паре со старыми чатами заметно думает.
  final cached = ref.read(chatsProvider(myUid)).asData?.value;
  final chatId = (cached == null ? null : directChatIn(cached, personUid))?.id ??
      await service.getOrCreateDirectChat(myUid: myUid, otherUid: personUid);
  if (!context.mounted) return;

  // ОТКРЫТЫЙ РАУНД — ОТКАЗ СЛОВАМИ, А НЕ МОЛЧАЛИВАЯ ПЕРЕЗАПИСЬ.
  //
  // Раунд на чат ровно один: поля не размножаются, и `setJobOffer`
  // намеренно стирает согласие и содержание прошлого раунда (разбор — в
  // самом методе). В чате этот случай закрыт тем, что пункт меню
  // прячется, — но вход, приходящий сбоку, о переговоре не знает по
  // устройству.
  //
  // Решение владельца 08.08: отказать и увести в чат. Довод тот же, что в
  // N40: человек нажимает «предложить», а теряет уже достигнутую
  // договорённость — то же самое действие, что «Əvəz et» делал с
  // договором.
  final meta = await service.fetchChatData(chatId);
  if (!context.mounted) return;
  final roundOpen = jobOfferRoundOpen(
    jobOfferBy: meta?['jobOfferBy'] as String?,
    roundStep: meta?['roundStep'] as String?,
    recipientAgreed: meta?['recipientAgreed'] as bool? ?? false,
  );
  if (roundOpen) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Bu adamla artıq iş danışığı gedir'),
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(
          label: 'Aç',
          // Из самого чата сюда не попасть — там пункт меню скрыт тем же
          // признаком. Переход оставлен без оговорки на этот случай
          // намеренно: оговорка описывала бы ветку, которой нет, и
          // следующий читал бы её как существующую.
          onPressed: () => context.push('/chat/$chatId'),
        ),
      ),
    );
    return;
  }

  await showModalBottomSheet<void>(
    context: context,
    // Прозрачный фон и никакой формы: лист рисует свой контейнер сам, во
    // весь экран. Оставь тут заливку и скругление — под собственным фоном
    // листа проступил бы второй, со своим скруглением.
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    // Тап по затемнённому фону не закрывает: по нему легко попасть,
    // целясь в поле формы, и терять введённое из-за промаха обидно. Свайп
    // и «Ləğv et» закрывают как обычно — их случайно не сделаешь. Одно
    // правило на все листы С ВВОДОМ (N28).
    isDismissible: false,
    builder: (sheetContext) => JobOfferDateSheet(
      initialDate: proposedDate,
      title: 'İş təklifi',
      submitLabel: 'Təklifi göndər',
      // Чей календарь проверяется на занятость — того, кто предлагает.
      currentUid: myUid,
      onSave: (date, type, location, notes) {
        // Запись уходит ОДНОЙ операцией и сразу содержательной: дата, тип,
        // место, заметки. Пустого предложения не бывает — и это свойство
        // устройства, а не внимательности вызывающего.
        service.setJobOffer(
          chatId: chatId,
          uid: myUid,
          eventDate: date,
          eventType: type,
          eventLocation: location,
          eventNotes: notes,
        );
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('📅 İş təklifi göndərildi'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      },
    ),
  );
}
