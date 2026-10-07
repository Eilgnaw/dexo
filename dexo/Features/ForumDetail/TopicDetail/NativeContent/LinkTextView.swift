import CookedHTML
import UIKit

/// Geometry from the text view's active layout engine. Unlike `layoutManager`,
/// UITextInput queries don't migrate a TextKit 2 view into compatibility mode.
enum TopicTextInputGeometry {
    static func offset(in textView: UITextView, at point: CGPoint) -> Int? {
        guard let position = textView.closestPosition(to: point) else { return nil }
        return max(0, min(
            textView.attributedText.length,
            textView.offset(from: textView.beginningOfDocument, to: position)
        ))
    }

    static func characterRange(in textView: UITextView, at point: CGPoint) -> NSRange? {
        guard let range = textView.characterRange(at: point) else { return nil }
        let start = textView.offset(from: textView.beginningOfDocument, to: range.start)
        let length = textView.offset(from: range.start, to: range.end)
        guard start >= 0, length > 0, start <= textView.attributedText.length,
              length <= textView.attributedText.length - start
        else { return nil }
        return NSRange(location: start, length: length)
    }

    static func rects(in textView: UITextView, for range: NSRange) -> [CGRect] {
        guard range.location >= 0, range.length > 0,
              range.location <= textView.attributedText.length,
              range.length <= textView.attributedText.length - range.location,
              let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
              let end = textView.position(from: start, offset: range.length),
              let textRange = textView.textRange(from: start, to: end)
        else { return [] }
        // UIKit already includes text-container insets and wrapped-line edges.
        return textView.selectionRects(for: textRange).map(\.rect).filter {
            !$0.isEmpty && !$0.isNull && !$0.isInfinite
        }
    }
}

/// On-demand responder for UIKit's selected-text services (Look Up, Translate,
/// Share, accessibility actions, etc.). It never draws or receives touches;
/// the virtualized post remains responsible for selection geometry/gestures.
final class TopicSelectionTextServicesView: UITextView {
    var onCopy: (() -> Void)?
    var onSelectAll: (() -> Void)?
    var canSelectAllContent = false
    var selectionAnchorRect = CGRect(x: 0, y: 0, width: 1, height: 20)

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 1, height: 1), textContainer: nil)
        isEditable = false
        isSelectable = true
        isScrollEnabled = true
        accessibilityElementsHidden = true
        backgroundColor = .clear
        textColor = .clear
        tintColor = .clear
        clipsToBounds = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }

    func prepare(selectedText: String) {
        text = selectedText
        _ = becomeFirstResponder()
        selectedRange = NSRange(location: 0, length: (selectedText as NSString).length)
        suppressSelectionDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        suppressSelectionDisplay()
    }

    private func suppressSelectionDisplay() {
        if #available(iOS 17.0, *) {
            for interaction in interactions {
                guard let display = interaction as? UITextSelectionDisplayInteraction else { continue }
                display.isActivated = false
                display.cursorView.isHidden = true
                display.highlightView.isHidden = true
                display.handleViews.forEach { $0.isHidden = true }
            }
        }
    }

    // The responder supplies text, not a second on-screen selection. Services
    // still get a real anchor for their popovers through firstRect(for:).
    override func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }
    override func caretRect(for position: UITextPosition) -> CGRect { .zero }
    override func firstRect(for range: UITextRange) -> CGRect { selectionAnchorRect }

    override func copy(_ sender: Any?) { onCopy?() }
    override func selectAll(_ sender: Any?) { onSelectAll?() }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(selectAll(_:)) { return canSelectAllContent }
        return super.canPerformAction(action, withSender: sender)
    }
}

