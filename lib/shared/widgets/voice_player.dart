import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/audio/audio_session_gate.dart';

// ---------------------------------------------------------------------------
// ОБЩИЙ ПРОИГРЫВАТЕЛЬ ГОЛОСОВОЙ ЗАПИСИ — вынесен из экрана чата 13.09
// ---------------------------------------------------------------------------
// Зачем: голос причины выхода (решение владельца 13.09) проигрывается на
// карточке вечера, а проигрыватель в приложении был один — приватный
// `_VoiceMessagePlayer` в `chat_screen.dart`. Решение владельца: «проигрывание
// общим виджетом», второго проигрывателя не заводить.
//
// ЧТО ЗДЕСЬ, А ЧТО У ЗОВУЩЕГО — разделено по задаче (I58). Здесь —
// воспроизведение: плеер, волна с перемоткой, позиция, «одновременно звучит
// одна запись». У зовущего — всё, что про переписку: цвета «прочитано /
// прослушано», аватар отправителя, строка времени с галочками. Они приходят
// сюда ДАННЫМИ (цвета и виджеты по краям), а не переключателем «я в чате»:
// появись здесь `if (чат)` — склеены два дела.
//
// Поведение воспроизведения перенесено из чата без изменений, вместе с
// разборами причуд iOS ниже — они проверены на трубках и в пересказе не
// нуждаются.

// Ensures only one voice message plays at a time app-wide, mirroring
// WhatsApp: starting a new one pauses whatever was previously playing,
// regardless of which chat it's in. A plain singleton rather than Riverpod
// state — this coordinates transient in-memory playback, not app data, and
// only ever has at most one interested reader (the currently active
// player) at a time.
//
// С 13.09 координатор общий и для голоса причины выхода: запись на карточке
// вечера и голосовое в чате не звучат разом.
class VoiceMessageCoordinator {
  VoiceMessageCoordinator._();
  static final instance = VoiceMessageCoordinator._();

  _VoicePlayerState? _active;

  void _starting(_VoicePlayerState player) {
    if (_active != null && _active != player) {
      _active!._pauseFromCoordinator();
    }
    _active = player;
  }

  void _stopped(_VoicePlayerState player) {
    if (_active == player) _active = null;
  }

  // Pauses whatever voice message is currently playing, without a new one
  // taking its place — called when opening VideoPlayerScreen, so the
  // video's own AVPlayer/AVAudioSession doesn't activate while a voice
  // message's just_audio session is still active. Two audio sessions
  // fighting over the shared iOS AVAudioSession was the suspected cause
  // of a real, watchdog-confirmed main-thread hang (SpringBoard's
  // "scene-update" watchdog fired after 5s) reproduced by scrubbing the
  // video progress bar right after opening a video message.
  void pauseActive() {
    _active?._pauseFromCoordinator();
  }
}

/// Проигрыватель одной голосовой записи — по ссылке или с диска.
///
/// [localFilePath] сильнее [audioURL]: запись, ещё не загруженная (или только
/// что сделанная и прослушиваемая перед отправкой), играет с диска.
///
/// Цвета и края приходят от зовущего. [leading] и [trailing] — виджеты по
/// краям строки (у чата — аватар отправителя с той или другой стороны);
/// [sideExtent] — их ширина вместе с отступом, чтобы позиция и [footerTrailing]
/// встали под кнопкой и волной, а не под краем.
class VoicePlayer extends StatefulWidget {
  const VoicePlayer({
    super.key,
    this.audioURL,
    this.localFilePath,
    this.waveform,
    required this.accentColor,
    required this.labelColor,
    required this.playedColor,
    required this.dotColor,
    this.thickWave = false,
    this.leading,
    this.trailing,
    this.sideExtent = 0,
    this.footerTrailing = const SizedBox.shrink(),
    this.caption = '',
    this.onListened,
    this.width = 230,
  });

  final String? audioURL;
  final String? localFilePath;
  final List<int>? waveform;

  /// Кнопка «играть/пауза».
  final Color accentColor;

  /// Подпись позиции и текст [caption].
  final Color labelColor;

  /// Проигранная часть волны.
  final Color playedColor;

  /// Точка перемотки.
  final Color dotColor;

  /// Толстые столбики волны.
  final bool thickWave;

  final Widget? leading;
  final Widget? trailing;
  final double sideExtent;
  final Widget footerTrailing;
  final String caption;
  final VoidCallback? onListened;
  final double width;

