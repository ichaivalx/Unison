#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

#include "win32_window.h"

// 承载 Flutter 界面的主窗口；运行期间常驻托盘，关闭时隐藏到托盘
class FlutterWindow : public Win32Window {
 public:
  // 开机自启的启动参数：带此参数启动时不显示窗口，直接驻留托盘
  static constexpr char kAutostartArgument[] = "--autostart";

  // 再次启动程序时发给已在运行的实例，使其显示窗口
  static constexpr wchar_t kShowMessageName[] = L"Unison.ShowWindow";

  // |show_on_start| 为 false 时首帧后不显示窗口
  FlutterWindow(const flutter::DartProject& project, bool show_on_start);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // 界面的窗口操作与黑屏；窗口最大化、最小化变化时通知界面
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> window_channel_;
  bool maximized_ = false;
  bool minimized_ = false;

  void HandleWindowCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void NotifyWindowState();

  bool show_on_start_;

  // 托盘图标；资源管理器重启后按 TaskbarCreated 重新添加
  HWND tray_window_ = nullptr;
  HICON tray_icon_ = nullptr;
  UINT taskbar_created_ = 0;
  UINT show_message_ = 0;

  // 托盘左键按下时窗口是否在前台：点击托盘会先使任务栏取得前台，刚刚失去前台的也算
  bool front_at_tray_press_ = false;
  ULONGLONG deactivated_at_ = 0;

  void AddTrayIcon();
  void RemoveTrayIcon();
  void ShowTrayMenu();
  bool InFront();

  // 显示到当前虚拟桌面并置前
  void Present();

  // 隐藏到托盘；黑屏中则退出黑屏后保持隐藏
  void Dismiss();
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
