// ДЕТАЛИ ОДНОГО ДНЯ — время, место, одежда и голосовое.
//
// **У КАЖДОГО ДНЯ СВОИ, ОБЩИХ ПОЛЕЙ НЕТ** (макет `mugam-14-secim`, решение
// автора 14.08). Прежняя редакция листа держала одно время на всё
// предложение; звали на пять вечеров — время у всех выходило одно, хотя в
// жизни оно у каждого своё.

/// Что вписано в один день. Пустые строки означают «не вписано» — это НЕ то
/// же самое, что «вписано пустым»: различие держит копирование ниже.
class DayDetails {
  const DayDetails({
    this.time = '',
    this.location = '',
    this.dress = '',
    this.voicePath,
    this.voiceWaveform = const [],
    this.voiceUrl,
  });

  final String time;
  final String location;
  final String dress;

  /// Путь к записи ВО ВРЕМЕННОЙ ПАПКЕ, а не готовый адрес в хранилище.
  ///
  /// Голос грузится только при «Göndər», вместе с документом: запись
  /// относится к конкретному дню, а дня в данных до отправки ещё нет.
  /// Закрыл лист не отправив — файл удаляется, и запись пропадает. Это
  /// решение, а не недосмотр: висящий в хранилище файл без предложения
  /// нельзя ни найти, ни удалить.
  final String? voicePath;

  final List<int> voiceWaveform;

  /// Адрес записи в хранилище — появляется ТОЛЬКО при отправке, когда файл
  /// загружен. До этого его нет, и это не пропуск: пока предложения не
  /// существует, загруженный файл был бы мусором без владельца.
  final String? voiceUrl;

  /// **ДВА ПОЛЯ ПРО ГОЛОС, А НЕ ОДНО, и спрашивать надо оба.** `voicePath`
  /// есть только у ЧЕРНОВИКА (запись лежит во временной папке, ещё не
  /// отправлена), `voiceUrl` — только у ПРОЧИТАННОГО ИЗ БАЗЫ (файл уже в
  /// хранилище, временного пути на этом телефоне нет и не будет).
  ///
  /// До 19.08 здесь стоял один `voicePath`, и на черновике это было верно —
  /// другого состояния у деталей тогда и не бывало. С появлением читателя
  /// (N139) день, где записано только голосовое, приходил бы из базы
  /// «пустым» и не показывался вовсе.
  bool get isEmpty =>
      time.isEmpty &&
      location.isEmpty &&
      dress.isEmpty &&
      voicePath == null &&
      voiceUrl == null;

  bool get isNotEmpty => !isEmpty;

  DayDetails copyWith({
    String? time,
    String? location,
    String? dress,
    String? voicePath,
    List<int>? voiceWaveform,
  }) => DayDetails(
    time: time ?? this.time,
    location: location ?? this.location,
    dress: dress ?? this.dress,
    voicePath: voicePath ?? this.voicePath,
    voiceWaveform: voiceWaveform ?? this.voiceWaveform,
    voiceUrl: voiceUrl,
  );

  /// Тот же день, но с уже загруженной записью.
  DayDetails withUploadedUrl(String? url) => DayDetails(
    time: time,
    location: location,
    dress: dress,
    voicePath: voicePath,
    voiceWaveform: voiceWaveform,
    voiceUrl: url,
  );

  Map<String, dynamic> toMap() => {
    'time': time,
    'location': location,
    'dress': dress,
    if (voiceUrl != null) 'voiceUrl': voiceUrl,
    if (voiceUrl != null && voiceWaveform.isNotEmpty)
      'voiceWaveform': voiceWaveform,
  };

