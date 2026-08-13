import 'package:flutter/material.dart';

import '../../../core/job_offer/job_offer.dart';
import '../../../core/theme/colors.dart';
import '../../../core/time/az_date_format.dart';

// КАРТОЧКА ПРЕДЛОЖЕНИЯ — ВИДЖЕТ ВНУТРИ ЛЕНТЫ СООБЩЕНИЙ, не плашка поверх
// экрана. Макеты `docs/design/mugam-9-teklif` и `mugam-10-secim` показывают
// это прямо: над карточкой и под ней стоят обычные реплики.
//
// Довод не про вид, а про историю: у карточки в ленте есть `seq`, значит она
// листается обычной прокруткой и достаётся существующей подкачкой старых
// сообщений. Через месяц человек её найдёт. Нынешняя плашка поверх ленты
// потому в истории и не лежит.
//
// ЧТО ПРЕДЛОЖЕНО ДЕЛАТЬ — решает НЕ ЭТОТ ФАЙЛ, а `offerCardActions`
// (`core/job_offer/job_offer.dart`), и у неё 24 теста. Здесь только показ.
// Разделение не косметическое: порядок ветвей в разметке механически не
// выразим и сторожа на него в проекте нет ни одного (I32), а цена этого уже
// заплачена — N125, тринадцать часов в проде при 569 зелёных тестах.
//
// ЗАПРЕТ, КОТОРЫЙ ЛЕГЧЕ ВСЕГО НАРУШИТЬ ПО ДОБРОТЕ: не добавлять сюда
// собственных условий вида «а этому показать, а этому нет». Появилось
// новое различие — оно едет в `offerCardActions`, где его видит тест.

class JobOfferCard extends StatefulWidget {
  const JobOfferCard({
    super.key,
    required this.offer,
    required this.viewerUid,
    required this.recipientUid,
    required this.initiatorName,
    required this.recipientName,
    this.busyDates = const {},
    this.onSendAnswer,
    this.onAccept,
    this.onWithdraw,
    this.onRecordVoice,
  });

  final JobOffer offer;
  final String viewerUid;

  /// Чей ответ показывать. Сегодня получатель один — это граница, названная
  /// автором: «один документ — один ответ». Звать нескольких одним
  /// предложением — другая работа, а не правка этой.
  final String recipientUid;

  final String initiatorName;
  final String recipientName;

  /// Дни, на которых у смотрящего уже есть работа. Помечаются `məşğulsan`
  /// **БЕЗ ИМЕНИ ЗАНЯВШЕГО** — чужая работа не показывается, и это
  /// приватность, а не краткость (`docs/design/README.md`).
  final Set<String> busyDates;

  final void Function(List<String> picked)? onSendAnswer;
  final VoidCallback? onAccept;
  final VoidCallback? onWithdraw;
  final VoidCallback? onRecordVoice;

  @override
  State<JobOfferCard> createState() => _JobOfferCardState();
}

class _JobOfferCardState extends State<JobOfferCard> {
  late Set<String> _picked = widget.offer.pickedBy(widget.viewerUid).toSet();
  bool _detailsOpen = false;
  bool _daysExpanded = false;

  /// Сколько строк спрятано сворачиванием. Считается в `_dayRows` и
  /// читается строкой «yenə N gün» под списком.
  int _hiddenDaysCount = 0;

  /// Порог сворачивания — решение автора 14.08 («пять-семь дат, дальше
  /// строка с раскрытием»), взята середина. Довод автора: карточка в ленте
  /// не должна занимать три экрана, человек листает переписку.
  ///
  /// На телефоне число НЕ проверялось (I50): шесть строк по ~46 пикселей —
  /// около 280, плюс шапка и подвал. Подвинуть — правка одной строки.
  static const int _collapseThreshold = 6;

  @override
  void didUpdateWidget(JobOfferCard old) {
    super.didUpdateWidget(old);
    // Правка пришла с другого телефона — подхватываем её, но НЕ затираем
    // ею то, что человек уже наотмечал и не отправил.
    final incoming = widget.offer.pickedBy(widget.viewerUid).toSet();
    final previous = old.offer.pickedBy(widget.viewerUid).toSet();
    if (!setEquals(incoming, previous)) {
      _picked = incoming;
    }
  }

