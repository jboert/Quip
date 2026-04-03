package dev.quip.android.services

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class SpeechService {

    companion object {
        private const val TAG = "SpeechService"
    }

    @Volatile var isRecording: Boolean = false
        private set
    @Volatile var transcribedText: String = ""
        private set
    @Volatile private var gotFinalResult: Boolean = false

    var onPartialResult: ((String) -> Unit)? = null
    var onFinalResult: ((String) -> Unit)? = null
    var onError: ((String) -> Unit)? = null

    private var speechRecognizer: SpeechRecognizer? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    fun isAvailable(context: Context): Boolean {
        return SpeechRecognizer.isRecognitionAvailable(context)
    }

    fun startRecording(context: Context) {
        if (isRecording) return

        if (!isAvailable(context)) {
            Log.e(TAG, "Speech recognition not available")
            onError?.invoke("Speech recognition not available on this device")
            return
        }

        transcribedText = ""
        gotFinalResult = false
        isRecording = true

        val recognizer = SpeechRecognizer.createSpeechRecognizer(context)
        speechRecognizer = recognizer

        recognizer.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {
                Log.d(TAG, "Ready for speech")
            }

            override fun onBeginningOfSpeech() {
                Log.d(TAG, "Speech started")
            }

            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}

            override fun onEndOfSpeech() {
                Log.d(TAG, "Speech ended")
            }

            override fun onError(error: Int) {
                val message = when (error) {
                    SpeechRecognizer.ERROR_AUDIO -> "Audio recording error"
                    SpeechRecognizer.ERROR_CLIENT -> "Client error"
                    SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Insufficient permissions"
                    SpeechRecognizer.ERROR_NETWORK -> "Network error"
                    SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "Network timeout"
                    SpeechRecognizer.ERROR_NO_MATCH -> "No speech recognized"
                    SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "Recognizer busy"
                    SpeechRecognizer.ERROR_SERVER -> "Server error"
                    SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "No speech input"
                    else -> "Unknown error ($error)"
                }
                Log.e(TAG, "Recognition error: $message (code=$error)")
                // ERROR_NO_MATCH and ERROR_SPEECH_TIMEOUT are not fatal —
                // they mean recognition finished with no text
                gotFinalResult = true
                isRecording = false
                if (error != SpeechRecognizer.ERROR_CLIENT) {
                    onError?.invoke(message)
                }
            }

            override fun onResults(results: Bundle?) {
                val matches = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                val bestResult = matches?.firstOrNull() ?: ""
                if (bestResult.isNotEmpty()) {
                    transcribedText = bestResult
                }
                Log.d(TAG, "Final result: '$transcribedText'")
                gotFinalResult = true
                isRecording = false
                onFinalResult?.invoke(transcribedText)
            }

            override fun onPartialResults(partialResults: Bundle?) {
                val matches = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                val partial = matches?.firstOrNull() ?: ""
                if (partial.isNotEmpty()) {
                    transcribedText = partial
                    Log.d(TAG, "Partial result: '$partial'")
                    onPartialResult?.invoke(partial)
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
        Log.i(TAG, "Started recording")
    }

    /**
     * Stop recording and return the transcribed text.
     * Signals the recognizer to stop, then waits briefly for the final result
     * callback before returning whatever text we have.
     */
    fun stopRecording(): String {
        Log.i(TAG, "stopRecording called, gotFinalResult=$gotFinalResult, text='$transcribedText'")

        // If we already got a final result (recognizer auto-stopped), just clean up
        if (gotFinalResult) {
            cleanupRecognizer()
            return transcribedText
        }

        // Tell recognizer to finish — this triggers onResults asynchronously
        try {
            speechRecognizer?.stopListening()
        } catch (e: Exception) {
            Log.w(TAG, "stopListening error: ${e.message}")
        }

        // Wait up to 1.5 seconds for the final result callback
        val startTime = System.currentTimeMillis()
        while (!gotFinalResult && System.currentTimeMillis() - startTime < 1500) {
            Thread.sleep(50)
        }

        Log.i(TAG, "After wait: gotFinalResult=$gotFinalResult, text='$transcribedText'")

        cleanupRecognizer()
        isRecording = false
        return transcribedText
    }

    private fun cleanupRecognizer() {
        mainHandler.post {
            try {
                speechRecognizer?.destroy()
            } catch (e: Exception) {
                Log.w(TAG, "destroy error: ${e.message}")
            }
            speechRecognizer = null
        }
    }

    fun destroy() {
        speechRecognizer?.destroy()
        speechRecognizer = null
        isRecording = false
    }
}
