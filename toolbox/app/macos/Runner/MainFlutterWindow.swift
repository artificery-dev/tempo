import Cocoa
import FlutterMacOS
import ObjectiveC

// The engine creates secondary windows as plain NSWindow instances. Borderless
// NSWindow defaults reject keyboard focus, so use a layout-identical subclass.
private class EmulatorNativeWindow: NSWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}

class MainFlutterWindow: NSWindow {
  // The direct editor emulator target can make the primary window borderless.
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    let channel = FlutterMethodChannel(
      name: "tempo/emulator_window", binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { call, result in
      guard let args = call.arguments as? [String: Any],
            let viewId = args["viewId"] as? Int64,
            let target = NSApp.windows.compactMap({ window -> FlutterViewController? in
              guard let controller = window.contentViewController as? FlutterViewController,
                    controller.attached(),
                    controller.viewIdentifier == viewId else { return nil }
              return controller
            }).first,
            let window = target.view.window else {
        result(FlutterError(code: "view_not_found", message: "Emulator view is not attached", details: nil))
        return
      }
      switch call.method {
      case "configure":
        if type(of: window) == NSWindow.self {
          object_setClass(window, EmulatorNativeWindow.self)
        }
        window.title = "Tempo Emulator"
        window.styleMask = [.borderless, .resizable]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        target.backgroundColor = .clear
      case "setSize":
        if let width = args["width"] as? Double, let height = args["height"] as? Double {
          window.setContentSize(NSSize(width: width, height: height))
        }
      case "close":
        window.close()
      case "startDrag":
        if let event = NSApp.currentEvent { window.performDrag(with: event) }
      default:
        result(FlutterMethodNotImplemented)
        return
      }
      result(nil)
    }

    super.awakeFromNib()
    self.title = "Tempo Toolbox"
  }
}
