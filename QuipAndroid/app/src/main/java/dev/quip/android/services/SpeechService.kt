package dev.quip.android.services

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import org.json.JSONObject
import org.vosk.Model
import org.vosk.Recognizer
import org.vosk.android.SpeechService as VoskSpeechService
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.zip.ZipInputStream

class SpeechService {

    companion object {
        private const val TAG = "SpeechService"
        private const val MODEL_NAME = "vosk-model-small-en-us-0.15"
        private const val MODEL_URL = "https://alphacephei.com/vosk/models/$MODEL_NAME.zip"
        private const val SAMPLE_RATE = 16000.0f
    }

    enum class Engine { ANDROID, VOSK, WHISPER }

    @Volatile var isRecording: Boolean = false
        private set
    @Volatile var transcribedText: String = ""
        private set
    @Volatile var isModelReady: Boolean = false
        private set
    val isModelDownloading: Boolean
        get() = _isModelDownloading || whisperEngine.isModelDownloading
    @Volatile private var _isModelDownloading: Boolean = false

    val downloadProgress: Int // 0-100, or -1 if unknown
        get() = if (whisperEngine.isModelDownloading) whisperEngine.downloadProgress else _downloadProgress
    @Volatile private var _downloadProgress: Int = -1

    var onPartialResult: ((String) -> Unit)? = null
    var onFinalResult: ((String) -> Unit)? = null
    var onError: ((String) -> Unit)? = null

    private var engine: Engine = Engine.ANDROID

    // Vosk state
    private var voskModel: Model? = null
    private var voskService: VoskSpeechService? = null
    private var downloadThread: Thread? = null

    // Android SpeechRecognizer state
    private var androidRecognizer: SpeechRecognizer? = null

    // Whisper state
    private val whisperEngine = WhisperEngine()

    /**
     * Initialize the speech engine.
     * Priority: Whisper (if native lib available) > Android SpeechRecognizer (Google) > Vosk.
     */
    fun initModel(context: Context, onReady: (() -> Unit)? = null) {
        if (isModelReady) { onReady?.invoke(); return }

        // Prefer Whisper when the native library is present
        if (whisperEngine.isAvailable()) {
            engine = Engine.WHISPER
            Log.i(TAG, "Using Whisper STT engine")
            whisperEngine.onError = { msg -> onError?.invoke(msg) }
            whisperEngine.initModel(context) {
                isModelReady = true
                onReady?.invoke()
            }
            return
        }

        if (SpeechRecognizer.isRecognitionAvailable(context)) {
            engine = Engine.ANDROID
            isModelReady = true
            Log.i(TAG, "Using Android SpeechRecognizer (Google)")
            onReady?.invoke()
            return
        }

        // Fall back to Vosk
        engine = Engine.VOSK
        Log.i(TAG, "Android SpeechRecognizer not available, falling back to Vosk")
        initVoskModel(context, onReady)
    }

    private fun initVoskModel(context: Context, onReady: (() -> Unit)? = null) {
        val thread = Thread {
            try {
                val modelDir = File(context.filesDir, MODEL_NAME)
                if (!modelDir.exists()) {
                    _isModelDownloading = true
                    _downloadProgress = 0
                    Log.i(TAG, "Downloading Vosk model from $MODEL_URL")
                    downloadAndUnzip(MODEL_URL, context.filesDir)
                    if (Thread.interrupted()) return@Thread
                    _isModelDownloading = false
                    _downloadProgress = -1
                    Log.i(TAG, "Model downloaded and extracted to ${modelDir.absolutePath}")
                }

                voskModel = Model(modelDir.absolutePath)
                isModelReady = true
                Log.i(TAG, "Vosk model loaded successfully")
                onReady?.invoke()
            } catch (e: InterruptedException) {
                _isModelDownloading = false
                _downloadProgress = -1
                Log.i(TAG, "Vosk model download cancelled")
            } catch (e: Throwable) {
                _isModelDownloading = false
                _downloadProgress = -1
                Log.e(TAG, "Failed to init Vosk model: ${e.message}", e)
                onError?.invoke("Failed to load speech model: ${e.message}")
            }
        }
        downloadThread = thread
        thread.start()
    }

    fun startRecording(context: Context) {
        if (isRecording) return

        if (!isModelReady) {
            Log.e(TAG, "Model not loaded yet")
            onError?.invoke("Speech model not ready — downloading...")
            initModel(context)
            return
        }

        transcribedText = ""
        isRecording = true

        when (engine) {
            Engine.ANDROID -> startAndroidRecording(context)
            Engine.VOSK -> startVoskRecording(context)
            Engine.WHISPER -> startWhisperRecording()
        }
    }

