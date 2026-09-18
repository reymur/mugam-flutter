import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/theme/colors.dart';
import 'package:mugam_flutter/firebase/models.dart';
import 'package:mugam_flutter/shared/widgets/online_dot.dart';

import 'support/source_text.dart';

// КРУЖОК «В СЕТИ» И ЕГО СОБСТВЕННОЕ ОБНОВЛЕНИЕ — решение владельца 18.09.
//
// Повод записан числом, а не словами: на 18.09 кружок рисовался в
// ОДИННАДЦАТИ местах девяти файлов, а таймер, без которого он врёт со
// временем, стоял ровно у ОДНОГО (замер многострочным разбором
// `isActuallyOnline … kGreen` по `lib` плюс `grep -rn "Timer.periodic" lib`).
// Десять замерших кружков появились не по небрежности: кружок без таймера
// выглядит точно так же, как кружок с таймером, и расходятся они только со
// временем — то есть увидеть пропажу нечем.
//
// ЧЕГО ЭТИ ВЕРДИКТЫ НЕ ДОКАЗЫВАЮТ. Они про сам кружок: цвет, размер, рамку и
// то, что удар будильника до него доходит. Что кружок ПОСТАВЛЕН на каждый из
// тринадцати экранов и стоит там, где нужно, — это сторож по исходникам ниже
// и проба глазами на трубке, а не эти вердикты (I55).

User _u({
  bool online = true,
  Duration seenAgo = const Duration(seconds: 1),
  int? intervalMs,
}) =>
    User(
      id: 'u',
      name: '',
      emoji: '',
      instrument: '',
      city: '',
      rating: 0,
      reviews: 0,
      available: true,
      goldRing: false,
      online: online,
      lastSeen: Timestamp.fromDate(DateTime.now().subtract(seenAgo)),
      presenceIntervalMs: intervalMs,
      bio: '',
    );

// `Center` здесь не украшение. Корень теста навязывает жёсткие 800×600, и
// `Container` с шириной и высотой под такими ограничениями растягивается на
// весь экран — размер кружка проверить было бы нечем. В проде он всегда стоит
// внутри `Positioned` или `trailing`, то есть в свободных ограничениях; это и
// воспроизводится.
Future<void> _show(WidgetTester tester, Widget child) => tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: child),
      ),
    );

BoxDecoration _dot(WidgetTester tester, {int at = 0}) {
  final container = tester.widgetList<Container>(
    find.descendant(
      of: find.byType(OnlineDot),
      matching: find.byType(Container),
    ),
  ).elementAt(at);
  return container.decoration! as BoxDecoration;
}

