#include "include/unison_native/unison_native_plugin_c_api.h"
#include "audio_output.h"
#include "unison/receiver.h"
#include <flutter/method_channel.h>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <algorithm>
#include <cmath>
#include <memory>
#include <optional>
#include <stdexcept>

namespace {
using Value = flutter::EncodableValue;
int64_t integer(const Value* value) {
    if (auto n = std::get_if<int64_t>(value)) return *n;
    return std::get<int32_t>(*value);
}
}
class UnisonNativePlugin : public flutter::Plugin {
 public:
  explicit UnisonNativePlugin(flutter::PluginRegistrarWindows* registrar) : registrar_(registrar) {
    channel_ = std::make_unique<flutter::MethodChannel<Value>>(registrar->messenger(),
        "unison_native/methods", &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler([this](const auto& call, auto result) {
      try {
        const auto& method = call.method_name(); const auto* args = call.arguments();
        if (method == "receiverId") result->Success(Value(static_cast<int64_t>(unison_windows::receiverId())));
        else if (method == "startReceiver") {
          const auto& data = std::get<flutter::EncodableMap>(*args);
          if (!unison_windows::start(std::get<std::string>(data.at(Value("sourceHost"))))) throw std::runtime_error("Cannot start receiver");
          result->Success();
        } else if (method == "stopReceiver") { unison_windows::stop(); result->Success(); }
        else if (method == "setReceiverOffsetUs") { unison_windows::offset(integer(args)); result->Success(); }
        else if (method == "outputDevices") {
          flutter::EncodableList names; for (const auto& name : unison_windows::devices()) names.emplace_back(name);
          result->Success(Value(names));
        } else if (method == "setOutputDevice") {
          std::string name;
          if (args && !std::holds_alternative<std::monostate>(*args)) name = std::get<std::string>(*args);
          const auto devices = unison_windows::devices();
          if (!name.empty() && std::find(devices.begin(), devices.end(), name) == devices.end()) throw std::runtime_error("Output device not found");
          unison_windows::device(name); result->Success();
        } else if (method == "volume") result->Success(Value(unison_windows::volume()));
        else if (method == "setVolume") {
          double value = std::get<double>(*args); if (!std::isfinite(value) || value < 0 || value > 1) throw std::runtime_error("Invalid volume");
          unison_windows::volume(value); emit("volume", Value(value)); result->Success();
        } else result->Error("unsupported", "This capability requires rooted Android");
      } catch (const std::exception& error) { result->Error("native", error.what()); }
    });
    events_ = std::make_unique<flutter::EventChannel<Value>>(registrar->messenger(), "unison_native/events", &flutter::StandardMethodCodec::GetInstance());
    events_->SetStreamHandler(std::make_unique<flutter::StreamHandlerFunctions<Value>>(
      [this](const Value*, std::unique_ptr<flutter::EventSink<Value>>&& sink) -> std::unique_ptr<flutter::StreamHandlerError<Value>> {
        sink_ = std::move(sink); emit("receiver", Value(unison_windows::stats())); emit("volume", Value(unison_windows::volume())); return nullptr;
      }, [this](const Value*) -> std::unique_ptr<flutter::StreamHandlerError<Value>> { sink_.reset(); return nullptr; }));
    window_ = registrar->GetView()->GetNativeWindow();
    timer_ = reinterpret_cast<UINT_PTR>(this);
    delegate_ = registrar->RegisterTopLevelWindowProcDelegate([this](HWND, UINT message, WPARAM wparam, LPARAM) -> std::optional<LRESULT> {
      if (message == WM_TIMER && wparam == timer_) {
        emit("receiver", Value(unison_windows::stats()));
        double volume = unison_windows::volume(); if (volume != previousVolume_) { previousVolume_ = volume; emit("volume", Value(volume)); }
        return 0;
      }
      return std::nullopt;
    });
    SetTimer(window_, timer_, 250, nullptr);
  }
  ~UnisonNativePlugin() override {
    KillTimer(window_, timer_); registrar_->UnregisterTopLevelWindowProcDelegate(delegate_);
    unison_windows::stop(); channel_->SetMethodCallHandler(nullptr); events_->SetStreamHandler(nullptr);
  }
 private:
  void emit(const std::string& type, Value data) {
    if (sink_) sink_->Success(Value(flutter::EncodableMap{{Value("type"), Value(type)}, {Value("data"), std::move(data)}}));
  }
  flutter::PluginRegistrarWindows* registrar_;
  HWND window_ = nullptr; UINT_PTR timer_ = 0; int delegate_ = -1;
  double previousVolume_ = -1;
  std::unique_ptr<flutter::MethodChannel<Value>> channel_;
  std::unique_ptr<flutter::EventChannel<Value>> events_;
  std::unique_ptr<flutter::EventSink<Value>> sink_;
};
extern "C" __declspec(dllexport) int64_t unison_monotonic_us() { return unison::monotonicUs(); }
void UnisonNativePluginCApiRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar) {
  auto* windows = flutter::PluginRegistrarManager::GetInstance()->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);
  windows->AddPlugin(std::make_unique<UnisonNativePlugin>(windows));
}
