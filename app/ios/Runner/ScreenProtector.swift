import UIKit

/// Obscures the app while a secret (recovery phrase) is on screen.
///
/// What iOS allows, stated honestly:
/// * Screenshots CANNOT be blocked by an app. (The user sees the thumbnail; the
///   phrase screen warns about this.)
/// * Screen recording / mirroring / AirPlay CAN be detected (UIScreen.isCaptured)
///   and the content hidden behind a blur while it is active.
/// * The app-switcher snapshot is taken when the app resigns active, so a blur
///   is shown at that moment and removed when the app becomes active again.
/// Driven by `setSecure(true/false)` on the shared "app.openfamily/keystore"
/// channel (the same call Android maps to FLAG_SECURE).
final class ScreenProtector {
  static let shared = ScreenProtector()

  private var secure = false
  private var observing = false
  private var cover: UIView?

  func setSecure(_ on: Bool) {
    secure = on
    if on { startObserving() }
    refresh(resigned: false)
  }

  private func startObserving() {
    guard !observing else { return }
    observing = true
    let nc = NotificationCenter.default
    nc.addObserver(self, selector: #selector(captureChanged),
                   name: UIScreen.capturedDidChangeNotification, object: nil)
    nc.addObserver(self, selector: #selector(willResign),
                   name: UIApplication.willResignActiveNotification, object: nil)
    nc.addObserver(self, selector: #selector(didBecomeActive),
                   name: UIApplication.didBecomeActiveNotification, object: nil)
  }

  @objc private func captureChanged() { refresh(resigned: false) }
  @objc private func willResign() { refresh(resigned: true) }
  @objc private func didBecomeActive() { refresh(resigned: false) }

  private var isCaptured: Bool {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .contains { $0.screen.isCaptured }
  }

  private var keyWindow: UIWindow? {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }
  }

  private func refresh(resigned: Bool) {
    let shouldCover = secure && (resigned || isCaptured)
    if shouldCover {
      guard cover == nil, let window = keyWindow else { return }
      let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
      blur.frame = window.bounds
      blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      window.addSubview(blur)
      cover = blur
    } else {
      cover?.removeFromSuperview()
      cover = nil
    }
  }
}
