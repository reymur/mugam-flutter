import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/job_offer/accept_batch.dart';
import 'package:mugam_flutter/core/job_offer/day_details.dart';
import 'package:mugam_flutter/core/job_offer/job_offer.dart';

// СОСТАВ ПАЧКИ, КОТОРУЮ ПИШЕТ ПРИЁМ.
//
// **ЧТО ЗНАЧИТ ЗЕЛЁНЫЙ ЭТОГО ФАЙЛА, СКАЗАНО ДО ПЕРВОГО ТЕСТА, ЧТОБЫ НЕ
// ПРОЧЛОСЬ ШИРЕ: «ПАЧКА СОБРАНА ВЕРНО», А НЕ «ПАЧКА В БАЗЕ».** Подделки
// Firestore в проекте нет (`fake_cloud_firestore`, `mocktail`, `mockito` —
// ни одной в `pubspec.yaml`), эмулятор есть только у `functions`. Дорога
// `WriteBatch` → Firestore не покрыта ничем и покрыта быть не может, пока
// подделки нет; единственное её подтверждение — снимок с трубки.
//
// **ПОЧЕМУ ЭТО ВСЁ-ТАКИ НАСТОЯЩИЙ ПУТЬ, А НЕ ЧИСТАЯ ФУНКЦИЯ РЯДОМ** (I55).
// `JobOfferRepository.accept` не решает ничего: он зовёт `buildAcceptBatch`
// и записывает ровно то, что она вернула. Ни одного `if` у него нет. Значит
// порча здесь портит прод, а не соседа.
//
// **ПРИНЯТИЕ НЕОБРАТИМО**, и потому состав записи проверяется поимённо, а
// не «в целом»: отозвать принятое правило не даёт (`roundOpen()`), а
// неверное поле в тридцати одном вечере правится тридцатью одной правкой
// руками.

const boss = 'boss-uid';
const player = 'player-uid';

JobOffer offer({
  List<String> dates = const ['2026-09-10', '2026-09-11', '2026-09-12'],
  Map<String, List<String>> answers = const {
    player: ['2026-09-11', '2026-09-10'],
  },
  Map<String, DayDetails> details = const {},
  String? createdAt = '2026-09-01T12:00:00.000',
}) => JobOffer(
  id: 'offer-1',
  createdBy: boss,
  dates: dates,
  eventType: 'Toy',
  answers: answers,
  details: details,
  createdAt: createdAt,
);

AcceptBatch build({JobOffer? o}) => buildAcceptBatch(
  offer: o ?? offer(),
  chatId: 'chat-1',
  initiatorUid: boss,
  recipientUid: player,
  recipientName: 'Teymur Orucov',
  acceptedAt: DateTime(2026, 9, 5, 18, 30),
);

