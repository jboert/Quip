package dev.quip.android.services

import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.util.Log
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL

/**
 * Whisper-based speech-to-text engine using whisper.cpp via JNI.
 *
 * Records raw PCM audio at 16 kHz mono via AudioRecord, accumulates samples,
 * and runs whisper.cpp inference when recording stops.
 */
class WhisperEngine {

    companion object {
        private const val TAG = "WhisperEngine"
        private const val SAMPLE_RATE = 16000
        private const val MODEL_NAME = "ggml-tiny.en.bin"
        private const val MODEL_URL =
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL_NAME"
        private const val PARTIAL_INTERVAL_MS = 2000L
    }

    @Volatile var isModelReady = false
        private set
    @Volatile var isModelDownloading = false
        private set
    @Volatile var downloadProgress = -1
        private set
    @Volatile var isRecording = false
        private set
    @Volatile var transcribedText = ""
        private set

    var onPartialResult: ((String) -> Unit)? = null
    var onFinalResult: ((String) -> Unit)? = null
    var onError: ((String) -> Unit)? = null

    private var contextPtr: Long = 0
    private var audioRecord: AudioRecord? = null
    private var recordingThread: Thread? = null
    private var downloadThread: Thread? = null
    private val audioSamples = mutableListOf<Float>()

    fun isAvailable(): Boolean = WhisperLib.isAvailable()

    fun initModel(context: Context, onReady: (() -> Unit)? = null) {
        if (isModelReady) { onReady?.invoke(); return }
        if (!isAvailable()) {
            Log.w(TAG, "Whisper native library not available")
            onError?.invoke("Whisper native library not available")
            return
        }

        val thread = Thread {
            try {
                val modelFile = File(context.filesDir, MODEL_NAME)
                if (!modelFile.exists()) {
                    isModelDownloading = true
                    downloadProgress = 0
                    Log.i(TAG, "Downloading Whisper model from $MODEL_URL")
                    downloadModel(MODEL_URL, modelFile)
                    if (Thread.interrupted()) return@Thread
                    isModelDownloading = false
                    downloadProgress = -1
                    Log.i(TAG, "Model downloaded to ${modelFile.absolutePath}")
                }

                contextPtr = WhisperLib.initContext(modelFile.absolutePath)
                if (contextPtr == 0L) {
                    throw RuntimeException("Failed to initialize Whisper context")
                }
                isModelReady = true
                Log.i(TAG, "Whisper model loaded successfully")
                onReady?.invoke()
            } catch (e: InterruptedException) {
                isModelDownloading = false
                downloadProgress = -1
                Log.i(TAG, "Whisper model download cancelled")
            } catch (e: Throwable) {
                isModelDownloading = false
                downloadProgress = -1
                Log.e(TAG, "Failed to init Whisper model: ${e.message}", e)
                onError?.invoke("Failed to load Whisper model: ${e.message}")
            }
        }
        downloadThread = thread
        thread.start()
    }

    fun startRecording() {
        if (isRecording || !isModelReady || contextPtr == 0L) return

        transcribedText = ""
        audioSamples.clear()
        isRecording = true

        val bufferSize = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_FLOAT
        ).coerceAtLeast(SAMPLE_RATE * 4) // At least 1 second buffer

        val recorder = try {
            AudioRecord(
                MediaRecorder.AudioSource.MIC,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_FLOAT,
                bufferSize
            )
        } catch (e: SecurityException) {
            Log.e(TAG, "No microphone permission: ${e.message}")
            isRecording = false
            onError?.invoke("Microphone permission required")
            return
        }

        if (recorder.state != AudioRecord.STATE_INITIALIZED) {
            Log.e(TAG, "AudioRecord failed to initialize")
            recorder.release()
            isRecording = false
            onError?.invoke("Failed to initialize audio recorder")
            return
        }

        audioRecord = recorder
        recorder.startRecording()

