#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <algorithm>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  const bool autostart =
      std::find(command_line_arguments.begin(), command_line_arguments.end(),
                FlutterWindow::kAutostartArgument) != command_line_arguments.end();

  // 单实例：已在运行（包括隐藏在托盘）时让它显示窗口并置前，本进程退出；开机自启时不打扰
  HANDLE single_instance = ::CreateMutexW(nullptr, FALSE, L"Local\\Unison.Instance");
  if (::GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND existing = ::FindWindowW(Win32Window::kClassName, nullptr);
    if (!autostart && existing != nullptr) {
      DWORD process = 0;
      ::GetWindowThreadProcessId(existing, &process);
      ::AllowSetForegroundWindow(process);
      ::PostMessageW(existing, ::RegisterWindowMessageW(FlutterWindow::kShowMessageName), 0, 0);
    }
    ::CloseHandle(single_instance);
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, !autostart);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1100, 720);
  if (!window.Create(L"Unison", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  ::CloseHandle(single_instance);
  return EXIT_SUCCESS;
}
