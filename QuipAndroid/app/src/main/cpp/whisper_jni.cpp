#include <jni.h>
#include <string>
#include "whisper.h"

extern "C" {

JNIEXPORT jlong JNICALL
Java_dev_quip_android_services_WhisperLib_initContext(
        JNIEnv *env, jobject /* this */, jstring modelPath) {
    const char *path = env->GetStringUTFChars(modelPath, nullptr);
    struct whisper_context_params cparams = whisper_context_default_params();
    struct whisper_context *ctx = whisper_init_from_file_with_params(path, cparams);
    env->ReleaseStringUTFChars(modelPath, path);
    return reinterpret_cast<jlong>(ctx);
}

JNIEXPORT void JNICALL
Java_dev_quip_android_services_WhisperLib_freeContext(
        JNIEnv * /* env */, jobject /* this */, jlong contextPtr) {
    auto *ctx = reinterpret_cast<struct whisper_context *>(contextPtr);
    if (ctx) {
        whisper_free(ctx);
    }
}

JNIEXPORT jstring JNICALL
Java_dev_quip_android_services_WhisperLib_fullTranscribe(
        JNIEnv *env, jobject /* this */, jlong contextPtr, jfloatArray audioData) {
    auto *ctx = reinterpret_cast<struct whisper_context *>(contextPtr);
    if (!ctx) {
        return env->NewStringUTF("");
    }

    jfloat *data = env->GetFloatArrayElements(audioData, nullptr);
    jsize len = env->GetArrayLength(audioData);

    struct whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.print_progress   = false;
    params.print_special    = false;
    params.print_realtime   = false;
    params.print_timestamps = false;
    params.single_segment   = true;
    params.language         = "en";
    params.n_threads        = 4;
    params.no_context       = true;

    int ret = whisper_full(ctx, params, data, len);
    env->ReleaseFloatArrayElements(audioData, data, JNI_ABORT);

    if (ret != 0) {
        return env->NewStringUTF("");
    }

    std::string result;
    int n_segments = whisper_full_n_segments(ctx);
    for (int i = 0; i < n_segments; i++) {
        const char *text = whisper_full_get_segment_text(ctx, i);
        if (text) {
            result += text;
        }
    }

    // Trim leading/trailing whitespace
    size_t start = result.find_first_not_of(" \t\n\r");
    size_t end = result.find_last_not_of(" \t\n\r");
    if (start != std::string::npos) {
        result = result.substr(start, end - start + 1);
    } else {
        result.clear();
    }

    return env->NewStringUTF(result.c_str());
}

} // extern "C"
