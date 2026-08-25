import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' hide User;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/job_offer/job_offer.dart';
import '../../../core/job_offer/job_offer_repository.dart';
import '../../../core/theme/colors.dart';
import '../../../firebase/firestore_service.dart';
import '../../agreements/screens/agreements_screen.dart';
import '../busy_days.dart';
import '../widgets/job_offer_card.dart';
import '../widgets/offer_answer_view.dart';
import 'job_offer_answer_sheet.dart';

// ЛИСТ ПРЕДЛОЖЕНИЯ — то, что раньше стояло развёрнутой карточкой в ленте.
//
// В переписке теперь короткая строка (`offerFeedLine`), а всё содержимое —
// дни, «Ətraflı», микрофон, отзыв, строка ожидания — открывается здесь.
// Решение автора 14.08, занесено в план 19.08.
//
// СЮДА ЖЕ ВЕДЁТ ЗАКРЫТЫЙ РАУНД, И НОВЫХ УСЛОВИЙ ДЛЯ ЭТОГО НЕ ЗАВЕДЕНО.
// При `accepted`/`withdrawn` `offerCardActions` отдаёт всё `false`, а
// `_footer` карточки первой же строкой рисует «Təklif qəbul edildi» /
// «geri götürüldü» без кнопок. Лист сам собой выходит просмотром — ровно
// то, что решил автор 19.08: «человек захочет увидеть, на каких днях
// сошлись, а идти в календарь — не одно касание».
//
// ЭТОТ ЛИСТ — ДВЕРЬ ВО ВСЕ ТРИ, И ТАК РЕШЕНО, А НЕ ВЫШЛО САМО (владелец,
// 22.08). Здесь стояло обратное — «сюда ведёт `offerSheetFor` только в тех
// клетках, где «Qəbul edirəm» не предлагается; ответ и приём — другие
// листы», — и запись эта устарела дважды: шагом 2 (ответ открывается
// отсюда кнопкой «Cavab ver») и шагом 3 (приём — кнопкой «Cavaba bax»).
//
// **Довод, по которому дверь одна.** Лист приёма и лист ответа — виджеты
// без своих данных: им подают предложение и имена. Живой поток и
// разрешение имён есть ТОЛЬКО здесь. Вести в них прямо из переписки
// значило бы либо питать их снимком — и потерять живое обновление, ради
// которого делалась N143, — либо завести второй источник тех же данных. А
// «Ətraflı» есть только здесь, и принимать без подробностей не лучше, чем
// отвечать без них.
//
// **`offerSheetFor` при этом НЕ выброшена и не переписана.** Её восемь
// клеток по-прежнему верны как ответ на вопрос «в каком состоянии человек
// и что ему сейчас предложено», и на ней стоят тесты. Изменилось лишь то,
// что переключатель в `chat_screen` открывает одну дверь, а какие кнопки
// за ней нарисованы, решает `offerCardActions`. **Если однажды покажется,
// что эта функция мертва, — сперва прочитать этот абзац: она не мертва, у
// неё другой потребитель.**

class JobOfferSheet extends ConsumerStatefulWidget {
  const JobOfferSheet({
    super.key,
    required this.chatId,
    required this.offerId,
    this.debugOffers,
    this.debugViewerUid,
    this.debugWriteAnswer,
    this.debugWriteAccept,
  });

  /// ОТ ВЫЗЫВАЮЩЕГО — ТОЛЬКО ЭТИ ДВА, и это не аскетизм.
  ///
  /// Лист, которому данные подаёт открывший, ломается там, где открывшего
  /// нет: на шаге 4 в него будут вести из уведомления, и заводить ради
  /// этого поток в обработчике уведомления значит завести второй источник
  /// тех же данных. Здесь лист сам знает, откуда их взять.
  final String chatId;
  final String offerId;

  /// Подмена потока ДЛЯ ТЕСТА, и её граница названа честно (I50).
  ///
  /// С ней проверяется, что лист **перерисовывается на каждую выдачу**, —
  /// то, ради чего заведена N143. Она НЕ проверяет дорогу
  /// `JobOfferRepository` → `snapshots()` → сюда: та остаётся непокрытой,
  /// потому что поднять Firestore в тесте нечем.
  @visibleForTesting
  final Stream<List<JobOffer>>? debugOffers;

