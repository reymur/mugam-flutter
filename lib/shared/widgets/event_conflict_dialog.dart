import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/agreements/event_edit.dart';
import '../../core/theme/colors.dart';
import '../../core/time/az_date_format.dart';
import '../../firebase/models.dart';
import 'event_conflict_banner.dart';

// Диалог «на это время у вас уже есть мероприятие» — один на календарь
// (agreements_screen.dart → _EventFormModal) и на лист предложения работы
// (chat/screens/job_offer_date_sheet.dart).
//
// Вынесен из agreements_screen.dart, когда проверку конфликта завели в
// предложении работы. Второй такой диалог не изобретался намеренно:
// вопрос у человека один и тот же («у меня занято, что делать»), и три
// ответа на него обязаны быть одинаковыми в обоих местах — иначе одно и
// то же затруднение выглядит по-разному в зависимости от того, откуда в
// него пришли.
//
// Возвращает через `Navigator.pop` [EventConflictChoice], `null` при
// закрытии мимо кнопок.
//
// Показ самого конфликтующего мероприятия НЕ живёт здесь: он тянет за
// собой карточку события и экран подробностей, которые остаются частью
// экрана договоров. Поэтому 'view' — это ответ диалога, а что по нему
// открыть, решает вызывающая сторона (в календаре — свой приватный экран,
// в чате — `agreementConflictEventRoute`).

/// Ответ диалога: что человек выбрал и о каком из мероприятий речь.
///
/// Мероприятие возвращается вместе с ответом, а не берётся вызывающей
/// стороной заново: при нескольких занятых мероприятиях в дне «то самое»
/// знает только диалог — человек указал его переключателем.
class EventConflictChoice {
  const EventConflictChoice(this.action, this.event);

  /// 'view' — посмотреть мероприятие;
  /// 'new' — это отдельное мероприятие, сохранить как есть;
  /// 'replace' — главное действие, и оно РАЗНОЕ у трёх вызывающих:
  ///   - календарь, выбрано СВОЁ мероприятие — переписать его тем, что
  ///     сейчас в форме («Mövcud tədbiri dəyiş»); тот же документ, тот же
  ///     id;
  ///   - календарь, выбрано ЧУЖОЕ — выйти из него, чтобы оно перестало
  ///     занимать мой календарь («Təqvimimdən sil»); у остальных остаётся;
  ///   - лист «İş təklif et» (`canReplace: false`) — всё равно отправить
  ///     предложение; замещать там пока нечего.
  /// Имя ответа осталось одно, потому что развилка живёт у вызывающего:
  /// диалог сообщает выбор, а не совершает поступок.
  final String action;

  /// Мероприятие, выбранное переключателем (при одном — оно же).
  final PersonalEvent event;
}

class EventConflictDialog extends StatefulWidget {
  /// Все мероприятия, мешающие выбранному времени, по возрастанию времени.
  ///
  /// Раньше сюда передавалось ОДНО, взятое как `.first` из нескольких, —
  /// то есть диалог называл произвольное из них, а человек не мог ни
  /// увидеть остальные, ни указать, о каком спрашивает. Тот же класс, что
  /// B29 (галочки показывали случайного участника из-за `firstWhere`).
  final List<PersonalEvent> conflicts;

  /// Кто смотрит. Нужен ровно для одного: заменить можно только СВОЁ
  /// мероприятие.
  final String currentUid;

  /// Умеет ли вызывающий экран вообще заменять. Календарь умеет — он
  /// создаёт мероприятие прямо сейчас, и «заменить» значит переписать
  /// выбранное. Лист «İş təklif et» не умеет: он отправляет предложение,
  /// а мероприятие появится только когда вторая сторона согласится, —
  /// заменять там пока нечего, и «Əvəz et» значит «всё равно отправить».
  final bool canReplace;

  const EventConflictDialog({
    super.key,
    required this.conflicts,
    required this.currentUid,
    this.canReplace = false,
  });

  @override
  State<EventConflictDialog> createState() => _EventConflictDialogState();
}

class _EventConflictDialogState extends State<EventConflictDialog> {
  late PersonalEvent _selected = widget.conflicts.first;

  /// Переписать можно только СВОЁ мероприятие. Это не осторожность, а
  /// граница возможного: `firestore.rules` разрешает `update` и `delete` в
  /// `personalEvents` исключительно владельцу
  /// (`resource.data.ownerUid == request.auth.uid`), и сервер откажет,
  /// что бы ни было нажато в приложении.
  ///
  /// Кнопку при этом НЕ гасим. Владелец 03.08: чужое мероприятие может
  /// быть уже неактуально, и запирать из-за него человека неправильно.
  /// Поэтому на чужом «Əvəz et» сохраняет своё как есть, а чужое остаётся
  /// на месте — и об этом сказано прямо, чтобы кнопка не выглядела
  /// сделавшей больше, чем сделала.
  ///
  /// Договор, где человек лишь участник, заканчивается не заменой, а
  /// отменой по согласию обеих сторон — это отдельный путь.
  bool get _selectedIsMine => _selected.ownerUid == widget.currentUid;

  /// Имя главной кнопки — по поступку, а не одно на все случаи (N39/N40).
  ///
  /// «Əvəz et» стояла на трёх разных действиях сразу: правке своего, сносе
  /// чужого и — при правке существующего — уничтожении постороннего
  /// мероприятия. Теперь у каждого поступка своё имя, и берётся оно из
  /// общего правила (`core/agreements/event_edit.dart`), а не пишется
  /// здесь строкой: разойтись имени и поступку негде, если имя приходит
  /// оттуда же, откуда решение.
  ///
  /// Лист «İş təklif et» (`canReplace: false`) сюда не попадает: там эта
  /// кнопка значит «всё равно отправить предложение», замещать нечего —
  /// мероприятия ещё не существует. Её имя оставлено прежним намеренно,
  /// отдельной находкой: правка сегодняшнего дня — про календарь.
  String get _mainActionLabel => widget.canReplace
      ? conflictAnswerLabel(
          _selectedIsMine
              ? ConflictAnswer.editExisting
              : ConflictAnswer.leaveForeign,
        )
      : 'Əvəz et';

