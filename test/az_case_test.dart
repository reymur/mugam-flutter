import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/text/az_case.dart';

// ОКОНЧАНИЕ «ОТ КОГО» — по гармонии гласных.
//
// Правило поправлено владельцем 19.08: не «Teymurun cavabı gözlənilir», а
// «Teymurdan cavab gözlənilir». Разница не в вежливости, а в падеже: ждут
// ответа ОТ человека, а не ответ человека.
//
// Проверяются оба ряда гласных, потому что приклеенное к имени окончание
// выглядит верным ровно до первого имени с другой гласной — а имена обеих
// сторон в этом чате как раз из разных рядов.

void main() {
  group('исходный падеж — по последней гласной', () {
    test('задняя гласная даёт -dan', () {
      expect(azFrom('Teymur'), 'Teymurdan');
      expect(azFrom('Rasim'), isNot('Rasimdan')); // последняя гласная `i`
      expect(azFrom('Aslan'), 'Aslandan');
      expect(azFrom('Orxan'), 'Orxandan');
    });

    test('передняя гласная даёт -dən', () {
      expect(azFrom('Rafael'), 'Rafaeldən');
      expect(azFrom('Rasim'), 'Rasimdən');
      expect(azFrom('Elçin'), 'Elçindən');
      expect(azFrom('Gülnar'), 'Gülnardan'); // последняя `a` — задняя
    });

    test('решает ПОСЛЕДНЯЯ гласная, а не первая', () {
      // Первая гласная передняя, последняя задняя — и наоборот.
      expect(azAblativeSuffix('Elmar'), 'dan');
      expect(azAblativeSuffix('Aygün'), 'dən');
    });

    test('азербайджанские буквы разбираются наравне с латинскими', () {
      expect(azAblativeSuffix('Səbinə'), 'dən');
      expect(azAblativeSuffix('Aytəkin'), 'dən');
      expect(azAblativeSuffix('Fərid'), 'dən');
      expect(azAblativeSuffix('Ilqar'), 'dan');
    });

    test('оглушения до -tan нет: согласная на конце не влияет', () {
      // В турецком было бы `-ten`, в азербайджанском только `-dən`.
      expect(azFrom('Vüqar'), 'Vüqardan');
      expect(azFrom('Nemət'), 'Nemətdən');
    });

    test('слово без гласных не роняет разбор', () {
      expect(azAblativeSuffix(''), 'dan');
      expect(azAblativeSuffix('щщщ'), 'dan');
    });
  });

  group('фраза ожидания ответа', () {
    test('с именем — исходный падеж и слово cavab без окончания', () {
      expect(azAwaitingAnswerFrom('Teymur'), 'Teymurdan cavab gözlənilir');
      expect(azAwaitingAnswerFrom('Rafael'), 'Rafaeldən cavab gözlənilir');
    });

    // ПУСТОЕ ИМЯ — НЕ ОБРУБОК НА ЭКРАНЕ.
    //
    // Ровно это и увидели 19.08 на трубке: имя не доехало, и строка
    // читалась как «un cavabı gözlənilir». Сама причина пустоты чинится
    // отдельно — здесь только то, чтобы человеку не показали огрызок.
    test('без имени — целая фраза, а не строка с дырой', () {
      expect(azAwaitingAnswerFrom(''), 'Cavab gözlənilir');
      expect(azAwaitingAnswerFrom('   '), 'Cavab gözlənilir');
    });

    test('лишние пробелы вокруг имени не попадают в окончание', () {
      expect(azAwaitingAnswerFrom(' Teymur '), 'Teymurdan cavab gözlənilir');
    });
  });
}
