package app.cogwheel.conduit

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.util.concurrent.LinkedBlockingQueue

class CallPlaybackBridge : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null

    private var audioTrack: AudioTrack? = null
    private var playbackThread: Thread? = null
    @Volatile
    private var shouldStop = false
    private val samples = LinkedBlockingQueue<ByteBuffer>()
    private var totalFeeds = 0L
    private var lastLowBufferFeed = 0L
    private var lastZeroFeed = 0L
    @Volatile
    private var feedThreshold = 0L

    fun setup(flutterEngine: FlutterEngine) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            METHOD_CHANNEL
        ).setMethodCallHandler(this)
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            EVENT_CHANNEL
        ).setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setup" -> {
                val sampleRate = call.argument<Int>("sampleRate") ?: 24000
                val numChannels = call.argument<Int>("numChannels") ?: 1
                result.success(setupTrack(sampleRate, numChannels))
            }
            "feed" -> {
                val buffer = call.argument<ByteArray>("buffer")
                if (buffer == null) {
                    result.error("InvalidArgs", "buffer is required", null)
                    return
                }
                feed(buffer)
                result.success(true)
            }
            "setFeedThreshold" -> {
                feedThreshold = (call.argument<Number>("threshold"))?.toLong() ?: 0L
                result.success(true)
            }
            "release" -> {
                releaseTrack()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    fun dispose() {
        releaseTrack()
    }

    private fun setupTrack(sampleRate: Int, numChannels: Int): Boolean {
        releaseTrack()

        val channelConfig = if (numChannels == 2) {
            AudioFormat.CHANNEL_OUT_STEREO
        } else {
            AudioFormat.CHANNEL_OUT_MONO
        }
        val minBufferSize = AudioTrack.getMinBufferSize(
            sampleRate,
            channelConfig,
            AudioFormat.ENCODING_PCM_16BIT
        )
        if (minBufferSize == AudioTrack.ERROR || minBufferSize == AudioTrack.ERROR_BAD_VALUE) {
            return false
        }

        val track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(sampleRate)
                    .setChannelMask(channelConfig)
                    .build()
            )
            .setBufferSizeInBytes(minBufferSize)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()

        if (track.state != AudioTrack.STATE_INITIALIZED) {
            track.release()
            return false
        }

        audioTrack = track
        samples.clear()
        totalFeeds = 0
        lastLowBufferFeed = 0
        lastZeroFeed = 0
        shouldStop = false

        val thread = Thread({ playbackLoop(track, numChannels) }, "CallPlaybackThread")
        thread.priority = Thread.MAX_PRIORITY
        playbackThread = thread
        thread.start()
        return true
    }

    private fun feed(buffer: ByteArray) {
        if (audioTrack == null) return
        synchronized(samples) {
            for (chunk in split(buffer, MAX_BYTES_PER_BUFFER)) {
                samples.add(chunk)
            }
            totalFeeds += 1
        }
    }

    private fun playbackLoop(track: AudioTrack, numChannels: Int) {
        android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_AUDIO)
        track.play()

        while (!shouldStop) {
            val data = try {
                samples.take()
            } catch (error: InterruptedException) {
                Thread.currentThread().interrupt()
                continue
            }

            track.write(data, data.remaining(), AudioTrack.WRITE_BLOCKING)

            val remainingFrames: Long
            val feeds: Long
            val threshold: Long
            synchronized(samples) {
                var totalBytes = 0L
                for (sample in samples) {
                    totalBytes += sample.remaining()
                }
                remainingFrames = totalBytes / (2 * numChannels)
                feeds = totalFeeds
                threshold = feedThreshold
            }

            val isLowBufferEvent = remainingFrames <= threshold && lastLowBufferFeed != feeds
            val isZeroCrossingEvent = remainingFrames == 0L && lastZeroFeed != feeds
            if (isLowBufferEvent || isZeroCrossingEvent) {
                if (isLowBufferEvent) lastLowBufferFeed = feeds
                if (isZeroCrossingEvent) lastZeroFeed = feeds
                mainHandler.post { emit(remainingFrames) }
            }
        }

        track.stop()
        track.flush()
        track.release()
    }

    private fun releaseTrack() {
        val thread = playbackThread
        if (thread != null) {
            shouldStop = true
            thread.interrupt()
            try {
                thread.join()
            } catch (error: InterruptedException) {
                Thread.currentThread().interrupt()
            }
            playbackThread = null
        }
        audioTrack = null
        samples.clear()
    }

    private fun split(buffer: ByteArray, maxSize: Int): List<ByteBuffer> {
        val chunks = ArrayList<ByteBuffer>()
        var offset = 0
        while (offset < buffer.size) {
            val length = minOf(buffer.size - offset, maxSize)
            chunks.add(ByteBuffer.wrap(buffer, offset, length))
            offset += length
        }
        return chunks
    }

    private fun emit(remainingFrames: Long) {
        eventSink?.success(mapOf("remaining_frames" to remainingFrames))
    }

    companion object {
        private const val METHOD_CHANNEL = "app.cogwheel.conduit/call_playback"
        private const val EVENT_CHANNEL = "app.cogwheel.conduit/call_playback/events"
        private const val MAX_BYTES_PER_BUFFER = 200
    }
}
