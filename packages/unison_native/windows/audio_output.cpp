#include "audio_output.h"
#include "unison/receiver.h"

#include <windows.h>
#include <audioclient.h>
#include <avrt.h>
#include <mmdeviceapi.h>
#include <propkeydef.h>
#include <functiondiscoverykeys_devpkey.h>
#include <ks.h>
#include <ksmedia.h>
#include <wrl/client.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <mutex>
#include <optional>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

using Microsoft::WRL::ComPtr;

namespace {
std::atomic<bool> running{false}, rebuild{false};
std::mutex volumeMutex;
float desiredGain = 1.0f, actualGain = 1.0f;
bool volumePending = false;
std::mutex settingsMutex;
std::wstring selectedOutput, endpointId;
bool usingDefaultOutput = true;
std::string actualDevice;
void setStatus(const std::string& value) { std::lock_guard<std::mutex> lock(settingsMutex); actualDevice = value; }
unison::Receiver networkReceiver;
std::thread worker;
std::string utf8(const std::wstring& value) {
    if (value.empty()) return {};
    int size = WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
    std::string out(size, '\0');
    WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), out.data(), size, nullptr, nullptr);
    return out;
}
std::wstring deviceName(IMMDevice* device) {
    ComPtr<IPropertyStore> store;
    PROPVARIANT name;
    PropVariantInit(&name);
    std::wstring value;
    if (SUCCEEDED(device->OpenPropertyStore(STGM_READ, &store)) &&
        SUCCEEDED(store->GetValue(PKEY_Device_FriendlyName, &name)) && name.vt == VT_LPWSTR)
        value = name.pwszVal;
    PropVariantClear(&name);
    return value;
}

HRESULT enumerator(ComPtr<IMMDeviceEnumerator>& out) {
    return CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&out));
}
HRESULT chooseDevice(IMMDeviceEnumerator* devices, const std::wstring& selection, ComPtr<IMMDevice>& out) {
    bool selectedActive = false;
    if (!selection.empty() && SUCCEEDED(devices->GetDevice(selection.c_str(), &out))) {
        DWORD state = 0;
        selectedActive = SUCCEEDED(out->GetState(&state)) && state == DEVICE_STATE_ACTIVE;
    }
    { std::lock_guard<std::mutex> lock(settingsMutex); usingDefaultOutput = !selectedActive; }
    if (selectedActive) return S_OK;
    // 只替换实际流，不清除用户选择；设备恢复通知会使其重新打开。
    out.Reset();
    return devices->GetDefaultAudioEndpoint(eRender, eConsole, &out);
}

struct AudioOutput {
    ComPtr<IAudioClient> client;
    ComPtr<IAudioRenderClient> renderer;
    ComPtr<IAudioClock> clock;
    ComPtr<ISimpleAudioVolume> sessionVolume;
    WAVEFORMATEX* format = nullptr;
    HANDLE event = nullptr;
    UINT32 capacity = 0;
    UINT64 frequency = 0;
    UINT64 written = 0;
    bool inflightReady = false;
    std::array<double, 5> inflightSamples{};
    size_t inflightCount = 0, inflightNext = 0;
    double inflightBaseline = 0;
    int64_t lastInflightUs = 0;
    int inflightDropCount = 0;
    int64_t inflightDropSinceUs = 0;
    REFERENCE_TIME latency = 0;
    bool floating = false;
    int validBits = 0;
    std::vector<float> stereo;

