import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/audio/voice_recording_session.dart';
import '../../core/theme/colors.dart';

// ---------------------------------------------------------------------------
// ЗАПИСЬ ГОЛОСА УДЕРЖАНИЕМ — ОДНА НА ЧАТ И ЛИСТ ВЫХОДА (решение владельца 13.09)
// ---------------------------------------------------------------------------
// Дублирования быть не должно: до 13.09 показ записи жил дважды — в строке
// ввода чата и в листе «Gələ bilmirəm». Общий сеанс (`VoiceRecordingSession`)
// был и раньше; продублирован был слой над ним — удержание, время, смахивание,
// замок, отказ микрофона. Он и вынесен сюда.
//
// ЗДЕСЬ ТОЛЬКО ЗАПИСЬ. Хвосты — у зовущих, через [VoiceHoldController.onRecorded]:
// чат отправляет запись сообщением, лист выхода возвращает файл. Файл не знает,
// куда уходит запись, и знать не должен: появись здесь «если чат» — склеены
// два дела (I58).
//
// ПОВЕДЕНИЕ ПЕРЕНЕСЕНО ИЗ ЧАТА КАК ЕСТЬ — пороги, размеры, цвета, слова, отклик
// вибрацией. Чат работает на трубках сегодня, и перенос не место для улучшений.
//
// ПОРЯДОК ПЕРЕВОДА — вариант Б владельца: общий файл → лист выхода → проверка →
// чат → снять старое. Довод: чат трогается последним, на проверенном файле.

/// Состояние и ходы записи удержанием.
///
/// Разметку не рисует: кнопку и полосу рисуют [VoiceHoldMicButton] и
/// [VoiceRecordingStrip], а раскладку строки — зовущий (у чата она своя, у
/// листа своя).
class VoiceHoldController extends ChangeNotifier {
  VoiceHoldController({
    required this._recorder,
    required this.onRecorded,
    this.onNoPermission,
    this.onError,
  });

  /// Смахнул влево дальше этого — отмена. Значение из чата, как было.
  static const double cancelThreshold = -80.0;

  /// Повёл вверх дальше этого — замок. Значение из чата, как было.
  static const double lockThreshold = -60.0;

  final VoiceRecorder _recorder;

  /// ХВОСТ ЗОВУЩЕГО: что сделать с готовой записью. Зовётся только с записью —
  /// случайный тычок (сеанс отдал `null`) хвоста не будит.
  final Future<void> Function(VoiceRecording recording) onRecorded;

  /// Разрешения на микрофон нет. Слова — у зовущего.
  final VoidCallback? onNoPermission;

  /// Сеанс записи отказал при остановке. Куда сказать — решает зовущий.
  final void Function(Object error, StackTrace stack)? onError;

  bool _isRecording = false;
  bool _isLocked = false;
  double _dragX = 0.0;
  double _dragY = 0.0;
  // Raw pointer position at press-down for the record button — needed to
  // compute drag deltas manually since raw PointerMoveEvents report absolute
  // position, not an offset-from-origin like LongPressMoveUpdateDetails used to.
  Offset? _pointerStart;
  final Stopwatch _stopwatch = Stopwatch();
  Timer? _timer;
  String _elapsedLabel = '0:00';
  bool _disposed = false;

  bool get isRecording => _isRecording;
  bool get isLocked => _isLocked;
  double get dragX => _dragX;
  double get dragY => _dragY;

  /// Время записи — «m:ss», как в чате.
  String get elapsedLabel => _elapsedLabel;

  Future<void> pointerDown(Offset position) {
    _pointerStart = position;
    return _start();
  }

  void pointerMove(Offset position) {
    if (!_isRecording || _isLocked || _pointerStart == null) return;
    final delta = position - _pointerStart!;
    _dragX = delta.dx;
    _dragY = delta.dy;
    _notify();
    if (_dragX < cancelThreshold) {
      cancel();
    } else if (_dragY < lockThreshold) {
      lock();
    }
  }

  Future<void> pointerUp() async {
    if (_isLocked) return;
    if (_isRecording) await stop();
  }

  void pointerCancel() {
    if (_isLocked) return;
    if (_isRecording) cancel();
  }

