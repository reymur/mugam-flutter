import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' hide User;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/job_offer/job_offer.dart';
import '../../../core/job_offer/job_offer_repository.dart';
import '../../../core/theme/colors.dart';
import '../../../firebase/firestore_service.dart';
import '../widgets/job_offer_card.dart';

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
// РАЗВОДКИ ПО ЛИСТАМ ВНУТРИ НЕТ И НЕ НУЖНО: сюда ведёт `offerSheetFor`
// только в тех клетках, где «Qəbul edirəm» не предлагается (инициатор до
// ответа и закрытый раунд у обеих сторон). Ответ и приём — другие листы.

class JobOfferSheet extends ConsumerStatefulWidget {
  const JobOfferSheet({
    super.key,
    required this.chatId,
    required this.offerId,
    this.debugOffers,
    this.debugViewerUid,
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

                  return _card(offer);
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
