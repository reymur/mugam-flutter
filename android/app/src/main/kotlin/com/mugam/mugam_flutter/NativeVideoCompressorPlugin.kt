package com.mugam.mugam_flutter

import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.effect.Presentation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

// Backs lib/core/media/video_compressor.dart's Android side. Uses Media3
// Transformer (androidx.media3:media3-transformer) as the actual encoding
// engine rather than hand-rolled MediaCodec+MediaMuxer — a raw Surface-to-
// Surface MediaCodec transcode pipeline needs a manual OpenGL ES render
// pass to resize between decoder output and encoder input (Android has no
// declarative-resize equivalent of iOS's AVVideoScalingModeKey at the raw
// MediaCodec level), which is real, device/GPU-specific risk for a chat
// app's compression feature. Transformer wraps that same MediaCodec/
// MediaMuxer/OpenGL pipeline as a Google-maintained library instead — the
// Android-side equivalent of using AVAssetReader/Writer instead of raw
// VTCompressionSession on iOS: framework-managed, not the lowest possible
// level, not a third-party pub.dev package.
//
// Only one compression runs at a time (single Transformer instance as
// state) — a second concurrent `compress` call fails fast with BUSY so the
// Dart side's safe-fallback (send the original file) kicks in.
class NativeVideoCompressorPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var binding: FlutterPlugin.FlutterPluginBinding
    private val mainHandler = Handler(Looper.getMainLooper())

    private var eventSink: EventChannel.EventSink? = null
    private var transformer: Transformer? = null
    private var isBusy = false
    // The MethodChannel.Result for whichever "compress" call is currently
    // in flight — Transformer.cancel() is documented to NOT invoke
    // onCompleted/onError (cancellation isn't treated as a completion or an
    // error by Media3), so without this, a cancelled compress's own result
    // callback would never be resolved and isBusy would never be reset,
    // wedging every later compress call behind a stale BUSY. The "cancel"
    // case below resolves this directly instead of relying on the listener.
    private var pendingCompressResult: MethodChannel.Result? = null
    private val progressHolder = ProgressHolder()
    private val progressRunnable = object : Runnable {
        override fun run() {
            val current = transformer ?: return
            val state = current.getProgress(progressHolder)
            if (state == Transformer.PROGRESS_STATE_AVAILABLE) {
                eventSink?.success(progressHolder.progress / 100.0)
            }
            if (state != Transformer.PROGRESS_STATE_NOT_STARTED) {
                mainHandler.postDelayed(this, 250)
            }
        }
    }

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        binding = flutterPluginBinding
        methodChannel = MethodChannel(flutterPluginBinding.binaryMessenger, "mugam/native_video_compressor")
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(flutterPluginBinding.binaryMessenger, "mugam/native_video_compressor/progress")
        eventChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "compress" -> {
                val path = call.argument<String>("path")
                val outputPath = call.argument<String>("outputPath")
                val shortSide = call.argument<Int>("shortSide")
                val bitrate = call.argument<Int>("bitrate")
                if (path == null || outputPath == null || shortSide == null || bitrate == null) {
                    result.error("INVALID_ARGUMENT", "Expected path, outputPath, shortSide, bitrate", null)
                    return
                }
                // Optional trim range — both present together or not at all
                // (Dart side only ever sends both or neither, see
                // video_compressor.dart).
                val startTimeMs = call.argument<Int>("startTimeMs")
                val endTimeMs = call.argument<Int>("endTimeMs")
                if (isBusy) {
                    result.error("BUSY", "A compression is already in progress", null)
                    return
                }
                isBusy = true
                pendingCompressResult = result
                compress(path, outputPath, shortSide, bitrate, startTimeMs, endTimeMs, result)
            }
            "cancel" -> {
                transformer?.cancel()
                // No-op if nothing is running (isBusy false / no compress in
                // flight) — pendingCompressResult is only non-null while a
                // "compress" call is outstanding, so a stray cancel just
                // resolves its own result.success(null) below and touches
                // nothing else.
                val pending = pendingCompressResult
                if (pending != null) {
                    // Clears pendingCompressResult before resolving it, so
                    // this can't double-resolve the same result even if
                    // onError/onCompleted somehow still fired first.
                    finish()
                    pending.error("CANCELLED", "Compression cancelled", null)
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun compress(
        path: String,
        outputPath: String,
        shortSide: Int,
        bitrate: Int,
        startTimeMs: Int?,
        endTimeMs: Int?,
        result: MethodChannel.Result
    ) {
        try {
            java.io.File(outputPath).delete()

            val videoEncoderSettings = VideoEncoderSettings.DEFAULT.buildUpon()
                .setBitrate(bitrate)
                .build()
            val encoderFactory = DefaultEncoderFactory.Builder(binding.applicationContext)
                .setRequestedVideoEncoderSettings(videoEncoderSettings)
                .setEnableFallback(true)
                .build()

            val listener = object : Transformer.Listener {
                override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                    finish()
                    result.success(null)
                }

                override fun onError(composition: Composition, exportResult: ExportResult, exception: ExportException) {
                    finish()
                    result.error("EXPORT_ERROR", exception.message ?: "Transformer export failed", null)
                }
            }

            val newTransformer = Transformer.Builder(binding.applicationContext)
                .setVideoMimeType(MimeTypes.VIDEO_H264)
                .setEncoderFactory(encoderFactory)
                .addListener(listener)
                .build()
            transformer = newTransformer

            // When a trim range is provided, MediaItem.ClippingConfiguration
            // is Media3's own documented mechanism for it (confirmed via
            // Android's Transformer docs) — Transformer trims and
            // re-encodes in the same export pass rather than two separate
            // operations.
            var mediaItemBuilder = MediaItem.Builder().setUri(Uri.fromFile(java.io.File(path)))
            if (startTimeMs != null && endTimeMs != null) {
                mediaItemBuilder = mediaItemBuilder.setClippingConfiguration(
                    MediaItem.ClippingConfiguration.Builder()
                        .setStartPositionMs(startTimeMs.toLong())
                        .setEndPositionMs(endTimeMs.toLong())
                        .build()
                )
            }
            val editedMediaItem = EditedMediaItem.Builder(mediaItemBuilder.build())
                .setEffects(
                    Effects(
                        /* audioProcessors= */ listOf(),
                        /* videoEffects= */ listOf(Presentation.createForShortSide(shortSide))
                    )
                )
                .build()

            newTransformer.start(editedMediaItem, outputPath)
            mainHandler.post(progressRunnable)
        } catch (e: Exception) {
            finish()
            result.error("EXPORT_ERROR", e.message ?: "Failed to start compression", null)
        }
    }

    private fun finish() {
        isBusy = false
        transformer = null
        pendingCompressResult = null
        mainHandler.removeCallbacks(progressRunnable)
    }
}
