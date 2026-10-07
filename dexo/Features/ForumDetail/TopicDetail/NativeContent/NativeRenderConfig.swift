import CookedHTML
import UIKit

enum NativeImageSizingMode {
    /// Match Discourse's 690px post canvas, scaling image dimensions with the
    /// available post width.
    case discourseResponsive
    /// Preserve the image's declared size whenever it fits, while still
    /// shrinking oversized images to the available width.
    case fitWithoutUpscaling
}

struct NativeRenderConfig {
    let baseFont: UIFont
    let baseColor: UIColor
    let linkColor: UIColor
    let codeFont: UIFont
    let codeBackgroundColor: UIColor
    let contentWidth: CGFloat
    let baseURL: String?
    let imageSizingMode: NativeImageSizingMode

    init(
        baseFont: UIFont,
        baseColor: UIColor,
        linkColor: UIColor,
        codeFont: UIFont,
        codeBackgroundColor: UIColor,
        contentWidth: CGFloat,
        baseURL: String?,
        imageSizingMode: NativeImageSizingMode = .discourseResponsive
    ) {
        self.baseFont = baseFont
        self.baseColor = baseColor
        self.linkColor = linkColor
        self.codeFont = codeFont
        self.codeBackgroundColor = codeBackgroundColor
        self.contentWidth = contentWidth
        self.baseURL = baseURL
        self.imageSizingMode = imageSizingMode
    }

    var attributedStringConfig: AttributedStringConfig {
        AttributedStringConfig(
            baseFont: baseFont,
            baseColor: baseColor,
            linkColor: linkColor,
            codeFont: codeFont,
            codeBackgroundColor: codeBackgroundColor,
            lineSpacing: baseFont.pointSize * 0.35
        )
    }

    static func `default`(contentWidth: CGFloat, baseURL: String? = nil) -> NativeRenderConfig {
        let fm = FontManager.shared
        return NativeRenderConfig(
            baseFont: fm.font(size: 16),
            baseColor: .label,
            linkColor: .link,
            codeFont: fm.monospacedFont(size: 15),
            codeBackgroundColor: ThemeManager.shared.codeBackgroundColor,
            contentWidth: contentWidth,
            baseURL: baseURL
        )
    }
}

// MARK: - BlockRenderer Protocol

protocol BlockRenderer {
    static func canRender(_ block: ContentBlock) -> Bool
    static func render(_ block: ContentBlock, config: NativeRenderConfig, delegate: PostCellDelegate?) -> UIView
}

// MARK: - NativeContentRenderer

enum NativeContentRenderer {
    /// Vertical spacing between blocks in `PostNativeCell.contentStackView`.
    /// Mirror this in any precomputed-height calculator so summed heights
    /// match the rendered layout.
    static let contentStackSpacing: CGFloat = 8

    /// Cap on the merged plain-text length (UTF-16 units, matches
    /// `NSAttributedString.length`) for a single paragraph chunk.
    ///
    /// Posts that are dozens of short `<p>` blocks (AI prompt dumps, FAQs,
    /// long lists with `<br>` separators) otherwise collapse into one giant
    /// text view. That creates an oversized backing store and makes initial
    /// TextKit layout unnecessarily expensive.
    ///
    /// At ~1000 UTF-16 units the cap kicks in only for outliers. Short
    /// posts merge into one view as before. Long posts are split into
    /// chunks small enough for selectable TextKit views to lay out without
    /// creating a single oversized backing store.
    static let maxMergedParagraphChars = 1000

    static let renderers: [BlockRenderer.Type] = [
        ParagraphRenderer.self,
        HeadingRenderer.self,
        DividerRenderer.self,
        ListRenderer.self,
        BlockquoteRenderer.self,
        ImageRenderer.self,
        CodeBlockRenderer.self,
        DiscourseQuoteRenderer.self,
        DetailsRenderer.self,
        SpoilerRenderer.self,
        OneboxRenderer.self,
        VideoRenderer.self,
        TableRenderer.self,
        PollRenderer.self,
        RawHTMLRenderer.self,
    ]

    static func renderBlocks(
        _ blocks: [ContentBlock],
        config: NativeRenderConfig,
        delegate: PostCellDelegate?
    ) -> [UIView] {
        renderBlockList(blocks, config: config, delegate: delegate)
    }