    HRESULT synchronizeVolume(bool initial = false) {
        std::optional<float> command;
        {
            std::lock_guard<std::mutex> lock(volumeMutex);
            if (volumePending) { command = desiredGain; volumePending = false; }
            else if (initial) command = actualGain;
        }
        if (command) {
            HRESULT hr = sessionVolume->SetMasterVolume(*command, nullptr);
            if (SUCCEEDED(hr)) hr = sessionVolume->SetMute(FALSE, nullptr);
            std::lock_guard<std::mutex> lock(volumeMutex);
            if (FAILED(hr)) {
                // 设备切换导致写入失败时保留命令；更新的命令优先。
                if (!volumePending) { desiredGain = *command; volumePending = true; }
            } else actualGain = *command;
            return hr;
        }
        float value = 0; BOOL muted = FALSE;
        HRESULT hr = sessionVolume->GetMasterVolume(&value);
        if (SUCCEEDED(hr)) hr = sessionVolume->GetMute(&muted);
        if (SUCCEEDED(hr)) {
            std::lock_guard<std::mutex> lock(volumeMutex);
            // 回读只修改实际值；并发到来的期望值仍在 pending 中等待下一轮消费。
            actualGain = muted ? 0.0f : value;
        }
        return hr;
    }

    ~AudioOutput() {
        if (client) client->Stop();
        renderer.Reset();
        clock.Reset();
        client.Reset();
        if (event) CloseHandle(event);
        CoTaskMemFree(format);
    }

