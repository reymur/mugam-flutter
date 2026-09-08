import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/text/az_case.dart';
import 'package:mugam_flutter/core/time/az_date_format.dart';

// ПРИВЕДЕНИЕ РЕГИСТРА ПО-АЗЕРБАЙДЖАНСКИ — обе половины пары (N208, 08.09).
//
// `azUpperCase` живёт с 12.08, `azLowerCase` заведена 08.09 после того, как
// выяснилось, что поиск людей слепнет: `'BAKI'.toLowerCase()` даёт `baki`, а
// `'Bakı'.toLowerCase()` — `bakı`, и человек, набравший город заглавными, не
// находил НИКОГО. В проде у 12 профилей из 12 город содержит `ı`.
//
// ВЕРДИКТЫ ПАРНЫЕ НАРОЧНО: у каждой буквы проверяется и то, что она
// приводится, и то, что соседняя пара при этом не пострадала. Односторонний
// набор («ı находится») был бы истинен и у функции, которая приводит всё
// подряд к одной букве.

void main() {
  group('строчные по-азербайджански (azLowerCase)', () {
    test('латинская I уходит в ı, и заглавное имя города находит строчное', () {
      expect(azLowerCase('BAKI'), 'bakı');
      expect(azLowerCase('BAKI'), azLowerCase('Bakı'));
      expect(azLowerCase('SUMQAYIT'), azLowerCase('Sumqayıt'));
    });

    test('İ уходит в i — эту пару Dart делает верно и сам', () {
      expect(azLowerCase('İyun'), 'iyun');
      expect(azLowerCase('İSTANBUL'), 'istanbul');
    });

    test('Ə уходит в ə — и эту тоже', () {
      expect(azLowerCase('GƏNCƏ'), 'gəncə');
      expect(azLowerCase('GƏNCƏ'), azLowerCase('Gəncə'));
    });

    // КАНАРЕЙКА: функция не превращает всё в одну букву и не отдаёт пустоту.
    // Без неё три вердикта выше прошли бы у `(s) => 'bakı'`.
    test('обычные слова не портятся', () {
      expect(azLowerCase('Rafael'), 'rafael');
      expect(azLowerCase('Tar'), 'tar');
      expect(azLowerCase(''), '');
    });

    // ЦЕНА, НАЗВАННАЯ ДО ПРАВКИ И ЗАПИСАННАЯ ВЕРДИКТОМ.
    //
    // Имя с латинской `I` уходит в `ı`. Это та же плата, что принята в
    // `azUpperCase` («заглавная I НЕ трогается»), и в проде таких имён ноль
    // из 12. Вердикт стоит затем, чтобы плата была видна, а не всплыла.
    test('латинская I в имени тоже уходит в ı — это названная плата', () {
      expect(azLowerCase('Ilya'), 'ılya');
      expect(azLowerCase('Ilya'), isNot('ilya'));
    });
  });

  group('заглавные по-азербайджански (azUpperCase) — вторая половина пары', () {
    test('i уходит в İ, а не в латинскую I', () {
      expect(azUpperCase('iyun'), 'İYUN');
      expect(azUpperCase('Reytinq'), 'REYTİNQ');
    });

    test('ı уходит в I', () {
      expect(azUpperCase('bakı'), 'BAKI');
    });

    test('обычные слова не портятся', () {
      expect(azUpperCase('rafael'), 'RAFAEL');
      expect(azUpperCase(''), '');
    });
  });

  // ПОЧЕМУ ЭТИ ДВЕ ФУНКЦИИ НЕ ОБРАТНЫ ДРУГ ДРУГУ, и это не дефект.
  //
  // `azUpperCase('Ilya')` не трогает латинскую `I`, а `azLowerCase` её
  // меняет. Вердикт записывает это прямо, чтобы следующий не «починил»
  // несуществующую несимметричность и не сломал обе.
  test('пара НЕ обратна на латинской I, и это записано, а не забыто', () {
    expect(azLowerCase(azUpperCase('Ilya')), 'ılya');
    expect(azUpperCase(azLowerCase('Ilya')), 'ILYA');
  });

  group('гармония гласных читает строчные тем же правилом', () {
    // `azAblativeSuffix` ищет последнюю гласную по строчной строке. До 08.09
    // он звал голый `toLowerCase`, и имя с латинской `I` давало `i` —
    // переднюю гласную — вместо задней `ı`, то есть окончание `-dən` вместо
    // `-dan`.
    test('имя с ı получает -dan', () {
      expect(azFrom('Sadığ'), 'Sadığdan');
    });

    test('имя с латинской I тоже получает -dan (N208)', () {
      expect(azAblativeSuffix('SEVIL'), 'dan',
          reason: 'N208: латинская I приводится к ı — задней гласной. '
              'Вернулся голый toLowerCase — станет dən');
    });

    // Канарейка: правило по-прежнему умеет отвечать и «dən».
    test('передняя гласная по-прежнему даёт -dən', () {
      expect(azAblativeSuffix('Rafael'), 'dən');
    });
  });
}