  @override
  State<VoicePlayer> createState() => _VoicePlayerState();
}

class _VoicePlayerState extends State<VoicePlayer> {
  late final AudioPlayer _player;
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _listenedFired = false;
  // Set right before the coordinator pauses this player to hand off to a
  // different message. Suppresses the deactivateAudioSession() call below
  // for that one transition — the incoming player is about to activate the
  // shared session again immediately, and racing our own deactivate against
  // its activate was silencing audio while still visually "playing" (same
  // race as the loop/alternation bug, triggered here by fast play-switching
  // between messages instead of natural completion).
  bool _pausedByCoordinator = false;
  // Set once this player has reached natural completion at least once.
  // iOS just_audio has a known quirk (confirmed on-device, matching a
  // documented package issue) where resuming playback after completion
  // reports a fully normal playing state but produces no actual audio —
  // manually dragging the seek bar during that silent playback reliably
  // restores sound immediately. Used to gate a one-time replicated "nudge"
  // seek right after play() on any attempt following a completion, without
  // touching the always-worked-fine first playback.
  bool _hasCompletedAtLeastOnce = false;

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();
    _player.positionStream.listen((pos) {
      if (mounted) setState(() => _position = pos);
    });
    _player.durationStream.listen((dur) {
      if (mounted && dur != null) setState(() => _duration = dur);
    });
    _player.playerStateStream.listen((state) {
      if (mounted) {
        // just_audio's audio_session integration handles responding to
        // interruptions (calls, etc.) but never sends the explicit "I'm
        // done" signal that lets iOS un-duck other apps on pause — same
        // gap already fixed for recording and video playback elsewhere in
        // this file/video_message_widgets.dart. Catch the true->false
        // edge here before overwriting _isPlaying below.
        final wasPlaying = _isPlaying;
        setState(() => _isPlaying = state.playing);
        if (wasPlaying && !state.playing) {
          if (_pausedByCoordinator) {
            _pausedByCoordinator = false;
          } else {
            unawaited(deactivateAudioSession());
          }
        }
        if (state.playing && !_listenedFired) {
          _listenedFired = true;
          widget.onListened?.call();
        }
        if (state.processingState == ProcessingState.completed) {
          // just_audio doesn't clear its own `playing` flag on completion —
          // only pause()/stop() do. Without an explicit pause() here,
          // seeking back to zero while `playing` is still true makes the
          // player resume from the new position, i.e. loop forever instead
          // of stopping.
          unawaited(_player.pause());
          _player.seek(Duration.zero);
          _hasCompletedAtLeastOnce = true;
          setState(() => _isPlaying = false);
        }
      }
    });
    final localPath = widget.localFilePath;
    if (localPath != null) {
      _player.setFilePath(localPath);
    } else if (widget.audioURL != null) {
      _player.setUrl(widget.audioURL!);
    }
  }

  void _pauseFromCoordinator() {
    if (mounted) {
      _pausedByCoordinator = true;
      _player.pause();
    }
  }

  @override
  void dispose() {
    if (_isPlaying) unawaited(deactivateAudioSession());
    VoiceMessageCoordinator.instance._stopped(this);
    _player.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final total = _duration.inMilliseconds > 0
        ? _duration.inMilliseconds.toDouble()
        : 1.0;
    final current = _position.inMilliseconds.toDouble().clamp(0.0, total);
    final playedFraction = (current / total).clamp(0.0, 1.0);

    final playButton = GestureDetector(
      onTap: () async {
        if (_isPlaying) {
          await _player.pause();
        } else {
          VoiceMessageCoordinator.instance._starting(this);
          await activateAudioSession();
          if (_hasCompletedAtLeastOnce) {
            // Replicates the manual seek-bar drag that reliably restored
            // sound during a silent replay on-device — a known just_audio/
            // iOS quirk where resuming playback after a natural completion
            // reports a fully normal playing state but produces no actual
            // audio until any seek happens. Done here, before play() and
            // while still paused, rather than shortly after starting
            // playback (an earlier version of this fix did that, but
            // skipped/lost whatever content played during the delay before
            // the nudge landed). Forward-then-back-to-zero forces a genuine
            // position change — seeking to the same position it's already
            // at can be a no-op that doesn't trigger the same fix.
            await _player.seek(const Duration(milliseconds: 50));
            await _player.seek(Duration.zero);
            if (!mounted) return;
          }
          // just_audio's play() Future only resolves at the NEXT stop/
          // pause/completion, not when playback actually starts.
          unawaited(_player.play());
        }
      },
      child: Icon(
        _isPlaying ? Icons.pause : Icons.play_arrow,
        color: widget.accentColor,
        size: 32,
      ),
    );

    final wave = Expanded(
      child: _WaveformSeekBar(
        levels: widget.waveform,
        playedFraction: playedFraction,
        playedColor: widget.playedColor,
        dotColor: widget.dotColor,
        thick: widget.thickWave,
        onSeek: (fraction) =>
            _player.seek(Duration(milliseconds: (fraction * total).round())),
      ),
    );

    final leading = widget.leading;
    final trailing = widget.trailing;
    final row = [
      if (leading != null) ...[leading, const SizedBox(width: 8)],
      playButton,
      const SizedBox(width: 6),
      wave,
      if (trailing != null) ...[const SizedBox(width: 8), trailing],
    ];

    // Position label always sits under the play button specifically, not
    // just at the row's leading edge — when a leading widget comes first,
    // it needs a leading indent matching that widget's width + spacing to
    // land in the same place it already does without one.
    final positionIndent = leading != null ? widget.sideExtent : 0.0;

    return SizedBox(
      width: widget.width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.center, children: row),
          const SizedBox(height: 2),
          Row(
            children: [
              Padding(
                padding: EdgeInsets.only(left: positionIndent),
                child: Text(
                  _fmt(_position),
                  style: TextStyle(
                    color: widget.labelColor.withAlpha(150),
                    fontSize: 10,
                  ),
                ),
              ),
              const Spacer(),
              // Mirrors positionIndent above: a trailing widget sits flush at
              // the row's right edge, so without this the footer ends up
              // right underneath it with no gap.
              Padding(
                padding: EdgeInsets.only(
                  right: trailing != null ? widget.sideExtent : 0,
                ),
                child: widget.footerTrailing,
              ),
            ],
          ),
          if (widget.caption.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              widget.caption,
              style: TextStyle(color: widget.labelColor, fontSize: 14),
            ),
          ],
        ],
      ),
    );
  }
}

