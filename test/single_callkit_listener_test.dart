import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// СТОРОЖ НА КЛАСС, А НЕ НА СЛУЧАЙ (N193).
//
// ЧТО СТЕРЕЖЁТ. У `EventChannel` во Flutter слушатель ровно ОДИН. Второй
// забирает поток себе МОЛЧА: `receiveBroadcastStream()` при подписке зовёт
// `binaryMessenger.setMessageHandler(имя канала, …)`, а тот ставится ПО ИМЕНИ
// и затирает прежний обработчик. Ни ошибки, ни предупреждения, ни падения —
// первый подписчик просто перестаёт получать события.
//
// ЧЕМ ЭТО ОБОШЛОСЬ 02.09: вторая подписка, заведённая в
// `VoipPushTokenService` ради обновления VoIP-адреса (событие, случающееся
// раз за установку), обесточила `CallKitService` целиком — приём и отклонение
// звонка перестали делать что-либо. Окно показывалось, нажатие не делало
// ничего, и выглядело это как поломка PushKit.
//
// ПОЧЕМУ СТОРОЖ СЧИТАЕТ, А НЕ СМОТРИТ НА ФАЙЛ. Проверять «в
// voip_push_token_service.dart нет подписки» бесполезно: следующая вторая
// подписка появится в третьем файле, которого сегодня нет. Считается ЧИСЛО
// подписок во всём `lib`, поэтому сторож краснеет от появления второй
// где угодно (I64: проверять не наличие правила, а каждого, кто под него
// подпадает).
//
// ЧЕГО ЭТОТ СТОРОЖ НЕ ЛОВИТ (границы пишутся вместе со сторожем):
//   - он считает подписки на ЭТОТ канал. Второй слушатель на любом ДРУГОМ
//     `EventChannel` того же приложения — та же болезнь, и он её не увидит;
//   - он смотрит на `lib`. Подписка, заведённая в тесте или в пакете, мимо;
//   - он считает по тексту исходника: подписка, собранная через промежуточную
//     переменную (`final s = FlutterCallkitIncoming.onEvent; s.listen(...)`),
//     им не опознаётся.
void main() {
  const channelOwner = 'lib/core/calls/callkit_service.dart';

  /// Все .dart из lib, из каждого — только КОД, без строк-комментариев.
  ///
  /// Отсечение обязательно, и это измерено, а не предположено: в
  /// `voip_push_token_service.dart` слова `FlutterCallkitIncoming.onEvent`
  /// стоят в разборе того, почему подписки там больше нет. Разбор по всему
  /// тексту насчитал бы их как живые и краснел бы на исправном дереве.
  Map<String, String> codeOfLib() {
    final out = <String, String>{};
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      out[f.path] = f
          .readAsStringSync()
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
    }
    return out;
  }

  test('КАНАРЕЙКА: обход видит lib и видит владельца канала', () {
    final code = codeOfLib();
    expect(
      code.length,
      greaterThan(50),
      reason: 'обход нашёл ${code.length} файлов — он слеп, а не «подписок нет»',
    );
    expect(
      code.containsKey(channelOwner),
      isTrue,
      reason: '$channelOwner не найден — обход смотрит не туда',
    );
    expect(
      code[channelOwner]!.contains('FlutterCallkitIncoming.onEvent'),
      isTrue,
      reason: 'в коде владельца нет обращения к каналу — разбор ослеп',
    );
  });

  test('КАНАРЕЙКА: отсечение комментариев работает и не съедает код', () {
    // ПРОВЕРЯЕТ ТОТ ЖЕ codeOfLib, КОТОРЫМ ПОЛЬЗУЮТСЯ ВЕРДИКТЫ, а не свою
    // копию того же приёма. Обе поправки сделаны порчей, а не задуманы:
    //
    //   - первая редакция утверждала «в voip_push_token_service.dart имя
    //     канала есть в разборе и нет в коде» и краснела, когда порча
    //     возвращала туда живую подписку: то есть была вторым сторожем на то
    //     же самое, привязанным к файлу;
    //   - вторая считала отсечение СВОИМ ЦИКЛОМ. Порча «снять отсечение в
    //     codeOfLib» её не уронила — канарейка проверяла копию инструмента,
    //     а не инструмент. Ровно то, от чего канарейка и ставится (I31).
    var raw = 0;
    final code = codeOfLib();
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      raw += f.readAsStringSync().length;
    }
    final stripped = code.values.fold<int>(0, (a, b) => a + b.length);

    expect(
      stripped,
      lessThan(raw),
      reason: 'отсечение не отсекло ничего: $stripped из $raw знаков — '
          'значит вердикты ниже считают комментарии наравне с кодом',
    );
    expect(
      stripped,
      greaterThan(raw ~/ 2),
      reason: 'после отсечения осталось $stripped из $raw знаков — съело код',
    );
    final emptied = code.entries
        .where((e) => e.value.trim().isEmpty)
        .map((e) => e.key)
        .toList();
    expect(emptied, isEmpty, reason: 'файлы опустели целиком: $emptied');
  });

  test('подписка на FlutterCallkitIncoming.onEvent во всём lib ровно ОДНА', () {
    final subscription = RegExp(r'FlutterCallkitIncoming\.onEvent\s*\.\s*listen\s*\(');
    final found = <String, int>{};
    codeOfLib().forEach((path, code) {
      final n = subscription.allMatches(code).length;
      if (n > 0) found[path] = n;
    });

    final total = found.values.fold<int>(0, (a, b) => a + b);

    expect(
      total,
      1,
      reason: 'подписок на канал CallKit: $total, а допустима ровно одна. '
          'Найдены в: $found. У EventChannel слушатель один, и второй '
          'ЗАБИРАЕТ ПОТОК СЕБЕ МОЛЧА — первый перестаёт получать события, '
          'без ошибки и без падения. Подписываться надо на '
          'CallKitService.instance.events, а не на канал.',
    );
    expect(
      found.keys.single,
      channelOwner,
      reason: 'единственная подписка переехала из $channelOwner в '
          '${found.keys.single}. Это допустимо, но владелец раздачи должен '
          'переехать вместе с ней — иначе CallKitService.events молчит',
    );
  });

  test('раздача событий существует, иначе снятой подписке некуда деться', () {
    // Утверждение НАЛИЧИЯ, значит само себе канарейка (I31).
    final owner = codeOfLib()[channelOwner]!;
    expect(
      owner.contains('StreamController<CallEvent>.broadcast()'),
      isTrue,
      reason: 'у владельца канала нет широковещательной раздачи — второму '
          'потребителю событий придётся снова подписаться на канал',
    );
    expect(
      RegExp(r'Stream<CallEvent>\s+get\s+events').hasMatch(owner),
      isTrue,
      reason: 'раздача не выставлена наружу',
    );
  });

  test('раздачу КОРМЯТ, а не только объявляют', () {
    // ЭТОТ ВЕРДИКТ ЗАВЕДЁН ПОРЧЕЙ, А НЕ ЗАДУМАН. Порча «снять строку
    // _events.add(event)» уронила НОЛЬ вердиктов: сторож проверял, что
    // раздача объявлена и что ею пользуются, и ни один не спрашивал, попадает
    // ли в неё хоть что-нибудь. Объявленная и пустая раздача выглядит точно
    // так же, как работающая, — I9 в чистом виде: проверка, которая не может
    // провалиться.
    final owner = codeOfLib()[channelOwner]!;
    final from = owner.indexOf('FlutterCallkitIncoming.onEvent');
    expect(from, greaterThan(0), reason: 'подписка не найдена — срез не с чего начать');
    final to = owner.indexOf('switch (event)', from);
    expect(to, greaterThan(from), reason: 'конец среза не найден');
    final body = owner.substring(from, to);
    // Срез по именам-границам доказывает, что кусок ТОТ, и не доказывает, что
    // он целый (N104) — поэтому длина названа числом.
    expect(
      body.length,
      inInclusiveRange(30, 2000),
      reason: 'тело подписки длиной ${body.length} — границы уехали',
    );
    expect(
      body.contains('_events.add('),
      isTrue,
      reason: 'в подписку не кладут события в раздачу: CallKitService.events '
          'существует, но молчит, и подписчики этого не заметят',
    );
  });

  test('потребители событий берут их у раздачи, а не у канала', () {
    final consumers = <String, int>{};
    codeOfLib().forEach((path, code) {
      if (path == channelOwner) return;
      final n = RegExp(r'CallKitService\.instance\.events').allMatches(code).length;
      if (n > 0) consumers[path] = n;
    });
    // Сегодня потребитель один. Число не проверяется — важно, что он
    // существует: ноль означал бы, что кто-то снова ушёл на канал напрямую.
    expect(
      consumers.isNotEmpty,
      isTrue,
      reason: 'раздачей никто не пользуется — либо потребитель снят, либо он '
          'вернулся на канал напрямую',
    );
  });
}
