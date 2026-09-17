import 'package:flutter_test/flutter_test.dart';
import 'package:mugam_flutter/core/agreements/call_targets.dart';
import 'package:mugam_flutter/core/agreements/event_answers.dart';
import 'package:mugam_flutter/firebase/models.dart';

import 'support/source_text.dart';

// КОГО ЗОВЁТ «ÖZ ADAMLARIMI ÇAĞIR» — правило вынесено из разметки (17.09).
//
// ПОВОД — ЖИВОЙ ДЕФЕКТ, НАЙДЕННЫЙ ГЛАЗАМИ. Владелец, не убирая вышедшего,
// нажал «позвать» дважды: приложение показало «приглашение отправлено», а
// человеку не пришло ничего. Решение жило одной строкой в виджете —
// `if (!already.contains(uid))`, где `already` это `musicians`, — и
// проверялось оно ничем: условие в разметке прогнать нечем (I32).
//
// РАБОТА ШЛА ДВУМЯ ШАГАМИ, И ЭТО ВИДНО ПО НАБОРУ. Первый разнёс МЕСТО
// решения: правило повторяло прежнее поведение дословно, включая неверное
// «вышедший уже спрошен», и вердикт на него стоял здесь красным напоминанием.
// Второй починил само решение, и тот вердикт перевёрнут — «ВЫШЕДШИЙ — ЗВАТЬ
// ЗАНОВО». Порознь нарочно: на живую пробу не должны ехать две переменные.
//
// СОБЫТИЕ СТРОИТСЯ ЧЕРЕЗ `fromFirestore`: карта ответов у модели закрыта, и
// это тот же путь, которым документ приходит в проде (I55).

const owner = 'rafael';
const guest = 'teymur';
const other = 'said';

PersonalEvent event({
  List<String> musicians = const [],
  Map<String, String> answers = const {},
  bool writtenByOwner = true,
}) =>
    PersonalEvent.fromFirestore('e', {
      'ownerUid': owner,
      'date': '2026-09-20T19:00:00.000',
      'musicians': musicians,
      'answers': answers,
      'answersWrittenByOwner': writtenByOwner,
      'status': 'agreed',
    });