// Static bars + draggable position dot, replacing the old continuous
// Slider — matches WhatsApp's segmented-waveform look. levels is the
// 0-100 normalized amplitude captured during recording (see
// _downsampleWaveform); null (message sent before that field existed)
// falls back to a flat, honest "no data" bar pattern rather than
// pretending to show a real waveform.
class _WaveformSeekBar extends StatefulWidget {
  final List<int>? levels;
  final double playedFraction;
  final Color playedColor;
  final Color dotColor;
  // Widens every bar (played and unplayed alike) once the recipient has
  // listened — independent of the played/unplayed color split below, which
  // stays keyed off playedFraction regardless of this flag.
  final bool thick;
  final ValueChanged<double> onSeek;

  const _WaveformSeekBar({
    required this.levels,
    required this.playedFraction,
    required this.playedColor,
    required this.dotColor,
    required this.thick,
    required this.onSeek,
  });

  @override
  State<_WaveformSeekBar> createState() => _WaveformSeekBarState();
}

class _WaveformSeekBarState extends State<_WaveformSeekBar> {
  static const double _barAreaHeight = 22;
  static const double _minBarHeight = 3;
  static const double _dotVisualSize = 14;
  // Bigger than the visual dot, per Apple/Material minimum-touch-target
  // guidance — the drawn circle stays small so it doesn't dominate the
  // waveform, but the draggable hit region around it is generous.
  static const double _dotHitSize = 44;

  // Absolute bar-local x of the dot while a drag on it is in progress —
  // set on drag start and accumulated by delta.dx on each update (rather
  // than derived from widget.playedFraction, which only updates once the
  // async player.seek()'s position-stream round trip lands, too slow to
  // track a fast finger movement 1:1). Stays set after the finger lifts,
  // too — cleared below once the real position stream catches up, rather
  // than immediately on release, so the dot doesn't snap back to the
  // stale pre-seek position and then jump forward again once the seek
  // resolves. Null when not mid-drag and not waiting on a catch-up.
  double? _dragX;

