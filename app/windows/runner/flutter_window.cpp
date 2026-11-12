#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  window_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "unison/window",
      &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) { HandleWindowCall(call, std::move(result)); });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::HandleWindowCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  if (method == "state") {
    result->Success(flutter::EncodableValue(flutter::EncodableMap{
        {flutter::EncodableValue("maximized"), flutter::EncodableValue(Maximized())},
        {flutter::EncodableValue("minimized"), flutter::EncodableValue(Minimized())},
    }));
    return;
  }
  // 拖动在系统的移动循环中进行，先回复
  result->Success();
  if (method == "startDrag") {
    StartDrag();
  } else if (method == "minimize") {
    Minimize();
  } else if (method == "toggleMaximize") {
    ToggleMaximize();
  } else if (method == "close") {
    Close();
  } else if (method == "blackout") {
    const auto* on = std::get_if<bool>(call.arguments());
    const bool active = on != nullptr && *on;
    // 黑屏期间显示器保持开启、系统不睡眠，显示器的扬声器不断电
    SetThreadExecutionState(active ? ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED
                                   : ES_CONTINUOUS);
    SetFullScreen(active);
  }
}

void FlutterWindow::NotifyWindowState() {
  const bool maximized = Maximized();
  const bool minimized = Minimized();
  if (!window_channel_ || (maximized == maximized_ && minimized == minimized_)) {
    return;
  }
  maximized_ = maximized;
  minimized_ = minimized;
  window_channel_->InvokeMethod(
      "state", std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
                   {flutter::EncodableValue("maximized"), flutter::EncodableValue(maximized)},
                   {flutter::EncodableValue("minimized"), flutter::EncodableValue(minimized)},
               }));
}

void FlutterWindow::OnDestroy() {
  window_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    // 黑屏期间的 Esc：交给界面按与黑屏层内 Esc 相同的路径退出
    case WM_HOTKEY:
      if (wparam == kEscapeHotKey && window_channel_) {
        window_channel_->InvokeMethod("escape", nullptr);
        return 0;
      }
      break;
  }

  const LRESULT handled = Win32Window::MessageHandler(hwnd, message, wparam, lparam);
  if (message == WM_SIZE) {
    NotifyWindowState();
  }
  return handled;
}
