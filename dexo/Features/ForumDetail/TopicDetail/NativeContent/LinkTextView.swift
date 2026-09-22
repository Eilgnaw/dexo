import CookedHTML
import UIKit

/// A UITextView subclass that disables text selection while preserving link tap interaction.
/// `isSelectable` remains `true` (required for link detection), but selection handles and
/// copy/paste menus are suppressed.
/// Also handles tap-to-reveal for inline spoiler text ranges (`<span class="spoiler">`).
final class LinkTextView: UITextView {
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

    override var selectedTextRange: UITextRange? {
        get { nil }
        set { }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        false
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Disable all built-in long press gestures (loupe/selection) so they don't
        // conflict with the cell's long press gesture. Link taps still work via tap.
        gestureRecognizers?.forEach { gesture in
            if gesture is UILongPressGestureRecognizer {
                gesture.isEnabled = false
            }
        }
    }

    override func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        []
    }

    deinit {}

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
            layoutManager.ensureLayout(forCharacterRange: range)
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)

            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, usedRect, _, lineGlyphRange, _ in
                let intersection = NSIntersectionRange(glyphRange, lineGlyphRange)
                guard intersection.length > 0 else { return }

                let glyphRect = self.layoutManager.boundingRect(
                    forGlyphRange: intersection, in: self.textContainer
                )

                // Snap to the line-fragment edges (container right, not the
                // tight `usedRect`) whenever the spoiler reaches that edge of
                // this line. `usedRect.maxX` varies with each line's content
                // length so adjacent / wrapped spoilers still looked jagged —
                // using `lineRect.maxX` puts every affected row's right edge
                // on the same column.
                let lineEnd = lineGlyphRange.location + lineGlyphRange.length
                let extendsToLineStart = intersection.location <= lineGlyphRange.location
                let extendsToLineEnd = intersection.location + intersection.length >= lineEnd
                let left = extendsToLineStart ? lineRect.minX : glyphRect.minX
                let right = extendsToLineEnd ? lineRect.maxX : glyphRect.maxX

                var rect = CGRect(x: left, y: usedRect.minY, width: right - left, height: usedRect.height)
                rect.origin.x += self.textContainerInset.left
                rect.origin.y += self.textContainerInset.top
                rect = rect.integral
                guard rect.width > 0, rect.height > 0 else { return }

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
