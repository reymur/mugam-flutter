import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/theme/colors.dart';
import '../../../firebase/models.dart';

// Живая строка присутствия в плашке переговоров «İş təklif et».
//
// Отдельным виджетом, а не куском плашки, по двум причинам. Во-первых,
// значение меняется САМО, без действий человека и без новых записей в
// базу: «был 5 минут назад» через минуту должно стать «6 минут назад».
// Значит нужен собственный тик, и он не должен перерисовывать плашку
// целиком. Во-вторых, оформление этой строки — работа второго этапа (см.
// docs/job-offer-plan.md), и она должна меняться, не задевая механику.
//
// ЧТО ЗДЕСЬ ЗАМЕНИЛОСЬ И ПОЧЕМУ. Прежняя строка отвечала на вопрос
// «посмотрел ли собеседник» по `lastReadAt`. После правки A3 эта отметка
// обновляется только когда пришло новое сообщение, требующее расписки, —
// а предложение работы не сообщение, а поле документа чата. То есть
// получатель мог сидеть в чате, смотреть на предложение и нажимать
// кнопки, а инициатор навсегда видел «hələ baxmayıb». Замер 02.08:
// предложение 22:39:28, получатель нажал кнопку в 22:40:54, его
// `lastReadAt` при этом остался 22:06:08.
//
// До A3 строка работала случайно — на отметке ВИЗИТА, том самом классе,
// который выпалывался весь тот день. Поэтому она переведена на
// присутствие: `activeChatId` отвечает «где человек», `lastSeen` — «жив
// ли признак», и оба вопроса честные.
//
// Формулировки намеренно мягкие. Присутствие врёт не дольше 60 секунд
// (убийство приложения, сворачивание, обрыв сети — замерено трижды
// 02.08), поэтому «çatdadır» («в чате») допустимо, а «смотрит прямо
// сейчас» было бы ложью в пределах этого окна.
class NegotiationPresenceLine extends StatefulWidget {
  const NegotiationPresenceLine({
    super.key,
    required this.chatId,
    required this.otherUser,
    required this.otherTypingAt,
    required this.waitingForDate,
  });

  final String chatId;
  final User? otherUser;
  // Отметка «печатает» собеседника. Живёт 5 с: явного «перестал печатать»
  // не существует, есть только более свежая отметка, поэтому истечение —
  // единственный признак окончания.
  final DateTime? otherTypingAt;
  // Получатель нажал «Razıyam» до того, как появилась дата. Перекрывает
  // всё остальное: это призыв к действию инициатору, а не сведение о
  // собеседнике.
  final bool waitingForDate;

  @override
  State<NegotiationPresenceLine> createState() =>
      _NegotiationPresenceLineState();
}

class _NegotiationPresenceLineState extends State<NegotiationPresenceLine> {
  Timer? _tick;

  // Достаточно часто, чтобы «сейчас в чате» гасло вскоре после ухода
  // собеседника, и достаточно редко, чтобы не будить экран впустую.
  // Сетевых обращений не делает: пересчитывает уже полученные значения
  // относительно текущего времени.
  static const _tickInterval = Duration(seconds: 10);

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(_tickInterval, (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  // НИЖНЯЯ ГРАНИЦА ЭТОЙ СТУПЕНИ РАВНА ШИРИНЕ ОКНА СВЕЖЕСТИ — это свойство
  // конструкции, а не пропущенный случай.
  //
  // Пока отметка свежа, показывается «в приложении»; «N назад» может
  // появиться только после того, как она протухла, а к этому моменту
  // прошло уже целое окно. При ударе раз в 30 с окно равно 60 с, значит
  // первое достижимое значение — «1 dəq əvvəl».
  //
  // Ступень «indicə» (меньше минуты) отсюда убрана: она была недостижима
  // ни при какой частоте и вводила в заблуждение при чтении кода. Увидели
  // это на устройстве 02.08 — при окне 120 с строка перескакивала с «в
  // приложении» сразу на «2 dəq əvvəl».
  //
  // Если кто-то соберётся вернуть нижнюю ступень: сначала придётся
  // сузить окно свежести, а его ширина задана двойным интервалом
  // сердцебиения — иначе одно пропущенное биение будет выбрасывать
  // человека, сидящего в чате.
  String _agoText(Duration since) {
    if (since.inMinutes < 60) return '${since.inMinutes} dəq əvvəl';
    if (since.inHours < 24) return '${since.inHours} saat əvvəl';
    return '';
  }

  @override
  Widget build(BuildContext context) {
    if (widget.waitingForDate) {
      // Прежний текст был «🤝 cavab gözləyir» — «жду ответа». Читалось
      // ровно наоборот: получатель уже ответил тапом, и ход за
      // инициатором. Строка теперь называет, чего ждут и от кого.
      return const _LineText('📅 tarix sizdən gözlənilir');
    }

    final typingAt = widget.otherTypingAt;
    final isTyping =
        typingAt != null &&
        DateTime.now().difference(typingAt) < const Duration(seconds: 5);
    if (isTyping) return const _LineText('✍️ yazır…');

    final other = widget.otherUser;
    if (other == null) return const SizedBox.shrink();

    if (other.isViewingChat(widget.chatId)) {
      return const _LineText('👀 çatdadır');
    }
    if (other.isPresenceFresh) {
      return const _LineText('📱 tətbiqdədir');
    }

    final seen = other.lastSeen;
    // Отметки нет вовсе — мы не знаем о человеке НИЧЕГО, и это не то же
    // самое, что «давно не появлялся». Строка исчезает целиком, потому
    // что отсутствие утверждения честнее утверждения об отсутствии: тот
    // же принцип, по которому весь день вычищались места, где «не знаю»
    // выдавалось за ответ (N13, N14), только здесь — прямо на экране.
    //
    // Случай достижим: так выглядят документы, созданные mugam-v2 (он
    // ставит `online`, но сердцебиения не ведёт), и любой только что
    // зарегистрированный человек до первого запуска приложения.
    if (seen == null) return const SizedBox.shrink();
    final ago = _agoText(DateTime.now().difference(seen.toDate()));
    if (ago.isNotEmpty) return _LineText('🕐 $ago');
    return const _LineText('⏳ çoxdan görünmür');
  }
}

class _LineText extends StatelessWidget {
  const _LineText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: const TextStyle(color: kMuted, fontSize: 13));
}
