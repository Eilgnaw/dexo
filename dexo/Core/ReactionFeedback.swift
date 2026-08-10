import UIKit

@MainActor
enum ReactionFeedback {
    struct CapturedSource {
        fileprivate let snapshot: UIView
        fileprivate let image: UIImage?
        fileprivate let frame: CGRect
        fileprivate weak var window: UIWindow?
    }

    static func capture(_ view: UIView) -> CapturedSource? {
        guard let window = view.window,
              let snapshot = view.snapshotView(afterScreenUpdates: false)
        else { return nil }
        return CapturedSource(
            snapshot: snapshot,
            image: renderedImage(of: view),
            frame: view.convert(view.bounds, to: window),
            window: window
        )
    }

    static func play(from sourceView: UIView?, to destinationView: UIView? = nil) {
        playHaptic()

        guard let sourceView,
              let capturedSource = capture(sourceView)
        else { return }
        animate(capturedSource, to: destinationView)
    }

    static func play(captured source: CapturedSource, to destinationView: UIView?) {
        playHaptic()
        animate(source, to: destinationView)
    }

    static func confirm(on destinationView: UIView, countView: UIView? = nil) {
        guard !UIAccessibility.isReduceMotionEnabled else { return }

        destinationView.layer.removeAllAnimations()
        destinationView.transform = CGAffineTransform(scaleX: 0.76, y: 0.76)
        countView?.alpha = 0

        UIView.animate(
            withDuration: 0.12,
            delay: 0,
            options: [.allowUserInteraction, .curveEaseOut]
        ) {
            destinationView.transform = CGAffineTransform(scaleX: 1.12, y: 1.12)
            countView?.alpha = 1
        } completion: { _ in
            UIView.animate(
                withDuration: 0.1,
                delay: 0,
                options: [.allowUserInteraction, .curveEaseInOut]
            ) {
                destinationView.transform = .identity
            }
        }
    }

    private static func playHaptic() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred(intensity: 0.8)
    }

    private static func animate(_ source: CapturedSource, to destinationView: UIView?) {
        guard !UIAccessibility.isReduceMotionEnabled,
              let window = source.window
        else { return }

        let snapshot = source.snapshot
        snapshot.frame = source.frame
        snapshot.isUserInteractionEnabled = false
        window.addSubview(snapshot)

        let destinationCenter: CGPoint
        if let destinationView {
            destinationCenter = destinationView.convert(
                CGPoint(x: destinationView.bounds.midX, y: destinationView.bounds.midY),
                to: window
            )
        } else {
            destinationCenter = CGPoint(x: snapshot.center.x - 72, y: snapshot.center.y)
        }
        let translationX = destinationCenter.x - snapshot.center.x
        let translationY = destinationCenter.y - snapshot.center.y

        UIView.animate(
            withDuration: 0.26,
            delay: 0,
            options: [.allowUserInteraction, .curveEaseIn]
        ) {
            snapshot.transform = CGAffineTransform(translationX: translationX, y: translationY)
                .scaledBy(x: 0.58, y: 0.58)
            snapshot.alpha = 0.92
        } completion: { _ in
            explode(
                image: source.image,
                snapshot: snapshot,
                at: destinationCenter,
                sourceSize: source.frame.size,
                in: window
            )
        }
    }

    private static func renderedImage(of view: UIView) -> UIImage? {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        return renderer.image { context in
            view.layer.render(in: context.cgContext)
        }
    }

    private static func explode(
        image: UIImage?,
        snapshot: UIView,
        at center: CGPoint,
        sourceSize: CGSize,
        in window: UIWindow
    ) {
        guard let image, let cgImage = image.cgImage else {
            UIView.animate(
                withDuration: 0.16,
                delay: 0,
                options: [.allowUserInteraction, .curveEaseOut]
            ) {
                snapshot.transform = snapshot.transform.scaledBy(x: 1.45, y: 1.45)
                snapshot.alpha = 0
            } completion: { _ in
                snapshot.removeFromSuperview()
            }
            return
        }

        let gridSize = 3
        let impactScale: CGFloat = 0.58
        let impactSize = CGSize(
            width: sourceSize.width * impactScale,
            height: sourceSize.height * impactScale
        )
        let shardSize = CGSize(
            width: impactSize.width / CGFloat(gridSize),
            height: impactSize.height / CGFloat(gridSize)
        )
        var shards: [UIView] = []

        for row in 0..<gridSize {
            for column in 0..<gridSize {
                let normalizedX = CGFloat(column) / CGFloat(gridSize)
                let normalizedY = CGFloat(row) / CGFloat(gridSize)
                let offsetX = (CGFloat(column) - 1) * shardSize.width
                let offsetY = (CGFloat(row) - 1) * shardSize.height
                let shard = UIView(
                    frame: CGRect(
                        x: center.x + offsetX - shardSize.width / 2,
                        y: center.y + offsetY - shardSize.height / 2,
                        width: shardSize.width,
                        height: shardSize.height
                    )
                )
                shard.isUserInteractionEnabled = false
                shard.layer.contents = cgImage
                shard.layer.contentsScale = image.scale
                shard.layer.contentsGravity = .resize
                shard.layer.contentsRect = CGRect(
                    x: normalizedX,
                    y: normalizedY,
                    width: 1 / CGFloat(gridSize),
                    height: 1 / CGFloat(gridSize)
                )
                shard.layer.masksToBounds = true
                window.addSubview(shard)
                shards.append(shard)
            }
        }

        snapshot.removeFromSuperview()

        UIView.animate(
            withDuration: 0.34,
            delay: 0,
            usingSpringWithDamping: 0.74,
            initialSpringVelocity: 1.4,
            options: [.allowUserInteraction, .curveEaseOut]
        ) {
            for (index, shard) in shards.enumerated() {
                let row = index / gridSize
                let column = index % gridSize
                var direction = CGVector(
                    dx: CGFloat(column) - 1,
                    dy: CGFloat(row) - 1
                )
                if direction.dx == 0, direction.dy == 0 {
                    direction = CGVector(dx: 0, dy: -1)
                }
                let length = max(hypot(direction.dx, direction.dy), 1)
                let distance = CGFloat(18 + (index % 3) * 4)
                shard.center.x += direction.dx / length * distance
                shard.center.y += direction.dy / length * distance
                shard.transform = CGAffineTransform(
                    rotationAngle: (CGFloat(column - row) * 0.22)
                ).scaledBy(x: 0.58, y: 0.58)
            }
        }

        UIView.animate(
            withDuration: 0.24,
            delay: 0.07,
            options: [.allowUserInteraction, .curveEaseIn]
        ) {
            shards.forEach { $0.alpha = 0 }
        } completion: { _ in
            shards.forEach { $0.removeFromSuperview() }
        }
    }
}
