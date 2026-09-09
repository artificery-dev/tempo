#include "flutter_window.h"

#include <optional>
#include <dwmapi.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter/plugin_registrar_windows.h>

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
  const auto registrar = flutter_controller_->engine()->GetRegistrarForPlugin("TempoEmulatorWindow");
  flutter::MethodChannel<flutter::EncodableValue> channel(
      flutter_controller_->engine()->messenger(), "tempo/emulator_window",
      &flutter::StandardMethodCodec::GetInstance());
  channel.SetMethodCallHandler([registrar](const auto& call, auto result) {
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (!args || args->count(flutter::EncodableValue("viewId")) == 0) {
      result->Error("invalid_arguments", "A viewId is required");
      return;
    }
    const auto& id = args->at(flutter::EncodableValue("viewId"));
    const int64_t view_id = std::holds_alternative<int64_t>(id)
        ? std::get<int64_t>(id) : std::get<int32_t>(id);
    const auto view = FlutterDesktopPluginRegistrarGetViewById(registrar, view_id);
    if (!view) {
      result->Error("view_not_found", "Emulator view is not attached");
      return;
    }
    const HWND window = GetAncestor(FlutterDesktopViewGetHWND(view), GA_ROOT);
    if (call.method_name() == "configure") {
      SetWindowText(window, L"Tempo Emulator");
      SetWindowLongPtr(window, GWL_STYLE,
          GetWindowLongPtr(window, GWL_STYLE) & ~(WS_CAPTION | WS_THICKFRAME));
      DWM_BLURBEHIND blur = {};
      blur.dwFlags = DWM_BB_ENABLE | DWM_BB_BLURREGION;
      blur.fEnable = TRUE;
      blur.hRgnBlur = CreateRectRgn(0, 0, -1, -1);
      DwmEnableBlurBehindWindow(window, &blur);
      DeleteObject(blur.hRgnBlur);
      SetWindowPos(window, nullptr, 0, 0, 0, 0,
          SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
    } else if (call.method_name() == "setSize") {
      const double scale = GetDpiForWindow(window) / 96.0;
      const auto width = std::get<double>(args->at(flutter::EncodableValue("width")));
      const auto height = std::get<double>(args->at(flutter::EncodableValue("height")));
      SetWindowPos(window, nullptr, 0, 0, static_cast<int>(width * scale),
          static_cast<int>(height * scale), SWP_NOMOVE | SWP_NOZORDER);
    } else if (call.method_name() == "close") {
      PostMessage(window, WM_CLOSE, 0, 0);
    } else if (call.method_name() == "startDrag") {
      ReleaseCapture();
      PostMessage(window, WM_NCLBUTTONDOWN, HTCAPTION, 0);
    } else {
      result->NotImplemented();
      return;
    }
    result->Success();
  });

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

void FlutterWindow::OnDestroy() {
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
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
