import Flutter
import SwiftUI
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var videoEditorChannel: FlutterMethodChannel?

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "memoirscore/video_editor",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "open" else {
        result(FlutterMethodNotImplemented)
        return
      }
      Task { @MainActor in
        guard let self else {
          result(FlutterError(code: "unavailable", message: "暂时无法打开视频剪辑。", details: nil))
          return
        }
        self.openVideoEditor(result: result)
      }
    }
    videoEditorChannel = channel
  }

  @MainActor
  private func openVideoEditor(result: FlutterResult) {
    let presenter = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .filter { $0.activationState == .foregroundActive }
      .compactMap { $0.windows.first(where: { $0.isKeyWindow })?.rootViewController }
      .first

    guard let presenter, presenter.presentedViewController == nil else {
      result(FlutterError(code: "unavailable", message: "暂时无法打开视频剪辑。", details: nil))
      return
    }

    let controller = UIHostingController(rootView: VideoEditorView { [weak presenter] in
      presenter?.dismiss(animated: true)
    })
    controller.modalPresentationStyle = .fullScreen
    presenter.present(controller, animated: true) { result(nil) }
  }
}
