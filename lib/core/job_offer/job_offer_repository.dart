import 'package:cloud_firestore/cloud_firestore.dart';

import 'day_details.dart';
import 'job_offer.dart';

// ЧЕТЫРЕ ХОДА И ОДНО ЧТЕНИЕ — ровно то, что разрешают правила
// (`firestore.rules`, блок `offers`; парный тест —
// `functions/test/job-offer-rules.test.ts`, 27 из 27).
//
// Пятого хода здесь нет и появиться не должно: каждый новый ход в этом
// файле обязан сперва появиться в правилах и в парном тесте, иначе он
// отказывает на устройстве, а человеку это показывается как «кнопка не
// работает».

class JobOfferRepository {
  JobOfferRepository(this._db);

  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> _offers(String chatId) =>
      _db.collection('chats').doc(chatId).collection('offers');

  /// ОДИН ПОТОК НА ВСЕ ПРЕДЛОЖЕНИЯ ЧАТА, а не по потоку на карточку.
  ///
  /// Карточек в ленте может быть много (каждое предложение — своя), и
  /// подписка у каждой означала бы столько же живых слушателей на один
  /// экран, растущих с прокруткой вглубь истории.
  ///
  /// **ОГОВОРКА, КОТОРУЮ НАДО ЗНАТЬ ДО ТОГО, КАК ТАКИХ ПОТОКОВ СТАНЕТ
  /// МНОГО: этот поток закрывает ТОТ, КТО ПОДПИСАЛСЯ.** Сам он не
  /// закроется никогда — `snapshots()` живёт, пока на него подписаны, и
  /// незакрытая подписка переживает экран: слушатель продолжает получать
  /// правки, дёргать перерисовку у снятого виджета и тратить чтения.
  /// Заметно это не сразу и не на одном экране, а числом — потому и
  /// записано здесь, у самого истока, а не в том месте, где однажды
  /// станет больно.
  ///
  /// **Кто подписывается, тот и отменяет** — в `dispose()`, рядом с
  /// остальными отменами. Riverpod-обёртка (`.autoDispose`) делает это
  /// сама, ручной `listen` — нет.
  Stream<List<JobOffer>> watchOffers(String chatId) {
    return _offers(chatId).snapshots().map(
      (snap) => snap.docs
          .map((d) => JobOffer.fromMap(d.id, d.data()))
          .toList(growable: false),
    );
  }

  /// Ход 1 — создание. Зовущий обязан назвать себя сам: правило требует
  /// `createdBy == request.auth.uid`, и подставлять этот uid где-то в
  /// глубине нельзя — тогда место, где решается «от чьего имени», уедет от
  /// места, где это видно.
  Future<String> createOffer({
    required String chatId,
    required String myUid,
    required List<String> dates,
    required String eventType,
    String? anchorMessageId,
    // ДЕТАЛИ У КАЖДОГО ДНЯ СВОИ (макет `mugam-14-secim`). Прежде здесь были
    // три поля на всё предложение — время, место, заметка, — и звали на
    // пять вечеров с одним временем на всех.
    //
    // Ключ карты — тот же ISO-день, что лежит в `dates`. Дни без единой
    // вписанной подробности в карту не попадают вовсе: пустая запись и
    // отсутствие записи значат одно, а хранить одно двумя способами значит
    // однажды прочитать их по-разному.
    Map<String, DayDetails> details = const {},
  }) async {
    final ref = _offers(chatId).doc();
    await ref.set({
      'createdBy': myUid,
      'createdAt': DateTime.now().toIso8601String(),
      'anchorMessageId': anchorMessageId,
      'dates': dates,
      'eventType': eventType,
      'details': {
        for (final e in details.entries) e.key: e.value.toMap(),
      },
      // Пустая карта обязательна: правило требует `answers` пустым при
      // создании. Отметка за музыканта, поставленная вперёд него, — тот же
      // подлог, что чужой `cancelledBy` (N37).
      'answers': <String, dynamic>{},
    });
    return ref.id;
  }

  /// Ход 2 — отметки дней.
  ///
  /// **ПИШЕТСЯ ИМЕННО `answers.<myUid>`, А НЕ `answers` ЦЕЛИКОМ, и это
  /// видно прямо в вызове.** Правило разрешает сдвинуть в карте ответов
  /// ровно один ключ — свой (`touchesOnlyOwnAnswer`), поэтому запись всей
  /// карты отказала бы, как только в ней окажется чужая отметка. Форма
  /// записи здесь — не стиль, а то самое правило, переписанное на языке
  /// клиента: следующему не придётся гадать, почему нельзя иначе.
  ///
  /// **Пустой `picked` — законный ответ «не могу ни на один день».** Не
  /// перехватывать его как «ничего не выбрано» и не отменять запись:
  /// отдельного отказа в этой работе нет, неотмеченные дни и значат «нет».
  Future<void> setMyAnswer({
    required String chatId,
    required String offerId,
    required String myUid,
    required List<String> picked,
  }) {
    return _offers(chatId).doc(offerId).update({
      'answers.$myUid': picked,
    });
  }

  /// Ход 3 — принятие. По нему создаются вечера, и потому это ход
  /// инициатора, а не получателя: «звали на пять, дали три, и работодатель
  /// часто не соглашается».
  Future<void> accept({
    required String chatId,
    required String offerId,
    required String myUid,
  }) {
    return _offers(chatId).doc(offerId).update({
      'acceptedBy': myUid,
      'acceptedAt': DateTime.now().toIso8601String(),
    });
  }

  /// Ход 4 — отзыв. Нужен затем, что без него ошибочное предложение висит;
  /// отправка нового вместо отзыва была бы вторым путём к той же операции.
  Future<void> withdraw({
    required String chatId,
    required String offerId,
    required String myUid,
  }) {
    return _offers(chatId).doc(offerId).update({
      'withdrawnBy': myUid,
      'withdrawnAt': DateTime.now().toIso8601String(),
    });
  }
}
