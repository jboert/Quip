package dev.quip.android.services

/**
 * JNI bridge to whisper.cpp native library.
 * Requires libwhisper_jni.so to be built via CMake (see app/src/main/cpp/).
 */
object WhisperLib {

    private var loaded = false

    fun isAvailable(): Boolean {
        if (loaded) return true
        return try {
            System.loadLibrary("whisper_jni")
            loaded = true
            true
        } catch (e: UnsatisfiedLinkError) {
            false
        }
    }

    /** Load a GGML model file and return a context pointer (0 on failure). */
    external fun initContext(modelPath: String): Long

    /** Free a previously created context. */
    external fun freeContext(contextPtr: Long)

    /** Run full transcription on float PCM audio (16 kHz mono). Returns transcribed text. */
    external fun fullTranscribe(contextPtr: Long, audioData: FloatArray): String
}
