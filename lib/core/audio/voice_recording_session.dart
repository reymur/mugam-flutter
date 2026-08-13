import 'dart:async';

import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../native_sound_effect.dart';
import 'audio_session_gate.dart';

// ОБЩАЯ ЗАПИСЬ ГОЛОСА — работа 2, вынесена 13.08 из состояния экрана чата.
//
// ЭТОТ КЛАСС НЕ ЗНАЕТ НИ ПРО ЧАТ, НИ ПРО ПРЕДЛОЖЕНИЕ РАБОТЫ, НИ ПРО
// FIRESTORE, И НЕ ДОЛЖЕН УЗНАТЬ. Он принимает нажатие и отдаёт наружу файл
// с волной. Всё. Ни `chatId`, ни `offerId`, ни отправки, ни очереди, ни
// сообщения — ничего из этого сюда не дописывается.
//
// **Требование владельца, записанное дословно 13.08:** «скажи в коде, что он
// ничего не знает про чат и про предложение — принимает результат наружу и
// всё. Иначе следующий пропишет туда отправку в чат „для удобства“, и мы
// получим четвёртую копию с другой стороны.»
//
// Четвёртая копия «с другой стороны» — это не ещё одна запись голоса, а
// РАЗВЕТВЛЕНИЕ внутри общей: стоит появиться здесь одному `if` про чат, и
// следующему месту понадобится второй, третьему третий. Снаружи это
// выглядит как один общий вход, а внутри — три склеенных дела.
// **Сторож на это стоит: `test/voice_recording_test.dart` не пускает сюда
// ни слова про чат, предложение и базу.**
//
// ГРАНИЦА, РАДИ КОТОРОЙ ЭТО ВООБЩЕ ВЫНОСИЛОСЬ (I58): здесь живёт СЕАНС
// ЗАПИСИ и только он — разрешение, отложенный старт, замер громкости,
// остановка, отбрасывание случайного тычка. Того, ЧТО ДЕЛАТЬ С ФАЙЛОМ,
// здесь нет и быть не должно: у трёх мест назначение разное — сообщение в
// переписке, голосовое к предложению работы, причина в «Gələ bilmirəm».
//
// **Переключатель «а этому не отправлять» внутри этого класса запрещён.**
// Он и был бы признаком, что сюда затащили два разных дела: общей остаётся
// только часть ДО расхождения. Сеанс отдаёт файл и волну и на этом кончается.
//
// ЧТО ОСТАЛОСЬ В ЭКРАНЕ ЧАТА И ПОЧЕМУ ЭТО НЕ НЕДОДЕЛКА. В экране остались
// пульсация, подпись со временем, смахивание с замком, спиннер отправки и
// сам хвост отправки. Это не копия записи и не остаток выноса: показ у
// каждого из трёх мест свой (у карточки предложения микрофон стоит внутри
// карточки, а не в строке ввода, и смахивания там нет вовсе), а назначение
// у всех трёх разное по определению. Общим сделано ровно то, что у трёх
// мест совпадает, — и ни строкой больше.
//
// Мгновенный отклик на нажатие сохранён через `onArmed` (см. `start`),
// потому что порядок «разрешение → показ → отложенный настоящий старт» был
// выверен на телефоне и его нельзя менять заодно с выносом.

/// Чем кончилась попытка начать запись. Показывать отказ — дело зовущего:
/// у экрана чата это `SnackBar`, у карточки предложения будет своё место.
enum VoiceStartOutcome {
  /// Сеанс открыт: настоящий захват начнётся после [_startBeepGuard].
  started,

  /// Разрешения на микрофон нет. На iOS первый вызов его же и запрашивает,
  /// поэтому этот исход означает именно отказ, а не «ещё не спрашивали».
  noPermission,

  /// Предыдущий сеанс ещё сворачивается. `AudioRecorder` — один общий
  /// ресурс и двух сеансов разом не держит.
  busy,
}

/// Готовая запись: файл на диске и волна для показа.
class VoiceRecording {
  const VoiceRecording({required this.filePath, required this.waveform});

  final String filePath;
  final List<int> waveform;
}

class VoiceRecordingSession {
  VoiceRecordingSession({AudioRecorder? recorder})
    : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;

