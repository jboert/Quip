package dev.quip.android.services

import android.content.Context
import android.util.Log
import org.json.JSONObject
import org.vosk.Model
import org.vosk.Recognizer
import org.vosk.android.RecognitionListener
import org.vosk.android.SpeechService as VoskSpeechService
import java.io.File
import java.io.FileOutputStream
import java.net.URL
import java.util.zip.ZipInputStream

class SpeechService {

    companion object {
        private const val TAG = "SpeechService"
        private const val MODEL_NAME = "vosk-model-small-en-us-0.15"
        private const val MODEL_URL = "https://alphacephei.com/vosk/models/$MODEL_NAME.zip"
        private const val SAMPLE_RATE = 16000.0f
    }

    @Volatile var isRecording: Boolean = false
        private set
    @Volatile var transcribedText: String = ""
        private set
    @Volatile var isModelReady: Boolean = false
        private set
    @Volatile var isModelDownloading: Boolean = false
        private set

    var onPartialResult: ((String) -> Unit)? = null
    var onFinalResult: ((String) -> Unit)? = null
    var onError: ((String) -> Unit)? = null

    private var model: Model? = null
    private var voskService: VoskSpeechService? = null

    /**
     * Initialize the Vosk model. Downloads on first use, then loads from disk.
     * Call from a background thread or early in the app lifecycle.
     */
    fun initModel(context: Context, onReady: (() -> Unit)? = null) {
        if (isModelReady) { onReady?.invoke(); return }

        Thread {
            try {
                val modelDir = File(context.filesDir, MODEL_NAME)
                if (!modelDir.exists()) {
                    isModelDownloading = true
                    Log.i(TAG, "Downloading Vosk model from $MODEL_URL")
                    downloadAndUnzip(MODEL_URL, context.filesDir)
                    isModelDownloading = false
                    Log.i(TAG, "Model downloaded and extracted to ${modelDir.absolutePath}")
                }

                model = Model(modelDir.absolutePath)
                isModelReady = true
                Log.i(TAG, "Vosk model loaded successfully")
                onReady?.invoke()
            } catch (e: Throwable) {
                isModelDownloading = false
                Log.e(TAG, "Failed to init Vosk model: ${e.message}", e)
                onError?.invoke("Failed to load speech model: ${e.message}")
            }
        }.start()
    }

    fun startRecording(context: Context) {
        if (isRecording) return

        val currentModel = model
        if (currentModel == null) {
            Log.e(TAG, "Model not loaded yet")
            onError?.invoke("Speech model not ready — downloading...")
            initModel(context)
            return
        }

        transcribedText = ""
        isRecording = true

        try {
            val recognizer = Recognizer(currentModel, SAMPLE_RATE)
            val service = VoskSpeechService(recognizer, SAMPLE_RATE)
            voskService = service

            // Accumulate completed segments across pauses
            val completedSegments = StringBuilder()

            service.startListening(object : RecognitionListener {
                override fun onPartialResult(hypothesis: String?) {
                    val partial = parseText(hypothesis, "partial")
                    if (partial.isNotEmpty()) {
                        // Show accumulated + current partial
                        transcribedText = (completedSegments.toString() + " " + partial).trim()
                        Log.d(TAG, "Partial: '$transcribedText'")
                        onPartialResult?.invoke(transcribedText)
                    }
                }

                override fun onResult(hypothesis: String?) {
                    val text = parseText(hypothesis, "text")
                    if (text.isNotEmpty()) {
                        // Append completed segment
                        if (completedSegments.isNotEmpty()) completedSegments.append(" ")
                        completedSegments.append(text)
                        transcribedText = completedSegments.toString()
                        Log.d(TAG, "Result segment: '$text', total: '$transcribedText'")
                    }
                }

                override fun onFinalResult(hypothesis: String?) {
                    val text = parseText(hypothesis, "text")
                    if (text.isNotEmpty()) {
                        if (completedSegments.isNotEmpty()) completedSegments.append(" ")
                        completedSegments.append(text)
                        transcribedText = completedSegments.toString()
                    }
                    Log.d(TAG, "Final: '$transcribedText'")
                    isRecording = false
                    onFinalResult?.invoke(transcribedText)
                }

                override fun onError(exception: Exception?) {
                    Log.e(TAG, "Vosk error: ${exception?.message}")
                    isRecording = false
                    onError?.invoke(exception?.message ?: "Recognition error")
                }

                override fun onTimeout() {
                    Log.d(TAG, "Vosk timeout")
                    isRecording = false
                    onFinalResult?.invoke(transcribedText)
                }
            })

            Log.i(TAG, "Started recording with Vosk")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start recording: ${e.message}", e)
            isRecording = false
            onError?.invoke("Failed to start recording: ${e.message}")
        }
    }

    fun requestStop() {
        Log.i(TAG, "requestStop called, current text='$transcribedText'")
        try {
            voskService?.stop() // triggers onFinalResult
        } catch (e: Exception) {
            Log.w(TAG, "stop error: ${e.message}")
        }
        voskService = null
    }

    fun stopRecording(): String {
        Log.i(TAG, "stopRecording called, text='$transcribedText'")
        requestStop()
        isRecording = false
        return transcribedText
    }

    fun destroy() {
        voskService?.apply {
            stop()
            shutdown()
        }
        voskService = null
        model?.close()
        model = null
        isRecording = false
        isModelReady = false
    }

    private fun parseText(json: String?, key: String): String {
        if (json.isNullOrBlank()) return ""
        return try {
            JSONObject(json).optString(key, "").trim()
        } catch (e: Exception) {
            ""
        }
    }

    private fun downloadAndUnzip(url: String, destDir: File) {
        val connection = URL(url).openConnection()
        connection.connectTimeout = 30_000
        connection.readTimeout = 60_000
        ZipInputStream(connection.getInputStream().buffered()).use { zis ->
            var entry = zis.nextEntry
            while (entry != null) {
                val outFile = File(destDir, entry.name)
                if (entry.isDirectory) {
                    outFile.mkdirs()
                } else {
                    outFile.parentFile?.mkdirs()
                    FileOutputStream(outFile).use { fos ->
                        zis.copyTo(fos)
                    }
                }
                zis.closeEntry()
                entry = zis.nextEntry
            }
        }
    }
}
