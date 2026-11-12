#include "flutter_window.h"

#include <shellapi.h>

#include <cstring>
#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {

constexpr UINT kTrayMessage = WM_APP + 1;
constexpr wchar_t kTrayClassName[] = L"UnisonTray";
constexpr UINT kTrayId = 1;
constexpr int kMenuShow = 1;
constexpr int kMenuQuit = 2;

// 当前用户的启动项
constexpr wchar_t kRunKey[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kRunValue[] = L"Unison";

// 启动项的值：本程序路径加开机自启参数
std::wstring AutostartCommand() {
  std::wstring path(MAX_PATH, L'\0');
  for (;;) {
    const DWORD length =
        GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
    if (length < path.size()) {
      path.resize(length);
      break;
    }
    path.resize(path.size() * 2);
  }
  const char* argument = FlutterWindow::kAutostartArgument;
  return L"\"" + path + L"\" " + std::wstring(argument, argument + std::strlen(argument));
}

// 启动项存在且指向本程序
bool AutostartEnabled() {
  DWORD size = 0;
  if (RegGetValueW(HKEY_CURRENT_USER, kRunKey, kRunValue, RRF_RT_REG_SZ, nullptr, nullptr,
                   &size) != ERROR_SUCCESS) {
    return false;
  }
  std::wstring value(size / sizeof(wchar_t) + 1, L'\0');
  size = static_cast<DWORD>(value.size() * sizeof(wchar_t));
  if (RegGetValueW(HKEY_CURRENT_USER, kRunKey, kRunValue, RRF_RT_REG_SZ, nullptr, value.data(),
                   &size) != ERROR_SUCCESS) {
    return false;
  }
  return _wcsicmp(value.c_str(), AutostartCommand().c_str()) == 0;
}

// 写入或删除启动项，返回之后的实际状态
bool SetAutostart(bool on) {
  if (on) {
    const std::wstring command = AutostartCommand();
    RegSetKeyValueW(HKEY_CURRENT_USER, kRunKey, kRunValue, REG_SZ, command.c_str(),
                    static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
  } else {
    RegDeleteKeyValueW(HKEY_CURRENT_USER, kRunKey, kRunValue);
  }
  return AutostartEnabled();
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project, bool show_on_start)
    : project_(project), show_on_start_(show_on_start) {}

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
    if (show_on_start_) {
      this->Show();
    }
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  taskbar_created_ = RegisterWindowMessageW(L"TaskbarCreated");
  show_message_ = RegisterWindowMessageW(kShowMessageName);
  CreateTrayWindow();
  AddTrayIcon();
  return true;
}

void FlutterWindow::CreateTrayWindow() {
  WNDCLASSW tray_class{};
  tray_class.lpfnWndProc = TrayProc;
  tray_class.hInstance = GetModuleHandle(nullptr);
  tray_class.lpszClassName = kTrayClassName;
  RegisterClassW(&tray_class);
  // 不可见的顶层窗口：能收到 TaskbarCreated 广播，也能作为菜单所有者取得前台
  tray_window_ = CreateWindowExW(WS_EX_TOOLWINDOW, kTrayClassName, L"", WS_POPUP, 0, 0, 0, 0,
                                 nullptr, nullptr, GetModuleHandle(nullptr), nullptr);
  SetWindowLongPtrW(tray_window_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
}

LRESULT CALLBACK FlutterWindow::TrayProc(HWND window, UINT message, WPARAM wparam,
                                         LPARAM lparam) {
  auto* that = reinterpret_cast<FlutterWindow*>(GetWindowLongPtrW(window, GWLP_USERDATA));
  if (that != nullptr) {
    if (message == kTrayMessage) {
      that->HandleTrayEvent(LOWORD(lparam));
      return 0;
    }
    if (that->taskbar_created_ != 0 && message == that->taskbar_created_) {
      that->AddTrayIcon();
      return 0;
    }
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

void FlutterWindow::HandleTrayEvent(UINT event) {
  switch (event) {
    case WM_LBUTTONDOWN:
    case WM_LBUTTONDBLCLK:
      front_at_tray_press_ = InFront();
      break;
    case WM_LBUTTONUP:
      // 不在前台（含可见但在其他虚拟桌面）时按显示处理：落到当前桌面并置前
      if (front_at_tray_press_) {
        Dismiss();
      } else {
        Present();
      }
      break;
    case WM_RBUTTONUP:
      ShowTrayMenu();
      break;
  }
}

void FlutterWindow::AddTrayIcon() {
  if (tray_window_ == nullptr) {
    return;
  }
  if (tray_icon_ == nullptr) {
    const UINT dpi = GetDpiForWindow(GetHandle());
    tray_icon_ = static_cast<HICON>(LoadImageW(
        GetModuleHandle(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
        GetSystemMetricsForDpi(SM_CXSMICON, dpi), GetSystemMetricsForDpi(SM_CYSMICON, dpi),
        LR_DEFAULTCOLOR));
  }
  NOTIFYICONDATAW icon{};
  icon.cbSize = static_cast<DWORD>(sizeof(icon));
  icon.hWnd = tray_window_;
  icon.uID = kTrayId;
  icon.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  icon.uCallbackMessage = kTrayMessage;
  icon.hIcon = tray_icon_;
  wcscpy_s(icon.szTip, L"Unison");
  Shell_NotifyIconW(NIM_ADD, &icon);
}

void FlutterWindow::RemoveTrayIcon() {
  if (tray_window_ == nullptr) {
    return;
  }
  NOTIFYICONDATAW icon{};
  icon.cbSize = static_cast<DWORD>(sizeof(icon));
  icon.hWnd = tray_window_;
  icon.uID = kTrayId;
  Shell_NotifyIconW(NIM_DELETE, &icon);
  DestroyWindow(tray_window_);
  tray_window_ = nullptr;
  if (tray_icon_ != nullptr) {
    DestroyIcon(tray_icon_);
    tray_icon_ = nullptr;
  }
}

void FlutterWindow::ShowTrayMenu() {
  HMENU menu = CreatePopupMenu();
  AppendMenuW(menu, MF_STRING, kMenuShow, L"显示 Unison");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kMenuQuit, L"退出");
  SetMenuDefaultItem(menu, kMenuShow, FALSE);
  POINT cursor{};
  GetCursorPos(&cursor);
  // 菜单所有者须在前台，点击别处时菜单才会关闭；置前的是辅助窗口，不激活主窗口
  SetForegroundWindow(tray_window_);
  const BOOL command = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY,
                                      cursor.x, cursor.y, 0, tray_window_, nullptr);
  PostMessage(tray_window_, WM_NULL, 0, 0);
  DestroyMenu(menu);
  if (command == kMenuShow) {
    Present();
  } else if (command == kMenuQuit) {
    DestroyWindow(GetHandle());
  }
}

bool FlutterWindow::InFront() {
  HWND window = GetHandle();
  return IsWindowVisible(window) && !IsIconic(window) && OnCurrentDesktop() &&
         (GetForegroundWindow() == window || GetTickCount64() - deactivated_at_ < 500);
}

void FlutterWindow::Present() {
  Reveal();
  if (flutter_controller_) {
    flutter_controller_->ForceRedraw();
  }
}

void FlutterWindow::Dismiss() {
  if (FullScreen()) {
    KeepHiddenAfterFullScreen();
    if (window_channel_) {
      window_channel_->InvokeMethod("escape", nullptr);
    }
    return;
  }
  Hide();
}

void FlutterWindow::HandleWindowCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  if (method == "autostart") {
    result->Success(flutter::EncodableValue(AutostartEnabled()));
    return;
  }
  if (method == "setAutostart") {
    const auto* on = std::get_if<bool>(call.arguments());
    result->Success(flutter::EncodableValue(SetAutostart(on != nullptr && *on)));
    return;
  }
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
  RemoveTrayIcon();
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
  if (message == WM_ACTIVATE && LOWORD(wparam) == WA_INACTIVE) {
    deactivated_at_ = GetTickCount64();
  }
  // 关闭按钮、Alt+F4 隐藏到托盘；托盘菜单的“退出”才结束进程
  if (message == WM_CLOSE) {
    Dismiss();
    return 0;
  }
  if (show_message_ != 0 && message == show_message_) {
    Present();
    return 0;
  }
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
