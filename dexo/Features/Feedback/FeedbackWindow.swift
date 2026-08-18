import UIKit

final class FeedbackWindow: UIWindow {
    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        guard motion == .motionShake else {
            super.motionEnded(motion, with: event)
            return
        }
        FeedbackCoordinator.shared.presentShakePrompt(in: self)
    }
}