/// A non-editable text view that supports native text selection, copy, link taps,
/// and tap-to-reveal for inline spoiler ranges (`<span class="spoiler">`).
final class LinkTextView: UITextView {
    var onExternalLinkTap: ((URL) -> Void)?
    var usesExternalSelectionInteraction = false {
        didSet {
            if usesExternalSelectionInteraction {
                super.selectedTextRange = nil
            }
            isSelectable = !usesExternalSelectionInteraction
            externalLinkTapGesture.isEnabled = usesExternalSelectionInteraction
        }
    }
    private lazy var externalLinkTapGesture: UITapGestureRecognizer = {
        let gesture = UITapGestureRecognizer(target: self, action: #selector(externalLinkTapped(_:)))
        gesture.isEnabled = false
        addGestureRecognizer(gesture)
        return gesture
    }()
    private var spoilerRevealed = false
    private var spoilerRanges: [NSRange] = []
    /// Tap-catching containers. Alpha stays at 1 so UIKit hit-testing keeps
    /// routing taps to them even when `blurViews` are faded out (alpha < 0.01
    /// would otherwise skip the view during hit-test).
    private var spoilerContainers: [UIView] = []
    /// The actual blur views nested inside each container — these are what we
    /// animate for reveal/hide.
    private var blurViews: [UIVisualEffectView] = []
    private var needsBlurLayout = false

    /// Full-intensity blur style used for inline spoilers. We keep `effect`
    /// static and toggle `alpha` — animating `effect` via UIView.animate is
    /// unreliable on iOS and causes the "reveal flashes then snaps back" bug.
    private static let blurStyle = SpoilerAppearance.blurStyle

    deinit {}

    override var selectedTextRange: UITextRange? {
        get { usesExternalSelectionInteraction ? nil : super.selectedTextRange }
        set {
            guard !usesExternalSelectionInteraction else { return }
            super.selectedTextRange = newValue
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        usesExternalSelectionInteraction
            ? false
            : super.canPerformAction(action, withSender: sender)
    }

    @objc private func externalLinkTapped(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, attributedText.length > 0 else { return }
        let point = gesture.location(in: self)
        guard let range = TopicTextInputGeometry.characterRange(in: self, at: point),
              TopicTextInputGeometry.rects(in: self, for: range).contains(where: {
                  $0.insetBy(dx: -4, dy: -4).contains(point)
              })
        else { return }
        let characterIndex = range.location
        let value = attributedText.attribute(.link, at: characterIndex, effectiveRange: nil)
        let url: URL?
        if let existing = value as? URL {
            url = existing
        } else if let raw = value as? String {
            url = URL(string: raw)
        } else {
            url = nil
        }
        if let url { onExternalLinkTap?(url) }
    }

    func prioritizeExternalSelectionGestures(
        longPressGesture: UIGestureRecognizer,
        doubleTapGesture: UITapGestureRecognizer
    ) {
        externalLinkTapGesture.require(toFail: longPressGesture)
        externalLinkTapGesture.require(toFail: doubleTapGesture)
    }

    /// Call after setting attributedText to enable inline spoiler tap handling if needed.
    func configureSpoilerIfNeeded() {
        guard let attrText = attributedText, attrText.length > 0 else { return }
        let full = NSRange(location: 0, length: attrText.length)

        var ranges: [NSRange] = []
        attrText.enumerateAttribute(.cookedHTMLSpoiler, in: full) { value, range, _ in
            if value != nil { ranges.append(range) }
        }

        guard !ranges.isEmpty else { return }
        spoilerRanges = ranges
        needsBlurLayout = true
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if needsBlurLayout, bounds.width > 0 {
            needsBlurLayout = false
            DispatchQueue.main.async { [weak self] in
                self?.createBlurOverlays()
            }
        }
    }

    // MARK: - Blur Overlays

    private func createBlurOverlays() {
        spoilerContainers.forEach { $0.removeFromSuperview() }
        spoilerContainers.removeAll()
        blurViews.removeAll()

        let effect = UIBlurEffect(style: Self.blurStyle)

        for range in spoilerRanges {
            for selectionRect in TopicTextInputGeometry.rects(in: self, for: range) {
                // Selection geometry includes full-width intermediate lines,
                // keeping wrapped spoilers covered without TK1 glyph queries.
                let rect = selectionRect.integral
                let container = UIView(frame: rect)
                container.isUserInteractionEnabled = true
                container.layer.cornerRadius = 3
                container.clipsToBounds = true
                let tap = UITapGestureRecognizer(target: self, action: #selector(self.toggleSpoiler))
                container.addGestureRecognizer(tap)

                let blur = UIVisualEffectView(effect: effect)
                blur.frame = container.bounds
                blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                blur.isUserInteractionEnabled = false
                blur.alpha = self.spoilerRevealed ? 0 : 1
                container.addSubview(blur)

                self.addSubview(container)
                self.spoilerContainers.append(container)
                self.blurViews.append(blur)
            }
        }
    }

    // MARK: - Reveal

    @objc private func toggleSpoiler() {
        spoilerRevealed.toggle()
        let targetAlpha: CGFloat = spoilerRevealed ? 0 : 1
        UIView.animate(withDuration: 0.25) {
            self.blurViews.forEach { $0.alpha = targetAlpha }
        }
    }
}
