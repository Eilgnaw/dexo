import CookedHTML
import UIKit

enum SpoilerAppearance {
    /// Keeps the concealed content visibly present without leaving text or
    /// image details readable. The ultra-thin material also distinguishes a
    /// spoiler from the flat gray image-loading placeholder.
    static let blurStyle: UIBlurEffect.Style = .systemUltraThinMaterial
}

enum SpoilerRenderer: BlockRenderer {
    static func canRender(_ block: ContentBlock) -> Bool {
        if case .spoiler = block { return true }
        return false
    }

    static func render(_ block: ContentBlock, config: NativeRenderConfig, delegate: PostCellDelegate?) -> UIView {
        guard case .spoiler(let blocks) = block else { return UIView() }
        return SpoilerBlockView(blocks: blocks, config: config, delegate: delegate)
    }
}

// MARK: - SpoilerOverlayView

/// Reusable blur overlay that wraps any content view with tap-to-toggle spoiler effect.
/// The blur effect itself is installed once at full intensity; reveal/hide is done by
/// animating `blurView.alpha` so the effect never snaps (animating `UIVisualEffectView.effect`
/// via UIView.animate is unreliable on iOS and was the cause of the reveal-then-flash bug).
class SpoilerOverlayView: UIView {
    private let blurView: UIVisualEffectView
    private let contentView: UIView
    private(set) var isRevealed = false
    var onRevealChange: ((Bool) -> Void)?

    init(
        contentView: UIView,
        cornerRadius: CGFloat = 0,
        blurStyle: UIBlurEffect.Style = SpoilerAppearance.blurStyle
    ) {
        self.contentView = contentView
        blurView = UIVisualEffectView(effect: UIBlurEffect(style: blurStyle))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = true
        layer.cornerRadius = cornerRadius

        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)

        blurView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blurView)

        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),

            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        contentView.isUserInteractionEnabled = false

        let tap = UITapGestureRecognizer(target: self, action: #selector(toggle))
        addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func toggle() {
        setRevealed(!isRevealed, animated: true)
    }

    func setRevealed(_ revealed: Bool, animated: Bool = false) {
        guard revealed != isRevealed || blurView.alpha != (revealed ? 0 : 1) else { return }
        isRevealed = revealed
        contentView.isUserInteractionEnabled = revealed
        let changes = { self.blurView.alpha = revealed ? 0 : 1 }
        if animated { UIView.animate(withDuration: 0.25, animations: changes) }
        else { changes() }
        onRevealChange?(revealed)
    }
}

// MARK: - SpoilerBlockView

private class SpoilerBlockView: UIView {
    private let overlay: SpoilerOverlayView
    private let contentStack: UIStackView

    init(blocks: [ContentBlock], config: NativeRenderConfig, delegate: PostCellDelegate?) {
        let contentStack = UIStackView()
        contentStack.axis = .vertical
        contentStack.spacing = 8
        contentStack.backgroundColor = ThemeManager.shared.cardBackgroundColor
        contentStack.isLayoutMarginsRelativeArrangement = true
        contentStack.layoutMargins = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        self.contentStack = contentStack

        let views = NativeContentRenderer.renderBlocks(blocks, config: config, delegate: delegate)
        for view in views {
            contentStack.addArrangedSubview(view)
        }

        overlay = SpoilerOverlayView(contentView: contentStack, cornerRadius: 6)

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange),
            name: ThemeManager.themeDidChangeNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func themeDidChange() {
        contentStack.backgroundColor = ThemeManager.shared.cardBackgroundColor
    }
}