  // record_start.wav's own real length (measured: 500ms) plus a small
  // margin for the audio session's category switch (playback -> record)
  // and the speaker's acoustic tail — the actual native recorder doesn't
  // start until this elapses, so the mic can never physically pick up the
  // start beep. Показ у зовущего поднимается мгновенно (см. `onArmed`),
  // откладывается только настоящий захват.
  static const Duration _startBeepGuard = Duration(milliseconds: 550);

  // Below this, a release is treated as an accidental tap rather than a
  // deliberate voice message (WhatsApp-style) — see [stopAndFinish]'s
  // discard branch. Compared against the moment real capture began, NOT
  // physical tap-down — real capture only begins after _startBeepGuard
  // (550ms) plus AVAudioRecorder's own hardware startup, which on-device
  // measured closer to ~850ms total (an earlier 300ms threshold — assuming
  // a ~650-720ms offset — required a ~1.1-1.2s physical hold to send,
  // confirming the real offset is larger than that initial estimate).
  // 150ms of real content is recalibrated against the measured ~850ms
  // offset: a genuine ~1s physical hold (1000ms - ~850ms ≈ 150ms of real
  // content) just clears this, while a truly instant tap-release (~0ms real
  // content, since release still happens well before the deferred start
  // resolves) reliably doesn't.
  static const Duration _minRecordingDuration = Duration(milliseconds: 150);

  /// Сколько столбиков в волне. Столько же было у экрана чата до выноса,
  /// и менять его здесь нельзя иначе как всем трём местам разом: волна
  /// уходит в документ сообщения и показывается по сохранённому числу.
  static const int waveformBars = 40;

  bool _busy = false;
  bool _active = false;
  bool _disposed = false;
  String? _path;
  DateTime? _captureStartedAt;
  Future<void>? _startFuture;
  StreamSubscription<Amplitude>? _amplitudeSub;
  final List<double> _rawAmplitudes = [];

  /// Идёт ли сеанс. Это НЕ признак для показа — показом каждый зовущий
  /// заведует сам; здесь оно нужно затем, чтобы отпускание пальца до
  /// настоящего старта не пыталось остановить незапущенное.
  bool get isActive => _active;

