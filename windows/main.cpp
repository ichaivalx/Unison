#include "unison/receiver.h"

#include <windows.h>
#include <audioclient.h>
#include <avrt.h>
#include <conio.h>
#include <mmdeviceapi.h>
#include <propkeydef.h>
#include <functiondiscoverykeys_devpkey.h>
#include <ks.h>
#include <ksmedia.h>
#include <wrl/client.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <cwctype>
#include <iomanip>
#include <iostream>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

using Microsoft::WRL::ComPtr;

namespace {
std::atomic<bool> running{true};
std::mutex statusMutex;
std::string outputStatus = "正在打开输出";

void setStatus(const std::string& value) {
    std::lock_guard<std::mutex> lock(statusMutex);
    outputStatus = value;
}
std::string status() {
    std::lock_guard<std::mutex> lock(statusMutex);
    return outputStatus;
}
std::string utf8(const std::wstring& value) {
    if (value.empty()) return {};
    int size = WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
    std::string out(size, '\0');
    WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), out.data(), size, nullptr, nullptr);
    return out;
}
std::wstring lower(std::wstring value) {
    for (auto& c : value) c = static_cast<wchar_t>(std::towlower(c));
    return value;
}
std::string errorText(HRESULT hr) {
    std::ostringstream text;
    text << "0x" << std::hex << static_cast<unsigned long>(hr);
    return text.str();
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
    if (selection.empty()) return devices->GetDefaultAudioEndpoint(eRender, eConsole, &out);
    ComPtr<IMMDeviceCollection> collection;
    HRESULT hr = devices->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &collection);
    if (FAILED(hr)) return hr;
    UINT count = 0;
    if (FAILED(hr = collection->GetCount(&count))) return hr;
    bool numeric = std::all_of(selection.begin(), selection.end(), [](wchar_t c) { return c >= L'0' && c <= L'9'; });
    std::wstring wanted = lower(selection);
    for (UINT i = 0; i < count; ++i) {
        ComPtr<IMMDevice> device;
        if (FAILED(collection->Item(i, &device))) continue;
        if ((numeric && selection == std::to_wstring(i)) ||
            (!numeric && lower(deviceName(device.Get())).find(wanted) != std::wstring::npos)) {
            out = device;
            return S_OK;
        }
    }
    return HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
}

struct AudioOutput {
    ComPtr<IAudioClient> client;
    ComPtr<IAudioRenderClient> renderer;
    ComPtr<IAudioClock> clock;
    WAVEFORMATEX* format = nullptr;
    HANDLE event = nullptr;
    UINT32 capacity = 0;
    UINT64 frequency = 0;
    UINT64 written = 0;
    REFERENCE_TIME latency = 0;
    bool floating = false;
    int validBits = 0;
    std::vector<float> stereo;

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
        hr = id.empty() ? devices->GetDefaultAudioEndpoint(eRender, eConsole, &device) : devices->GetDevice(id.c_str(), &device);
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
        if (FAILED(hr = clock->GetFrequency(&frequency))) return hr;
        client->GetStreamLatency(&latency);
        stereo.resize(static_cast<size_t>(capacity) * 2);
        BYTE* initial = nullptr;
        if (FAILED(hr = renderer->GetBuffer(capacity, &initial))) return hr;
        if (FAILED(hr = renderer->ReleaseBuffer(capacity, AUDCLNT_BUFFERFLAGS_SILENT))) return hr;
        written = capacity;
        if (FAILED(hr = client->Start())) return hr;
        setStatus(utf8(deviceName(device.Get())) + " " + std::to_string(format->nSamplesPerSec) + " Hz " +
            std::to_string(format->wBitsPerSample) + (floating ? "bit float " : "bit PCM ") +
            std::to_string(format->nChannels) + "ch");
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
        UINT32 padding = 0;
        HRESULT hr = client->GetCurrentPadding(&padding);
        if (FAILED(hr)) return hr;
        UINT32 frames = capacity - padding;
        if (!frames) return S_OK;
        UINT64 position = 0, qpc100ns = 0;
        bool real = clock->GetPosition(&position, &qpc100ns) == S_OK && frequency != 0 && position != 0;
        int64_t firstFrameUs;
        if (real) {
            double playedFrames = static_cast<double>(position) * format->nSamplesPerSec / frequency;
            // padding 不包含引擎到硬件的在途帧；欠载后重建流，不能据此修补帧零点。
            if (playedFrames > written) {
                receiver.addXruns(1);
                return AUDCLNT_E_BUFFER_ERROR;
            }
            firstFrameUs = static_cast<int64_t>(qpc100ns / 10.0 +
                (static_cast<double>(written) / format->nSamplesPerSec - static_cast<double>(position) / frequency) * 1e6);
        } else {
            firstFrameUs = unison::monotonicUs() + latency / 10 +
                static_cast<int64_t>(padding * 1e6 / format->nSamplesPerSec);
        }
        BYTE* target = nullptr;
        if (FAILED(hr = renderer->GetBuffer(frames, &target))) return hr;
        receiver.render(stereo.data(), static_cast<int>(frames), static_cast<int>(format->nSamplesPerSec), firstFrameUs, real);
        encode(target, frames);
        hr = renderer->ReleaseBuffer(frames, 0);
        if (SUCCEEDED(hr)) written += frames;
        return hr;
    }
};