  /// Обратный ход к `toMap`. **Его не было вовсе до 19.08** — писатель
  /// существовал, читателя не существовало, и записанное в базу никто не
  /// доставал обратно (N139).
  ///
  /// **`voicePath` здесь не восстанавливается и восстановлен быть не
  /// может:** это путь во временной папке ТОГО телефона, где записывали.
  /// Из базы приходит `voiceUrl` — адрес в хранилище. Два разных поля для
  /// двух разных вещей, и подставлять одно вместо другого нельзя.
  ///
  /// Чтение защитное, а не жёсткое (I49): документ пишет наш клиент, но
  /// правкой руками в консоли сюда может лечь что угодно, а пустая строка
  /// вместо падения здесь безвредна — поле необязательное по смыслу.
  static DayDetails fromMap(Map<String, dynamic> map) => DayDetails(
    time: map['time'] as String? ?? '',
    location: map['location'] as String? ?? '',
    dress: map['dress'] as String? ?? '',
    voiceUrl: map['voiceUrl'] as String?,
    voiceWaveform: (map['voiceWaveform'] as List<dynamic>? ?? const [])
        .whereType<num>()
        .map((n) => n.toInt())
        .toList(growable: false),
  );
}

/// Сколько дней затронет копирование — считается ДО нажатия, потому что
/// число называется человеку в вопросе: «Bu detallar N günə köçürüləcək».
///
/// Считаются все выбранные дни, кроме дня-источника. Дни с уже вписанными
/// деталями **входят в счёт**: их поля тоже будут затронуты — те, что у
/// источника заполнены.
int copyTargetCount({
  required Iterable<String> selectedDays,
  required String fromDay,
}) => selectedDays.where((d) => d != fromDay).length;

/// Копирование деталей одного дня в остальные выбранные.
///
/// **ПУСТОЕ ПОЛЕ НЕ ЗАТИРАЕТ ЗАПОЛНЕННОЕ, ПОТОМУ ЧТО КОПИРУЕТСЯ ТО, ЧТО
/// ЧЕЛОВЕК ВПИСАЛ, А НЕ ТО, ЧЕГО ОН НЕ ВПИСАЛ.**
///
/// Сказано словами, а не оставлено поведению, потому что следующий увидит
/// «копирование, которое копирует не всё» и «починит» его на полное
/// замещение — оно выглядит правильнее и проще. Не чинить.
///
/// Довод: самый частый случай — **время общее, место у каждого своё**.
/// Работодатель ставит 20:00 первому дню и жмёт «во все»; у третьего дня
/// уже вписан свой зал. Полное замещение стёрло бы этот зал пустотой
/// источника — молча, потому что поле выглядит одинаково пустым и до, и
/// после. Пять раз в этом проекте чинили ровно такую тихую потерю.
///
/// Голосовое копируется, если оно есть у источника: путь один и тот же,
/// файл при отправке грузится один раз.
Map<String, DayDetails> copyDetailsToDays({
  required Map<String, DayDetails> details,
  required String fromDay,
  required Iterable<String> selectedDays,
}) {
  final source = details[fromDay];
  if (source == null || source.isEmpty) return details;

  final next = Map<String, DayDetails>.from(details);
  for (final day in selectedDays) {
    if (day == fromDay) continue;
    final was = next[day] ?? const DayDetails();
    next[day] = DayDetails(
      // Каждое поле переносится ТОЛЬКО если у источника оно заполнено.
      time: source.time.isEmpty ? was.time : source.time,
      location: source.location.isEmpty ? was.location : source.location,
      dress: source.dress.isEmpty ? was.dress : source.dress,
      voicePath: source.voicePath ?? was.voicePath,
      voiceWaveform: source.voicePath == null
          ? was.voiceWaveform
          : source.voiceWaveform,
      voiceUrl: source.voicePath == null ? was.voiceUrl : source.voiceUrl,
    );
  }
  return next;
}

/// Все временные файлы записей, которые лист держит. Нужны, чтобы удалить
/// их разом при закрытии без отправки.
///
/// Множество, а не список: одна запись после копирования принадлежит
/// нескольким дням, а удалять файл дважды незачем.
Set<String> voiceFilesIn(Map<String, DayDetails> details) => details.values
    .map((d) => d.voicePath)
    .whereType<String>()
    .toSet();