void main() {
  group('сколько вечеров и какие', () {
    // ДНИ БЕРУТСЯ ИЗ ОТВЕТА, А НЕ ИЗ ПРЕДЛОЖЕНИЯ. Звали на три, музыкант
    // смог два — вечеров два. Взять `dates` значило бы завести человеку в
    // календарь день, на который он прямо сказал «нет».
    test('вечеров столько, сколько дней отмечено, а не сколько предложено', () {
      final plan = build();

      expect(plan.events.length, 2);
      expect(
        plan.events.map((e) => e.data['date']).toList(),
        // Порядок — по возрастанию дня, независимо от порядка в ответе:
        // в ответе выше 11-е стоит первым.
        ['2026-09-10', '2026-09-11'],
      );
    });

    // ИМЯ ДОКУМЕНТА — ЗАЩИТА ОТ ПОВТОРА, и потому проверяется точной
    // строкой, а не «начинается с offerId».
    test('имя документа — offerId_день, а не случайное', () {
      final plan = build();

      expect(
        plan.events.map((e) => e.id).toList(),
        ['offer-1_2026-09-10', 'offer-1_2026-09-11'],
      );
    });

    // ПОВТОРНОЕ ПРИНЯТИЕ ДАЁТ ТЕ ЖЕ ИМЕНА. Это и есть смысл `set` вместо
    // `add`: два нажатия, обрыв связи, второй телефон — всё это перезапишет
    // те же документы, а не заведёт вторые.
    test('повтор даёт те же имена документов', () {
      expect(
        build().events.map((e) => e.id).toList(),
        build().events.map((e) => e.id).toList(),
      );
    });
  });

  group('состав одного вечера', () {
    test('поля, по которым его найдут и покажут', () {
      final e = build().events.first.data;

      expect(e['ownerUid'], boss, reason: 'правило требует ownerUid == себя');
      expect(e['date'], '2026-09-10');
      expect(e['type'], 'Toy');
      expect(e['musicians'], [boss, player]);
      expect(e['status'], 'agreed');
    });

    // ТРИ ПОЛЯ ДОГОВОРА, И У КАЖДОГО НАЗВАН ЧИТАТЕЛЬ — иначе они выглядят
    // данью симметрии с прежним писателем и однажды будут сняты как лишние.
    test('договор, а не личный вечер: isAgree, партнёр, чат', () {
      final e = build().events.first.data;

      // Читает `eventCardKind` (core/agreements/event_lookup.dart:45) и
      // фильтр «Müqavilələr» на профиле.
      expect(e['isAgree'], isTrue);
      expect(e['partnerUid'], player);
      expect(e['partnerName'], 'Teymur Orucov');
      // По нему возвращаются в переписку, из которой договор родился.
      expect(e['agreementChatId'], 'chat-1');
    });

    // ГЛАВНОЕ ПОЛЕ ЭТОЙ РАБОТЫ, И ОНО ЛЕГЧЕ ВСЕГО ПОТЕРЯЛОСЬ БЫ.
    //
    // `jobOfferAt` — когда ушло ПРЕДЛОЖЕНИЕ, а не когда его приняли. По
    // нему сортируются карточки договоров и на каждой печатается дата
    // прихода (`agreementStampValue`, `agreementArrivalValue`). Оставь тут
    // пусто — на всех карточках встал бы момент принятия, а он бывает
    // позже на дни.
    test('jobOfferAt — время отправки предложения, не время принятия', () {
      final e = build().events.first.data;

      expect(e['jobOfferAt'], '2026-09-01T12:00:00.000');
      // А `createdAt` вечера — ОТМЕТКА СЕРВЕРА, не наша строка и не часы
      // телефона: так пишут оба существующих писателя этой коллекции.
      // Проверяется тип, потому что значения у неё до записи нет вовсе.
      expect(e['createdAt'], isA<FieldValue>());
      expect(
        e['createdAt'],
        isNot('2026-09-05T18:30:00.000'),
        reason: 'момент принятия ставит сервер, а не клиент',
      );
    });

    // У СТАРЫХ ПРЕДЛОЖЕНИЙ ПОЛЯ МОЖЕТ НЕ БЫТЬ — приём обязан пройти, а не
    // упасть: карточка тогда откатится на `createdAt` (запасной путь у неё
    // предусмотрен и работает с 25 договорами прода из 26).
    test('предложение без createdAt — вечер создаётся, jobOfferAt пуст', () {
      final plan = build(o: offer(createdAt: null));

      expect(plan.events.length, 2);
      expect(plan.events.first.data['jobOfferAt'], isNull);
    });

    // МОЛЧАНИЕ СЕРВЕРА — ЭТО ПОЛЕ, А НЕ ОТСУТСТВИЕ КОДА.
    //
    // `onPersonalEventCreated` выходит сразу при `lastActionType ==
    // 'agreed'` (functions/src/index.ts:2325). Не будь этого значения,
    // музыкант получил бы по уведомлению «вас добавили» НА КАЖДЫЙ ДЕНЬ — и
    // все об одном своём же ответе. Одно уведомление на предложение — шаг
    // 4 (N130), и снимается молчание там.
    test('lastActionType agreed — сервер молчит; автор назван', () {
      final e = build().events.first.data;

      expect(e['lastActionType'], 'agreed');
      expect(e['lastActionBy'], boss);
    });

    // ПОЛЕ, РАДИ КОТОРОГО ВСЯ ЗАПИСЬ И ДЕЛАЕТСЯ, И ПОТОМУ ОНО ЗДЕСЬ ПЕРВЫМ
    // СРЕДИ РАВНЫХ.
    //
    // Договор из принятого предложения рождается ИЗ СОСТОЯВШЕГОСЯ СОГЛАСИЯ:
    // музыкант отметил этот день сам, работодатель нажал «Qəbul edirəm».
    // Спрашивать музыканта заново — «Gəlirəm / Bacarmıram» — значит
    // спрашивать о том, на что он уже ответил, и хуже: дать ему отказаться
    // от работы, которую отозвать уже нельзя.
    //
    // Проверяются ОБА ключа, а не только музыкантов: карта, где владельца
    // нет вовсе, прошла бы проверку «музыкант going» и оставила бы
    // работодателя ждущим ответа на собственном вечере (N112).
    test('оба участника going — согласие уже состоялось', () {
      final e = build().events.first.data;

      expect(e['answers'], {boss: 'going', player: 'going'});
      // Карта заполнена ЦЕЛИКОМ по составу — значит отсутствующий в ней
      // человек не «неизвестен», а не спрошен (N115). Ставит только тот,
      // кто пишет карту целиком.
      expect(e['answersWrittenByOwner'], isTrue);
    });

    // ПОЛЯ ОТМЕНЫ ОБЯЗАНЫ БЫТЬ, ХОТЬ И ПУСТЫЕ. Оба существующих писателя
    // их кладут; разойдись мы с ними — отмена по согласию работала бы на
    // одних вечерах и молча не работала на других.
    test('четыре поля отмены на месте и пусты', () {
      final e = build().events.first.data;

      expect(e.containsKey('cancelRequestedBy'), isTrue);
      expect(e.containsKey('cancelRequestedAt'), isTrue);
      expect(e.containsKey('cancelConfirmedBy'), isTrue);
      expect(e.containsKey('cancelledAt'), isTrue);
      expect(e['cancelRequestedBy'], isNull);
      expect(e['cancelledAt'], isNull);
    });
  });

  group('подробности дня едут в вечер, а не теряются', () {
    // У КАЖДОГО ДНЯ СВОИ. Общего времени и места у предложения нет вовсе —
    // так решено 14.08, — поэтому проверяются РАЗНЫЕ дни с разным
    // содержимым: одинаковые прошли бы и при перепутанных ключах.
    test('место и время берутся у СВОЕГО дня', () {
      final plan = build(
        o: offer(
          details: const {
            '2026-09-10': DayDetails(time: '19:00', location: 'Şəhriyar'),
            '2026-09-11': DayDetails(time: '21:00', location: 'Gülüstan'),
          },
        ),
      );

      expect(plan.events[0].data['location'], 'Şəhriyar');
      expect(plan.events[0].data['notes'], '19:00');
      expect(plan.events[1].data['location'], 'Gülüstan');
      expect(plan.events[1].data['notes'], '21:00');
    });

    // ВРЕМЯ И ОДЕЖДА УХОДЯТ В ЗАМЕТКУ, потому что своего поля у вечера
    // нет. Терять вписанное нельзя: ради него человек и открывал
    // подробности.
    test('время и одежда сведены в заметку', () {
      final plan = build(
        o: offer(
          details: const {
            '2026-09-10': DayDetails(time: '19:00', dress: 'Qara kostyum'),
          },
        ),
      );

      expect(plan.events[0].data['notes'], '19:00 · Qara kostyum');
    });

    // ДЕНЬ БЕЗ ПОДРОБНОСТЕЙ В КАРТУ НЕ ПОПАДАЕТ ВОВСЕ — так их пишет
    // `createOffer`. Отсутствие ключа законно и означает «ничего не
    // вписано», а не поломку.
    test('день без подробностей — пустые строки, а не падение', () {
      final e = build().events.first.data;

      expect(e['location'], '');
      expect(e['notes'], '');
    });
  });

  group('правка самого предложения', () {
    // РОВНО ДВА КЛЮЧА. Правило не пустит третий:
    // `changedKeys().hasOnly(['acceptedBy', 'acceptedAt'])`. Лишнее поле
    // здесь означало бы отказ всей пачки на устройстве — и человеку это
    // видно как «нажал и ничего».
    test('в предложение уходят только acceptedBy и acceptedAt', () {
      final patch = build().offerPatch;

      expect(patch.keys.toSet(), {'acceptedBy', 'acceptedAt'});
      expect(patch['acceptedBy'], boss);
      // ЗДЕСЬ ИМЕННО ISO-СТРОКА, А НЕ ОТМЕТКА СЕРВЕРА, и это не забытая
      // половина правки `createdAt` выше. У предложений своё соседство:
      // `createOffer` пишет `createdAt` строкой, `withdraw` — `withdrawnAt`
      // строкой. Две коллекции — два уговора, и каждое поле держится своего.
      expect(patch['acceptedAt'], '2026-09-05T18:30:00.000');
    });

    // ЧИСЛО ЗАПИСЕЙ В ПАЧКЕ НАЗВАНО ВСЛУХ. Предел Firestore — 500 на
    // Commit, и держит его правило `dates.size() <= 31`, а не надежда.
    test('записей в пачке — N вечеров плюс одна правка', () {
      final plan = build();
      expect(plan.events.length + 1, 3);
    });
  });

  // ПРИНИМАТЬ НЕЧЕГО — ЭТО ОШИБКА, А НЕ ТИХОЕ СОГЛАСИЕ.
  //
  // Ноль отмеченных дней — законный ответ «не могу ни в один», и кнопку в
  // этом состоянии не рисуют (`canAcceptAnswer`). Но если сюда всё же
  // дойдут, пачка вышла бы из одной правки и НИ ОДНОГО вечера: предложение
  // помечено принятым, а в календаре пусто. Молчаливое согласие с этим
  // хуже отказа — отозвать принятое правило уже не даст.
  test('ответ нулём дней — сборка отказывает, а не пишет пустую пачку', () {
    expect(
      () => build(o: offer(answers: const {player: []})),
      throwsArgumentError,
    );
  });
}