  /// Открывает сеанс. [onArmed] зовётся сразу после того, как разрешение
  /// получено, и ДО стартового звука и отложенного настоящего старта —
  /// в этой точке зовущий поднимает свой показ, чтобы отклик на нажатие
  /// остался мгновенным.
  Future<VoiceStartOutcome> start({void Function()? onArmed}) async {
    if (_busy || _disposed) return VoiceStartOutcome.busy;
    _busy = true;
    // hasPermission() also requests permission on first call on iOS
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      _busy = false;
      return VoiceStartOutcome.noPermission;
    }
    _active = true;
    _captureStartedAt = null;
    _rawAmplitudes.clear();
    onArmed?.call();
    unawaited(NativeSoundEffect.play('record_start'));
    _startFuture = _reallyStart();
    await _startFuture;
    return VoiceStartOutcome.started;
  }

  // Отдельным методом, чтобы остановка и отмена могли дождаться именно
  // этого шага (через `_startFuture`) прежде, чем просить native-запись
  // остановиться: без такого ожидания очень быстрый тычок (короче
  // _startBeepGuard) звал бы stop() раньше, чем отработал start().
  Future<void> _reallyStart() async {
    final dir = await getTemporaryDirectory();
    _path = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await Future.delayed(_startBeepGuard);
    // Палец отпустили (или сеанс снесли) прежде, чем захват успел начаться.
    // Раньше здесь стояло `!mounted || !_isRecording` — то же самое, только
    // признаки были у экрана.
    if (_disposed || !_active) return;
    await _recorder.start(
      RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 128000,
        sampleRate: 44100,
        // record sets its own AVAudioSessionCategoryOptions outright
        // (replacing, not merging with, whatever main.dart's shared
        // audio_session config set) — duckOthers has to be requested here
        // explicitly too, alongside the package's existing defaults, or
        // background audio wouldn't duck during recording specifically.
        iosConfig: const IosRecordConfig(
          categoryOptions: [
            IosAudioCategoryOption.defaultToSpeaker,
            IosAudioCategoryOption.allowBluetooth,
            IosAudioCategoryOption.allowBluetoothA2DP,
            IosAudioCategoryOption.duckOthers,
          ],
        ),
      ),
      path: _path!,
    );
    _captureStartedAt = DateTime.now();
    _amplitudeSub = _recorder
        .onAmplitudeChanged(const Duration(milliseconds: 100))
        .listen((amp) => _rawAmplitudes.add(amp.current));
  }

  /// Закрывает сеанс и отдаёт запись. `null` означает «отдавать нечего» —
  /// случайный тычок короче [_minRecordingDuration] либо запись, которой
  /// не оказалось на диске.
  ///
  /// Зовётся ПОСЛЕ того, как зовущий уже опустил свой показ: всё, что ждёт
  /// native-запись, идёт фоном и мгновенности отклика не задерживает.
  Future<VoiceRecording?> stopAndFinish() async {
    _active = false;
    try {
      await _startFuture;
      await _amplitudeSub?.cancel();
      // Мерится от настоящего начала захвата, а НЕ от нажатия: между ними
      // лежит _startBeepGuard, и счёт от нажатия засчитал бы эту паузу как
      // «записанное», отчего мгновенный тычок проходил бы порог, не
      // захватив ничего. Захват, который так и не начался, считается нулём
      // и порога не проходит — это и требуется.
      final startedAt = _captureStartedAt;
      final captured = startedAt == null
          ? Duration.zero
          : DateTime.now().difference(startedAt);
      if (captured < _minRecordingDuration) {
        // Случайный тычок — отбрасываем, не показывая ни звука остановки,
        // ни отправки. Отклик на отпускание у зовущего уже отработал, так
        // что тишина здесь не читается как зависание.
        await _recorder.stop();
        unawaited(deactivateAudioSession());
        return null;
      }
      // Звук — до ожидания stop(), а не после: микрофон перестаёт слушать в
      // тот же миг, когда позвали stop(), а Future разрешается только когда
      // кодировщик дописал файл, и это заметная задержка.
      unawaited(NativeSoundEffect.play('record_stop'));
      final path = await _recorder.stop();
      unawaited(deactivateAudioSession());
      if (path == null) return null;
      return VoiceRecording(
        filePath: path,
        waveform: downsampleWaveform(_rawAmplitudes, waveformBars),
      );
    } finally {
      _busy = false;
    }
  }

  /// Закрывает сеанс без записи — смахивание в сторону.
  Future<void> cancel() async {
    _active = false;
    try {
      await _startFuture;
      await _amplitudeSub?.cancel();
      await _recorder.stop();
      unawaited(deactivateAudioSession());
    } finally {
      _busy = false;
    }
  }

  void dispose() {
    _disposed = true;
    _active = false;
    unawaited(_amplitudeSub?.cancel());
  }
}

// Collapses the raw dBFS samples captured during recording (one every
// 100ms via onAmplitudeChanged) into a fixed number of bars for the
// waveform display — WhatsApp shows the same bar count regardless of
// clip length. Takes the peak within each bucket rather than the
// average, matching how a waveform visually reads (loud transients
// stay visible instead of getting smoothed away). floorDb/ceilDb are a
// rough estimate of quiet-room/loud-speech mic levels.
//
// Вынесена наружу класса намеренно: это единственная часть записи, которую
// можно прогнать тестом без телефона и без native-записи.
List<int> downsampleWaveform(List<double> raw, int targetCount) {
  if (raw.isEmpty) return List.filled(targetCount, 0);
  const floorDb = -50.0;
  const ceilDb = -5.0;
  return List.generate(targetCount, (b) {
    final start = (b * raw.length / targetCount).floor();
    final end = (((b + 1) * raw.length / targetCount).ceil()).clamp(
      start + 1,
      raw.length,
    );
    final peak = raw.sublist(start, end).reduce((x, y) => x > y ? x : y);
    final norm =
        ((peak.clamp(floorDb, ceilDb) - floorDb) / (ceilDb - floorDb) * 100)
            .round();
    return norm.clamp(0, 100);
  });
}
