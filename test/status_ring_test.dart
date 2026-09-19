import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/theme/colors.dart';
import 'package:mugam_flutter/core/time/stale_clock.dart';
import 'package:mugam_flutter/features/status/widgets/status_ring.dart';
import 'package:mugam_flutter/firebase/firestore_service.dart';
import 'package:mugam_flutter/firebase/models.dart';
import 'package:mugam_flutter/shared/widgets/avatar_ring.dart';

import 'support/source_text.dart';

// ОБОДОК ИСТОРИИ — ПРАВИЛО, ОБА НАЖАТИЯ И СВОИ ЧАСЫ В ОДНОМ ВИДЖЕТЕ.
//
// Повод записан числом: на 18.09 решение «есть ли живая история» было написано
// РУКАМИ в одиннадцати местах десяти файлов (`grep -rn "hasActiveStatus" lib`
// — 48 строк, из них 6 комментарии и 1 объявление), при одном-единственном
// ободке (`AvatarRing`, свёрнут 16.09). Размножено было не изображение, а
// правило и поведение вокруг него — и разошлось: правило «у СЕБЯ ободок не
// золотой» соблюдалось в ДВУХ местах из одиннадцати.
//
// ЧЕГО ЭТИ ВЕРДИКТЫ НЕ ДОКАЗЫВАЮТ. Они про сам виджет: какое правило он
// применяет, что показывает в каждой из двух ветвей и что пересчитывает себя
// по времени. Что `StatusRing` ПОСТАВЛЕН на каждый из одиннадцати экранов —
// это сторож по исходникам в конце файла, а что он там хорошо выглядит —
// глаза на трубке (I55).

User _u({
  String id = 'owner',
  Duration? storyExpiresIn,
  Duration? storyPostedAgo,
  Map<String, Timestamp> viewed = const {},
}) =>
    User(
      id: id,
      name: 'Adam',
      emoji: '🎺',
      instrument: '',
      city: '',
      rating: 0,
      reviews: 0,
      available: true,
      goldRing: false,
      online: false,
      bio: '',
      mostRecentStatusExpiresAt: storyExpiresIn == null
          ? null
          : Timestamp.fromDate(DateTime.now().add(storyExpiresIn)),
      mostRecentStatusCreatedAt: storyPostedAgo == null
          ? null
          : Timestamp.fromDate(DateTime.now().subtract(storyPostedAgo)),
      lastViewedStatusOwnerAt: viewed,
    );

