#include "win32_window.h"

#include <commctrl.h>
#include <dwmapi.h>
#include <flutter_windows.h>
#include <shobjidl.h>
#include <windowsx.h>

#include "resource.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr const wchar_t* kWindowClassName = Win32Window::kClassName;

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  HWND window = CreateWindow(
      window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
      Scale(origin.x, scale_factor), Scale(origin.y, scale_factor),
      Scale(size.width, scale_factor), Scale(size.height, scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  UpdateTheme(window);
  // 按收回顶部后的非客户区重新计算一次，首帧即没有原生标题栏
  SetWindowPos(window, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);

  return OnCreate();
}

bool Win32Window::Show() {
  return ShowWindow(window_handle_, SW_SHOWNORMAL);
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    case WM_SYSCOMMAND:
      if (wparam == SC_KEYMENU && (lparam >> 16) <= 0) {
        return 0;
      }
    break;

    case WM_DESTROY:
      if (fullscreen_) {
        UnregisterHotKey(hwnd, kEscapeHotKey);
      }
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_SIZE: {
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      return 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    // 去掉标题栏：按标准边框计算后收回顶部，保留左、右、下的缩放边框。wparam 为 FALSE 时 lparam
    // 指向单个 RECT，与 NCCALCSIZE_PARAMS 的 rgrc[0] 同位。窗口类带 CS_HREDRAW | CS_VREDRAW，
    // DefWindowProc 会返回重绘标志，原样返回
    case WM_NCCALCSIZE:
      if (!fullscreen_) {
        auto client = reinterpret_cast<RECT*>(lparam);
        const LONG top = client->top;
        const LRESULT result = DefWindowProc(hwnd, message, wparam, lparam);
        client->top = top + (IsZoomed(hwnd) ? FrameHeight() : 0);
        return result;
      }
      break;

    case WM_NCHITTEST: {
      const LRESULT hit = DefWindowProc(hwnd, message, wparam, lparam);
      if (hit == HTCLIENT && InTopBorder(lparam)) {
        return HTTOP;
      }
      return hit;
    }
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  SetWindowSubclass(content, ContentProc, 1, reinterpret_cast<DWORD_PTR>(this));
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

LRESULT CALLBACK Win32Window::ContentProc(HWND window, UINT message,
                                          WPARAM wparam, LPARAM lparam,
                                          UINT_PTR id, DWORD_PTR data) {
  if (message == WM_NCHITTEST &&
      reinterpret_cast<Win32Window*>(data)->InTopBorder(lparam)) {
    return HTTRANSPARENT;
  }
  return DefSubclassProc(window, message, wparam, lparam);
}

int Win32Window::FrameHeight() {
  const UINT dpi = GetDpiForWindow(window_handle_);
  return GetSystemMetricsForDpi(SM_CYFRAME, dpi) +
         GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
}

bool Win32Window::InTopBorder(LPARAM lparam) {
  if (fullscreen_ || IsZoomed(window_handle_)) {
    return false;
  }
  POINT point{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
  ScreenToClient(window_handle_, &point);
  return point.y >= 0 && point.y < FrameHeight();
}

void Win32Window::StartDrag() {
  ReleaseCapture();
  SendMessage(window_handle_, WM_SYSCOMMAND, SC_MOVE | HTCAPTION, 0);
}

void Win32Window::Minimize() {
  ShowWindow(window_handle_, SW_MINIMIZE);
}

void Win32Window::ToggleMaximize() {
  ShowWindow(window_handle_, IsZoomed(window_handle_) ? SW_RESTORE : SW_MAXIMIZE);
}

void Win32Window::Close() {
  PostMessage(window_handle_, WM_CLOSE, 0, 0);
}

bool Win32Window::Maximized() {
  return IsZoomed(window_handle_) != FALSE;
}

bool Win32Window::Minimized() {
  return IsIconic(window_handle_) != FALSE;
}

void Win32Window::SetFullScreen(bool on) {
  HWND window = window_handle_;
  if (on == fullscreen_ || window == nullptr) {
    return;
  }
  if (on) {
    hidden_before_fullscreen_ = !IsWindowVisible(window);
    GetWindowPlacement(window, &placement_);
    maximized_before_fullscreen_ =
        IsZoomed(window) || (IsIconic(window) && (placement_.flags & WPF_RESTORETOMAXIMIZED));
    // 隐藏在托盘时进入：随下面的显示出现在用户当前所在的虚拟桌面
    HideIfOnOtherDesktop();
    if (IsIconic(window) || IsZoomed(window)) {
      ShowWindow(window, SW_RESTORE);
    }
    // 还原后再读样式，并清掉状态位：最大化、最小化由保存的位置在退出时恢复
    const LONG_PTR style = GetWindowLongPtr(window, GWL_STYLE) & ~(WS_MINIMIZE | WS_MAXIMIZE);
    MONITORINFO monitor{sizeof(MONITORINFO)};
    GetMonitorInfo(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &monitor);
    const RECT& area = monitor.rcMonitor;
    fullscreen_ = true;
    SetWindowLongPtr(window, GWL_STYLE, (style & ~WS_OVERLAPPEDWINDOW) | WS_POPUP);
    SetWindowPos(window, HWND_TOPMOST, area.left, area.top,
                 area.right - area.left, area.bottom - area.top,
                 SWP_FRAMECHANGED | SWP_SHOWWINDOW);
    // 远程进入时系统可能不允许取得前台，键盘仍在其他应用；注册失败则只能在取得焦点后按 Esc
    RegisterHotKey(window, kEscapeHotKey, MOD_NOREPEAT, VK_ESCAPE);
    SetForegroundWindow(window);
    return;
  }
  WINDOWPLACEMENT placement = placement_;
  if (hidden_before_fullscreen_) {
    // 可见性与最大化分开恢复：位置按原样、保持隐藏，最大化留到恢复普通界面时
    reveal_maximized_ = reveal_maximized_ || maximized_before_fullscreen_;
    placement.showCmd = SW_HIDE;
  } else {
    // 进入时隐藏、黑屏期间要求显示的按普通显示；待恢复的最大化在此用上并清掉
    if (placement.showCmd == SW_HIDE) {
      placement.showCmd = SW_SHOWNORMAL;
    }
    if (reveal_maximized_) {
      if (placement.showCmd == SW_SHOWMINIMIZED) {
        placement.flags |= WPF_RESTORETOMAXIMIZED;
      } else {
        placement.showCmd = SW_SHOWMAXIMIZED;
      }
      reveal_maximized_ = false;
    }
    if (IsIconic(window)) {
      if (placement.showCmd == SW_SHOWMAXIMIZED) {
        placement.flags |= WPF_RESTORETOMAXIMIZED;
      }
      placement.showCmd = SW_SHOWMINIMIZED;
    }
  }
  hidden_before_fullscreen_ = false;
  UnregisterHotKey(window, kEscapeHotKey);
  fullscreen_ = false;
  const LONG_PTR style = GetWindowLongPtr(window, GWL_STYLE);
  SetWindowLongPtr(window, GWL_STYLE, (style & ~WS_POPUP) | WS_OVERLAPPEDWINDOW);
  SetWindowPos(window, HWND_NOTOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED);
  SetWindowPlacement(window, &placement);
}

void Win32Window::Reveal() {
  HWND window = window_handle_;
  hidden_before_fullscreen_ = false;
  // 黑屏期间不改变窗口的显示方式，待恢复的最大化留到退出黑屏时
  if (fullscreen_) {
    SetForegroundWindow(window);
    return;
  }
  HideIfOnOtherDesktop();
  int command = IsIconic(window) ? SW_RESTORE : SW_SHOW;
  if (reveal_maximized_) {
    command = SW_SHOWMAXIMIZED;
    reveal_maximized_ = false;
  }
  ShowWindow(window, command);
  SetForegroundWindow(window);
}

void Win32Window::Hide() {
  ShowWindow(window_handle_, SW_HIDE);
}

bool Win32Window::OnCurrentDesktop() {
  IVirtualDesktopManager* manager = nullptr;
  if (FAILED(CoCreateInstance(__uuidof(VirtualDesktopManager), nullptr, CLSCTX_ALL,
                              IID_PPV_ARGS(&manager)))) {
    return true;
  }
  BOOL current = TRUE;
  if (FAILED(manager->IsWindowOnCurrentVirtualDesktop(window_handle_, &current))) {
    current = TRUE;
  }
  manager->Release();
  return current != FALSE;
}

void Win32Window::HideIfOnOtherDesktop() {
  if (IsWindowVisible(window_handle_) && !OnCurrentDesktop()) {
    ShowWindow(window_handle_, SW_HIDE);
  }
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

// 应用只有深色主题，标题栏固定为深色
void Win32Window::UpdateTheme(HWND const window) {
  BOOL enable_dark_mode = TRUE;
  DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                        &enable_dark_mode, sizeof(enable_dark_mode));
}