  /// Вторая подмена ДЛЯ ТЕСТА — свой uid.
  ///
  /// В проде он берётся у `FirebaseAuth.instance`, и подменить его нечем:
  /// это одиночка, а провайдера под него в проекте нет — **61 место
  /// читает его напрямую** (замер 19.08). Заводить провайдер ради одного
  /// листа значит взяться за соседнюю работу (I51).
  ///
  /// Без этой подмены лист не поднимается в тесте вовсе: обращение к
  /// `FirebaseAuth.instance` без поднятого Firebase падает, и проверить
  /// живое обновление становится нечем.
  @visibleForTesting
  final String? debugViewerUid;

  /// Третья подмена ДЛЯ ТЕСТА — куда уходит ответ музыканта (шаг 2).
  ///
  /// **Заведена ровно затем, чтобы порчу гнать по НАСТОЯЩЕМУ пути** (I55):
  /// без неё проверить можно было бы только чистую функцию рядом, а прод
  /// идёт кнопка → лист ответа → `onSend` → `setMyAnswer`.
  ///
  /// **ГРАНИЦА НАЗВАНА ЧЕСТНО, И ОНА УЗКАЯ (I50):** шов доводит проверку до
  /// вызова записи с точными доводами — и **ни на шаг дальше**. Последний
  /// стык, `setMyAnswer` → Firestore, тестом не достаётся: подделки
  /// Firestore в проекте нет (`fake_cloud_firestore`, `mocktail`, `mockito`
  /// — ни одной в `pubspec.yaml`, замер 20.08), а эмулятор есть только у
  /// `functions`. **Порча тела `setMyAnswer` не уронит ничего**, и зелёный
  /// прогон не означает «в базу записалось».
  @visibleForTesting
  final Future<void> Function(List<String> picked)? debugWriteAnswer;

  /// Четвёртая подмена ДЛЯ ТЕСТА — запись принятия, и граница у неё та же
  /// (I50). С ней проверяется, что нажатие «Qəbul edirəm» доводит ДО
  /// ПИСАТЕЛЯ то самое предложение, которое открыто. Она НЕ проверяет
  /// дорогу `WriteBatch` → Firestore: подделки Firestore в проекте нет,
  /// эмулятор только у `functions`. Что именно уходит в пачку,
  /// проверяется отдельно — у `buildAcceptBatch`, который и есть путь
  /// прода.
  @visibleForTesting
  final Future<void> Function(JobOffer offer)? debugWriteAccept;

  @override
  ConsumerState<JobOfferSheet> createState() => _JobOfferSheetState();
}

class _JobOfferSheetState extends ConsumerState<JobOfferSheet> {
  /// СОБИРАЕТСЯ ЗДЕСЬ, А НЕ В `build`, и это не стиль (N143).
  ///
  /// `snapshots()` отдаёт НОВЫЙ поток при каждом вызове; собранный в
  /// `build`, он заводил бы новую подписку на каждую перерисовку, а старую
  /// бросал. У листа это опаснее, чем у ленты: жизнь короче, открывают
  /// часто, и утечка накапливается по одной на открытие.
  ///
  /// Отписку делает `StreamBuilder` ниже — он уходит вместе с маршрутом.
  /// **Ручного `listen` здесь нет намеренно:** у него отмена на совести
  /// пишущего, а оговорка про это стоит у самого истока
  /// (`job_offer_repository.dart`, `watchOffers`).
  late final Stream<List<JobOffer>> _offers;

  @override
  void initState() {
    super.initState();
    _offers =
        widget.debugOffers ??
        JobOfferRepository(FirebaseFirestore.instance).watchOffers(widget.chatId);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);