Future<void> _show(
  WidgetTester tester, {
  required User? user,
  String currentUid = 'me',
  User? viewer,
  double plainRingWidth = 0,
  Color? plainRingColor,
  double? plainFallbackFontSize,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentUserProvider.overrideWith((ref, uid) => Stream.value(viewer)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: StatusRing(
              user: user,
              currentUid: currentUid,
              size: 60,
              fallbackEmoji: '🎺',
              plainRingColor: plainRingColor,
              plainRingWidth: plainRingWidth,
              plainFallbackFontSize: plainFallbackFontSize,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Цвет НАРИСОВАННОГО ободка, а не переданного флага.
///
/// Спрашивается у самой рамки нарочно: `hasUnviewed` — это то, что виджет
/// СКАЗАЛ, а рамка — то, что человек УВИДЕЛ, и между ними стоит ещё одно
/// правило (`ringColor ?? (hasUnviewed ? kGold : kMuted)` в `AvatarRing`).
/// Проверять надо второе.
Color? _ringColor(WidgetTester tester) {
  final container = tester.widgetList<Container>(
    find.descendant(
      of: find.byType(AvatarRing),
      matching: find.byType(Container),
    ),
  ).first;
  final border = (container.decoration! as BoxDecoration).border;
  return border == null ? null : (border as Border).top.color;
}

void main() {
  // Будильник ОДИН НА ВСЁ ПРИЛОЖЕНИЕ, и вердикты видят след друг друга —
  // разбор в `test/stale_clock_test.dart`.
  setUp(staleClockResetForTest);

  group('ободок истории: что он показывает', () {
    testWidgets('живая история — ободок есть', (tester) async {
      await _show(
        tester,
        user: _u(storyExpiresIn: const Duration(hours: 5), storyPostedAgo: const Duration(minutes: 1)),
        viewer: _u(id: 'me'),
      );
      expect(_ringColor(tester), isNotNull,
          reason: 'у человека живая история, а ободка вокруг портрета нет');
    });

    testWidgets('истёкшая история — ободка нет', (tester) async {
      // Срок годности в прошлом. Поле `mostRecentStatusExpiresAt` при этом
      // ЗАПОЛНЕНО — сервер его никогда не чистит, — то есть отличить живую
      // историю от истёкшей можно только сравнением со временем. Ровно на
      // этом и держалась поломка: без часов ободок так и горел бы.
      await _show(
        tester,
        user: _u(storyExpiresIn: const Duration(hours: -1), storyPostedAgo: const Duration(days: 2)),
        viewer: _u(id: 'me'),
      );
      expect(_ringColor(tester), isNull,
          reason: 'история истекла, а ободок остался');
    });

    testWidgets('истории не было вовсе — ободка нет', (tester) async {
      await _show(tester, user: _u(), viewer: _u(id: 'me'));
      expect(_ringColor(tester), isNull);
    });

    testWidgets('человека ещё нет — ветвь «истории нет», а не пустота',
        (tester) async {
      // ПЯТЬ мест из десяти подают в ободок значение, которое МОЖЕТ быть
      // пустым. Пустота обязана быть законным входом, иначе у зовущего снова
      // заводится своё условие.
      //
      // ЧИСЛО СНЯТО ЗАМЕРОМ 19.09 тем же приёмом, что у кружка: поле `user`
      // в `status_ring.dart` временно объявлено непустым, `flutter analyze
      // lib` назвал отказы поимённо, поле возвращено.
      //
      // ЗДЕСЬ И В САМОМ `status_ring.dart` СТОЯЛО «шесть из одиннадцати», и
      // замер даёт пять. Знаменатель уехал понятно почему — мест с ободком
      // стало десять. Числитель разошёлся, и я НЕ объявляю прежнюю запись
      // ошибкой: она про «живой документ ещё не приехал», а замер — про тип,
      // и это соседние вопросы (I13). Кто будет сводить их, пусть считает
      // оба, а не выбирает правдоподобное (I36).
      await _show(tester, user: null, viewer: _u(id: 'me'));
      expect(find.byType(AvatarRing), findsOneWidget);
      expect(_ringColor(tester), isNull);
    });

    testWidgets('непросмотренная история — ЗОЛОТОЙ', (tester) async {
      await _show(
        tester,
        user: _u(
          storyExpiresIn: const Duration(hours: 5),
          storyPostedAgo: const Duration(minutes: 1),
        ),
        // Смотрящий не открывал этого человека ни разу: отметки нет вовсе.
        viewer: _u(id: 'me'),
      );
      expect(_ringColor(tester), kGold);
    });

    testWidgets('просмотренная история — ПРИГЛУШЁННЫЙ', (tester) async {
      await _show(
        tester,
        user: _u(
          storyExpiresIn: const Duration(hours: 5),
          storyPostedAgo: const Duration(minutes: 10),
        ),
        viewer: _u(
          id: 'me',
          viewed: {
            'owner': Timestamp.fromDate(
              DateTime.now().subtract(const Duration(minutes: 1)),
            ),
          },
        ),
      );
      expect(_ringColor(tester), kMuted,
          reason: 'смотрел он этого человека ПОЗЖЕ, чем тот выложил историю — '
              'значит смотреть нечего, и золота быть не должно');
    });

    testWidgets('СВОЯ ИСТОРИЯ НИКОГДА НЕ ЗОЛОТАЯ', (tester) async {
      // ГЛАВНЫЙ ВЕРДИКТ ЭТОГО ФАЙЛА, и стоит он тут потому, что правило было
      // соблюдено в ДВУХ местах из одиннадцати (замер 18.09, N245): на
      // профиле и у участника группы — флагами `!isOwnProfile` и `!isMe` у
      // зовущего. В остальных девяти своя свежая история светилась золотом,
      // как чужая непросмотренная.
      //
      // Здесь правило выводится ИЗ ДАННЫХ — `user.id == currentUid`, — и
      // потому действует на всех одиннадцать сразу, без переключателя у
      // зовущего (I58).
      //
      // Условия нарочно такие, при которых золото было бы у чужого: история
      // живая, выложена минуту назад, отметки о просмотре нет.
      await _show(
        tester,
        user: _u(
          id: 'me',
          storyExpiresIn: const Duration(hours: 5),
          storyPostedAgo: const Duration(minutes: 1),
        ),
        currentUid: 'me',
        viewer: _u(id: 'me'),
      );
      expect(_ringColor(tester), isNotNull,
          reason: 'канарейка: ободок у своей живой истории ЕСТЬ, снимать его '
              'правило не должно — оно только про цвет');
      expect(_ringColor(tester), kMuted,
          reason: 'своя история светится золотом: «есть что посмотреть '
              'впервые» сказано про того, кто её только что и выложил');
    });
  });

  group('ободок истории: вид ветви «истории нет» берётся у зовущего', () {
    testWidgets('цвет, толщина и размер знака — чужие, не свои',
        (tester) async {
      // ТРИ ОТЛИЧИЯ ПЕРЕНОСЯТСЯ ПАРАМЕТРАМИ, А НЕ ПРИВОДЯТСЯ К ОДНОМУ ВИДУ:
      // у одиннадцати мест эта ветвь выглядит по-разному, и приведение молча
      // изменило бы вид одиннадцати экранов.
      await _show(
        tester,
        user: _u(),
        viewer: _u(id: 'me'),
        plainRingColor: kBorder,
        plainRingWidth: 1.5,
        plainFallbackFontSize: 24,
      );
      expect(_ringColor(tester), kBorder);
      final ring = tester.widget<AvatarRing>(find.byType(AvatarRing));
      expect(ring.ringWidth, 1.5);
      expect(ring.fallbackFontSize, 24);
    });

    testWidgets('вид ветви «истории нет» на живую историю НЕ действует',
        (tester) async {
      // Иначе параметр показа стал бы вторым способом задать то же самое, и
      // следующий, увидев, что цвет иногда не действует, искал бы причину не
      // здесь (I47).
      await _show(
        tester,
        user: _u(
          storyExpiresIn: const Duration(hours: 5),
          storyPostedAgo: const Duration(minutes: 1),
        ),
        viewer: _u(id: 'me'),
        plainRingColor: kBorder,
        plainRingWidth: 1.5,
      );
      expect(_ringColor(tester), kGold);
    });
  });

  group('ободок истории: нажатия', () {
    testWidgets('живая история — есть и долгое нажатие', (tester) async {
      await _show(
        tester,
        user: _u(
          storyExpiresIn: const Duration(hours: 5),
          storyPostedAgo: const Duration(minutes: 1),
        ),
        viewer: _u(id: 'me'),
      );
      final g = tester.widget<GestureDetector>(
        find.descendant(
          of: find.byType(StatusRing),
          matching: find.byType(GestureDetector),
        ),
      );
      expect(g.onTap, isNotNull, reason: 'открыть историю нечем');
      expect(g.onLongPress, isNotNull,
          reason: 'окошко «показать фото / показать историю» пропало');
    });

    testWidgets('истории нет и фотографии нет — НАЖИМАТЬ НЕ НА ЧТО',
        (tester) async {
      // I64 в чистом виде: кнопка без адресата не рисуется. Здесь она не
      // рисуется тем, что `onTap` пуст, — иначе нажатие на портрет без фото
      // молча не делало бы ничего (ровно N146).
      await _show(tester, user: _u(), viewer: _u(id: 'me'));
      final g = tester.widget<GestureDetector>(
        find.descendant(
          of: find.byType(StatusRing),
          matching: find.byType(GestureDetector),
        ),
      );
      expect(g.onTap, isNull);
      expect(g.onLongPress, isNull,
          reason: 'окошко про историю предложено там, где истории нет');
    });
  });

  group('ободок истории: свои часы', () {
    testWidgets('один ободок — один слушатель общего будильника',
        (tester) async {
      await _show(
        tester,
        user: _u(storyExpiresIn: const Duration(hours: 5)),
        viewer: _u(id: 'me'),
      );
      expect(staleClockListenerCount, 1);
      expect(staleClockTimerCount, 1);
    });

    testWidgets('ободок ушёл с экрана — отписался', (tester) async {
      await _show(
        tester,
        user: _u(storyExpiresIn: const Duration(hours: 5)),
        viewer: _u(id: 'me'),
      );
      expect(staleClockTimerCount, 1, reason: 'канарейка: было чему сниматься');
      await tester.pumpWidget(const SizedBox());
      expect(staleClockListenerCount, 0);
      expect(staleClockTimerCount, 0);
    });

    testWidgets('ОБОДОК ГАСНЕТ САМ, без нового документа', (tester) async {
      // ВЕСЬ СМЫСЛ РАБОТЫ В ЭТОМ ВЕРДИКТЕ, и стоит он дороже остальных — две с
      // половиной секунды настоящего ожидания.
      //
      // ЗАЧЕМ НАСТОЯЩЕГО. `hasActiveStatus` сравнивает срок годности с
      // `DateTime.now()`, а часы теста двигают только таймеры, не настоящее
      // время. Значит истечение приходится ждать по-честному: срок ставится
      // через две секунды после начала.
      //
      // Документ при этом НЕ МЕНЯЕТСЯ ни разу — в этом всё дело: поток
      // Firestore здесь не сработал бы (сервер `mostRecentStatusExpiresAt`
      // никогда не чистит), и без будильника ободок горел бы до тех пор, пока
      // человек не откроет экран заново.
      await _show(
        tester,
        user: _u(
          storyExpiresIn: const Duration(seconds: 2),
          storyPostedAgo: const Duration(minutes: 1),
        ),
        viewer: _u(id: 'me'),
      );
      expect(_ringColor(tester), kGold, reason: 'до истечения — золотой');

      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2500)),
      );
      await tester.pump(const Duration(seconds: 20));

      expect(_ringColor(tester), isNull,
          reason: 'удар будильника пришёл, а ободок не пересчитался — значит '
              'он перерисовывается не от времени');
    });
  });

  group('сторож: решение про историю принимает один виджет', () {
    // ЧТО ЭТОТ СТОРОЖ УТВЕРЖДАЕТ: «`hasActiveStatus` во всём `lib` не
    // спрашивает НИКТО, кроме самого ободка и модели, где он объявлен». Это
    // утверждение ОТСУТСТВИЯ, а оно ломается молча (I31): ослепни разбор — он
    // даст ноль, ноль и есть искомое, и сторож зазеленеет собственной
    // слепотой. Поэтому рядом стоит канарейка.
    //
    // ПОЧЕМУ ПОДПИСЬ ПО `hasActiveStatus`, А НЕ ПО `AvatarRing`. Второе
    // покраснело бы на здоровом: `AvatarRing` законно зовут десять раз безо
    // всякой истории — в ленте статусов, в поиске, в просмотрщике, — и там
    // ободок значит не историю, а просто рамку портрета. А вот спросить «жива
    // ли история» и решить по ответу, что рисовать, — это ровно то дело,
    // которое размножать нельзя.
    //
    // ЧЕГО ЭТОТ СТОРОЖ НЕ ЛОВИТ — четыре дыры, названные поимённо:
    //
    // 1. ПРАВИЛО, ПЕРЕПИСАННОЕ РУКАМИ. `expiresAt.toDate().isAfter(
    //    DateTime.now())` вместо геттера — то же решение другими словами, и
    //    сторож пройдёт мимо. Он смотрит на имя, а не на смысл.
    // 2. ЗАБЫТЫЙ ОБОДОК. Экран, где история нужна, а `StatusRing` не
    //    поставлен, выглядит для этого разбора безупречно: `hasActiveStatus`
    //    там и правда нет.
    // 3. НЕ СМОТРИТ НА ВИД. Ободок можно позвать с чужим размером, чужой
    //    толщиной или не там, где нужно, — это глаза на трубке.
    // 4. НЕ ЛОВИТ ПРАВИЛО «У СЕБЯ НЕ ЗОЛОТОЙ». Оно внутри виджета и
    //    проверяется вердиктом выше, а не текстом.

    const ring = 'lib/features/status/widgets/status_ring.dart';
    const model = 'lib/firebase/models.dart';
    final rule = RegExp(r'hasActiveStatus');

    List<String> libFiles() => Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => f.path)
        .where((p) => p.endsWith('.dart'))
        .toList()
      ..sort();

    test('КАНАРЕЙКА: тот же разбор находит правило там, где оно заведомо есть',
        () {
      // Падает на нуле. Ноль здесь означает «разбор ослеп», а не «чисто»:
      // переехал файл, переименовали геттер, сменилась форма записи — и
      // сторож ниже стал бы зелёным, ничего не проверяя.
      expect(rule.allMatches(readCode(ring)).length, 1,
          reason: 'разбор не видит вопроса про историю там, где ободок его '
              'заведомо задаёт — значит и «больше нигде не задают» он '
              'доказать не может');
      expect(rule.allMatches(readCode(model)).length, 1,
          reason: 'разбор не видит объявления правила в модели');
    });

    test('ВОПРОС ПРО ЖИВУЮ ИСТОРИЮ — НИ ОДНОГО, кроме ободка и модели', () {
      final guilty = <String>[];
      var hits = 0;
      for (final path in libFiles()) {
        if (path == ring || path == model) continue;
        final n = rule.allMatches(readCode(path)).length;
        if (n > 0) {
          hits += n;
          guilty.add('$path — $n');
        }
      }
      expect(guilty, isEmpty,
          reason: 'решение «есть ли живая история» принимается мимо '
              'StatusRing в ${guilty.length} файлах, всего $hits мест:\n'
              '${guilty.join('\n')}\n'
              'Одиннадцать таких копий уже расходились молча: правило «у себя '
              'ободок не золотой» было соблюдено в двух из них, и заметить '
              'это было нечем.');
    });

    test('ДОЛЯ ЧИСЛОМ: одиннадцать мест зовут ободок', () {
      // I64 — проверяется не наличие правила, а КАЖДЫЙ, кто под него
      // подпадает. «Правило записано» соврать может; «десять из десяти» — нет.
      //
      // Завёл новый ободок — это число меняется здесь руками, и в том его
      // смысл: пересчёт обязателен, а не желателен.
      //
      // ЧИСЛО 19.09 УШЛО И ВЕРНУЛОСЬ, И ЭТО НАДО ЧИТАТЬ ВНИМАТЕЛЬНО: было
      // одиннадцать в десяти файлах, стало одиннадцать в десяти — а СОСТАВ
      // другой. Минус одно место (снят `_ParticipantPickerDialog`), плюс одно
      // (свой профиль переведён на общее правило, N251). Совпадение итога
      // случайно, и если бы кто-то сверял только число, он решил бы, что не
      // менялось ничего.
      //
      // ЧТО БЫЛО СНЯТО — 19.09,
      // вместе со снятием `_ParticipantPickerDialog`. **И это ПОТЕРЯ, в
      // отличие от кружка, — сказано прямо, а не обойдено:** снятый лист
      // рисовал ободок на строке человека, а общий лист рисует простой
      // кружок с фотографией. То есть в окне выбора людей на вечер больше не
      // видно, у кого есть живая история.
      //
      // ВЕРНУТЬ — правка одной строки в `PersonRow`
      // (`features/people/widgets/person_picker_core.dart`), но она отдала бы
      // ободок И одноместному листу «кому предложить работу», где его
      // отродясь не было. Поэтому это решение владельца, а не побочный итог
      // уборки (I51: не заводить своими руками то, что сами же осудим).
      //
      // ОГОВОРКА К ТАБЛИЦЕ ОДИННАДЦАТИ МЕСТ В `docs/handoff.md`: строка
      // «состав вечера — agreements_screen.dart:7063» указывала на ЛИСТ
      // ВЫБОРА, а не на состав. Настоящий состав (`_PartyMemberRow`) рисует
      // простой `AvatarRing` без всякой развилки и в одиннадцать никогда не
      // входил.
      final places = <String, int>{};
      for (final path in libFiles()) {
        if (path == ring) continue;
        final n = 'StatusRing('.allMatches(readCode(path)).length;
        if (n > 0) places[path] = n;
      }
      final total = places.values.fold<int>(0, (a, b) => a + b);
      expect(total, 11,
          reason: 'мест с ободком стало $total вместо одиннадцати:\n'
              '${places.entries.map((e) => '${e.key} — ${e.value}').join('\n')}');
      expect(places.keys.length, 10,
          reason: 'файлов с ободком стало ${places.keys.length} вместо десяти');
    });
  });
}