    // -- Android SpeechRecognizer --

    private fun startAndroidRecording(context: Context) {
        try {
            val recognizer = SpeechRecognizer.createSpeechRecognizer(context)
            androidRecognizer = recognizer

            val completedSegments = StringBuilder()

            recognizer.setRecognitionListener(object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) {
                    Log.d(TAG, "Android STT ready for speech")
                }

                override fun onBeginningOfSpeech() {
                    Log.d(TAG, "Android STT speech started")
                }

                override fun onRmsChanged(rmsdB: Float) {}
                override fun onBufferReceived(buffer: ByteArray?) {}

                override fun onEndOfSpeech() {
                    Log.d(TAG, "Android STT end of speech")
                }

                override fun onError(error: Int) {
                    val msg = when (error) {
                        SpeechRecognizer.ERROR_NO_MATCH -> "No speech detected"
                        SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "Speech timeout"
                        SpeechRecognizer.ERROR_AUDIO -> "Audio error"
                        SpeechRecognizer.ERROR_NETWORK -> "Network error"
                        SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "Network timeout"
                        else -> "Recognition error ($error)"
                    }
                    Log.e(TAG, "Android STT error: $msg")
                    isRecording = false
                    // For no-match/timeout, treat as final with whatever we have
                    if (error == SpeechRecognizer.ERROR_NO_MATCH || error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT) {
                        onFinalResult?.invoke(transcribedText)
                    } else {
                        this@SpeechService.onError?.invoke(msg)
                    }
                }

                override fun onResults(results: Bundle?) {
                    val matches = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                    val text = matches?.firstOrNull()?.trim() ?: ""
                    if (text.isNotEmpty()) {
                        if (completedSegments.isNotEmpty()) completedSegments.append(" ")
                        completedSegments.append(text)
                        transcribedText = completedSegments.toString()
                    }
                    Log.d(TAG, "Android STT final: '$transcribedText'")
                    isRecording = false
                    onFinalResult?.invoke(transcribedText)
                }

                override fun onPartialResults(partialResults: Bundle?) {
                    val matches = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                    val partial = matches?.firstOrNull()?.trim() ?: ""
                    if (partial.isNotEmpty()) {
                        transcribedText = (completedSegments.toString() + " " + partial).trim()
                        Log.d(TAG, "Android STT partial: '$transcribedText'")
                        onPartialResult?.invoke(transcribedText)
                    }
                }

                override fun onEvent(eventType: Int, params: Bundle?) {}
            })

            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            }

            recognizer.startListening(intent)
            Log.i(TAG, "Started recording with Android SpeechRecognizer")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start Android recording: ${e.message}", e)
            isRecording = false
            onError?.invoke("Failed to start recording: ${e.message}")
        }
    }

    // -- Vosk --

    @Suppress("UNUSED_PARAMETER")
    private fun startVoskRecording(context: Context) {
        val currentModel = voskModel
        if (currentModel == null) {
            Log.e(TAG, "Vosk model not loaded yet")
            isRecording = false
            onError?.invoke("Speech model not ready")
            return
        }

        try {
            val recognizer = Recognizer(currentModel, SAMPLE_RATE)
            val service = VoskSpeechService(recognizer, SAMPLE_RATE)
            voskService = service

            val completedSegments = StringBuilder()

            service.startListening(object : org.vosk.android.RecognitionListener {
                override fun onPartialResult(hypothesis: String?) {
                    val partial = parseVoskText(hypothesis, "partial")
                    if (partial.isNotEmpty()) {
                        transcribedText = (completedSegments.toString() + " " + partial).trim()
                        Log.d(TAG, "Vosk partial: '$transcribedText'")
                        onPartialResult?.invoke(transcribedText)
                    }
                }

                override fun onResult(hypothesis: String?) {
                    val text = parseVoskText(hypothesis, "text")
                    if (text.isNotEmpty()) {
                        if (completedSegments.isNotEmpty()) completedSegments.append(" ")
                        completedSegments.append(text)
                        transcribedText = completedSegments.toString()
                        Log.d(TAG, "Vosk result segment: '$text', total: '$transcribedText'")
                    }
                }

                override fun onFinalResult(hypothesis: String?) {
                    val text = parseVoskText(hypothesis, "text")
                    if (text.isNotEmpty()) {
                        if (completedSegments.isNotEmpty()) completedSegments.append(" ")
                        completedSegments.append(text)
                        transcribedText = completedSegments.toString()
                    }
                    Log.d(TAG, "Vosk final: '$transcribedText'")
                    isRecording = false
                    onFinalResult?.invoke(transcribedText)
                }

                override fun onError(exception: Exception?) {
                    Log.e(TAG, "Vosk error: ${exception?.message}")
                    isRecording = false
                    this@SpeechService.onError?.invoke(exception?.message ?: "Recognition error")
                }

                override fun onTimeout() {
                    Log.d(TAG, "Vosk timeout")
                    isRecording = false
                    onFinalResult?.invoke(transcribedText)
                }
            })

            Log.i(TAG, "Started recording with Vosk")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start Vosk recording: ${e.message}", e)
            isRecording = false
            onError?.invoke("Failed to start recording: ${e.message}")
        }
    }

    // -- Whisper --

    private fun startWhisperRecording() {
        whisperEngine.onPartialResult = { text ->
            transcribedText = text
            Log.d(TAG, "Whisper partial: '$text'")
            onPartialResult?.invoke(text)
        }
        whisperEngine.onFinalResult = { text ->
            transcribedText = text
            Log.d(TAG, "Whisper final: '$text'")
            isRecording = false
            onFinalResult?.invoke(text)
        }
        whisperEngine.onError = { msg ->
            Log.e(TAG, "Whisper error: $msg")
            isRecording = false
            onError?.invoke(msg)
        }

        try {
            whisperEngine.startRecording()
            Log.i(TAG, "Started recording with Whisper")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start Whisper recording: ${e.message}", e)
            isRecording = false
            onError?.invoke("Failed to start recording: ${e.message}")
        }
    }

    fun requestStop() {
        Log.i(TAG, "requestStop called, engine=$engine, text='$transcribedText'")
        when (engine) {
            Engine.ANDROID -> {
                try {
                    androidRecognizer?.stopListening()
                } catch (e: Exception) {
                    Log.w(TAG, "Android STT stop error: ${e.message}")
                }
            }
            Engine.VOSK -> {
                try {
                    voskService?.stop()
                } catch (e: Exception) {
                    Log.w(TAG, "Vosk stop error: ${e.message}")
                }
                voskService = null
            }
            Engine.WHISPER -> {
                try {
                    whisperEngine.requestStop()
                } catch (e: Exception) {
                    Log.w(TAG, "Whisper stop error: ${e.message}")
                }
            }
        }
    }

    fun stopRecording(): String {
        Log.i(TAG, "stopRecording called, text='$transcribedText'")
        requestStop()
        isRecording = false
        return transcribedText
    }

    fun destroy() {
        // Cancel any in-progress Vosk model download
        downloadThread?.interrupt()
        downloadThread = null

        androidRecognizer?.apply {
            cancel()
            destroy()
        }
        androidRecognizer = null

        voskService?.apply {
            stop()
            shutdown()
        }
        voskService = null
        voskModel?.close()
        voskModel = null

        whisperEngine.destroy()

        isRecording = false
        isModelReady = false
    }

    private fun parseVoskText(json: String?, key: String): String {
        if (json.isNullOrBlank()) return ""
        return try {
            JSONObject(json).optString(key, "").trim()
        } catch (e: Exception) {
            ""
        }
    }

    @Throws(InterruptedException::class)
    private fun downloadAndUnzip(url: String, destDir: File) {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.connectTimeout = 30_000
        connection.readTimeout = 60_000
        connection.connect()

        val totalBytes = connection.contentLength.toLong() // may be -1
        var bytesRead = 0L

        ZipInputStream(connection.inputStream.buffered()).use { zis ->
            var entry = zis.nextEntry
            while (entry != null) {
                if (Thread.interrupted()) throw InterruptedException()
                val outFile = File(destDir, entry.name)
                if (entry.isDirectory) {
                    outFile.mkdirs()
                } else {
                    outFile.parentFile?.mkdirs()
                    FileOutputStream(outFile).use { fos ->
                        val buffer = ByteArray(8192)
                        var len: Int
                        while (zis.read(buffer).also { len = it } != -1) {
                            if (Thread.interrupted()) throw InterruptedException()
                            fos.write(buffer, 0, len)
                            bytesRead += len
                            if (totalBytes > 0) {
                                _downloadProgress = ((bytesRead * 100) / totalBytes).toInt().coerceIn(0, 100)
                            }
                        }
                    }
                }
                zis.closeEntry()
                entry = zis.nextEntry
            }
        }
    }
}
