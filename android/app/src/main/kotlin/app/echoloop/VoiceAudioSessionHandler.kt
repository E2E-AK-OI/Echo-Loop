package app.echoloop

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.audiofx.AcousticEchoCanceler
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * AI 口语外放插话的音频路由会话。
 *
 * 外放时把输出切到 VOICE_COMMUNICATION，并让录音使用 VOICE_COMMUNICATION，
 * 平台才会把播放信号作为回声参考交给 AEC；仅设置录音源通常不足以消除回声。
 * 耳机/蓝牙等非外放路由保持媒体输出，避免无谓地把通话模式套到音乐播放上。
 *
 * AEC 是否真正生效由设备厂商决定：这里只报告系统能力，控制器在不可用时
 * 降级为手动停止朗读，绝不把回声当成用户插话。
 */
class VoiceAudioSessionHandler(
    context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    companion object {
        private const val TAG = "VoiceAudioSession"
        private const val CHANNEL_NAME = "top.echo-loop/voice_audio_session"
    }

    private val audioManager =
        context.applicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private var savedMode: Int? = null
    private var savedSpeakerphone: Boolean? = null
    private var isActive = false

    private val channel = MethodChannel(messenger, CHANNEL_NAME).also {
        it.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "begin" -> result.success(begin())
            "prepareForTts" -> result.success(prepareForTts())
            "end" -> {
                end()
                result.success(null)
            }

            "status" -> {
                val route = readOutputRoute()
                result.success(status(route.isSpeaker, route.isKnown))
            }
            else -> result.notImplemented()
        }
    }

    private fun begin(): Map<String, Any?> {
        val route = readOutputRoute()
        if (route.isSpeaker) {
            saveSettingsIfNeeded()
            applySpeakerMode()
        }
        isActive = true
        return status(route.isSpeaker, route.isKnown)
    }

    private fun prepareForTts(): Map<String, Any?> {
        val route = readOutputRoute()
        if (route.isSpeaker) {
            saveSettingsIfNeeded()
            applySpeakerMode()
        }
        isActive = true
        return status(route.isSpeaker, route.isKnown)
    }

    private fun status(isSpeaker: Boolean, isRouteKnown: Boolean = true): Map<String, Any?> {
        val aecAvailable = try {
            AcousticEchoCanceler.isAvailable()
        } catch (error: Exception) {
            Log.w(TAG, "read AEC availability failed: ${error.message}")
            false
        }
        val speakerModeApplied = isSpeaker && isSpeakerModeApplied()
        return mapOf(
            // 外放且系统没有接受通话路由时，上层必须关闭语音插话。
            "isSupported" to (!isSpeaker || speakerModeApplied),
            "isSpeakerOutput" to isSpeaker,
            "isAecAvailable" to aecAvailable,
            "isRouteKnown" to isRouteKnown,
            "usage" to if (speakerModeApplied) "voiceCommunication" else "media",
        )
    }

    @Suppress("DEPRECATION")
    private fun saveSettingsIfNeeded() {
        // 会话可能先在耳机路由下开始、播放前才切到外放；只要还没保存过，
        // 就必须在第一次真正修改系统音频设置前记录原始值。
        if (savedMode != null) return
        savedMode = audioManager.mode
        savedSpeakerphone = audioManager.isSpeakerphoneOn
    }

    @Suppress("DEPRECATION")
    private fun applySpeakerMode(): Boolean {
        return try {
            audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
            audioManager.isSpeakerphoneOn = true
            true
        } catch (error: Exception) {
            Log.w(TAG, "apply speaker mode failed: ${error.message}")
            false
        }
    }

    @Suppress("DEPRECATION")
    private fun isSpeakerModeApplied(): Boolean {
        return try {
            audioManager.mode == AudioManager.MODE_IN_COMMUNICATION &&
                audioManager.isSpeakerphoneOn
        } catch (error: Exception) {
            Log.w(TAG, "read speaker mode failed: ${error.message}")
            false
        }
    }

    private data class OutputRoute(val isSpeaker: Boolean, val isKnown: Boolean)

    /**
     * 有已连接的外接输出设备时按耳机处理，保持媒体路由即可。
     *
     * GET_DEVICES_OUTPUTS 返回的是「已连接」设备，不是正在使用的路由；
     * 因此读不到时把 isKnown 置为 false，由上层关闭语音插话，避免把
     * 未知路由误当成耳机后打开 VAD。
     */
    private fun readOutputRoute(): OutputRoute {
        return try {
            val hasExternal = audioManager
                .getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                .any { device ->
                    device.type != AudioDeviceInfo.TYPE_BUILTIN_SPEAKER &&
                        device.type != AudioDeviceInfo.TYPE_BUILTIN_EARPIECE
                }
            OutputRoute(isSpeaker = !hasExternal, isKnown = true)
        } catch (error: Exception) {
            Log.w(TAG, "read output devices failed: ${error.message}")
            OutputRoute(isSpeaker = true, isKnown = false)
        }
    }

    @Suppress("DEPRECATION")
    private fun end() {
        if (!isActive) return
        isActive = false
        try {
            savedMode?.let { audioManager.mode = it }
        } catch (error: Exception) {
            Log.w(TAG, "restore audio mode failed: ${error.message}")
        }
        try {
            savedSpeakerphone?.let { audioManager.isSpeakerphoneOn = it }
        } catch (error: Exception) {
            Log.w(TAG, "restore speakerphone failed: ${error.message}")
        }
        savedMode = null
        savedSpeakerphone = null
    }

    fun dispose() {
        end()
        channel.setMethodCallHandler(null)
    }
}
