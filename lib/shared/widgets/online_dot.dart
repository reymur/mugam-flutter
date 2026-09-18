import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/colors.dart';
import '../../firebase/models.dart';

/// ЗЕЛЁНЫЙ КРУЖОК «В СЕТИ» — И ЕГО ОБНОВЛЕНИЕ, В ОДНОМ МЕСТЕ.
///
/// **Решение владельца 18.09: один файл — и кружок, и его обновление
/// внутри. Вставил кружок — обновление пришло с ним само.**
///
/// --- ПОЧЕМУ ЭТО ОДИН ФАЙЛ, А НЕ ДВА ---
///
/// `User.isActuallyOnline` сравнивает `lastSeen` с `DateTime.now()`: ответ
/// зависит от ВРЕМЕНИ, а не только от данных. Поток Firestore перерисовывает
/// экран, лишь когда меняется документ, — от того, что просто идёт время, он
/// не сработает ни разу. Значит кружок замирает на том, каким был в миг
/// открытия: человек вышел минуту назад, а он всё зелёный.
///
/// Лечится это перерисовкой по таймеру. Пока таймер жил ОТДЕЛЬНО от кружка,
/// его надо было помнить и заводить руками у каждого, кто кружок рисует, — и
/// так появились **десять замерших кружков в восьми файлах** при одном живом
/// (замер 18.09, до этой работы:
/// `grep -rn "Timer.periodic" lib` против многострочного разбора
/// `isActuallyOnline … kGreen`). Забыть таймер было нечем: кружок без него
/// выглядит точно так же, как кружок с ним, и врёт только со временем.
///
/// Поэтому таймер переехал ВНУТРЬ. Забыть его теперь невозможно: он не
/// отдельный шаг, а свойство самого кружка.
///
/// --- ЧТО ЭТОТ ФАЙЛ НЕ РЕШАЕТ ---
///
/// Он не отвечает за то, ГДЕ кружок стоит. `Positioned` остаётся у зовущего,
/// потому что на главном экране кружок садится СЛЕВА, а во всех остальных
/// справа. Затащив расположение внутрь, пришлось бы принять переключатель
/// «а этому слева» — признак склейки двух дел (I58).

/// Как часто кружок пересчитывает себя.
///
/// **Одно число на весь проект, и это его смысл.** Возьми каждое место своё
/// — один и тот же человек гас бы в чате и горел в списке, и различить это
/// было бы нечем. Двадцать секунд: кружок гаснет в пределах десятков секунд
/// после протухания отметки, при этом перерисовка ПУСТАЯ — никаких новых
/// чтений из базы, а само сердцебиение и так пишется раз в 30 секунд
/// (`PresenceService._heartbeatInterval`).
const Duration onlineDotRefreshInterval = Duration(seconds: 20);

/// ОДИН БУДИЛЬНИК НА ВСЁ ПРИЛОЖЕНИЕ, а не по одному на кружок.
///
/// **Решение владельца 18.09.** На экране со списком кружков бывает два
/// десятка; двадцать личных таймеров не были бы бедой по нагрузке (двадцать
/// пустых перерисовок раз в двадцать секунд — это меньше работы, чем один
/// `setState` на весь экран, как было раньше), но дали бы две настоящие
/// беды: кружки считали бы каждый от своего рождения и мигали бы вразнобой,
/// и выключать их пришлось бы в двадцати местах.
///
/// Здесь будильник заводится, когда появляется ПЕРВЫЙ кружок, и снимается,
/// когда уходит ПОСЛЕДНИЙ. Зовущий об этом не знает и знать не должен.
class _OnlineDotTicker {
  _OnlineDotTicker._();

  static final _OnlineDotTicker instance = _OnlineDotTicker._();

  final Set<VoidCallback> _listeners = <VoidCallback>{};
  Timer? _timer;

  /// Сколько будильников заведено ЗА ВСЮ ЖИЗНЬ, а не сколько сейчас.
  ///
  /// Считается ради одного вердикта, и повод записан замером: проверка «сейчас
  /// заведён один» держится на поле `_timer`, а поле остаётся непустым и
  /// после того, как сам таймер умер вместе со своей зоной. Значит поле
  /// отвечает на «просили ли завести», а не на «сколько их живёт», и завести
  /// двадцать штук оно бы не заметило. Счётчик отвечает прямо.
  int timersStarted = 0;

  int get listenerCount => _listeners.length;

  bool get isRunning => _timer != null;

  void add(VoidCallback listener) {
    _listeners.add(listener);
    if (_timer == null) {
      _timer = Timer.periodic(onlineDotRefreshInterval, (_) => _beat());
      timersStarted++;
    }
  }