    static func renderBlocks(
        _ annotatedBlocks: [AnnotatedBlock],
        config: NativeRenderConfig,
        delegate: PostCellDelegate?,
        pollProvider: ((String) -> (poll: DiscourseTopicDetail.Poll, votedOptionIds: Set<String>, post: DiscourseTopicDetail.Post)?)? = nil,
        precomputedBlockHeights: [CGFloat?]? = nil
    ) -> [UIView] {
        _ = annotatedBlocks.map { annotated -> ContentBlock? in
            if case .poll(_) = annotated.block, pollProvider != nil {
                return annotated.block // handled separately below
            }
            return annotated.block
        }

        var views: [UIView] = []
        var i = 0
        while i < annotatedBlocks.count {
            let annotated = annotatedBlocks[i]

            // Poll blocks need extra data from the Post model
            if case .poll(let name) = annotated.block,
               let pollData = pollProvider?(name)
            {
                views.append(PollRenderer.render(
                    poll: pollData.poll,
                    votedOptionIds: pollData.votedOptionIds,
                    post: pollData.post,
                    containerWidth: config.contentWidth,
                    delegate: delegate
                ))
                i += 1
                continue
            }

            // Combine consecutive paragraphs into a single selectable text view.
            if case .paragraph(let firstInlines) = annotated.block {
                let j = paragraphRunEnd(annotatedBlocks: annotatedBlocks, startIndex: i)

                let attr: NSAttributedString
                if j > i + 1 {
                    attr = mergeParagraphs(annotatedBlocks[i..<j], config: config)
                } else {
                    attr = firstInlines.attributedString(config: config.attributedStringConfig)
                }

                views.append(ParagraphRenderer.makeTextView(attributedText: attr, config: config))
                i = j
                continue
            }

            var matched = false
            for renderer in renderers where renderer.canRender(annotated.block) {
                views.append(renderer.render(annotated.block, config: config, delegate: delegate))
                matched = true
                break
            }
            if !matched {
                // Unrecognized block (e.g., `.rawHTML` parser fallback). Append
                // a placeholder so `views.count` stays aligned with the per-block
                // heights array — otherwise the `heights.count == views.count`
                // guard below skips ALL pinning, dropping the surrounding
                // paragraph chunks back to autosize.
                views.append(UIView())
            }
            i += 1
        }

        // Pin each block view to its precomputed height. Lets PostNativeCell
        // skip the systemLayoutSizeFitting → Core Text typesetting cascade
        // when measuring the cell — the contentStackView sums known heights
        // instead of asking each label/textView for its intrinsic content size.
        //
        // Length must match the view sequence (paragraph merging considered).
        // Mismatched lengths fall through to autosizing rather than crash.
        if let heights = precomputedBlockHeights, heights.count == views.count {
            for (view, h) in zip(views, heights) {
                guard let h else { continue }
                let c = view.heightAnchor.constraint(equalToConstant: h)
                // Below `.required` so a text view whose intrinsic content height
                // differs from `boundingRect` by a sub-pixel can self-adjust
                // without crashing autolayout.
                c.priority = UILayoutPriority(999)
                c.isActive = true
            }
        }

        return views
    }

    /// Shared implementation for plain ContentBlock arrays (used by quote/details renderers).
    private static func renderBlockList(
        _ blocks: [ContentBlock],
        config: NativeRenderConfig,
        delegate: PostCellDelegate?
    ) -> [UIView] {
        blocks.compactMap { block in
            for renderer in renderers where renderer.canRender(block) {
                return renderer.render(block, config: config, delegate: delegate)
            }
            return nil
        }
    }

    /// Returns the exclusive end index `j` such that `annotatedBlocks[i..<j]`
    /// is the next paragraph run to merge into one view. The run stops at the
    /// first non-paragraph block, OR when adding the next paragraph would push
    /// the merged plain-text length past `maxMergedParagraphChars`.
    ///
    /// Always includes at least one paragraph (a single oversized paragraph
    /// can't be split further without breaking semantics).
    ///
    /// `BlockHeightCalculator.perBlockHeights` calls this too so the height
    /// array length stays aligned with the view sequence — required by the
    /// `heights.count == views.count` guard in `renderBlocks`.
    static func paragraphRunEnd(annotatedBlocks: [AnnotatedBlock], startIndex i: Int) -> Int {
        guard i < annotatedBlocks.count,
              case .paragraph(let firstInlines) = annotatedBlocks[i].block
        else { return i }

        var j = i + 1
        var totalLength = inlinesPlainTextLength(firstInlines)
        while j < annotatedBlocks.count,
              case .paragraph(let inlines) = annotatedBlocks[j].block
        {
            let next = inlinesPlainTextLength(inlines)
            // +1 for the small-font newline separator between paragraphs.
            if totalLength + 1 + next > maxMergedParagraphChars { break }
            totalLength += 1 + next
            j += 1
        }
        return j
    }

    /// Approximate UTF-16 length of the plain text rendered by `inlines`.
    /// Used only as a chunking signal — exactness isn't needed.
    private static func inlinesPlainTextLength(_ inlines: [InlineNode]) -> Int {
        var total = 0
        for inline in inlines {
            switch inline {
            case .text(let s):
                total += s.utf16.count
            case .styledText(let s, _):
                total += s.utf16.count
            case .code(let s):
                total += s.utf16.count
            case .lineBreak:
                total += 1
            case .link(_, let children):
                total += inlinesPlainTextLength(children)
            case .spoiler(let children):
                total += inlinesPlainTextLength(children)
            case .mention(let username, _):
                total += username.utf16.count + 1
            case .mentionGroup(let name, _):
                total += name.utf16.count + 1
            case .hashtag(let text, _, _):
                total += text.utf16.count + 1
            case .image:
                total += 1
            }
        }
        return total
    }

    /// Merge consecutive paragraph blocks into a single NSAttributedString with paragraph spacing.
    private static func mergeParagraphs<C: Collection>(
        _ blocks: C, config: NativeRenderConfig
    ) -> NSAttributedString where C.Element == AnnotatedBlock {
        let result = NSMutableAttributedString()
        for (offset, annotated) in blocks.enumerated() {
            guard case .paragraph(let inlines) = annotated.block else { continue }
            if offset > 0 {
                // Paragraph separator — gives visual spacing similar to stackView spacing
                result.append(NSAttributedString(string: "\n", attributes: [
                    .font: config.baseFont.withSize(8), // small font → ~8pt gap between paragraphs
                ]))
            }
            result.append(inlines.attributedString(config: config.attributedStringConfig))
        }
        return result
    }
}
