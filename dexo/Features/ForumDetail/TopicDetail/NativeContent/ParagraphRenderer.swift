import UIKit
import CookedHTML

enum ParagraphRenderer: BlockRenderer {
    static func canRender(_ block: ContentBlock) -> Bool {
        if case .paragraph = block { return true }
        return false
    }

    static func render(_ block: ContentBlock, config: NativeRenderConfig, delegate: PostCellDelegate?) -> UIView {
        guard case .paragraph(let inlines) = block else { return UIView() }
        let attr = inlines.attributedString(config: config.attributedStringConfig)
        return makeTextView(attributedText: attr, config: config)
    }

    /// Creates a configured LinkTextView — also used by NativeContentRenderer for merged paragraphs.
    static func makeTextView(attributedText: NSAttributedString, config: NativeRenderConfig) -> LinkTextView {
        let textView = LinkTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.backgroundColor = .clear
        textView.dataDetectorTypes = []
        textView.attributedText = attributedText
        textView.linkTextAttributes = [
            .foregroundColor: config.linkColor,
        ]
        textView.translatesAutoresizingMaskIntoConstraints = false
        return textView
    }

    /// Creates a TextKit 2 backed UITextView. Use only for paragraphs that
    /// don't need link tap / spoiler / inline-image handling — those go through
    /// `makeTextView` (LinkTextView, TextKit 1) because the spoiler overlay
    /// pipeline reaches into `layoutManager` (TK1-only API).
    ///
    /// Hypothesis: TK2's `NSTextLayoutManager` defers glyph generation to
    /// drawing time per layout-fragment, which on first display might cost
    /// less than UILabel's whole-string Core Text rasterization. **Caveat:**
    /// with `isScrollEnabled = false` the text view sizes to the full content
    /// rect, so a CALayer-bound backing store still has to rasterize every
    /// visible glyph. Whether TK2 actually wins here is empirical — this is
    /// the experiment.
    @available(iOS 16.0, *)
    static func makeTK2TextView(attributedText: NSAttributedString, config: NativeRenderConfig) -> UITextView {
        let textView = UITextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.backgroundColor = .clear
        textView.dataDetectorTypes = []
        textView.attributedText = attributedText
        textView.linkTextAttributes = [
            .foregroundColor: config.linkColor,
        ]
        textView.translatesAutoresizingMaskIntoConstraints = false
        return textView
    }
}