    return Container(
      height: media.size.height * 0.92,
      decoration: const BoxDecoration(
        color: kBg2,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            const SizedBox(height: 12),
            Center(
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: kMuted.withAlpha(90),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Expanded(
              child: StreamBuilder<List<JobOffer>>(
                stream: _offers,
                builder: (context, snap) {
                  // ТРИ СОСТОЯНИЯ, И ДВА ИЗ НИХ НЕЛЬЗЯ СВОДИТЬ К ОДНОМУ —
                  // это N133 в новом месте: два разных незнания, сведённые
                  // к одному ответу, на экране неразличимы.
                  //
                  //   ждём первой выдачи — доли секунды после открытия;
                  //   выдача пришла, документа нет — предложение УДАЛЕНО;
                  //   документ есть — обычная работа.
                  //
                  // В ленте первые два можно было рисовать одинаково: якорь
                  // без документа показывался обычным текстом, и человек
                  // ничего не терял. Здесь он **открыл лист нарочно** и
                  // ждёт содержимого — молчание читается как поломка
                  // приложения, а не как отсутствие предложения.
                  if (!snap.hasData) return _waiting();

                  final offer = snap.data!
                      .where((o) => o.id == widget.offerId)
                      .firstOrNull;
                  if (offer == null) return _deleted(context);

                  // ОТВЕТ ЕСТЬ — РИСУЕМ ОТВЕТ, А НЕ КАРТОЧКУ (25.08, макет
                  // владельца). Промежуточной карточки с «Cavaba bax» и
                  // «Cavab ver» между лентой и ответом больше нет: строка в
                  // ленте ведёт прямо сюда.
                  //
                  // **Дверь при этом осталась одна, и это условие того же
                  // решения владельца от 22.08.** Оно запрещало вести из
                  // ленты прямо в лист приёма — потому что тот пришлось бы
                  // питать СНИМКОМ и потерять живое обновление (N143). Здесь
                  // снимка нет: содержимое сменилось внутри двери, у того же
                  // потока.
                  //
                  // Состояние спрашивается у самого предложения, а не у
                  // `offerSheetFor`: та отвечает на «в каком состоянии
                  // человек и что ему предложено», и у неё другой
                  // потребитель — см. шапку файла.
                  return offer.state == OfferState.answered
                      ? _answer(offer)
                      : _card(offer);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Доли секунды до первой выдачи. **Тонкая полоска, а не заглушка:**
  /// заглушка на такой срок мигнёт и прочитается как рывок.
  Widget _waiting() => const Padding(
    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 20),
    child: Align(
      alignment: Alignment.topCenter,
      child: SizedBox(
        key: ValueKey('offer-sheet-waiting'),
        height: 2,
        child: LinearProgressIndicator(
          minHeight: 2,
          backgroundColor: kBg3,
          color: kGoldDim,
        ),
      ),
    ),
  );

  /// Предложения в базе нет — его удалили, пока лист был открыт либо до
  /// открытия.
  ///
  /// **ЛИСТ НЕ ЗАКРЫВАЕТСЯ САМ — решение автора 19.08.** Схлопнувшийся сам
  /// лист неотличим от промаха пальцем и от падения приложения: человек не
  /// узнает, что произошло, и попробует ещё раз. Он должен **прочитать и
  /// закрыть сам**.
  Widget _deleted(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Təklif silinib',
            key: ValueKey('offer-sheet-deleted'),
            style: TextStyle(color: kText, fontSize: 18),
          ),
          const SizedBox(height: 16),
          GestureDetector(
            key: const ValueKey('offer-sheet-close'),
            onTap: () => Navigator.of(context).maybePop(),
            child: Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 28),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: kGold,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text(
                'Bağla',
                style: TextStyle(
                  color: kOnGold,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  /// ВИД ОТВЕТА — то, что видят обе стороны, когда музыкант ответил.
  ///
  /// Кнопки раздаются ПО СТОРОНЕ, и раздача живёт здесь, а не в виджете:
  /// виджет рисует то, чему передан обработчик, и не знает про роли.
  ///
  ///   инициатору  — «Qəbul edirəm» (её же гасит `canAcceptAnswer` внутри,
  ///                 когда согласованных дней ноль) и «Təklifi geri götür»;
  ///   отвечавшему — «Cavabı dəyiş», та самая дверь в лист ответа, которой
  ///                 раньше была кнопка на карточке.
  ///
  /// **Отзыв не предлагается отвечавшему, и это не забывчивость:** отозвать
  /// предложение может только тот, кто его сделал. Правило то же и в
  /// `firestore.rules`.
  Widget _answer(JobOffer offer) {
    final viewerUid =
        widget.debugViewerUid ??
        FirebaseAuth.instance.currentUser?.uid ??
        '';
    final recipientUid = _recipientUid(offer, viewerUid);
    final viewerAnswered = viewerUid == recipientUid;

    return OfferAnswerView(
      offer: offer,
      viewerUid: viewerUid,
      recipientUid: recipientUid,
      recipientName: _nameOf(recipientUid, viewerUid),
      onAccept: viewerAnswered
          ? null
          : () => _writeAccept(
              offer,
              viewerUid,
              recipientUid,
              _nameOf(recipientUid, viewerUid),
            ),
      onWithdraw: viewerAnswered
          ? null
          : () async {
              await JobOfferRepository(FirebaseFirestore.instance).withdraw(
                chatId: widget.chatId,
                offerId: offer.id,
                myUid: viewerUid,
              );
            },
      onChangeAnswer: viewerAnswered
          ? () => _openAnswerSheet(offer, viewerUid)
          : null,
    );
  }

  Widget _card(JobOffer offer) {
    final viewerUid =
        widget.debugViewerUid ??
        FirebaseAuth.instance.currentUser?.uid ??
        '';
    final recipientUid = _recipientUid(offer, viewerUid);

    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 16),
      child: JobOfferCard(
        offer: offer,
        viewerUid: viewerUid,
        recipientUid: recipientUid,
        initiatorName: _nameOf(offer.createdBy, viewerUid),
        recipientName: _nameOf(recipientUid, viewerUid),
        // ШАГ 2 — ОТВЕТ МУЗЫКАНТА. Обработчик передаётся ТОЛЬКО тогда,
        // когда экрану ответа есть куда вести; кнопку рисует сама карточка
        // по своему условию `canAnswer && onOpenAnswer != null`.
        //
        // ПОЧЕМУ ЛИСТ ОТВЕТА ОТКРЫВАЕТСЯ ПОВЕРХ, А НЕ ВМЕСТО (решение
        // владельца 20.08): подробности («Ətraflı» — время, место,
        // заметки) остаются жить ЗДЕСЬ и никуда не переносятся. Перенести
        // их в лист ответа значило бы завести второе место, где рисуются
        // те же данные, — и они разойдутся, как разошлись `eventTime` с
        // `details` (N139). Порядок «сперва читаю, что предлагают, потом
        // отвечаю» — не лишнее нажатие, а сам смысл.
        //
        // Закрыв лист ответа, человек возвращается сюда, и здесь уже
        // виден его ответ: лист живёт потоком, а не снимком (N143).
        onOpenAnswer: () => _openAnswerSheet(offer, viewerUid),
        // ШАГ 3 — ПРИЁМ. `onAccept` СЮДА БОЛЬШЕ НЕ ПЕРЕДАЁТСЯ (25.08).
        //
        // Карточка рисует «Cavaba bax» по условию `canAccept && onAccept !=
        // null`, а `canAccept` истинен ровно в одном состоянии — `answered`.
        // В нём дверь теперь рисует не карточку, а сам ответ (`_answer`),
        // значит эта ветка карточки отсюда недостижима, и обработчик,
        // переданный ей, был бы обещанием без адресата.
        //
        // **Довод владельца от 22.08, стоявший здесь, снят макетом, а не
        // отменён.** Он звучал так: вести из ленты прямо в приём нельзя,
        // потому что лист пришлось бы питать снимком (потеря N143) и потому
        // что инициатор потерял бы «Ətraflı» — в листе приёма его не было.
        // Обе половины закрыты: содержимое сменилось ВНУТРИ двери, у того же
        // потока, а подробности в новом виде есть, и лежат они по дням.
        onWithdraw: () async {
          await JobOfferRepository(FirebaseFirestore.instance).withdraw(
            chatId: widget.chatId,
            offerId: offer.id,
            myUid: viewerUid,
          );
        },
        // onRecordVoice — отдельная работа: запись голоса к предложению
        // живёт в листе составления, и переносить её сюда без разбора
        // значило бы завести вторую копию (N129 про временные файлы).
      ),
    );
  }

  /// Открыть лист ответа и записать то, что человек отметил.
  ///
  /// **ЗАНЯТОСТЬ ПОДКЛЮЧЕНА 25.08** — до неё здесь стоял литерал
  /// `busyUnknown: true`, и вся неправда была в нём: он утверждал «мы не
  /// знаем» независимо от того, знаем мы или нет. Цена измерена на трубке
  /// 22.08: музыкант отметил день, на котором у него уже стоял «Toy · 15:00»,
  /// и узнал об этом ПОСЛЕ приёма, когда отказаться нельзя.
  ///
  /// Поставщик — `busyDaysProvider` (`features/job_offer/busy_days.dart`),
  /// один на этот лист и на лист набора дней; там же разобрано, чем «занятых
  /// нет» отличается от «ещё не загрузилось».
  ///
  /// **`Consumer` ВНУТРИ МОДАЛКИ ОБЯЗАТЕЛЕН, и это не украшение.** Модалка —
  /// отдельное поддерево, её `builder` от перестройки этого экрана не
  /// зависит. Возьми занятость снаружи, из `build` листа предложения, — и
  /// человек, открывший лист на секунду раньше, чем ответили потоки, остался
  /// бы с «не знаем» НАВСЕГДА, до закрытия и повторного открытия. Это N143 в
  /// третий раз: лист живого обновления даром не получает.
  void _openAnswerSheet(JobOffer offer, String viewerUid) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Consumer(
        builder: (context, ref, _) {
          final busy = ref.watch(busyDaysProvider(viewerUid));
          return JobOfferAnswerSheet(
            offer: offer,
            myUid: viewerUid,
            initiatorName: _nameOf(offer.createdBy, viewerUid),
            // Занятость одним объектом: дни, вечера и признак «знаем ли» —
            // один ответ, и разъехаться им нельзя.
            busy: busy,
            // ДВЕРЬ В КАРТОЧКУ ВЕЧЕРА — та же, что у всего остального
            // (`eventDetailRoute`, N90/N117): она одна на проект и сама
            // разбирает три случая — грузится, удалено, показываем.
            //
            // Открывается ПОВЕРХ листа, а не вместо: человек смотрит, чем
            // занят день, и возвращается к ответу, ничего не потеряв.
            onOpenBusyEvent: (eventId) => Navigator.of(context).push(
              eventDetailRoute(eventId: eventId, currentUid: viewerUid),
            ),
            // ДВЕРЬ В КАРТОЧКУ ВЕЧЕРА — та же, что у всего остального
            // (`eventDetailRoute`, N90/N117): она одна на проект и сама
            // разбирает три случая — грузится, удалено, показываем.
            //
            // Открывается ПОВЕРХ листа, а не вместо: человек смотрит, чем
            // занят день, и возвращается к ответу, ничего не потеряв.

            onSend: (picked) async {
              // ЗАКРЫВАЕМ ДО ЗАПИСИ, А НЕ ПОСЛЕ. Запись уходит в сеть, и
              // ждать её с открытым листом значит держать человека перед
              // экраном, который уже ничего не решает. Ответ он увидит на
              // листе предложения — тот обновится потоком сам (N143).
              Navigator.of(sheetContext).pop();
              await _writeAnswer(offer, viewerUid, picked);
            },
          );
        },
      ),
    );
  }

  // `_openAcceptSheet` СНЯТ 25.08 ВМЕСТЕ С ПРОМЕЖУТОЧНОЙ КАРТОЧКОЙ.
  //
  // Он открывал лист приёма ПОВЕРХ карточки, по кнопке «Cavaba bax». Теперь
  // ответ рисует сама дверь (`_answer` выше), и открывать поверх нечего:
  // строка в ленте ведёт прямо к ответу.
  //
  // Кнопка «Cavaba bax» при этом ЖИВА в самой карточке и покрыта тестом —
  // карточка просто больше не показывается в состоянии `answered`. Снимать
  // её оттуда не стали: карточка — отдельный виджет, её показывают и другие
  // места, и правило «после ответа инициатору предлагают посмотреть ответ»
  // от смены двери не изменилось.

  /// Настоящий путь записи принятия — `accept`, и только он.
  ///
  /// **ЧЕГО ЗЕЛЁНЫЙ ПРОГОН ПРО ЭТО НЕ ГОВОРИТ:** подделки Firestore в
  /// проекте нет (`fake_cloud_firestore`, `mocktail`, `mockito` — ни одной
  /// в `pubspec.yaml`), эмулятор есть только у `functions`. Тест доходит до
  /// этой границы и дальше не идёт. Значит зелёный означает «пачка собрана
  /// верно и дошла до писателя целой», а НЕ «пачка в базе».
  Future<void> _writeAccept(
    JobOffer offer,
    String viewerUid,
    String recipientUid,
    String recipientName,
  ) {
    final write = widget.debugWriteAccept;
    if (write != null) return write(offer);
    return JobOfferRepository(FirebaseFirestore.instance).accept(
      chatId: widget.chatId,
      offer: offer,
      myUid: viewerUid,
      recipientUid: recipientUid,
      recipientName: recipientName,
    );
  }

  /// Настоящий путь записи ответа — `setMyAnswer`, и только он.
  ///
  /// Правило на этот ход **уже выложено** (`firestore.rules:801-806`:
  /// не инициатор, `changedKeys().hasOnly(['answers'])`,
  /// `touchesOnlyOwnAnswer()`, `answerFitsOffer()`), новых не нужно.
  ///
  /// **Пустой `picked` передаётся как есть.** Ноль отмеченных дней — это
  /// ответ «не могу ни на один», а не отсутствие ответа; перехватить его
  /// здесь значило бы отнять у человека единственный способ отказаться.
  Future<void> _writeAnswer(
    JobOffer offer,
    String viewerUid,
    List<String> picked,
  ) {
    final write = widget.debugWriteAnswer;
    if (write != null) return write(picked);
    return JobOfferRepository(FirebaseFirestore.instance).setMyAnswer(
      chatId: widget.chatId,
      offerId: offer.id,
      myUid: viewerUid,
      picked: picked,
    );
  }

  /// Получатель — участник чата, который предложение НЕ создавал.
  ///
  /// Берётся из состава чата, а не из `answers`: до ответа ключей там нет,
  /// а имя получателя нужно уже тогда — строка «Teymurdan cavab
  /// gözlənilir» показывается именно до ответа.
  String _recipientUid(JobOffer offer, String viewerUid) {
    final members =
        (ref.watch(chatDataProvider(widget.chatId)).value?['members'] as List?)
            ?.whereType<String>()
            .toList() ??
        const [];
    final other = members.where((m) => m != offer.createdBy).toList();
    if (other.isNotEmpty) return other.first;
    // Состав ещё не пришёл: если смотрящий не создатель, получатель — он.
    return viewerUid == offer.createdBy ? '' : viewerUid;
  }

  /// Имя — из КАРТОЧКИ ПОЛЬЗОВАТЕЛЯ, а не из документа чата (N141).
  ///
  /// Поле `name` на чате пишет mugam-v2 с точки зрения того, кто чат
  /// создал, и больше не трогает: вторая сторона читает там своё имя, а в
  /// новых чатах — пустоту.
  String _nameOf(String uid, String viewerUid) {
    if (uid.isEmpty) return '';
    if (uid == viewerUid) {
      if (widget.debugViewerUid != null) return 'Mən';
      return FirebaseAuth.instance.currentUser?.displayName ?? '';
    }
    return ref.watch(currentUserProvider(uid)).value?.name ?? '';
  }
}