void audioThread(unison::Receiver& receiver, const std::wstring& id) {
    HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(initialized)) { setStatus("COM 初始化失败 " + errorText(initialized)); return; }
    DWORD taskIndex = 0;
    HANDLE priority = AvSetMmThreadCharacteristicsW(L"Pro Audio", &taskIndex);
    while (running.load()) {
        bool underrun = false;
        {
            AudioOutput output;
            HRESULT hr = output.open(id);
            if (SUCCEEDED(hr)) {
                receiver.resetOutputTiming();
                while (running.load()) {
                    DWORD signaled = WaitForSingleObject(output.event, 100);
                    if (signaled == WAIT_FAILED) { hr = HRESULT_FROM_WIN32(GetLastError()); break; }
                    if (FAILED(hr = output.fill(receiver))) break;
                }
            }
            underrun = hr == AUDCLNT_E_BUFFER_ERROR;
            if (underrun) setStatus("输出欠载，正在重建流");
            else if (FAILED(hr)) setStatus("输出不可用 " + errorText(hr) + "，等待重连");
        }
        if (underrun) continue;
        for (int i = 0; i < 10 && running.load(); ++i)
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    if (priority) AvRevertMmThreadCharacteristics(priority);
    CoUninitialize();
}

BOOL WINAPI consoleSignal(DWORD signal) {
    if (signal == CTRL_C_EVENT || signal == CTRL_BREAK_EVENT || signal == CTRL_CLOSE_EVENT) {
        running.store(false);
        return TRUE;
    }
    return FALSE;
}

int run(int argc, wchar_t** argv) {
    std::wstring deviceSelection, source;
    bool list = false;
    for (int i = 1; i < argc; ++i) {
        std::wstring arg = argv[i];
        if (arg == L"--list") list = true;
        else if ((arg == L"--device" || arg == L"--source") && i + 1 < argc) {
            auto value = argv[++i];
            if (arg == L"--device") deviceSelection = value;
            else source = value;
        } else {
            std::cerr << "用法: unison-receiver [--list] [--device 序号或名称片段] [--source IPv4]\n";
            return 2;
        }
    }
    ComPtr<IMMDeviceEnumerator> devices;
    HRESULT hr = enumerator(devices);
    if (FAILED(hr)) { std::cerr << "枚举设备失败 " << errorText(hr) << '\n'; return 1; }
    if (list) {
        ComPtr<IMMDeviceCollection> collection;
        if (FAILED(hr = devices->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &collection))) return 1;
        UINT count = 0;
        collection->GetCount(&count);
        for (UINT i = 0; i < count; ++i) {
            ComPtr<IMMDevice> device;
            if (SUCCEEDED(collection->Item(i, &device))) std::cout << i << ": " << utf8(deviceName(device.Get())) << '\n';
        }
        return 0;
    }
    std::wstring id;
    if (!deviceSelection.empty()) {
        ComPtr<IMMDevice> device;
        if (FAILED(hr = chooseDevice(devices.Get(), deviceSelection, device))) {
            std::cerr << "找不到输出设备，请先使用 --list\n";
            return 1;
        }
        LPWSTR deviceId = nullptr;
        if (FAILED(device->GetId(&deviceId))) return 1;
        id = deviceId;
        CoTaskMemFree(deviceId);
    }
    unison::Receiver receiver;
    if (!receiver.start(utf8(source))) { std::cerr << "接收端启动失败，检查 UDP 端口与音源 IP\n"; return 1; }
    SetConsoleCtrlHandler(consoleSignal, TRUE);
    std::cout << "+ / -: 偏移 ±1 ms   ] / [: ±10 ms   q: 退出（正偏移更晚发声）\n";
    std::thread output([&] { audioThread(receiver, id); });
    float offset = 0;
    int64_t lastStatus = 0;
    while (running.load()) {
        while (_kbhit()) {
            wchar_t key = _getwch();
            if (key == L'q' || key == L'Q') running.store(false);
            if (key == L'+') offset += 1;
            if (key == L'-') offset -= 1;
            if (key == L']') offset += 10;
            if (key == L'[') offset -= 10;
            receiver.setOffsetMs(offset);
        }
        int64_t now = unison::monotonicUs();
        if (now - lastStatus >= 1'000'000) {
            std::string line = receiver.statsLine() + " | " + status();
            CONSOLE_SCREEN_BUFFER_INFO screen{};
            if (GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), &screen)) {
                size_t width = static_cast<size_t>(screen.srWindow.Right - screen.srWindow.Left);
                if (line.size() > width) {
                    line.resize(width);
                    // UTF-8 设备名按字节保守裁剪，保留一行且不截断字符。
                    while (!line.empty() && (static_cast<unsigned char>(line.back()) & 0xc0) == 0x80) line.pop_back();
                    if (!line.empty() && static_cast<unsigned char>(line.back()) >= 0xc0) line.pop_back();
                }
            }
            std::cout << "\r\x1b[2K" << line << std::flush;
            lastStatus = now;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(25));
    }
    output.join();
    receiver.stop();
    SetConsoleCtrlHandler(consoleSignal, FALSE);
    std::cout << '\n';
    return 0;
}
}  // namespace

int wmain(int argc, wchar_t** argv) {
    SetConsoleOutputCP(CP_UTF8);
    HANDLE console = GetStdHandle(STD_OUTPUT_HANDLE);
    DWORD mode = 0;
    if (GetConsoleMode(console, &mode)) SetConsoleMode(console, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(hr)) return 1;
    int result = run(argc, argv);
    CoUninitialize();
    return result;
}
