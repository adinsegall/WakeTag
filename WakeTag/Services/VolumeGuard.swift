import Foundation
import AVFoundation
import MediaPlayer
import UIKit

/// While an alarm is ringing, pins system media volume at the target level.
/// If the user lowers it with the hardware buttons before scanning their tag,
/// it snaps back. Uses the well-known hidden-MPVolumeView-slider technique —
/// the only way to move system volume programmatically.
@MainActor
final class VolumeGuard {
    static let shared = VolumeGuard()

    private var volumeView: MPVolumeView?
    private var observation: NSKeyValueObservation?
    private var target: Float = 1.0
    private(set) var isEngaged = false

    private init() {}

    func engage(target: Float = 1.0) {
        guard !isEngaged else { return }
        self.target = target
        isEngaged = true

        let view = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 80, height: 20))
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        keyWindow?.addSubview(view)
        volumeView = view

        // Give the slider a beat to attach to the window before nudging it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.setSystemVolume()
        }

        observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            let newValue = change.newValue
            Task { @MainActor [weak self] in
                guard let self, self.isEngaged else { return }
                if let volume = newValue, volume < self.target - 0.05 {
                    self.setSystemVolume()
                }
            }
        }
    }

    func disengage() {
        observation?.invalidate()
        observation = nil
        volumeView?.removeFromSuperview()
        volumeView = nil
        isEngaged = false
    }

    private func setSystemVolume() {
        guard let slider = volumeView?.subviews.compactMap({ $0 as? UISlider }).first else { return }
        slider.value = target
    }

    private var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
}
