import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/time/stale_clock.dart';

// ОБЩИЙ БУДИЛЬНИК ДЛЯ ВСЕГО, ЧТО ПРОТУХАЕТ ОТ ХОДА ВРЕМЕНИ.
//
// Эти вердикты — про САМ БУДИЛЬНИК: один ли он, заводится ли лениво,
// снимается ли с уходом последнего, приходит ли удар по сроку. Что от удара
// перерисовывается кружок «в сети» и ободок истории — вердикты их собственных
// файлов (`online_dot_test.dart`, `status_ring_test.dart`), и это не
// дублирование: здесь проверяется часовой механизм, там — что стрелку видно.
//
// ЧЕГО ЭТИ ВЕРДИКТЫ НЕ ДОКАЗЫВАЮТ: что на будильник кто-то ПОДПИСАН там, где
// это нужно. Виджет, забывший подписаться, выглядит точно так же, как
// подписавшийся, и расходятся они только со временем (I55). Это ловят сторожи
// по исходникам в файлах кружка и ободка.

void main() {
  // БУДИЛЬНИК ОДИН НА ВСЁ ПРИЛОЖЕНИЕ — в этом его смысл, и он же означает,
  // что вердикты видят след друг друга: зона времени у каждого теста своя, а
  // поля будильника общие. Сброс найден порчей, а не предусмотрен: сняв
  // отписку у кружка, я ждал падения одиннадцати вердиктов из одиннадцати и
  // получил ПЯТЬ — остальные молчали ровно потому, что чужой мёртвый
  // будильник считался живым и не давал завести новый.
  setUp(staleClockResetForTest);

  testWidgets('двадцать подписчиков — один будильник', (tester) async {
    // ГЛАВНЫЙ ВЕРДИКТ ЭТОГО ФАЙЛА. Без него «часы внутри виджета» означало бы
    // сорок таймеров на списке из двадцати портретов: кружок и ободок сидят
    // на одной фотографии в девяти местах из одиннадцати.
    //
    // Пустой корень нужен до всего: `pump` без `pumpWidget` не проверка, а
    // отказ — часы теста некому двигать, пока дерева нет.
    await tester.pumpWidget(const SizedBox());
    final listeners = [for (var i = 0; i < 20; i++) () {}];
    for (final l in listeners) {
      StaleClock.instance.addListener(l);
    }
    expect(staleClockListenerCount, 20);
    expect(staleClockTimerCount, 1);
    // ЗАВЕДЁН ровно один, а не «сейчас числится один». Разница не придирка:
    // заводи `addListener` будильник каждому без оглядки, поле всё равно
    // показывало бы единицу — оно одно, — а таймеров тикало бы двадцать.
    // Проверять надо то, что делается, а не то, что записано.
    expect(staleClockTimersStarted, 1);

    for (final l in listeners) {
      StaleClock.instance.removeListener(l);
    }
  });

  testWidgets('до первого слушателя будильника нет вовсе', (tester) async {
    // ЛЕНИВЫЙ ЗАПУСК — это не экономия, а условие: будильник заводится на
    // ПЕРВОМ слушателе. Заведись он в конструкторе, приложение тикало бы
    // всегда, в том числе на экранах, где ни кружка, ни ободка нет.
    await tester.pumpWidget(const SizedBox());
    expect(staleClockTimerCount, 0);
    expect(staleClockTimersStarted, 0);

    void listener() {}
    StaleClock.instance.addListener(listener);
    expect(staleClockTimerCount, 1, reason: 'канарейка: заводиться он умеет');
    StaleClock.instance.removeListener(listener);
  });

  testWidgets('последний ушёл — будильник снят', (tester) async {
    await tester.pumpWidget(const SizedBox());
    void first() {}
    void second() {}
    StaleClock.instance.addListener(first);
    StaleClock.instance.addListener(second);
    expect(staleClockTimerCount, 1, reason: 'канарейка: было чему сниматься');

    StaleClock.instance.removeListener(first);
    expect(staleClockTimerCount, 1,
        reason: 'ушёл один из двух — будильник нужен оставшемуся');

    StaleClock.instance.removeListener(second);
    expect(staleClockListenerCount, 0);
    expect(staleClockTimerCount, 0);
  });

  testWidgets('удар приходит через двадцать секунд, а не раньше',
      (tester) async {
    await tester.pumpWidget(const SizedBox());
    var beats = 0;
    void count() => beats++;
    StaleClock.instance.addListener(count);

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
    // ЗАОДНО ЭТО ЗАМЕР, А НЕ НЕУДОБСТВО: та же проверка уронит любой вердикт,
    // в котором виджет ушёл с экрана, а отписаться забыл. Значит забытая
    // отписка ловится не текстом сторожа, а самим прогоном.
    StaleClock.instance.removeListener(count);
    expect(staleClockTimerCount, 0);
  });

  testWidgets('отписку делает AnimatedBuilder, а не зовущий', (tester) async {
    // РАДИ ЭТОГО И ВЗЯТ `ChangeNotifier`. Стандартный путь Flutter означает,
    // что пары `addListener`/`removeListener` у зовущего нет вовсе — то есть
    // и забыть её негде. Вердикт держит обе половины: подписка появилась при
    // постановке в дерево И пропала при уходе из него, хотя ни того ни
    // другого никто не писал руками.
    await tester.pumpWidget(
      AnimatedBuilder(
        animation: StaleClock.instance,
        builder: (context, _) => const SizedBox(),
      ),
    );
    expect(staleClockListenerCount, 1);
    expect(staleClockTimerCount, 1);

    await tester.pumpWidget(const SizedBox());
    expect(staleClockListenerCount, 0);
    expect(staleClockTimerCount, 0);
  });
}
