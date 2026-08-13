import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/chat/direct_chat_lookup.dart';
import 'package:mugam_flutter/core/chat/job_offer_round.dart';
import 'package:mugam_flutter/core/job_offer/offer_draft.dart';
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

  // ГРУППА «ЧАС ПО УМОЛЧАНИЮ» СНЯТА 14.08 ВМЕСТЕ С САМИМ ЧАСОМ, и на её
  // месте стоит новое правило — не потому, что старое разонравилось, а
  // потому что предмет исчез.
  //
  // Прежде предложение обязано было нести конкретное ВРЕМЯ, и лист
  // подставлял его сам (`kJobOfferDefaultHour = 19`). Три теста сторожили
  // то, что этот час записан ОДНИМ именем на лист и на календарь (I22).
  // Теперь набор дней времени не несёт вовсе, время — отдельное
  // необязательное поле, и подставлять нечего: второго места, где число
  // могло бы разойтись, не существует.
  //
  // ПОБОЧНО ИЗМЕНИЛОСЬ ПОВЕДЕНИЕ, и это записано отдельной проверкой ниже:
  // сегодняшний день переставал годиться после 19:00 — не по решению, а
  // потому что час умолчания уже истёк. Теперь сегодня годится весь день.
  group('на какой день ещё можно предложить работу', () {
    test('прошлый день не годится', () {
      expect(
        canOfferOnDay(DateTime(2026, 8, 13), DateTime(2026, 8, 14, 10)),
        isFalse,
      );
    });

    test('завтра и дальше годятся', () {
      expect(
        canOfferOnDay(DateTime(2026, 8, 15), DateTime(2026, 8, 14, 10)),
        isTrue,
      );
      expect(
        canOfferOnDay(DateTime(2026, 12, 31), DateTime(2026, 8, 14, 10)),
        isTrue,
      );
    });

    // ИЗМЕНЕНИЕ ПОВЕДЕНИЯ, названное числом: в 23:59 сегодняшний день
    // ГОДИТСЯ. Прежняя редакция вернула бы здесь `false`, потому что 19:00
    // давно позади. Позвать вечером на сегодня — законный случай, и
    // раньше он запрещался побочно, а не по решению.
    test('сегодня годится весь день, включая поздний вечер', () {
      expect(
        canOfferOnDay(DateTime(2026, 8, 14), DateTime(2026, 8, 14, 23, 59)),
        isTrue,
      );
    });
  });
}