        recordingThread = Thread {
            val buffer = FloatArray(SAMPLE_RATE) // 1-second chunks
            var lastPartialTime = System.currentTimeMillis()

            while (isRecording && !Thread.interrupted()) {
                val read = recorder.read(buffer, 0, buffer.size, AudioRecord.READ_BLOCKING)
                if (read > 0) {
                    synchronized(audioSamples) {
                        for (i in 0 until read) {
                            audioSamples.add(buffer[i])
                        }
                    }

                    // Periodic partial transcription
                    val now = System.currentTimeMillis()
                    if (now - lastPartialTime >= PARTIAL_INTERVAL_MS) {
                        lastPartialTime = now
                        runPartialTranscription()
                    }
                }
            }
        }
        recordingThread?.start()
        Log.i(TAG, "Started recording with Whisper engine")
    }

    fun requestStop() {
        Log.i(TAG, "requestStop called")
        isRecording = false

        try {
            recordingThread?.join(2000)
        } catch (_: InterruptedException) {}
        recordingThread = null

        audioRecord?.apply {
            try { stop() } catch (_: Exception) {}
            release()
        }
        audioRecord = null

        // Run final transcription
        val samples: FloatArray
        synchronized(audioSamples) {
            samples = FloatArray(audioSamples.size) { audioSamples[it] }
        }

        if (samples.isNotEmpty() && contextPtr != 0L) {
            try {
                val text = WhisperLib.fullTranscribe(contextPtr, samples)
                transcribedText = text
                Log.d(TAG, "Whisper final: '$text'")
                onFinalResult?.invoke(text)
            } catch (e: Exception) {
                Log.e(TAG, "Whisper transcription failed: ${e.message}", e)
                onFinalResult?.invoke(transcribedText)
            }
        } else {
            onFinalResult?.invoke("")
        }
    }

    fun stopRecording(): String {
        requestStop()
        return transcribedText
    }

    fun destroy() {
        downloadThread?.interrupt()
        downloadThread = null

        isRecording = false
        recordingThread?.interrupt()
        recordingThread = null

        audioRecord?.apply {
            try { stop() } catch (_: Exception) {}
            release()
        }
        audioRecord = null

        if (contextPtr != 0L) {
            WhisperLib.freeContext(contextPtr)
            contextPtr = 0
        }

        isModelReady = false
    }

    private fun runPartialTranscription() {
        val samples: FloatArray
        synchronized(audioSamples) {
            if (audioSamples.isEmpty()) return
            samples = FloatArray(audioSamples.size) { audioSamples[it] }
        }

        try {
            val text = WhisperLib.fullTranscribe(contextPtr, samples)
            if (text.isNotEmpty()) {
                transcribedText = text
                onPartialResult?.invoke(text)
            }
        } catch (e: Exception) {
            Log.w(TAG, "Partial transcription failed: ${e.message}")
        }
    }

    @Throws(InterruptedException::class)
    private fun downloadModel(url: String, destFile: File) {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.connectTimeout = 30_000
        connection.readTimeout = 60_000
        connection.instanceFollowRedirects = true
        connection.connect()

        val totalBytes = connection.contentLength.toLong()
        var bytesRead = 0L

        destFile.parentFile?.mkdirs()
        val tmpFile = File(destFile.parentFile, "${destFile.name}.tmp")

        connection.inputStream.buffered().use { input ->
            FileOutputStream(tmpFile).use { output ->
                val buffer = ByteArray(8192)
                var len: Int
                while (input.read(buffer).also { len = it } != -1) {
                    if (Thread.interrupted()) throw InterruptedException()
                    output.write(buffer, 0, len)
                    bytesRead += len
                    if (totalBytes > 0) {
                        downloadProgress = ((bytesRead * 100) / totalBytes).toInt().coerceIn(0, 100)
                    }
                }
            }
        }

        tmpFile.renameTo(destFile)
    }
}
