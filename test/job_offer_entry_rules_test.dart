import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/chat/direct_chat_lookup.dart';
import 'package:mugam_flutter/core/chat/job_offer_round.dart';
import 'package:mugam_flutter/features/job_offer/screens/job_offer_date_sheet.dart';
import 'package:mugam_flutter/firebase/models.dart';

// Два правила, на которых стоит пункт 6 (`docs/plan.md`), и час по
// умолчанию. Все три вынесены в чистые функции ровно потому, что внутри
// `build()` их нельзя проверить возвратом (I17): там они были выражением,
// у которого нет ни имени, ни второго читателя.
//
// ПРИ КАКОМ ПОВЕДЕНИИ КОДА ЭТИ ПРОВЕРКИ ПРОВАЛЯТСЯ (I9), по каждой сказано
// в её же теле — иначе они доказывают только то, что функции существуют.

Chat _chat({
  required String id,
  required List<String> members,
  bool isGroup = false,
}) =>
    Chat(
      id: id,
      name: '',
      emoji: '',
      lastMessage: '',
      unreadCount: 0,
      members: members,
      isGroup: isGroup,
    );

void main() {
  group('открыт ли раунд переговоров', () {
    // Провалится, если признак начнут строить на наличии поля вместо шага
    // — то есть при возврате к «предложение есть, значит раунд идёт».
    test('без инициатора раунда нет ни при каком шаге', () {
      expect(
        jobOfferRoundOpen(
          jobOfferBy: null,
          roundStep: 'dated',
          recipientAgreed: false,
        ),
        isFalse,
      );
    });

    test('шаг «предложено» и «с датой» — раунд открыт', () {
      for (final step in ['proposed', 'dated']) {
        expect(
          jobOfferRoundOpen(
            jobOfferBy: 'u1',
            roundStep: step,
            // Согласие уже стоит, а шаг говорит обратное: верит ШАГ.
            // Провалится, если вернуть вывод из флагов — тогда здесь
            // выйдет false.
            recipientAgreed: true,
          ),
          isTrue,
          reason: 'шаг $step',
        );
      }
    });

    test('состоявшийся или отменённый раунд закрыт', () {
      for (final step in ['agreed', 'cancelled', '']) {
        expect(
          jobOfferRoundOpen(
            jobOfferBy: 'u1',
            roundStep: step,
            recipientAgreed: false,
          ),
          isFalse,
          reason: 'шаг $step',
        );
      }
    });

    // ЗАПАСНАЯ ВЕТКА — она не украшение: документы чатов, которых не
    // касались с прежней сборки, поля `roundStep` не имеют вовсе. Уберут
    // её — на старых чатах плашка исчезнет, а пункт меню появится
    // поверх живого переговора, и заметить это будет некому.
    test('без шага решает согласие — старые документы', () {
      expect(
        jobOfferRoundOpen(
          jobOfferBy: 'u1',
          roundStep: null,
          recipientAgreed: false,
        ),
        isTrue,
      );
      expect(
        jobOfferRoundOpen(
          jobOfferBy: 'u1',
          roundStep: null,
          recipientAgreed: true,
        ),
        isFalse,
      );
    });
  });

  group('возврат к выбору человека после закрытия листа (N91)', () {
    // Найдено на устройстве: выбрал не того — и вернуться некуда, выбор
    // людей закрылся насовсем. Правило вынесено отдельно ровно затем,
    // чтобы его можно было испортить и увидеть падение.
    test('закрыл лист, человека выбирали здесь — снова показать список', () {
      expect(
        jobOfferReturnsToPicker(sent: false, personGivenByEntry: false),
        isTrue,
      );
    });

    test('отправил — ход закончен, список не возвращается', () {
      expect(
        jobOfferReturnsToPicker(sent: true, personGivenByEntry: false),
        isFalse,
      );
    });

    // Пришли из чата или из карточки человека: списка не было вовсе, и
    // «вернуться» означало бы показать выбор, которого человек не открывал.
    test('человека дал вход — возвращаться не к чему ни при каком исходе', () {
      expect(
        jobOfferReturnsToPicker(sent: false, personGivenByEntry: true),
        isFalse,
      );
      expect(
        jobOfferReturnsToPicker(sent: true, personGivenByEntry: true),
        isFalse,
      );
    });
  });

  group('личный чат с человеком в загруженном списке', () {
    // Провалится, если отбор перестанет смотреть на `isGroup`: групповой
    // чат, где этот человек состоит, — не переписка с ним, и предложение
    // ушло бы в группу на глазах у всех.
    test('группа с этим человеком не годится', () {
      final chats = [
        _chat(id: 'g', members: ['me', 'him', 'third'], isGroup: true),
      ];
      expect(directChatIn(chats, 'him'), isNull);
    });

    test('личный чат с этим человеком находится', () {
      final chats = [
        _chat(id: 'g', members: ['me', 'him'], isGroup: true),
        _chat(id: 'd', members: ['me', 'him']),
      ];
      expect(directChatIn(chats, 'him')?.id, 'd');
    });

    // «Нет в списке» — это НЕ «не существует». Разница названа в самой
    // функции: ответ про существование знает только
    // `getOrCreateDirectChat`, и вызывающий обязан пойти к нему.
    test('чужого человека в списке нет — null, а не первый попавшийся', () {
      final chats = [
        _chat(id: 'd', members: ['me', 'him']),
      ];
      expect(directChatIn(chats, 'stranger'), isNull);
    });
  });

  group('час по умолчанию — одно имя на лист и на календарь', () {
    // САМАЯ ВАЖНАЯ ИЗ ТРЁХ ПРОВЕРОК ЭТОГО ФАЙЛА, и вот почему: она падает
    // ровно в том случае, ради которого час получил имя (I22). Пропиши
    // календарю своё «19:00» — сегодня совпадёт, а в день, когда
    // умолчание листа поправят, значения разойдутся молча, оба оставаясь
    // законными числами.
    test('день из календаря получает ТОТ ЖЕ час, что умолчание листа', () {
      final def = jobOfferDefaultDate(DateTime(2026, 8, 8, 11, 22));
      final onDay = jobOfferDateOnDay(DateTime(2026, 9, 1));
      expect(onDay.hour, def.hour);
      expect(onDay.minute, def.minute);
    });

    test('умолчание листа — завтрашний день', () {
      final def = jobOfferDefaultDate(DateTime(2026, 8, 8, 23, 59));
      expect(def.year, 2026);
      expect(def.month, 8);
      expect(def.day, 9);
    });

    // Полночь означала бы «мероприятие в 00:00» — то есть час, которого
    // человек не выбирал и который выглядит как выбранный.
    test('день из календаря не превращается в полночь', () {
      final onDay = jobOfferDateOnDay(DateTime(2026, 9, 1));
      expect(onDay.hour, isNot(0));
      expect(onDay.day, 1);
      expect(onDay.month, 9);
    });
  });
}