  static bool setEquals(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  @override
  Widget build(BuildContext context) {
    final offer = widget.offer;
    final actions = offerCardActions(offer, widget.viewerUid);
    final isInitiator = offer.roleOf(widget.viewerUid) == OfferRole.initiator;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
      decoration: BoxDecoration(
        color: kBg3,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kBorder),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _header(offer, isInitiator),
            style: const TextStyle(
              color: kMuted,
              fontSize: 11,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _title(offer),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          ..._dayRows(offer, actions.canPickDays),
          if (_hiddenDaysCount > 0)
            InkWell(
              key: const ValueKey('offer-days-expand'),
              onTap: () => setState(() => _daysExpanded = true),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'yenə $_hiddenDaysCount gün',
                  style: const TextStyle(color: kGold, fontSize: 13),
                ),
              ),
            ),
          if (_declinedLine(offer) != null) ...[
            const SizedBox(height: 6),
            Text(
              _declinedLine(offer)!,
              // Мелко и серо, под крупным «3 gün»: отказ показан, но не
              // выделен — он не поступок, а остаток выбора.
              style: const TextStyle(color: kMuted, fontSize: 12),
            ),
          ],
          if (_hasDetails(offer)) _details(offer),
          const SizedBox(height: 10),
          _footer(offer, actions, isInitiator),
        ],
      ),
    );
  }

  String _header(JobOffer offer, bool isInitiator) {
    switch (offer.state) {
      case OfferState.withdrawn:
        return azUpperCase('təklif geri götürüldü');
      case OfferState.accepted:
        return azUpperCase('təklif qəbul edildi');
      case OfferState.answered:
        return azUpperCase('${widget.recipientName} cavab verdi');
      case OfferState.awaitingAnswer:
        return isInitiator
            ? azUpperCase('təklif göndərildi')
            : azUpperCase('${widget.initiatorName} təklif edir');
    }
  }

  String _title(JobOffer offer) {
    // После ответа крупным числом идёт то, на что человек СОГЛАСИЛСЯ, а не
    // то, сколько предлагали: «3 gün» под «5 gün · Toy».
    if (offer.hasAnswered(widget.recipientUid)) {
      final n = offer.pickedBy(widget.recipientUid).length;
      return '$n gün';
    }
    return '${offer.dates.length} gün · ${offer.eventType}';
  }

  /// СПИСОК СТРОИТСЯ ИЗ `offer.dates` И БОЛЬШЕ НИОТКУДА.
  ///
  /// Это не удобство, а вторая половина правила: отметить день, которого в
  /// предложении нет, запрещено (`answerFitsOffer` в `firestore.rules`), и
  /// на экране такой возможности не должно быть тоже. Взяв дни из календаря,
  /// из ответа или из чего-нибудь ещё, мы получили бы квадратик, который
  /// отказывает молча — человеку это видно как «нажал и ничего».
  List<Widget> _dayRows(JobOffer offer, bool canPick) {
    final answered = offer.hasAnswered(widget.recipientUid);
    final picked = offer.pickedBy(widget.recipientUid).toSet();

    // После ответа перечисляются ТОЛЬКО отмеченные дни; неотмеченные уходят
    // в мелкую строку «10, 12 — yox» под заголовком.
    final all = answered && !canPick
        ? offer.dates.where(picked.contains).toList()
        : offer.dates;

    // ДЛИННЫЙ СПИСОК СВОРАЧИВАЕТСЯ — НО ТОЛЬКО НЕРЕДАКТИРУЕМЫЙ, и эта
    // неравномерность намеренная.
    //
    // Предела на число дней нет нигде (ни в правилах, ни в листе, ни
    // здесь — решение автора 14.08), значит месяц целиком законен: тридцать
    // строк по ~46 пикселей — три-четыре экрана внутри ленты.
    //
    // У ТОГО, КТО ОТМЕЧАЕТ, СПИСОК ВСЕГДА ПОЛНЫЙ — не «раскрывается по
    // тапу», а РАЗВЁРНУТ ПО УСТРОЙСТВУ, и разница здесь существенная.
    //
    // Раскрытие по тапу означало бы, что человек может ответить, не увидев
    // части дней: свернул обратно (или не разворачивал вовсе), отметил
    // видимые шесть и нажал «Göndər» — а неотмеченные значат «нет», то
    // есть он молча отказался от того, чего не видел. Свёрнутый список у
    // отмечающего — не теснота, а потерянный ответ.
    //
    // Признак в коде — `!canPick`: сворачивается только то, что нельзя
    // тронуть. Появится новое состояние с отметками — оно получит полный
    // список само, без правки этого места.
    final collapsible = !canPick && all.length > _collapseThreshold;
    final shown = collapsible && !_daysExpanded
        ? all.take(_collapseThreshold).toList()
        : all;
    _hiddenDaysCount = collapsible && !_daysExpanded
        ? all.length - _collapseThreshold
        : 0;

    return shown.map((iso) {
      final busy = widget.busyDates.contains(iso);
      final on = _picked.contains(iso);
      final row = Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (canPick) ...[
              _checkbox(on),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _fmtDay(iso),
                    style: const TextStyle(color: Colors.white, fontSize: 15),
                  ),
                  if (busy)
                    const Text(
                      // БЕЗ ИМЕНИ ЗАНЯВШЕГО — чужая работа не показывается.
                      'məşğulsan',
                      style: TextStyle(color: kMuted, fontSize: 12),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
      if (!canPick) return row;
      return InkWell(
        key: ValueKey('offer-day-$iso'),
        onTap: () => setState(() {
          if (!_picked.remove(iso)) _picked.add(iso);
        }),
        child: row,
      );
    }).toList();
  }

  Widget _checkbox(bool on) => Container(
    width: 22,
    height: 22,
    decoration: BoxDecoration(
      color: on ? kGold : Colors.transparent,
      borderRadius: BorderRadius.circular(5),
      border: Border.all(color: on ? kGold : kMuted, width: 1.5),
    ),
    child: on
        ? const Icon(Icons.check, size: 16, color: kOnGold)
        : const SizedBox.shrink(),
  );

  String? _declinedLine(JobOffer offer) {
    final declined = offer.declinedBy(widget.recipientUid);
    if (declined.isEmpty) return null;
    final days = declined.map((iso) {
      final d = DateTime.tryParse(iso);
      return d == null ? iso : '${d.day}';
    }).join(', ');
    return '$days — yox';
  }

  bool _hasDetails(JobOffer offer) =>
      offer.eventTime.isNotEmpty ||
      offer.eventLocation.isNotEmpty ||
      offer.eventNotes.isNotEmpty;

  Widget _details(JobOffer offer) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 4),
        InkWell(
          onTap: () => setState(() => _detailsOpen = !_detailsOpen),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Ətraflı',
                // Свёрнута — приглушённая, раскрыта — золотая.
                style: TextStyle(
                  color: _detailsOpen ? kGold : kMuted,
                  fontSize: 13,
                ),
              ),
              Icon(
                _detailsOpen ? Icons.expand_less : Icons.expand_more,
                size: 18,
                color: _detailsOpen ? kGold : kMuted,
              ),
            ],
          ),
        ),
        if (_detailsOpen) ...[
          if (offer.eventTime.isNotEmpty) _detailRow('Saat', offer.eventTime),
          if (offer.eventLocation.isNotEmpty)
            _detailRow('Yer', offer.eventLocation),
          if (offer.eventNotes.isNotEmpty) _detailRow('Qeyd', offer.eventNotes),
        ],
      ],
    );
  }

  Widget _detailRow(String name, String value) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(name, style: const TextStyle(color: kMuted, fontSize: 13)),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
        ),
      ],
    ),
  );

  Widget _footer(JobOffer offer, OfferCardActions actions, bool isInitiator) {
    if (actions.isReadOnly) {
      return Text(
        offer.state == OfferState.withdrawn
            ? 'Təklif geri götürüldü'
            : 'Təklif qəbul edildi',
        style: const TextStyle(color: kMuted, fontSize: 13),
      );
    }

    final children = <Widget>[];

    if (actions.canRecordVoice) {
      children.add(
        InkWell(
          key: const ValueKey('offer-voice'),
          onTap: widget.onRecordVoice,
          child: Container(
            width: 36,
            height: 36,
            decoration: const BoxDecoration(
              color: kGoldDim,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.mic, size: 18, color: kGold),
          ),
        ),
      );
      children.add(const SizedBox(width: 12));
    }

    if (actions.canSend) {
      children.add(
        Expanded(
          child: _goldButton(
            key: const ValueKey('offer-send'),
            label: 'Göndər',
            // ОТМЕТКА НУЛЯ ДНЕЙ — ЗАКОННЫЙ ОТВЕТ, и кнопка при пустом
            // списке ОБЯЗАНА работать. Серая кнопка здесь означала бы, что
            // ответить «не могу ни на один день» нельзя вовсе, — а
            // отдельного отказа в этой работе нет: неотмеченные дни и
            // значат «нет». Условия на `_picked.isNotEmpty` тут не будет.
            onTap: () => widget.onSendAnswer?.call(_picked.toList()..sort()),
          ),
        ),
      );
    } else if (actions.canAccept) {
      children.add(
        Expanded(
          child: _goldButton(
            key: const ValueKey('offer-accept'),
            label: 'Qəbul edirəm',
            onTap: widget.onAccept,
          ),
        ),
      );
    } else if (isInitiator) {
      children.add(
        Expanded(
          child: Text(
            '${widget.recipientName}un cavabı gözlənilir',
            style: const TextStyle(color: kMuted, fontSize: 13),
          ),
        ),
      );
    }

    final row = Row(children: children);
    if (!actions.canWithdraw) return row;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row,
        const SizedBox(height: 8),
        InkWell(
          key: const ValueKey('offer-withdraw'),
          onTap: widget.onWithdraw,
          child: const Text(
            'Təklifi geri götür',
            style: TextStyle(color: kMuted, fontSize: 12),
          ),
        ),
      ],
    );
  }

  Widget _goldButton({
    required Key key,
    required String label,
    required VoidCallback? onTap,
  }) => InkWell(
    key: key,
    onTap: onTap,
    child: Container(
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: kGold,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: kOnGold,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );

  String _fmtDay(String iso) {
    final d = DateTime.tryParse(iso);
    return d == null ? iso : fmtDayHeader(d);
  }
}