void main() {
  group('кого звать — по ответу, а не по разметке', () {
    test('ЧЕЛОВЕКА В СОСТАВЕ НЕТ — добавить и спросить', () {
      final t = callTargets(event: event(), picked: const [guest]);
      expect(t.single.uid, guest);
      expect(t.single.outcome, CallOutcome.addToParty);
    });

    test('ПОЗВАН И МОЛЧИТ — не трогать: вопрос уже задан', () {
      final t = callTargets(
        event: event(musicians: const [guest], answers: const {guest: kAnswerWaiting}),
        picked: const [guest],
      );
      expect(t.single.outcome, CallOutcome.alreadyAsked);
    });

    test('СОГЛАСИЛСЯ — не трогать', () {
      final t = callTargets(
        event: event(musicians: const [guest], answers: const {guest: kAnswerGoing}),
        picked: const [guest],
      );
      expect(t.single.outcome, CallOutcome.alreadyAsked);
    });

    test('ВЫШЕДШИЙ — ЗВАТЬ ЗАНОВО, а не пропускать', () {
      // ГЛАВНЫЙ ВЕРДИКТ ВСЕЙ РАБОТЫ. До 17.09 здесь стояло обратное —
      // `alreadyAsked`, — и это был дефект, доживший до трубки: владелец,
      // не убирая вышедшего, нажал «позвать» дважды, увидел «отправлено» и
      // не позвал никого.
      //
      // Довод владельца дословно: Рафаэль видит вышедшего и жмёт «позвать» —
      // это естественное действие. Что надо сперва удалить, а потом звать,
      // нигде не сказано и само по себе странно: зачем удалять того, кого
      // зовёшь.
      final t = callTargets(
        event: event(musicians: const [guest], answers: const {guest: kAnswerLeft}),
        picked: const [guest],
      );
      expect(t.single.outcome, CallOutcome.askAgain);
    });

    test('НЕ СПРАШИВАЛИ — тоже звать: вопроса перед ним нет', () {
      // Человек в составе, ключа в карте нет, а карту заполнял владелец —
      // значит его не спрашивали (N115). Действие то же, что у вышедшего:
      // поставить вопрос. Случаи в данных РАЗНЫЕ и остаются разными; одинаков
      // только ход (I47: различать надо там, где решается «норма или
      // поломка», а здесь решается «что сделать»).
      final t = callTargets(
        event: event(musicians: const [guest], answers: const {}),
        picked: const [guest],
      );
      expect(t.single.outcome, CallOutcome.askAgain);
    });

    test('ЗАНОВО ЗВАТЬ — НЕ значит добавлять в состав второй раз', () {
      // Он уже в `musicians`. Уйди он в `addToParty`, состав получил бы
      // двойника — та же беда, что дала двойную строку на экране 17.09.
      //
      // ЭТОТ ВЕРДИКТ СЛАБЕЕ СВОЕГО ИМЕНИ, и показала это порча, а не разбор.
      // Он требует «не `addToParty`», а этому условию удовлетворяет и
      // НЕВЕРНЫЙ `alreadyAsked`: порча, вернувшая вышедшему «уже спрошен»,
      // уронила два соседних вердикта и этот НЕ тронула. То есть в одиночку
      // он не отличит починку от дефекта.
      //
      // Оставлен, а не снят: он ловит СВОЮ ошибку — попытку решить задачу
      // добавлением в состав, — и её соседи не ловят. Но полагаться на него
      // как на сторожа зова нельзя, и это сказано здесь, чтобы следующий не
      // счёл его достаточным.
      final t = callTargets(
        event: event(musicians: const [guest], answers: const {guest: kAnswerLeft}),
        picked: const [guest],
      );
      expect(t.single.outcome, isNot(CallOutcome.addToParty));
    });

    test('КАНАРЕЙКА: правило вообще различает случаи', () {
      // Шесть вердиктов выше зазеленели бы разом, начни правило отвечать
      // одним и тем же на всё (I31).
      final t = callTargets(
        event: event(
          musicians: const [guest],
          answers: const {guest: kAnswerGoing},
        ),
        picked: const [guest, other],
      );
      expect(t.map((x) => x.outcome).toSet().length, 2,
          reason: 'канарейка: правило отвечает одинаково на разные случаи');
    });
  });

  group('порядок и отбор', () {
    test('ПОРЯДОК ОТМЕТКИ СОХРАНЯЕТСЯ', () {
      final t = callTargets(event: event(), picked: const [other, guest]);
      expect([for (final x in t) x.uid], [other, guest]);
    });

    test('дважды отмеченный — одна запись', () {
      // Иначе он ушёл бы в состав дважды; цена такой ошибки уже оплачена
      // двойной строкой на экране 17.09.
      final t = callTargets(event: event(), picked: const [guest, guest]);
      expect(t.length, 1);
    });

    test('пустой uid выбрасывается', () {
      final t = callTargets(event: event(), picked: const ['', guest]);
      expect(t.length, 1);
      expect(t.single.uid, guest);
    });

    test('никого не отметили — ни одной записи', () {
      expect(callTargets(event: event(), picked: const []), isEmpty);
    });
  });

  group('есть ли что отправлять — правило для плашки', () {
    test('ВЫШЕДШИЙ — ЕСТЬ ЧТО ОТПРАВИТЬ, и это ровно случай с трубки', () {
      // Плашка «Çağırış göndərildi» врала именно здесь: правило считало
      // вышедшего уже спрошенным, отправлять было нечего, а плашка бодро
      // отчитывалась об отправке.
      final t = callTargets(
        event: event(musicians: const [guest], answers: const {guest: kAnswerLeft}),
        picked: const [guest],
      );
      expect(anythingToSend(t), isTrue);
    });

    test('все уже спрошены — отправлять НЕЧЕГО', () {
      // ЭТО И ЕСТЬ ВТОРАЯ БЕДА С ТРУБКИ: плашка «Çağırış göndərildi»
      // считала ОТМЕЧЕННЫХ, а не отправленных, и человек, уже бывший в
      // составе, молча попадал в счёт. Владелец видел «отправлено» и был
      // уверен, что позвал.
      final t = callTargets(
        event: event(musicians: const [guest], answers: const {guest: kAnswerGoing}),
        picked: const [guest],
      );
      expect(anythingToSend(t), isFalse);
    });

    test('хоть один новый — есть что отправлять', () {
      final t = callTargets(
        event: event(musicians: const [guest], answers: const {guest: kAnswerGoing}),
        picked: const [guest, other],
      );
      expect(anythingToSend(t), isTrue);
    });

    test('никого не отметили — отправлять нечего', () {
      expect(anythingToSend(const []), isFalse);
    });
  });

  group('решение принимает ПРАВИЛО, а не разметка', () {
    // ЗАЧЕМ ПО ИСХОДНИКУ. Вердикты выше доказывают, что правило отвечает
    // верно, и молчат о том, СПРАШИВАЕТ ли его экран. Ровно этой половины и
    // не хватало: правило «кого звать» существовало в голове, а в коде было
    // условием в разметке (I32, N125).
    late String screen;

    setUpAll(() {
      screen = readCode('lib/features/agreements/screens/agreements_screen.dart');
    });

    test('экран ЗОВЁТ правило', () {
      // Утверждение НАЛИЧИЯ, значит само себе канарейка (I31).
      expect(screen.contains('callTargets(event: event, picked: picked)'), isTrue,
          reason: 'Зов перестал спрашивать правило — значит решение «кого '
              'звать» снова принимается в разметке, где его нечем прогнать.');
    });

    test('ПЛАШКА СПРАШИВАЕТ ПРАВИЛО, а не считает отмеченных', () {
      // ВТОРАЯ БЕДА С ТРУБКИ, и она отдельная от первой: приложение говорило
      // «Çağırış göndərildi», когда не отправило ничего. Человек уверен, что
      // позвал, а узнают об этом на свадьбе.
      //
      // Утверждение НАЛИЧИЯ, значит само себе канарейка (I31).
      expect(screen.contains('if (!anythingToSend(targets))'), isTrue,
          reason: 'Плашка перестала спрашивать правило «ушло ли хоть '
              'что-нибудь» — значит снова хвалится по числу отмеченных.');
      // И ЧИСЛО — ИЗ ТОГО ЖЕ РАЗБОРА, а не из длины отмеченного списка: уже
      // спрошенный остаётся в слотах «позванным», и разность молча прибавила
      // бы к числу единицу.
      expect(screen.contains('sendingUids.contains(s.uid)'), isTrue,
          reason: 'Число в плашке считается не по тем, кому ушло.');
      expect(
        screen.contains(r'Çağırış göndərildi: ${slotsAfterWrite.length}'),
        isFalse,
        reason: 'Плашка снова называет длину ОТМЕЧЕННОГО списка. Это дефект '
            '17.09 дословно: «отправлено» про того, кому не ушло.',
      );
    });

    test('у экрана НЕТ своего условия по составу', () {
      // Отрицание; канарейка к нему — вердикт выше.
      expect(
        screen.contains('event.participantUids.toSet()'),
        isFalse,
        reason: 'В зове снова появилось своё условие по `musicians`. Это '
            'поле после выхода значит «видит вечер», а не «участвует», и '
            'читать его как «уже позван» — тот самый дефект 17.09.',
      );
    });
  });
}
