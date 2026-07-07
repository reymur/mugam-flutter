package com.mugam.mugam_flutter

import android.media.AudioAttributes
import android.media.SoundPool
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

// Backs lib/core/native_sound_effect.dart's Android side. Deliberately does
// not touch audio focus/AudioManager at all — that stays entirely owned by
// the rest of the app, mirroring the iOS implementation
// (NativeSoundEffectPlugin.swift) which likewise never touches
// AVAudioSession. SoundPool is Android's own purpose-built low-latency
// mechanism for short UI sound effects (as opposed to MediaPlayer, the
// heavier analog of just_audio).
//
// UNTESTED — no Android device was available in the session this was
// written in. Verify actual playback (correct sound, no latency, no
// interaction with the recorder's own audio focus handling) on a real
// Android device before relying on this.
class NativeSoundEffectPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var soundPool: SoundPool
    private lateinit var binding: FlutterPlugin.FlutterPluginBinding
    private val soundIds = mutableMapOf<String, Int>()
    private val pendingLoads = mutableMapOf<Int, MethodChannel.Result>()

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        binding = flutterPluginBinding
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "mugam/native_sound_effect")
        channel.setMethodCallHandler(this)

        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        soundPool = SoundPool.Builder()
            .setMaxStreams(4)
            .setAudioAttributes(attributes)
            .build()
        soundPool.setOnLoadCompleteListener { _, sampleId, status ->
            val result = pendingLoads.remove(sampleId)
            if (status == 0) {
                result?.success(null)
            } else {
                result?.error("LOAD_ERROR", "SoundPool failed to load (status=$status)", null)
            }
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "load" -> {
                val soundId = call.argument<String>("soundId")
                val path = call.argument<String>("path")
                if (soundId == null || path == null) {
                    result.error("INVALID_ARGUMENT", "Expected soundId and path", null)
                    return
                }
                try {
                    val assetKey = binding.flutterAssets.getAssetFilePathByName(path)
                    val afd = binding.applicationContext.assets.openFd(assetKey)
                    val sampleId = soundPool.load(afd, 1)
                    soundIds[soundId] = sampleId
                    pendingLoads[sampleId] = result
                } catch (e: Exception) {
                    result.error("LOAD_ERROR", "Failed to load $path: ${e.message}", null)
                }
            }
            "play" -> {
                val soundId = call.argument<String>("soundId")
                val sampleId = soundIds[soundId]
                if (sampleId == null) {
                    result.error("PLAY_ERROR", "No sound loaded for $soundId", null)
                    return
                }
                soundPool.play(sampleId, 1f, 1f, 1, 0, 1f)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        soundPool.release()
    }
}