    HRESULT open(const std::wstring& id) {
        ComPtr<IMMDeviceEnumerator> devices;
        HRESULT hr = enumerator(devices);
        if (FAILED(hr)) return hr;
        ComPtr<IMMDevice> device;
        hr = chooseDevice(devices.Get(), id, device);
        if (FAILED(hr)) return hr;
        if (FAILED(hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, &client))) return hr;
        if (FAILED(hr = client->GetMixFormat(&format))) return hr;
        validBits = format->wBitsPerSample;
        floating = format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT;
        bool pcm = format->wFormatTag == WAVE_FORMAT_PCM;
        if (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE && format->cbSize >= sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)) {
            auto* ext = reinterpret_cast<WAVEFORMATEXTENSIBLE*>(format);
            floating = IsEqualGUID(ext->SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT);
            pcm = IsEqualGUID(ext->SubFormat, KSDATAFORMAT_SUBTYPE_PCM);
            if (ext->Samples.wValidBitsPerSample) validBits = ext->Samples.wValidBitsPerSample;
        }
        if (!format->nSamplesPerSec || !format->nChannels ||
            (!floating && !pcm) ||
            (floating && format->wBitsPerSample != 32 && format->wBitsPerSample != 64) ||
            (pcm && format->wBitsPerSample != 8 && format->wBitsPerSample != 16 &&
             format->wBitsPerSample != 24 && format->wBitsPerSample != 32) ||
            validBits <= 0 || validBits > format->wBitsPerSample)
            return AUDCLNT_E_UNSUPPORTED_FORMAT;

        // 优先用设备允许的最短共享周期；引擎周期被其他客户端锁定时使用默认共享模式。
        ComPtr<IAudioClient3> client3;
        hr = client.As(&client3);
        if (SUCCEEDED(hr)) {
            UINT32 defaultPeriod = 0, fundamental = 0, minimum = 0, maximum = 0;
            hr = client3->GetSharedModeEnginePeriod(format, &defaultPeriod, &fundamental, &minimum, &maximum);
            if (SUCCEEDED(hr)) hr = client3->InitializeSharedAudioStream(AUDCLNT_STREAMFLAGS_EVENTCALLBACK, minimum, format, nullptr);
        }
        if (FAILED(hr)) {
            client3.Reset();
            client.Reset();
            if (FAILED(hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, &client))) return hr;
            hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_EVENTCALLBACK, 0, 0, format, nullptr);
        }
        if (FAILED(hr)) return hr;
        event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        if (!event) return HRESULT_FROM_WIN32(GetLastError());
        if (FAILED(hr = client->SetEventHandle(event))) return hr;
        if (FAILED(hr = client->GetBufferSize(&capacity))) return hr;
        if (FAILED(hr = client->GetService(IID_PPV_ARGS(&renderer)))) return hr;
        if (FAILED(hr = client->GetService(IID_PPV_ARGS(&clock)))) return hr;
        if (FAILED(hr = client->GetService(IID_PPV_ARGS(&sessionVolume)))) return hr;
        if (FAILED(hr = synchronizeVolume(true))) return hr;
        if (FAILED(hr = clock->GetFrequency(&frequency))) return hr;
        client->GetStreamLatency(&latency);
        stereo.resize(static_cast<size_t>(capacity) * 2);
        BYTE* initial = nullptr;
        if (FAILED(hr = renderer->GetBuffer(capacity, &initial))) return hr;
        if (FAILED(hr = renderer->ReleaseBuffer(capacity, AUDCLNT_BUFFERFLAGS_SILENT))) return hr;
        written = capacity;
        if (FAILED(hr = client->Start())) return hr;
        setStatus(utf8(deviceName(device.Get())));
        LPWSTR currentId = nullptr;
        if (SUCCEEDED(device->GetId(&currentId))) { std::lock_guard<std::mutex> lock(settingsMutex); endpointId = currentId; CoTaskMemFree(currentId); }
        return S_OK;
    }

    void encode(BYTE* target, UINT32 frames) {
        int bytes = format->wBitsPerSample / 8;
        std::memset(target, 0, static_cast<size_t>(frames) * format->nBlockAlign);
        for (UINT32 f = 0; f < frames; ++f) {
            for (int channel = 0; channel < format->nChannels; ++channel) {
                float value = format->nChannels == 1 ? (stereo[f * 2] + stereo[f * 2 + 1]) * 0.5f :
                    (channel < 2 ? stereo[f * 2 + channel] : 0.0f);
                BYTE* p = target + static_cast<size_t>(f) * format->nBlockAlign + channel * bytes;
                if (floating) {
                    if (bytes == 4) std::memcpy(p, &value, 4);
                    else { double wide = value; std::memcpy(p, &wide, 8); }
                } else if (bytes == 1) {
                    p[0] = static_cast<BYTE>(std::clamp(std::lround(value * 127) + 128, 0L, 255L));
                } else {
                    double scale = static_cast<double>((uint64_t{1} << (validBits - 1)) - 1);
                    int64_t integer = std::llround(std::clamp(static_cast<double>(value), -1.0, 1.0) * scale);
                    integer *= int64_t{1} << (format->wBitsPerSample - validBits);
                    for (int b = 0; b < bytes; ++b) p[b] = static_cast<BYTE>(static_cast<uint64_t>(integer) >> (8 * b));
                }
            }
        }
    }

    HRESULT fill(unison::Receiver& receiver) {
        constexpr int64_t kInflightDropUs = 3'000;
        constexpr int64_t kMaxQueryUs = 1'000;
        int64_t queryStartedUs = unison::monotonicUs();
        UINT32 padding = 0;
        HRESULT hr = client->GetCurrentPadding(&padding);
        if (FAILED(hr)) return hr;
        UINT32 frames = capacity - padding;
        UINT64 position = 0, qpc100ns = 0;
        bool real = clock->GetPosition(&position, &qpc100ns) == S_OK && frequency != 0 && position != 0;
        int64_t queriedUs = unison::monotonicUs();
        int64_t firstFrameUs;
        if (real) {
            double playedFrames = static_cast<double>(position) * format->nSamplesPerSec / frequency;
            double inflight = static_cast<double>(written) - playedFrames - padding;
            double dropFrames = format->nSamplesPerSec * (kInflightDropUs / 1e6);
            // 两次查询未原子配对；采样本身停顿过久时留待下一次检测。
            bool paired = queriedUs - queryStartedUs < kMaxQueryUs;
            // padding 不包含引擎到硬件的在途帧；欠载后重建流，不能据此修补帧零点。
            if (playedFrames > written) {
                receiver.addXruns(1);
                return AUDCLNT_E_BUFFER_ERROR;
            }
            if (paired) {
                inflightSamples[inflightNext] = inflight;
                inflightNext = (inflightNext + 1) % inflightSamples.size();
                if (inflightCount < inflightSamples.size()) ++inflightCount;
                if (inflightCount == inflightSamples.size()) {
                    auto sorted = inflightSamples;
                    std::sort(sorted.begin(), sorted.end());
                    double median = sorted[sorted.size() / 2];
                    if (!inflightReady && playedFrames >= capacity) {
                        // 预填充缓冲发声后，用完整窗口建立新流的基线。
                        inflightBaseline = median;
                        inflightReady = true;
                    } else if (inflightReady && inflightBaseline - median > dropFrames) {
                        // 候选下降期间冻结基线，连续有效观测足够久才重建。
                        if (inflightDropCount == 0) inflightDropSinceUs = queriedUs;
                        ++inflightDropCount;
                        if (inflightDropCount >= 3 && queriedUs - inflightDropSinceUs >= 30'000) {
                            receiver.addXruns(1);
                            return AUDCLNT_E_BUFFER_ERROR;
                        }
                    } else if (inflightReady) {
                        inflightDropCount = 0;
                        inflightDropSinceUs = 0;
                        double follow = 1.0 - std::exp(-(queriedUs - lastInflightUs) / 1e6);
                        inflightBaseline += follow * (median - inflightBaseline);
                    }
                }
                lastInflightUs = queriedUs;
            }
            firstFrameUs = static_cast<int64_t>(qpc100ns / 10.0 +
                (static_cast<double>(written) / format->nSamplesPerSec - static_cast<double>(position) / frequency) * 1e6);
        } else {
            firstFrameUs = unison::monotonicUs() + latency / 10 +
                static_cast<int64_t>(padding * 1e6 / format->nSamplesPerSec);
        }
        if (!frames) return S_OK;
        BYTE* target = nullptr;
        if (FAILED(hr = renderer->GetBuffer(frames, &target))) return hr;
        receiver.render(stereo.data(), static_cast<int>(frames), static_cast<int>(format->nSamplesPerSec), firstFrameUs, real);
        if (FAILED(hr = synchronizeVolume())) { renderer->ReleaseBuffer(frames, AUDCLNT_BUFFERFLAGS_SILENT); return hr; }
        encode(target, frames);
        hr = renderer->ReleaseBuffer(frames, 0);
        if (SUCCEEDED(hr)) written += frames;
        return hr;
    }
};