  void _pop(String action) =>
      Navigator.of(context).pop(EventConflictChoice(action, _selected));

  @override
  Widget build(BuildContext context) {
    final many = widget.conflicts.length > 1;
    // Предупреждение показывается только там, где замена вообще возможна
    // (календарь). В листе предложения «Əvəz et» и так значит «всё равно
    // отправить» — там нечего замещать.
    final warnNotMine = widget.canReplace && !_selectedIsMine;
    return Dialog(
      // Прозрачный фон и своя коробка: иначе тень легла бы ПОД
      // непрозрачную подложку Dialog и её не было бы видно. Без тени окно
      // читалось как приклеенное к форме под ним — замечено владельцем на
      // устройстве 03.08.
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: Container(
        decoration: BoxDecoration(
          color: kBg2,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: kGold.withAlpha(70)),
          boxShadow: [
            // Два слоя: золотое свечение поднимает окно над формой, чёрная
            // тень даёт ему вес. Одним золотым получается ореол без
            // глубины, одной чёрной — на почти чёрном фоне не видно
            // ничего.
            BoxShadow(
              color: kGold.withAlpha(60),
              blurRadius: 34,
              spreadRadius: 2,
            ),
            const BoxShadow(
              color: Color(0xCC000000),
              blurRadius: 26,
              offset: Offset(0, 12),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '⚠️ Bu tarixdə tədbir var',
                style: GoogleFonts.nunito(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: kRed,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              // При нескольких — список с переключателем, прокручиваемый:
              // в дне их может быть сколько угодно, и окно не должно
              // вылезать за экран.
              if (many)
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.34,
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final e in widget.conflicts) _choice(e),
                      ],
                    ),
                  ),
                )
              else
                _card(widget.conflicts.first),
              if (warnNotMine) ...[
                const SizedBox(height: 10),
                // Светло-красным, а не `kMuted`: это предупреждение о
                // необратимом действии, и серо-коричневым по чёрному оно
                // читалось как примечание мелким шрифтом — замечено
                // владельцем на устройстве 03.08. Тот же тон, что у
                // заголовка плашки конфликта: одно значение — один цвет.
                const Text(
                  'Bu tədbir sizin deyil — yalnız sizin təqvimdən silinəcək',
                  style: TextStyle(
                    color: kWarnTitle,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    height: 1.35,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => _pop('view'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: kGold,
                        side: const BorderSide(color: kGold),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: const Text('Bax'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Кнопки во всю ширину, по одной в строке.
              //
              // Раньше две нижние стояли рядом, и это держалось на том, что
              // «Əvəz et» — два коротких слова. Имя, называющее поступок,
              // короткому не обязано: «Mövcud tədbiri dəyiş» в половину
              // ширины окна не помещается и обрезалось бы многоточием —
              // то есть ровно та часть, ради которой имя и менялось,
              // пропала бы с экрана.
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => _pop('replace'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kGold,
                    foregroundColor: const Color(0xFF1A0E00),
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: Text(
                    _mainActionLabel,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => _pop('new'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kBg3,
                    foregroundColor: kMuted,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                      side: const BorderSide(color: kBorder),
                    ),
                  ),
                  child: const Text('Yeni tədbir'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Карточка единственного мероприятия — вид, который здесь был всегда.
  Widget _card(PersonalEvent conflict) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: kBg3,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: kGold.withAlpha(60)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (conflict.type.isNotEmpty) ...[
          Text(
            conflict.type,
            style: GoogleFonts.nunito(
              color: kGold,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
          const Divider(color: kBorder, height: 1),
          const SizedBox(height: 10),
        ],
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (conflict.location.isNotEmpty) ...[
              const Text('📍', style: TextStyle(fontSize: 13)),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  conflict.location,
                  style: const TextStyle(
                    color: kText,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (conflict.date.isNotEmpty) const SizedBox(width: 12),
            ],
            if (conflict.date.isNotEmpty) ...[
              const Text('🕐', style: TextStyle(fontSize: 13)),
              const SizedBox(width: 4),
              Text(
                '${fmtEventDate(conflict.date)}  '
                '${fmtEventTime(conflict.date)}',
                style: const TextStyle(
                  color: kText,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ],
    ),
  );

  /// Строка списка с переключателем — когда мешает не одно мероприятие.
  /// Нажимается вся строка, а не только кружок переключателя.
  Widget _choice(PersonalEvent e) {
    final on = identical(e, _selected) || e.id == _selected.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _selected = e),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
          decoration: BoxDecoration(
            color: on ? kGold.withAlpha(28) : kBg3,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: on ? kGold : kBorder,
              width: on ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 20,
                height: 20,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: on ? kGold : kMuted,
                    width: 2,
                  ),
                ),
                child: on
                    ? Container(
                        width: 10,
                        height: 10,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: kGold,
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (e.type.isNotEmpty)
                      Text(
                        e.type,
                        style: GoogleFonts.nunito(
                          color: on ? kGold : kText,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (fmtEventTime(e.date).isNotEmpty) fmtEventTime(e.date),
                        if (e.location.isNotEmpty) e.location,
                      ].join(' · '),
                      style: const TextStyle(
                        color: kText,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
