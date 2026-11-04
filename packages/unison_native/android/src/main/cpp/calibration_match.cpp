#include <jni.h>
#include <algorithm>
#include <cmath>
#include <complex>
#include <vector>

// 匹配滤波与直达声选择借鉴 PiliPlus calibration_signal.dart；这里只处理一条扫频。
static void fft(std::vector<std::complex<double>>& data, bool inverse) {
    const size_t n = data.size();
    for (size_t i = 1, j = 0; i < n; ++i) {
        size_t bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) std::swap(data[i], data[j]);
    }
    constexpr double pi = 3.14159265358979323846;
    for (size_t length = 2; length <= n; length <<= 1) {
        const auto step = std::polar(1.0, (inverse ? 2 : -2) * pi / length);
        for (size_t start = 0; start < n; start += length) {
            std::complex<double> rotation(1, 0);
            for (size_t j = 0; j < length / 2; ++j) {
                const auto a = data[start + j];
                const auto b = data[start + j + length / 2] * rotation;
                data[start + j] = a + b;
                data[start + j + length / 2] = a - b;
                rotation *= step;
            }
        }
    }
    if (inverse) for (auto& value : data) value /= n;
}

extern "C" JNIEXPORT jdoubleArray JNICALL
Java_io_github_ichaivalx_unison_capture_AcousticCalibration_detect(
        JNIEnv* env, jobject, jfloatArray recording, jfloatArray sine, jfloatArray cosine, jboolean directSound) {
    const auto length = static_cast<size_t>(env->GetArrayLength(recording));
    const auto m = static_cast<size_t>(env->GetArrayLength(sine));
    if (m == 0 || length < m + 3 || env->GetArrayLength(cosine) != static_cast<jsize>(m)) return nullptr;
    std::vector<float> samples(length), s(m), c(m);
    env->GetFloatArrayRegion(recording, 0, length, samples.data());
    env->GetFloatArrayRegion(sine, 0, m, s.data());
    env->GetFloatArrayRegion(cosine, 0, m, c.data());
    size_t n = 1;
    while (n < length + m - 1) n <<= 1;
    std::vector<std::complex<double>> signal(n), kernel(n);
    double mean = 0, norm = 0;
    for (const auto value : samples) mean += value;
    mean /= length;
    for (size_t i = 0; i < length; ++i) signal[i] = samples[i] - mean;
    for (size_t i = 0; i < m; ++i) {
        kernel[m - 1 - i] = {s[i], c[i]};
        norm += double(s[i]) * s[i];
    }
    fft(signal, false); fft(kernel, false);
    for (size_t i = 0; i < n; ++i) signal[i] *= kernel[i];
    fft(signal, true);
    const size_t lags = length - m + 1;
    std::vector<double> envelope(lags);
    size_t peak = 0;
    for (size_t i = 0; i < lags; ++i) {
        envelope[i] = std::abs(signal[i + m - 1]);
        if (envelope[i] > envelope[peak]) peak = i;
    }
    double noise = 0;
    size_t count = 0;
    for (size_t i = 0; i < lags; ++i) if (std::abs(double(i) - peak) >= m) {
        noise += envelope[i] * envelope[i]; ++count;
    }
    noise = std::sqrt(noise / std::max(size_t(1), count));
    // 最强峰前 15ms 内，取达到其一半且高于背景的最早局部峰。
    const double threshold = std::max(envelope[peak] * 0.5, noise * 8);
    const size_t earliest = peak > 720 ? peak - 720 : 1;
    for (size_t i = earliest; directSound && i < peak; ++i) {
        if (envelope[i] >= threshold && envelope[i] >= envelope[i - 1] && envelope[i] >= envelope[i + 1]) {
            peak = i; break;
        }
    }
    double fraction = 0;
    if (peak > 0 && peak + 1 < lags) {
        const double denominator = envelope[peak - 1] - 2 * envelope[peak] + envelope[peak + 1];
        if (denominator != 0) fraction = std::clamp(0.5 * (envelope[peak - 1] - envelope[peak + 1]) / denominator, -0.5, 0.5);
    }
    double energy = 0;
    for (size_t i = 0; i < m; ++i) energy += std::pow(samples[peak + i] - mean, 2);
    const double values[] = {double(peak) + fraction, envelope[peak] / std::max(noise, 1e-12),
        std::min(1.0, envelope[peak] / std::sqrt(std::max(energy * norm, 1e-24)))};
    jdoubleArray result = env->NewDoubleArray(3);
    if (result) env->SetDoubleArrayRegion(result, 0, 3, values);
    return result;
}
