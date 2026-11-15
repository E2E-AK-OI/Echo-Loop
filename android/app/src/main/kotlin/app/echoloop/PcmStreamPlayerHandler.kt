package app.echoloop

import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.LinkedBlockingQueue
import kotlin.math.max
import kotlin.math.min

/**
 * 把 Dart 侧持续写入的 PCM 块送入 AudioTrack 播放。
 *
 * 关闭音频时不能只调用 stop：流式合成刚结束时，队列里通常还有大量未播放的
 * 音频，直接 release 会造成只有开头约一秒的截断。finish 会等待队列排空并
 * 跟踪 playbackHeadPosition，等全部写入帧真正播放完后再释放。
 */
class PcmStreamPlayerHandler(
    messenger: BinaryMessenger,
    private val onDisposed: (() -> Unit)? = null,
) : MethodChannel.MethodCallHandler {
    companion object {
        private const val TAG = "PcmStreamPlayer"
        private const val CHANNEL_NAME = "top.echo-loop/pcm_stream_player"
        private const val DEFAULT_SAMPLE_RATE = 24000
        private const val BYTES_PER_SAMPLE = 2
        private const val BUFFER_DURATION_MS = 500
        private const val MIN_BUFFER_BYTES = 4096
        private const val WRITE_CHUNK_BYTES = 960
        private const val MAX_DRAIN_MS = 600_000L
        private const val DRAIN_POLL_MS = 20L
        private const val PLAYBACK_TAIL_MS = 100L
        private const val WRITER_JOIN_MS = 2_000L
    }

    private val lock = Any()
    private val queue = LinkedBlockingQueue<ByteArray>()
    private var audioTrack: AudioTrack? = null
    private var writer: Thread? = null
    private var finishThread: Thread? = null
    private var framesWritten = 0L
    private var volume = 1.0f

    @Volatile
    private var isReleased = false

    @Volatile
    private var generation = 0

    private val channel = MethodChannel(messenger, CHANNEL_NAME).also {
        it.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (isReleased) {
            result.success(null)
            return
        }
        when (call.method) {
            "start" -> {
                val sampleRate = call.argument<Int>("sampleRate") ?: DEFAULT_SAMPLE_RATE
                val usage = when (call.argument<String>("usage")) {
                    "voiceCommunication" -> AudioAttributes.USAGE_VOICE_COMMUNICATION
                    else -> AudioAttributes.USAGE_MEDIA
                }
                start(sampleRate, usage)
                result.success(null)
            }

            "write" -> {
                val bytes = call.argument<ByteArray>("bytes")
                if (bytes != null) {
                    write(bytes)
                }
                result.success(null)
            }

            "flush" -> {
                flush()
                result.success(null)
            }

            "finish" -> finish(result)

            "stop" -> {
                stop()
                result.success(null)
            }

            "setVolume" -> {
                setVolume(call.argument<Double>("volume")?.toFloat() ?: 1.0f)
                result.success(null)
            }

            "outputRoute" -> {
                val route = readTrackOutputRoute()
                result.success(
                    mapOf(
                        "isSpeaker" to route.isSpeaker,
                        "isKnown" to route.isKnown,
                    ),
                )
            }

            else -> result.notImplemented()
        }
    }

    private fun start(sampleRate: Int, usage: Int) {
        synchronized(lock) {
            stopLocked()
            generation += 1
            framesWritten = 0
            val minBufferSize = AudioTrack.getMinBufferSize(
                sampleRate,
                AudioFormat.CHANNEL_OUT_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
            )
            val bufferSize = max(
                if (minBufferSize > 0) minBufferSize else MIN_BUFFER_BYTES,
                sampleRate * BYTES_PER_SAMPLE * BUFFER_DURATION_MS / 1000,
            )
            val attributes = AudioAttributes.Builder()
                .setUsage(usage)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()
            val format = AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(sampleRate)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                .build()
            val track = AudioTrack.Builder()
                .setAudioAttributes(attributes)
                .setAudioFormat(format)
                .setBufferSizeInBytes(bufferSize)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
            track.setVolume(volume)
            track.play()
            audioTrack = track
            startWriter(track)
        }
    }

    /** 仅入队，不阻塞 Flutter 主线程。 */
    private fun write(bytes: ByteArray) {
        synchronized(lock) {
            if (audioTrack == null || finishThread != null) return
            queue.offer(bytes)
        }
    }

    private data class TrackOutputRoute(
        val isSpeaker: Boolean,
        val isKnown: Boolean,
    )

    /**
     * 读取 AudioTrack 真实路由，而不是「已连接设备列表」。
     *
     * 手机外放时列表里也可能残留 TYPE_TELEPHONY、TYPE_UNKNOWN 等非播放设备；
     * 这里只把明确的扬声器/耳机类型视为已知路由，其余返回 unknown，由上层
     * 关闭语音插话，避免把回声当成用户输入。
     */
    private fun readTrackOutputRoute(): TrackOutputRoute {
        synchronized(lock) {
            val track = audioTrack ?: return TrackOutputRoute(false, false)
            return try {
                val device = track.routedDevice
                    ?: return TrackOutputRoute(false, false)
                Log.i(TAG, "AudioTrack route type=${device.type}")
                when (device.type) {
                    AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> TrackOutputRoute(true, true)
                    AudioDeviceInfo.TYPE_BUILTIN_EARPIECE,
                    AudioDeviceInfo.TYPE_WIRED_HEADSET,
                    AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
                    AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
                    AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
                    AudioDeviceInfo.TYPE_USB_HEADSET,
                    AudioDeviceInfo.TYPE_USB_DEVICE,
                    AudioDeviceInfo.TYPE_USB_ACCESSORY,
                    AudioDeviceInfo.TYPE_HEARING_AID,
                    AudioDeviceInfo.TYPE_BLE_HEADSET,
                    AudioDeviceInfo.TYPE_BLE_SPEAKER,
                    AudioDeviceInfo.TYPE_BLE_BROADCAST,
                    -> TrackOutputRoute(false, true)
                    else -> TrackOutputRoute(false, false)
                }
            } catch (error: IllegalStateException) {
                Log.w(TAG, "read output route failed: ${error.message}")
                TrackOutputRoute(false, false)
            }
        }
    }

    /** 外放插话的 duck 音量控制，只影响当前播放器，不改系统音量。 */
    private fun setVolume(volume: Float) {
        synchronized(lock) {
            this.volume = volume.coerceIn(0.0f, 1.0f)
            try {
                audioTrack?.setVolume(this.volume)
            } catch (error: IllegalStateException) {
                Log.w(TAG, "set volume failed: ${error.message}")
            }
        }
    }

    private fun flush() {
        synchronized(lock) {
            cancelFinishLocked()
            generation += 1
            framesWritten = 0
            queue.clear()
            val track = audioTrack ?: return
            writer?.interrupt()
            writer = null
            try {
                track.pause()
                track.flush()
                track.play()
            } catch (error: IllegalStateException) {
                Log.w(TAG, "flush failed: ${error.message}")
            }
            startWriter(track)
        }
    }

    /**
     * 自然收尾：等队列写完、写入线程结束，再等播放头追上已写入帧数。
     * result 在排空线程结束后回主线程返回，Dart 侧据此继续下一轮对话。
     */
    private fun finish(result: MethodChannel.Result) {
        val target = synchronized(lock) {
            if (finishThread != null) return@synchronized null
            val track = audioTrack ?: return@synchronized null
            track to generation
        }
        if (target == null) {
            result.success(null)
            return
        }
        val track = target.first
        val drainGeneration = target.second
        val thread = Thread({
            try {
                drainTrack(track, drainGeneration)
            } catch (error: InterruptedException) {
                Thread.currentThread().interrupt()
            } finally {
                synchronized(lock) {
                    if (finishThread === Thread.currentThread()) {
                        finishThread = null
                    }
                    if (generation == drainGeneration) {
                        stopLocked()
                    }
                }
                Handler(Looper.getMainLooper()).post { result.success(null) }
            }
        }, "PcmStreamDrain").apply { isDaemon = true }
        synchronized(lock) {
            if (generation != drainGeneration) {
                result.success(null)
                return
            }
            finishThread = thread
        }
        thread.start()
    }

    private fun drainTrack(track: AudioTrack, drainGeneration: Int) {
        val deadline = System.currentTimeMillis() + MAX_DRAIN_MS
        while (System.currentTimeMillis() < deadline) {
            if (generation != drainGeneration) return
            if (queue.isEmpty()) break
            Thread.sleep(DRAIN_POLL_MS)
        }
        val writerToStop = synchronized(lock) {
            if (generation != drainGeneration) return@synchronized null
            writer
        }
        writerToStop?.interrupt()
        writerToStop?.join(WRITER_JOIN_MS)
        val totalFrames = synchronized(lock) {
            if (generation == drainGeneration) framesWritten else 0L
        }
        if (totalFrames <= 0L) return
        var playedToEnd = false
        while (System.currentTimeMillis() < deadline) {
            if (generation != drainGeneration) return
            val head = try {
                track.playbackHeadPosition.toLong() and 0xFFFFFFFFL
            } catch (error: IllegalStateException) {
                Log.w(TAG, "read playback head failed: ${error.message}")
                return
            }
            if (head >= totalFrames) {
                playedToEnd = true
                break
            }
            Thread.sleep(DRAIN_POLL_MS)
        }
        // AudioTrack 播完最后一帧后，硬件仍可能残留极短的缓冲区。
        if (playedToEnd) {
            Thread.sleep(PLAYBACK_TAIL_MS)
        }
    }

    private fun startWriter(track: AudioTrack) {
        val startedGeneration = generation
        writer = Thread({
            drainQueue(track, startedGeneration)
        }, "PcmStreamWriter").apply { isDaemon = true }
        writer?.start()
    }

    private fun drainQueue(track: AudioTrack, startedGeneration: Int) {
        while (!isReleased) {
            val bytes = try {
                queue.take()
            } catch (error: InterruptedException) {
                return
            }
            if (startedGeneration != generation || isReleased) return
            var offset = 0
            while (offset < bytes.size) {
                val size = min(WRITE_CHUNK_BYTES, bytes.size - offset)
                val written = try {
                    track.write(bytes, offset, size)
                } catch (error: IllegalStateException) {
                    Log.w(TAG, "write failed: ${error.message}")
                    return
                }
                if (written <= 0) return
                offset += written
                synchronized(lock) {
                    if (startedGeneration == generation) {
                        framesWritten += (written / BYTES_PER_SAMPLE).toLong()
                    }
                }
                if (startedGeneration != generation || isReleased) return
            }
        }
    }

    private fun cancelFinishLocked() {
        finishThread?.interrupt()
        finishThread = null
    }

    private fun stopLocked() {
        cancelFinishLocked()
        generation += 1
        framesWritten = 0
        queue.clear()
        writer?.interrupt()
        writer = null
        val track = audioTrack
        audioTrack = null
        volume = 1.0f
        if (track != null) {
            try {
                track.pause()
                track.flush()
                track.stop()
            } catch (error: IllegalStateException) {
                Log.w(TAG, "stop failed: ${error.message}")
            } finally {
                track.release()
            }
        }
    }

    private fun stop() {
        synchronized(lock) {
            stopLocked()
        }
    }

    fun dispose() {
        synchronized(lock) {
            isReleased = true
            stopLocked()
        }
        channel.setMethodCallHandler(null)
        onDisposed?.invoke()
    }
}