  /// Только для вердиктов: вернуть будильник в состояние «никого нет».
  ///
  /// Нужен потому, что будильник ОДИН НА ВСЁ ПРИЛОЖЕНИЕ — то самое свойство,
  /// ради которого он и заведён. В проде это благо, а в прогоне означает, что
  /// вердикты видят чужой след: у каждого теста своя зона времени, а поле
  /// `_timer` общее, и оставшийся от соседа таймер молча не даёт завести
  /// новый. Без сброса половина вердиктов проверяла бы порядок их
  /// объявления.
  void reset() {
    _timer?.cancel();
    _timer = null;
    _listeners.clear();
    timersStarted = 0;
  }

  void remove(VoidCallback listener) {
    _listeners.remove(listener);
    if (_listeners.isEmpty) {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _beat() {
    // Копия списка: подписчик вправе отписаться прямо в ответ на удар
    // (кружок уезжает с экрана), и правка множества на обходе уронила бы
    // весь удар — то есть все остальные кружки заодно.
    for (final listener in _listeners.toList()) {
      listener();
    }
  }
}

/// Сколько будильников сейчас заведено: 0 или 1, и никогда больше.
@visibleForTesting
int get onlineDotTimerCount => _OnlineDotTicker.instance.isRunning ? 1 : 0;

/// Сколько кружков сейчас слушает общий будильник.
@visibleForTesting
int get onlineDotListenerCount => _OnlineDotTicker.instance.listenerCount;

/// Сколько будильников заведено с начала прогона (или с последнего сброса).
@visibleForTesting
int get onlineDotTimersStarted => _OnlineDotTicker.instance.timersStarted;

/// Сбросить общий будильник перед вердиктом.
@visibleForTesting
void onlineDotResetForTest() => _OnlineDotTicker.instance.reset();

/// Подписаться на ТОТ ЖЕ удар, что слушают кружки.
///
/// Нужно вердикту, который доказывает, что удар вообще приходит: изнутри
/// кружка это не наблюдаемо, а два разных будильника доказывали бы разное.
@visibleForTesting
void onlineDotAddTestListener(VoidCallback listener) =>
    _OnlineDotTicker.instance.add(listener);

@visibleForTesting
void onlineDotRemoveTestListener(VoidCallback listener) =>
    _OnlineDotTicker.instance.remove(listener);

/// Кружок «в сети / не в сети».
///
/// Единственное место в проекте, где это рисуется. Нарисованный руками —
/// находка, а не вариант: сторож «кружок рисуется одним местом»
/// (`test/online_dot_test.dart`) краснеет на паре `kGreen`/`kMuted` в любом
/// другом файле `lib`.
class OnlineDot extends StatefulWidget {
  /// Пустой человек — серый кружок, а не пропавший.
  ///
  /// Пустоту принимает НАРОЧНО: в пяти местах из тринадцати живой
  /// пользователь ещё не приехал, и там стояло `user?.isActuallyOnline ==
  /// true` (счёт: `grep -rn "OnlineDot(user: " lib` и сверка типов у пяти
  /// зовущих). Теперь этого вопроса у зовущего нет.
  final User? user;

  /// Поперечник. Двенадцать — у десяти мест из тринадцати; десять — в списке
  /// чатов (кружок там не на фотографии); восемнадцать — на двух крупных
  /// портретах, профиле и карточке контакта. Десять плюс один плюс два — это
  /// и есть тринадцать.
  /// **Это параметры, а не приведение к одному виду: разный размер здесь
  /// осознан.**
  final double size;

  /// Цвет рамки — это цвет ФОНА под кружком: рамка отделяет его от фотографии.
  /// `null` — рамки нет вовсе (кружок стоит не на фото).
  final Color? borderColor;

  final double borderWidth;

  const OnlineDot({
    super.key,
    required this.user,
    this.size = 12,
    this.borderColor = kBg2,
    this.borderWidth = 2,
  });

  @override
  State<OnlineDot> createState() => _OnlineDotState();
}

class _OnlineDotState extends State<OnlineDot> {
  @override
  void initState() {
    super.initState();
    _OnlineDotTicker.instance.add(_onBeat);
  }

  @override
  void dispose() {
    _OnlineDotTicker.instance.remove(_onBeat);
    super.dispose();
  }

  void _onBeat() {
    // Перерисовка ПУСТАЯ: ничего не читает и ничего не просит. Вся её работа
    // — заставить `isActuallyOnline` сравниться со свежим `DateTime.now()`.
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final online = widget.user?.isActuallyOnline ?? false;
    final border = widget.borderColor;
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: online ? kGreen : kMuted,
        shape: BoxShape.circle,
        border: border == null
            ? null
            : Border.all(color: border, width: widget.borderWidth),
      ),
    );
  }
}