std::wstring wide(const std::string& text) {
    int size = MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0);
    std::wstring value(size, L'\0'); MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), value.data(), size); return value;
}
std::string jsonString(const std::string& text) {
    std::string out = "\"";
    for (unsigned char c : text) { if (c == '"' || c == '\\') out += '\\'; if (c >= 32) out += static_cast<char>(c); }
    return out + "\"";
}
class Notifications : public IMMNotificationClient {
    std::atomic<ULONG> references{1};
public:
    ULONG STDMETHODCALLTYPE AddRef() override { return ++references; }
    ULONG STDMETHODCALLTYPE Release() override { auto n = --references; if (!n) delete this; return n; }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override {
        if (iid == __uuidof(IUnknown) || iid == __uuidof(IMMNotificationClient)) { *out = static_cast<IMMNotificationClient*>(this); AddRef(); return S_OK; }
        *out = nullptr; return E_NOINTERFACE;
    }
    HRESULT STDMETHODCALLTYPE OnDefaultDeviceChanged(EDataFlow flow, ERole role, LPCWSTR) override {
        std::lock_guard<std::mutex> lock(settingsMutex);
        if (flow == eRender && role == eConsole && usingDefaultOutput) rebuild = true;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE OnDeviceAdded(LPCWSTR id) override { std::lock_guard<std::mutex> lock(settingsMutex); if (selectedOutput == id) rebuild = true; return S_OK; }
    HRESULT STDMETHODCALLTYPE OnDeviceRemoved(LPCWSTR id) override { std::lock_guard<std::mutex> lock(settingsMutex); if (endpointId == id) rebuild = true; return S_OK; }
    HRESULT STDMETHODCALLTYPE OnDeviceStateChanged(LPCWSTR id, DWORD) override { std::lock_guard<std::mutex> lock(settingsMutex); if (endpointId == id || selectedOutput == id) rebuild = true; return S_OK; }
    HRESULT STDMETHODCALLTYPE OnPropertyValueChanged(LPCWSTR, const PROPERTYKEY) override { return S_OK; }
};
void renderLoop() {
    if (FAILED(CoInitializeEx(nullptr, COINIT_MULTITHREADED))) return;
    DWORD index = 0; HANDLE priority = AvSetMmThreadCharacteristicsW(L"Pro Audio", &index);
    ComPtr<IMMDeviceEnumerator> watcher; enumerator(watcher);
    auto* notifications = new Notifications;
    if (watcher) watcher->RegisterEndpointNotificationCallback(notifications);
    while (running.load()) {
        rebuild = false;
        std::wstring id; { std::lock_guard<std::mutex> lock(settingsMutex); id = selectedOutput; }
        bool underrun = false;
        {
            setStatus("");
            AudioOutput output;
            HRESULT hr = output.open(id);
            if (SUCCEEDED(hr)) {
                networkReceiver.resetOutputTiming();
                while (running.load() && !rebuild.load()) {
                    if (WaitForSingleObject(output.event, 100) == WAIT_FAILED) break;
                    if (FAILED(hr = output.fill(networkReceiver))) break;
                }
            }
            underrun = hr == AUDCLNT_E_BUFFER_ERROR;
        }
        if (underrun) continue;
        for (int i = 0; i < 10 && running.load() && !rebuild.load(); ++i) std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    if (watcher) watcher->UnregisterEndpointNotificationCallback(notifications);
    notifications->Release();
    if (priority) AvRevertMmThreadCharacteristics(priority);
    CoUninitialize();
}
}
namespace unison_windows {
uint64_t receiverId() { return networkReceiver.receiverId(); }
bool start(const std::string& source) {
    stop(); if (!networkReceiver.start(source)) return false;
    running = true; worker = std::thread(renderLoop); return true;
}
void stop() { running = false; if (worker.joinable()) worker.join(); networkReceiver.stop(); }
void offset(int64_t us) { networkReceiver.setOffsetUs(us); }
std::string stats() {
    std::string data = networkReceiver.statsJson(); data.pop_back();
    std::lock_guard<std::mutex> lock(settingsMutex);
    return data + ",\"outputDevice\":" + jsonString(running.load() ? actualDevice : "") + "}";
}
std::vector<OutputDevice> devices() {
    HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    std::vector<OutputDevice> values;
    ComPtr<IMMDeviceEnumerator> list; ComPtr<IMMDeviceCollection> collection;
    if (SUCCEEDED(enumerator(list)) && SUCCEEDED(list->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &collection))) {
        UINT count = 0; collection->GetCount(&count);
        for (UINT i = 0; i < count; ++i) {
            ComPtr<IMMDevice> current;
            if (FAILED(collection->Item(i, &current))) continue;
            LPWSTR id = nullptr;
            if (SUCCEEDED(current->GetId(&id))) { values.push_back({utf8(id), utf8(deviceName(current.Get()))}); CoTaskMemFree(id); }
        }
    }
    collection.Reset(); list.Reset(); if (SUCCEEDED(initialized)) CoUninitialize(); return values;
}
void device(const std::string& id) {
    std::lock_guard<std::mutex> lock(settingsMutex); selectedOutput = wide(id); rebuild = true;
}
void volume(double value) { std::lock_guard<std::mutex> lock(volumeMutex); desiredGain = static_cast<float>(std::clamp(value, 0.0, 1.0)); volumePending = true; }
double volume() { std::lock_guard<std::mutex> lock(volumeMutex); return volumePending ? desiredGain : actualGain; }
}