  @override
  Widget build(BuildContext context) {
    final bars = widget.levels ?? List.filled(28, 35);
    return LayoutBuilder(
      builder: (context, constraints) {
        void seekAtX(double dx) {
          widget.onSeek((dx / constraints.maxWidth).clamp(0.0, 1.0));
        }

        if (_dragX != null &&
            (widget.playedFraction * constraints.maxWidth - _dragX!).abs() <
                3) {
          _dragX = null;
        }
        final dotCenterX =
            _dragX ?? widget.playedFraction * constraints.maxWidth;
        // Same visual-vs-real split as the dot above, applied to the
        // played/unplayed bar coloring too — without this the bars' fill
        // boundary was still driven straight off widget.playedFraction (the
        // real, stream-lagged position), so the wave's own color edge kept
        // jumping/lagging behind the finger even after the dot itself
        // started following it immediately.
        final visualFraction = dotCenterX / constraints.maxWidth;
        return Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.centerLeft,
          children: [
            // Tap/drag anywhere on the bar seeks there — this is the
            // OUTER detector; the dot below gets its own nested one so
            // grabbing the dot specifically is a Flutter gesture-arena
            // child, which takes priority over both this bar detector and
            // the ancestor bubble's long-press/swipe-to-reply detectors,
            // isolating a dot-drag from triggering either of those.
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) {
                // A tap has no separate "end" event, so commit the real
                // seek right away — this is a single discrete action, not
                // a per-frame stream of them, so there's no jank risk here.
                setState(() => _dragX = d.localPosition.dx);
                seekAtX(d.localPosition.dx);
              },
              onHorizontalDragUpdate: (d) {
                // Visual only during the drag itself — move the dot/wave
                // immediately, in step with the touch. The real seek() is
                // deliberately NOT called per-frame here: firing it dozens
                // of times a second was hammering the native audio engine
                // via the platform channel, which was the actual source of
                // the stutter/hesitation, not the visual state update
                // itself. It fires once, on release, in onHorizontalDragEnd
                // below — matching WhatsApp's own scrub behavior (silent
                // while dragging, seeks once on release).
                setState(() => _dragX = d.localPosition.dx);
              },
              onHorizontalDragEnd: (_) {
                if (_dragX != null) seekAtX(_dragX!);
              },
              onHorizontalDragCancel: () {
                if (_dragX != null) seekAtX(_dragX!);
              },
              child: SizedBox(
                height: _barAreaHeight,
                width: double.infinity,
                child: Row(
                  children: [
                    for (var i = 0; i < bars.length; i++)
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: widget.thick ? 0.5 : 1,
                          ),
                          child: Container(
                            height:
                                _minBarHeight +
                                (bars[i].clamp(0, 100) / 100) *
                                    (_barAreaHeight - _minBarHeight),
                            decoration: BoxDecoration(
                              // 150 rather than the previous 70 — at
                              // position 0 (not yet playing), every bar is
                              // "unplayed" and was rendering the whole
                              // wave at low alpha, making it barely
                              // visible before playback starts.
                              color: (i / bars.length) <= visualFraction
                                  ? widget.playedColor
                                  : widget.playedColor.withAlpha(150),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: (dotCenterX - _dotHitSize / 2).clamp(
                -_dotHitSize / 2,
                constraints.maxWidth - _dotHitSize / 2,
              ),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragStart: (_) =>
                    setState(() => _dragX = dotCenterX),
                onHorizontalDragUpdate: (d) {
                  // Visual only, same reasoning as the outer detector above
                  // — no per-frame seek() call, just the local dot/wave
                  // position, to keep dragging jank-free.
                  final next = (_dragX ?? dotCenterX) + d.delta.dx;
                  setState(() => _dragX = next);
                },
                // Deliberately NOT clearing _dragX here — see the field's
                // doc comment. It's released once widget.playedFraction
                // (driven by the player's position stream) catches up to
                // wherever the finger let go, in the build method above.
                // The real seek() fires exactly once here, on release.
                onHorizontalDragEnd: (_) {
                  if (_dragX != null) seekAtX(_dragX!);
                },
                onHorizontalDragCancel: () {
                  if (_dragX != null) seekAtX(_dragX!);
                },
                child: SizedBox(
                  width: _dotHitSize,
                  height: _dotHitSize,
                  child: Center(
                    child: Container(
                      width: _dotVisualSize,
                      height: _dotVisualSize,
                      decoration: BoxDecoration(
                        color: widget.dotColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
