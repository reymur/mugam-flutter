import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// Проверка утверждения, на котором держится РЕШЕНИЕ, а не описание.
//
// В `agreements_screen.dart` (N23) записано: карточка договора может
// смело слушать `personalEventsProvider(uid)`, потому что «Riverpod на
// одинаковый аргумент семейства отдаёт ту же самую подписку, лишней не
// создаётся». Из этого следует, что живой поток на карточке бесплатен.
//
// Утверждение было написано рассуждением. Если оно неверно, у каждого
// открытия карточки заводится второй слушатель на ту же коллекцию — и
// заметить это можно было бы только по счёту чтений в консоли Firebase.
//
// Взгляд вбок после N28, где такое же утверждение о фреймворке оказалось
// неверным и держало на себе несуществующую защиту.

void main() {
  test('семейство: одинаковый аргумент — один экземпляр провайдера', () {
    var creations = 0;
    final family = StreamProvider.family<int, String>((ref, arg) {
      creations += 1;
      return Stream<int>.value(arg.length);
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);

    // Два независимых слушателя на ОДИН аргумент — как родительский экран
    // и открытая поверх него карточка.
    container.listen(family('uid-1'), (_, _) {}, fireImmediately: true);
    container.listen(family('uid-1'), (_, _) {}, fireImmediately: true);

    expect(creations, 1,
        reason: 'второй слушатель не должен порождать второй поток');

    // Разный аргумент — уже другой провайдер, и это тоже часть правила.
    container.listen(family('uid-2'), (_, _) {}, fireImmediately: true);
    expect(creations, 2);
  });

  test('autoDispose: поток жив, пока есть хоть один слушатель', () {
    var creations = 0;
    var disposed = 0;
    final family = StreamProvider.autoDispose.family<int, String>((ref, arg) {
      creations += 1;
      ref.onDispose(() => disposed += 1);
      return Stream<int>.value(1);
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);

    final a = container.listen(family('u'), (_, _) {}, fireImmediately: true);
    final b = container.listen(family('u'), (_, _) {}, fireImmediately: true);
    expect(creations, 1);

    // Ушёл один — поток остаётся: карточка закрылась, родительский экран
    // продолжает слушать.
    a.close();
    expect(disposed, 0);

    b.close();
  });
}