void main() {
  // БУДИЛЬНИК ОДИН НА ВСЁ ПРИЛОЖЕНИЕ — в этом его смысл, и он же означает,
  // что вердикты видят след друг друга: зона времени у каждого теста своя, а
  // поле с будильником общее. Сброс найден порчей, а не предусмотрен: сняв
  // отписку, я ждал падения одиннадцати вердиктов из одиннадцати и получил
  // ПЯТЬ — остальные молчали ровно потому, что чужой мёртвый будильник
  // считался живым и не давал завести новый.
  setUp(onlineDotResetForTest);

  group('кружок онлайна: что он показывает', () {
    testWidgets('свежая отметка — зелёный', (tester) async {
      await _show(tester, OnlineDot(user: _u(seenAgo: const Duration(seconds: 5))));
      expect(_dot(tester).color, kGreen);
    });

    testWidgets('протухшая отметка — серый, даже при online: true', (tester) async {
      // Ровно тот случай, ради которого правило вообще существует: убитое
      // приложение оставляет `online: true` навсегда, и доверять можно
      // только свежести отметки.
      await _show(tester, OnlineDot(user: _u(seenAgo: const Duration(minutes: 9))));
      expect(_dot(tester).color, kMuted);
    });

    testWidgets('явный выход — серый при свежей отметке', (tester) async {
      await _show(tester, OnlineDot(user: _u(online: false)));
      expect(_dot(tester).color, kMuted);
    });

    testWidgets('человека ещё нет — серый, а не пропавший кружок', (tester) async {
      // Четыре места из тринадцати рисуют кружок раньше, чем приедет живой
      // документ. Пустота обязана быть законным входом, иначе у зовущего
      // снова заводится своё условие.
      await _show(tester, const OnlineDot(user: null));
      expect(_dot(tester).color, kMuted);
      expect(find.byType(OnlineDot), findsOneWidget);
    });
  });

  group('кружок онлайна: вид берётся у зовущего', () {
    testWidgets('размер, цвет рамки и её толщина — чужие, не свои', (tester) async {
      // ТРИ ОТКЛОНЕНИЯ ПЕРЕНОСЯТСЯ ПАРАМЕТРАМИ, А НЕ ПРИВОДЯТСЯ К ОДНОМУ
      // ВИДУ (условие владельца 18.09): восемнадцать на портрете, десять в
      // списке чатов, свой цвет фона на главном.
      await _show(
        tester,
        OnlineDot(
          user: _u(),
          size: 18,
          borderColor: kHeroBg,
          borderWidth: 3,
        ),
      );
      final d = _dot(tester);
      expect(d.border, Border.all(color: kHeroBg, width: 3));
      final box = tester.getSize(find.byType(OnlineDot));
      expect(box, const Size(18, 18));
    });

    testWidgets('рамки нет вовсе, когда её не просили', (tester) async {
      // Список чатов: кружок стоит не на фотографии, отделять его не от чего.
      await _show(tester, OnlineDot(user: _u(), size: 10, borderColor: null));
      expect(_dot(tester).border, isNull);
      expect(tester.getSize(find.byType(OnlineDot)), const Size(10, 10));
    });

    testWidgets('без просьбы — двенадцать и рамка под цвет kBg2', (tester) async {
      // Умолчание описывает БОЛЬШИНСТВО, а не «как получилось»: так стоит в
      // десяти местах из тринадцати.
      await _show(tester, OnlineDot(user: _u()));
      expect(tester.getSize(find.byType(OnlineDot)), const Size(12, 12));
      expect(_dot(tester).border, Border.all(color: kBg2, width: 2));
    });
  });

  group('кружок онлайна: будильник один на всех', () {
    testWidgets('двадцать кружков — один будильник, двадцать слушателей',
        (tester) async {
      // ГЛАВНЫЙ ВЕРДИКТ ЭТОГО ФАЙЛА. Без него «таймер внутри кружка» означало
      // бы двадцать таймеров на списке из двадцати строк.
      await _show(
        tester,
        Column(children: [for (var i = 0; i < 20; i++) OnlineDot(user: _u())]),
      );
      expect(find.byType(OnlineDot), findsNWidgets(20));
      expect(onlineDotListenerCount, 20);
      expect(onlineDotTimerCount, 1);
      // ЗАВЕДЁН ровно один, а не «сейчас числится один». Разница не
      // придирка: заводи `add` будильник каждому кружку без оглядки, поле
      // всё равно показывало бы единицу — оно одно, — а таймеров тикало бы
      // двадцать. Проверять надо то, что делается, а не то, что записано.
      expect(onlineDotTimersStarted, 1);
    });

    testWidgets('последний ушёл — будильник снят', (tester) async {
      await _show(tester, OnlineDot(user: _u()));
      expect(onlineDotTimerCount, 1, reason: 'канарейка: было чему сниматься');
      await _show(tester, const SizedBox());
      expect(onlineDotListenerCount, 0);
      expect(onlineDotTimerCount, 0);
    });

    testWidgets('удар приходит через двадцать секунд, а не раньше',
        (tester) async {
      // Пустой корень нужен до всего: `pump` без `pumpWidget` не проверка, а
      // отказ — часы теста некому двигать, пока дерева нет.
      await _show(tester, const SizedBox());
      var beats = 0;
      void count() => beats++;
      onlineDotAddTestListener(count);

      await tester.pump(const Duration(seconds: 19));
      expect(beats, 0, reason: 'раньше срока бить не должен');
      await tester.pump(const Duration(seconds: 2));
      expect(beats, 1);
      await tester.pump(const Duration(seconds: 20));
      expect(beats, 2, reason: 'удар повторяется, а не случается однажды');

      // Снимается ЗДЕСЬ, а не в `addTearDown`: проверка «не осталось живых
      // таймеров» идёт РАНЬШЕ уборки, и оставленный слушатель уронил бы этот
      // вердикт чужой причиной.
      //
      // ЗАОДНО ЭТО ЗАМЕР, А НЕ НЕУДОБСТВО: та же проверка уронит любой
      // вердикт, в котором кружок ушёл с экрана, а отписаться забыл. Значит
      // забытая отписка ловится не текстом сторожа, а самим прогоном.
      onlineDotRemoveTestListener(count);
      expect(onlineDotTimerCount, 0);
    });

    testWidgets('КРУЖОК ГАСНЕТ САМ, без нового документа', (tester) async {
      // ВЕСЬ СМЫСЛ РАБОТЫ В ЭТОМ ВЕРДИКТЕ, и стоит он дороже остальных —
      // две с половиной секунды настоящего ожидания.
      //
      // ЗАЧЕМ НАСТОЯЩЕГО. `isActuallyOnline` сравнивает отметку с
      // `DateTime.now()`, а часы теста двигают только таймеры, не настоящее
      // время. Значит протухание приходится ждать по-честному: отметка
      // ставится за 118 секунд до начала при окне 120, и через две с
      // половиной секунды ожидания человек обязан протухнуть.
      //
      // Документ при этом НЕ МЕНЯЕТСЯ ни разу — в этом всё дело: поток
      // Firestore здесь не сработал бы, и без будильника кружок остался бы
      // зелёным навсегда.
      await _show(
        tester,
        OnlineDot(user: _u(seenAgo: const Duration(seconds: 118))),
      );
      expect(_dot(tester).color, kGreen, reason: 'до протухания — зелёный');

      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2500)),
      );
      await tester.pump(const Duration(seconds: 20));

      expect(_dot(tester).color, kMuted,
          reason: 'удар будильника пришёл, а цвет не пересчитался — значит '
              'кружок перерисовывается не от времени');
    });
  });

  group('сторож: кружок онлайна рисуется одним местом', () {
    // ЧТО ЭТОТ СТОРОЖ УТВЕРЖДАЕТ: «кружка, нарисованного руками, в `lib`
    // НЕТ». Это утверждение ОТСУТСТВИЯ, а оно ломается молча (I31): ослепни
    // разбор — он даст ноль, ноль и есть искомое, и сторож зазеленеет
    // собственной слепотой. Поэтому рядом стоит канарейка, ищущая ТЕМ ЖЕ
    // способом заведомо существующее.
    //
    // ПОЧЕМУ ПОДПИСЬ ИМЕННО ТАКАЯ. Пара `kGreen`/`kMuted` в одном выражении
    // означает «крашу по признаку в сети / не в сети» и ничего другого: на
    // 18.09 таких пар во всём `lib` было ОДИННАДЦАТЬ, и все одиннадцать —
    // кружки (замер этим же разбором до перевода). Постороннего употребления
    // пары нет, значит сторож не краснеет на законном.
    //
    // ЧЕГО ЭТОТ СТОРОЖ НЕ ЛОВИТ — четыре дыры, названные поимённо:
    //
    // 1. КРУЖОК, НАРИСОВАННЫЙ ЛИТЕРАЛОМ ЦВЕТА вместо `kGreen`. Это не
    //    выдумка: до 18.09 в проекте жили ДВА таких места — надписи
    //    «● Onlayn» в шапке чата и в карточке контакта красились
    //    `Color(0xFF4CAF50)`, то есть другим зелёным, чем все кружки. Их
    //    сняла эта же работа, но следующий волен завести такое снова.
    // 2. КРУЖОК ПО ДРУГОМУ ПРАВИЛУ — `user.online` без проверки свежести.
    //    Если цвета при этом наши, сторож покраснеет; если и цвета свои —
    //    пройдёт насквозь.
    // 3. КРУЖОК В НОВОМ ФАЙЛЕ СО СВОИМИ ПОСТОЯННЫМИ (`myGreen`, `myGrey`).
    //    Сторож смотрит на два имени, а не на смысл.
    // 4. НЕ СМОТРИТ НА РАСПОЛОЖЕНИЕ. `OnlineDot` можно поставить в угол,
    //    которого не видно, или не поставить вовсе — это глаза на трубке.
    //
    // Пятая дыра, которую я записывал сюда же и которая ЗАКРЫЛАСЬ: забытая
    // отписка от общего будильника. Ловится не текстом, а самим прогоном —
    // проверка «не осталось живых таймеров» роняет любой вердикт, где
    // кружок ушёл с экрана, не отписавшись (замер порчей: 10 из 11).

    const home = 'lib/shared/widgets/online_dot.dart';
    final pair = RegExp(r'kGreen[\s\S]{0,60}?kMuted');

    List<String> libFiles() => Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => f.path)
        .where((p) => p.endsWith('.dart'))
        .toList()
      ..sort();

    test('КАНАРЕЙКА: тот же разбор находит кружок в самом online_dot.dart', () {
      // Падает на нуле. Ноль здесь означает «разбор ослеп», а не «чисто»:
      // переехал файл, сменилась форма записи, переименовали цвета — и
      // сторож ниже стал бы зелёным, ничего не проверяя.
      final found = pair.allMatches(readCode(home)).length;
      expect(found, 1,
          reason: 'разбор не видит кружка там, где кружок заведомо есть — '
              'значит и «нигде больше нет» он доказать не может');
    });

    test('КРУЖОК РУКАМИ — НИ ОДНОГО, кроме online_dot.dart', () {
      final guilty = <String>[];
      var pairs = 0;
      for (final path in libFiles()) {
        if (path.endsWith('online_dot.dart')) continue;
        final n = pair.allMatches(readCode(path)).length;
        if (n > 0) {
          pairs += n;
          guilty.add('$path — $n');
        }
      }
      expect(guilty, isEmpty,
          reason: 'кружок «в сети» нарисован мимо OnlineDot в '
              '${guilty.length} файлах, всего $pairs мест:\n'
              '${guilty.join('\n')}\n'
              'Два таких кружка расходятся молча: правку внесут в один, а '
              'второй останется врать, и заметить это будет нечем.');
    });

    // ТРИ ОТКЛОНЕНИЯ И ДВА НОВЫХ МЕСТА — каждое своим вердиктом, условие
    // владельца 18.09. Сведение к одному виджету обязано было СОХРАНИТЬ
    // разницу, а не стереть её: крупный кружок на портрете, мелкий без рамки
    // в списке чатов и левый угол на главном выбраны осознанно. Сторож выше
    // говорит «рисует одно место» и про размеры молчит — эти говорят про
    // размеры.
    test('ОТКЛОНЕНИЕ 1: на портрете профиля кружок крупнее и с рамкой в три',
        () {
      // ПЕРВАЯ РЕДАКЦИЯ ЭТОГО ВЕРДИКТА БЫЛА НЕГОДНОЙ, и поймала её порча, а
      // не глаза: он искал `size: 18` ПО ВСЕМУ ФАЙЛУ, а такая же запись стоит
      // у значка галочки ниже (`Icon(Icons.check_circle, … size: 18)`). Снял
      // размер у кружка — вердикт остался зелёным, потому что нашёл чужое.
      // Ровно I13: сторож считал не то и молчал так же, как если бы ему
      // нечего было сказать.
      //
      // ФОРМА ТЕПЕРЬ СВЕРЯЕТ ВЫЗОВ ЦЕЛИКОМ, а не три слова по отдельности.
      final code = readCode('lib/features/user/screens/user_profile_screen.dart');
      final call = RegExp(
        r'OnlineDot\(\s*user: liveUser,\s*size: 18,\s*'
        r'borderColor: kHeroBg,\s*borderWidth: 3,\s*\)',
      );
      expect(call.hasMatch(code), isTrue,
          reason: 'кружок на портрете профиля перестал быть крупным: рамка — '
              'это цвет фона под ним (kHeroBg), а восемнадцать точек взяты '
              'потому, что двенадцать на таком портрете теряются');
    });

    test('ОТКЛОНЕНИЕ 2: в списке чатов кружок мельче и БЕЗ рамки', () {
      final code = readCode('lib/features/chats/screens/chats_screen.dart');
      expect(code.contains('OnlineDot(user: user, size: 10, borderColor: null)'),
          isTrue,
          reason: 'кружок в конце строки стоит не на фотографии — рамке '
              'нечего отделять, и десять точек там достаточно');
    });

    test('ОТКЛОНЕНИЕ 3: на главном кружок СЛЕВА и с рамкой цвета карточки', () {
      final code = readCode('lib/features/home/screens/home_screen.dart');
      expect(code.contains('OnlineDot(user: musician, borderColor: kCard)'),
          isTrue);
      // Расположение осталось у зовущего, и это единственное место, где оно
      // слева. Уехало бы внутрь виджета — пришлось бы завести переключатель.
      expect(code.contains('left: 0'), isTrue,
          reason: 'кружок на главном переехал вправо — либо расположение '
              'затащили внутрь виджета, либо потеряли при переводе');
    });

    test('ДВА НОВЫХ МЕСТА: там, где были слова, теперь кружок', () {
      // 18.09 надписи «● Onlayn / ○ Oflayn» сняты решением владельца, и на их
      // месте тот же кружок, что везде. Вердикт держит обе половины: кружок
      // появился И слов не осталось.
      final chat = readCode('lib/features/chat/screens/chat_screen.dart');
      final about =
          readCode('lib/features/chat/screens/about_contact_screen.dart');
      expect(chat.contains('OnlineDot(user: otherUser)'), isTrue);
      expect(about.contains('OnlineDot('), isTrue);
      expect(chat.contains("Onlayn'"), isFalse,
          reason: 'слово вернулось в шапку чата — «в сети» снова показывается '
              'двумя разными способами');
      expect(about.contains("Onlayn'"), isFalse);
      // Канарейка к двум утверждениям отсутствия выше: разбор обоих файлов
      // не пуст.
      expect(chat.contains('AvatarRing('), isTrue);
      expect(about.contains('AvatarRing('), isTrue);
    });

    test('ДОЛЯ ЧИСЛОМ: тринадцать мест зовут кружок', () {
      // I64 — проверяется не наличие правила, а КАЖДЫЙ, кто под него
      // подпадает. «Правило записано» соврать может; «тринадцать из
      // тринадцати» — нет.
      //
      // Завёл новый кружок — это число меняется здесь руками, и в том его
      // смысл: пересчёт обязателен, а не желателен.
      final places = <String, int>{};
      for (final path in libFiles()) {
        if (path.endsWith('online_dot.dart')) continue;
        final n = 'OnlineDot('.allMatches(readCode(path)).length;
        if (n > 0) places[path] = n;
      }
      final total = places.values.fold<int>(0, (a, b) => a + b);
      expect(total, 13,
          reason: 'мест с кружком стало $total вместо тринадцати:\n'
              '${places.entries.map((e) => '${e.key} — ${e.value}').join('\n')}');
      expect(places.keys.length, 11);
    });
  });
}
