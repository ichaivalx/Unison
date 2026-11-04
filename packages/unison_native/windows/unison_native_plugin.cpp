#include "include/unison_native/unison_native_plugin_c_api.h"
#include "unison/receiver.h"
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <memory>

class UnisonNativePlugin : public flutter::Plugin {
 public:
  explicit UnisonNativePlugin(flutter::PluginRegistrarWindows* registrar) {
    channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(registrar->messenger(),
        "unison_native/methods", &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler([](const auto&, auto result) { result->Error("unsupported", "Native capability is being initialized"); });
  }
 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};
extern "C" __declspec(dllexport) int64_t unison_monotonic_us() { return unison::monotonicUs(); }
void UnisonNativePluginCApiRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar) {
  auto* windows = flutter::PluginRegistrarManager::GetInstance()->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);
  windows->AddPlugin(std::make_unique<UnisonNativePlugin>(windows));
}