  Future<void> _start() async {
    // Fires before anything else, including the permission check — a tactile
    // response the instant the finger presses down reinforces the immediate
    // visual feedback, same idea as WhatsApp's own haptic tap on record start.
    unawaited(HapticFeedback.mediumImpact());
    final outcome = await _recorder.start(
      // Зовётся сразу после разрешения и ДО стартового звука — ровно та
      // точка, где показ обязан подняться мгновенно. Настоящий захват
      // отложен на длину звука и ничего здесь не ждёт.
      onArmed: () {
        if (_disposed) return;
        _isRecording = true;
        _stopwatch
          ..reset()
          ..start();
        _timer?.cancel();
        _timer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (_disposed) return;
          final s = _stopwatch.elapsed.inSeconds;
          _elapsedLabel = '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
          _notify();
        });
        _notify();
      },
    );
    if (outcome == VoiceStartOutcome.noPermission && !_disposed) {
      onNoPermission?.call();
    }
  }

  /// Остановить и отдать запись зовущему.
  ///
  /// Показ опускается СРАЗУ, до ожидания сеанса — мгновенный отклик на
  /// отпускание, как в WhatsApp/Telegram; всё, что ждёт native-запись, идёт
  /// следом.
  Future<void> stop() async {
    // Lighter than the start haptic — a distinct "released" feel, fired
    // before anything else for the same instant-response reason.
    unawaited(HapticFeedback.lightImpact());
    if (!_isRecording) return;
    _lower();
    try {
      final recording = await _recorder.stopAndFinish();
      if (recording == null) return;
      await onRecorded(recording);
    } catch (e, st) {
      onError?.call(e, st);
    }
  }

  /// Отмена без записи — смахивание или корзина при замке.
  void cancel() {
    if (!_isRecording) return;
    _lower();
    unawaited(_recorder.cancel());
  }

  void lock() {
    _isLocked = true;
    _dragX = 0.0;
    _dragY = 0.0;
    _notify();
  }

  void _lower() {
    _dragX = 0.0;
    _dragY = 0.0;
    _isLocked = false;
    _isRecording = false;
    _elapsedLabel = '0:00';
    _stopwatch.stop();
    _timer?.cancel();
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

/// Кнопка микрофона с пузырём замка над ней.
///
/// [busy] — данные хвоста, а не состояние записи: чат рисует на кнопке
/// крутилку, пока голосовое уходит в очередь отправки.
class VoiceHoldMicButton extends StatelessWidget {
  const VoiceHoldMicButton({
    super.key,
    required this.controller,
    this.busy = false,
  });

  final VoiceHoldController controller;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final recording = controller.isRecording;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Listener(
              behavior: HitTestBehavior.opaque,
              // Raw pointer events, not a GestureDetector/
              // LongPressGestureRecognizer — any gesture recognizer (even with
              // a short duration) still has to go through gesture-arena
              // resolution before firing, which is itself a perceptible delay
              // on top of whatever duration is configured (confirmed
              // on-device: shortening the recognizer's duration to 120ms still
              // felt laggy). Listener fires directly on the hardware
              // touch-down/up with no recognition/arena step at all, matching
              // WhatsApp's true-instant response.
              onPointerDown: (event) => controller.pointerDown(event.position),
              onPointerMove: (event) => controller.pointerMove(event.position),
              onPointerUp: (_) => controller.pointerUp(),
              onPointerCancel: (_) => controller.pointerCancel(),
              child: Container(
                // Bigger than the visual circle, per Apple/Material
                // minimum-touch-target guidance — the tappable region around
                // the drawn circle is generous. Kept modest since in the chat
                // the camera button sits only 4px away.
                width: 52,
                height: 52,
                alignment: Alignment.center,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 100),
                  curve: Curves.easeOut,
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: recording ? kRed : kBg3,
                    shape: BoxShape.circle,
                    border: Border.all(color: recording ? kRed : kBorder),
                  ),
                  child: busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: kGold,
                          ),
                        )
                      : Icon(
                          Icons.mic,
                          color: recording ? Colors.white : kGold,
                          size: 22,
                        ),
                ),
              ),
            ),
            // Lock icon above mic button — only shown during unlocked recording.
            if (recording && !controller.isLocked)
              Positioned(
                top: -48,
                left: 0,
                right: 0,
                child: Opacity(
                  opacity: (1.0 +
                          controller.dragY /
                              VoiceHoldController.lockThreshold.abs())
                      .clamp(0.0, 1.0),
                  child: Column(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: kBg3,
                          shape: BoxShape.circle,
                          border: Border.all(color: kBorder),
                        ),
                        child: const Icon(
                          Icons.lock_outline,
                          color: kMuted,
                          size: 18,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Kilid',
                        style: TextStyle(color: kMuted, fontSize: 9),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Полоса идущей записи: пульсирующая точка, время, «Sürüşdür».
///
/// Показывается зовущим ТОЛЬКО пока запись идёт — поэтому пульсация заводится
/// при появлении полосы и гаснет вместе с ней.
class VoiceRecordingStrip extends StatefulWidget {
  const VoiceRecordingStrip({super.key, required this.controller});

  final VoiceHoldController controller;

  @override
  State<VoiceRecordingStrip> createState() => _VoiceRecordingStripState();
}

class _VoiceRecordingStripState extends State<VoiceRecordingStrip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
  )..repeat(reverse: true);

  late final Animation<double> _opacity = Tween<double>(
    begin: 0.3,
    end: 1.0,
  ).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut));

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Container(
        height: 44,
        decoration: BoxDecoration(
          color: kBg3,
          borderRadius: BorderRadius.circular(24),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            AnimatedBuilder(
              animation: _opacity,
              builder: (_, _) => Opacity(
                opacity: _opacity.value,
                child: const Icon(Icons.circle, color: kRed, size: 10),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              controller.elapsedLabel,
              style: const TextStyle(
                color: kRed,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            if (!controller.isLocked)
              Opacity(
                opacity: (1.0 +
                        controller.dragX /
                            VoiceHoldController.cancelThreshold.abs())
                    .clamp(0.0, 1.0),
                child: const Row(
                  children: [
                    Icon(Icons.chevron_left, color: kMuted, size: 16),
                    Text(
                      'Sürüşdür',
                      style: TextStyle(color: kMuted, fontSize: 12),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
