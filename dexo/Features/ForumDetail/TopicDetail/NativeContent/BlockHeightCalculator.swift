import CookedHTML
import UIKit

/// Computes the height of a `PostNativeCell`'s content stack without going
/// through UIKit's autolayout solver. Lets `heightForRowAt` (or
/// `systemLayoutSizeFitting`) short-circuit the slow Core Text + autolayout
/// path that otherwise dominates first-display cost on complex posts.
///
/// Coverage is intentionally partial: each block type is opt-in and unsupported
/// types return `nil`, signalling the caller to fall back to autosizing. As
/// renderers are migrated, more cells gain the fast path.
enum BlockHeightCalculator {
    /// Total content stack height for `annotatedBlocks` at `config.contentWidth`,
    /// including the inter-block spacing. Returns `nil` if any block type
    /// doesn't yet support height precomputation.
    ///
    /// `spacing` defaults to `NativeContentRenderer.contentStackSpacing` for the
    /// top-level cell stack. Nested stacks (blockquote, list, discourseQuote)
    /// use smaller values and pass them explicitly.
    static func contentStackHeight(
        for annotatedBlocks: [AnnotatedBlock],
        config: NativeRenderConfig,
        spacing: CGFloat = NativeContentRenderer.contentStackSpacing
    ) -> CGFloat? {
        let heights = perBlockHeights(annotatedBlocks: annotatedBlocks, config: config)
        if heights.isEmpty { return 0 }
        // We can only return a total when every block is measurable.
        let resolved = heights.compactMap { $0 }
        guard resolved.count == heights.count else { return nil }
        return resolved.reduce(0, +) + CGFloat(heights.count - 1) * spacing
    }

    /// Total height of a nested block stack (blockquote, discourseQuote inner
    /// content, list complex item, etc.). Inputs are plain `ContentBlock`s —
    /// these paths skip the consecutive-paragraph merge that the top-level
    /// `AnnotatedBlock` path uses, mirroring `NativeContentRenderer.renderBlockList`.
    static func nestedStackHeight(
        for blocks: [ContentBlock],
        config: NativeRenderConfig,
        spacing: CGFloat
    ) -> CGFloat? {
        if blocks.isEmpty { return 0 }
        var total: CGFloat = 0
        for block in blocks {
            guard let h = height(for: block, config: config) else { return nil }
            total += h
        }
        return total + CGFloat(blocks.count - 1) * spacing
    }

    /// Per-block heights aligned with the view sequence produced by
    /// `NativeContentRenderer.renderBlocks(_:config:delegate:pollProvider:)`.
    ///
    /// Always returns one entry per chunk (paragraph merge considered). Entries
    /// are `nil` for block types the calculator can't measure (`table`,
    /// `details`, `poll`, `rawHTML`). The renderer skips pinning for those
    /// indices — surrounding paragraphs still get the precomputed-height fast
    /// path. Previously a single unsupported block forced the entire post to
    /// fall back to autosize.
    static func perBlockHeights(
        annotatedBlocks: [AnnotatedBlock],
        config: NativeRenderConfig
    ) -> [CGFloat?] {
        perBlockHeightsProfiled(annotatedBlocks: annotatedBlocks, config: config).heights
    }

    /// Per-type timing aggregator returned alongside the heights array.
    /// Use this from the background warmup so the trace can show *exactly*
    /// where the time goes (paragraph chunks vs image vs onebox vs ...).
    /// Sync callers stick with `perBlockHeights` and pay no overhead.
    static func perBlockHeightsProfiled(
        annotatedBlocks: [AnnotatedBlock],
        config: NativeRenderConfig
    ) -> (heights: [CGFloat?], profile: [String: (count: Int, ms: Double)]) {
        var result: [CGFloat?] = []
        var profile: [String: (count: Int, ms: Double)] = [:]
        var i = 0
        while i < annotatedBlocks.count {
            let annotated = annotatedBlocks[i]

            // Mirror NativeContentRenderer's consecutive-paragraph merge,
            // including the maxMergedParagraphChars cap so chunk boundaries
            // (and thus the heights array) match the view sequence.
            if case .paragraph = annotated.block {
                let j = NativeContentRenderer.paragraphRunEnd(
                    annotatedBlocks: annotatedBlocks, startIndex: i
                )
                let t0 = CACurrentMediaTime()
                if j > i, let h = mergedParagraphHeight(annotatedBlocks[i..<j], config: config) {
                    result.append(h)
                } else {
                    result.append(nil)
                }
                let ms = (CACurrentMediaTime() - t0) * 1000
                var entry = profile["paragraph", default: (0, 0)]
                entry.count += 1
                entry.ms += ms
                profile["paragraph"] = entry
                i = max(j, i + 1)
                continue
            }

            let t0 = CACurrentMediaTime()
            result.append(height(for: annotated.block, config: config))
            let ms = (CACurrentMediaTime() - t0) * 1000
            let key = blockTypeName(annotated.block)
            var entry = profile[key, default: (0, 0)]
            entry.count += 1
            entry.ms += ms
            profile[key] = entry
            i += 1
        }
        return (result, profile)
    }

    private static func blockTypeName(_ block: ContentBlock) -> String {
        switch block {
        case .paragraph: return "paragraph"
        case .heading: return "heading"
        case .codeBlock: return "codeBlock"
        case .blockquote: return "blockquote"
        case .discourseQuote: return "discourseQuote"
        case .image: return "image"
        case .divider: return "divider"
        case .list: return "list"
        case .video: return "video"
        case .spoiler: return "spoiler"
        case .onebox: return "onebox"
        case .table: return "table"
        case .details: return "details"
        case .poll: return "poll"
        case .rawHTML: return "rawHTML"
        }
    }

    /// Height of a single block at `config.contentWidth`. Returns `nil` for
    /// block types that haven't been migrated yet.
    static func height(for block: ContentBlock, config: NativeRenderConfig) -> CGFloat? {
        switch block {
        case .paragraph(let inlines):
            return paragraphHeight(inlines, config: config)

        case .heading(let level, let inlines):
            return headingHeight(level: level, inlines: inlines, config: config)

        case .image(_, _, let width, let height, _):
            return imageHeight(
                width: width,
                height: height,
                containerWidth: config.contentWidth,
                sizingMode: config.imageSizingMode
            )

        case .divider:
            return Self.dividerHeight

        case .codeBlock(_, let code):
            return codeBlockHeight(code: code, config: config)

        case .blockquote(let inner):
            return blockquoteHeight(inner: inner, config: config)

        case .discourseQuote(_, _, _, _, let categoryName, _, let content):
            return discourseQuoteHeight(
                hasCategory: !(categoryName ?? "").isEmpty,
                content: content,
                config: config
            )

        case .list(let ordered, let items):
            return listHeight(ordered: ordered, items: items, config: config)

        case .video(_, _, _, let width, let height, _, _):
            return imageHeight(
                width: width,
                height: height,
                containerWidth: config.contentWidth,
                sizingMode: .discourseResponsive
            )

        case .spoiler(let blocks):
            return spoilerHeight(blocks: blocks, config: config)

        case .onebox(_, let title, let description, let imageURL, let imageWidth, let imageHeight, _):
            return oneboxHeight(
                title: title,
                description: description,
                imageURL: imageURL,
                imageWidth: imageWidth,
                imageHeight: imageHeight,
                config: config
            )

        // Block types whose height we can't predict accurately:
        // - table: cells lay out at column widths whose TextKit-resolved
        //   heights don't reliably match `boundingRect` (off by ~10pt for
        //   CJK-heavy content). The renderer hands back a scroll view that
        //   self-sizes via constraints, so autosize works correctly.
        // - details: expand toggle changes height; needs explicit invalidation
        // - poll: needs per-vote runtime data via pollProvider
        // - rawHTML: opaque fallback, not safe to precompute
        case .table,
             .details,
             .poll,
             .rawHTML:
            return nil
        }
    }

    // MARK: - Constants matching renderer layouts

    /// Mirrors `DividerRenderer` — the inner line is 1px but the container is 16pt tall.
    private static let dividerHeight: CGFloat = 16

    /// Mirrors `TappableImageContainer.referenceWidth` — Discourse's reference width
    /// at which `<img width=...>` translates to full container width.
    private static let imageReferenceWidth: CGFloat = 690

    // MARK: - Paragraph

    private static func paragraphHeight(
        _ inlines: [InlineNode],
        config: NativeRenderConfig
    ) -> CGFloat {
        let attr = inlines.attributedString(config: config.attributedStringConfig)
        return attributedTextHeight(attr, width: config.contentWidth)
    }

    /// Mirrors `NativeContentRenderer.mergeParagraphs` — joins paragraphs with a
    /// small (8pt) font separator so the rendered height matches what the cell
    /// will actually display.
    private static func mergedParagraphHeight<C: Collection>(
        _ blocks: C,
        config: NativeRenderConfig
    ) -> CGFloat? where C.Element == AnnotatedBlock {
        let result = NSMutableAttributedString()
        for (offset, annotated) in blocks.enumerated() {
            guard case .paragraph(let inlines) = annotated.block else { return nil }
            if offset > 0 {
                result.append(NSAttributedString(string: "\n", attributes: [
                    .font: config.baseFont.withSize(8),
                ]))
            }
            result.append(inlines.attributedString(config: config.attributedStringConfig))
        }
        return attributedTextHeight(result, width: config.contentWidth)
    }

    // MARK: - Heading

    /// Mirrors `HeadingRenderer.render` — picks the same per-level font and
    /// rebuilds the attributed string with that as the base font so the
    /// computed height matches what the rendered label / textView produces.
    private static func headingHeight(
        level: Int,
        inlines: [InlineNode],
        config: NativeRenderConfig
    ) -> CGFloat {
        let (size, weight) = headingFontParams(level: level)
        let headingConfig = NativeRenderConfig(
            baseFont: FontManager.shared.font(size: size, weight: weight),
            baseColor: config.baseColor,
            linkColor: config.linkColor,
            codeFont: config.codeFont,
            codeBackgroundColor: config.codeBackgroundColor,
            contentWidth: config.contentWidth,
            baseURL: config.baseURL,
            imageSizingMode: config.imageSizingMode
        )
        let attr = inlines.attributedString(config: headingConfig.attributedStringConfig)
        return attributedTextHeight(attr, width: config.contentWidth)
    }

    private static func headingFontParams(level: Int) -> (CGFloat, UIFont.Weight) {
        switch level {
        case 1: return (28, .bold)
        case 2: return (24, .bold)
        case 3: return (20, .semibold)
        case 4: return (18, .semibold)
        case 5: return (16, .semibold)
        default: return (16, .medium)
        }
    }

    // MARK: - Image

    /// Mirrors `TappableImageContainer.init`'s height formula. Falls back to a
    /// 16:9 placeholder when HTML didn't supply dimensions; the renderer's
    /// post-load fix-up corrects the height once the image arrives.
    private static func imageHeight(
        width: Int?,
        height: Int?,
        containerWidth: CGFloat,
        sizingMode: NativeImageSizingMode
    ) -> CGFloat {
        if let w = width, let h = height, w > 0, h > 0 {
            let displayWidth: CGFloat
            switch sizingMode {
            case .discourseResponsive:
                let fraction = min(CGFloat(w) / Self.imageReferenceWidth, 1)
                displayWidth = containerWidth * fraction
            case .fitWithoutUpscaling:
                displayWidth = min(CGFloat(w), containerWidth)
            }
            return CGFloat(h) * (displayWidth / CGFloat(w))
        }
        return containerWidth * 9.0 / 16.0
    }

    // MARK: - Code Block

    /// Mirrors `CodeBlockRenderer`. Delegates visual-line height to the
    /// renderer's TextKit measurement so the cell height and the actual code
    /// view stay in sync — the old `font.lineHeight * lines` estimate
    /// underestimated for some fonts and caused short blocks to scroll.
    private static func codeBlockHeight(code: String, config: NativeRenderConfig) -> CGFloat {
        let codeHeight = CodeBlockRenderer.measureCodeHeight(
            code: code,
            font: config.codeFont,
            contentWidth: config.contentWidth
        )
        return Self.codeChromeHeight + codeHeight
    }

    /// 4 (top) + 26 (header copy button) + 2 (gap to code) + 12 (bottom) = 44
    private static let codeChromeHeight: CGFloat = 44

    // MARK: - Blockquote

    /// Mirrors `BlockquoteRenderer`. Inner content uses spacing 6, width
    /// reduced by 15 (3 bar + 12 gap to content); outer container has 4pt
    /// top + 4pt bottom padding. Callouts (`> [!warning]` etc.) take a
    /// different layout path.
    private static func blockquoteHeight(inner: [ContentBlock], config: NativeRenderConfig) -> CGFloat? {
        if let parsed = BlockquoteRenderer.parseCallout(inner) {
            return calloutHeight(parsed: parsed, config: config)
        }
        let innerConfig = NativeRenderConfig(
            baseFont: config.baseFont,
            baseColor: .secondaryLabel,
            linkColor: config.linkColor,
            codeFont: config.codeFont,
            codeBackgroundColor: config.codeBackgroundColor,
            contentWidth: config.contentWidth - 15,
            baseURL: config.baseURL,
            imageSizingMode: config.imageSizingMode
        )
        guard let innerH = nestedStackHeight(for: inner, config: innerConfig, spacing: 6) else { return nil }
        return innerH + Self.blockquoteVerticalPadding
    }

    private static func calloutHeight(parsed: BlockquoteRenderer.ParsedCallout, config: NativeRenderConfig) -> CGFloat? {
        let contentConfig = NativeRenderConfig(
            baseFont: config.baseFont,
            baseColor: config.baseColor,
            linkColor: config.linkColor,
            codeFont: config.codeFont,
            codeBackgroundColor: config.codeBackgroundColor,
            contentWidth: config.contentWidth - BlockquoteRenderer.calloutHorizontalPadding * 2,
            baseURL: config.baseURL,
            imageSizingMode: config.imageSizingMode
        )
        guard let innerH = nestedStackHeight(
            for: parsed.blocks,
            config: contentConfig,
            spacing: BlockquoteRenderer.calloutContentSpacing
        ) else { return nil }
        return BlockquoteRenderer.calloutTitleHeight
            + BlockquoteRenderer.calloutTitleContentGap
            + innerH
            + BlockquoteRenderer.calloutVerticalPadding
    }

    /// 4 (top) + 4 (bottom)
    private static let blockquoteVerticalPadding: CGFloat = 8

    // MARK: - Discourse Quote

    /// Mirrors `DiscourseQuoteRenderer`. The renderer reduces the inner content
    /// width by 36pt (more than the constraint math demands — kept identical to
    /// match exact rendering). Header height is `max(avatarSize, textBaseline)`.
    private static func discourseQuoteHeight(
        hasCategory: Bool,
        content: [ContentBlock],
        config: NativeRenderConfig
    ) -> CGFloat? {
        let innerConfig = NativeRenderConfig(
            baseFont: config.baseFont.withSize(config.baseFont.pointSize - 1),
            baseColor: .secondaryLabel,
            linkColor: config.linkColor,
            codeFont: config.codeFont,
            codeBackgroundColor: config.codeBackgroundColor,
            contentWidth: config.contentWidth - 36,
            baseURL: config.baseURL,
            imageSizingMode: config.imageSizingMode
        )
        guard let innerH = nestedStackHeight(for: content, config: innerConfig, spacing: 6) else { return nil }

        let avatarSize = FontManager.shared.scaled(20)
        // Header text intrinsic height — title uses 13pt semibold (one line),
        // username uses 13pt semibold (one line), category badge uses 11pt
        // semibold + 2+2 padding (~16pt). Center-aligned stack → take the max.
        let titleLineHeight = FontManager.shared.font(size: 13, weight: .semibold).lineHeight
        let badgeHeight: CGFloat = hasCategory ? 18 : 0
        let headerTextHeight = max(titleLineHeight, badgeHeight)
        let headerHeight = max(avatarSize, headerTextHeight)

        return Self.discourseQuoteTopPadding
            + headerHeight
            + Self.discourseQuoteHeaderToContent
            + innerH
            + Self.discourseQuoteBottomPadding
    }

    /// 10 (top of container to header)
    private static let discourseQuoteTopPadding: CGFloat = 10
    /// 8 (header bottom to content top)
    private static let discourseQuoteHeaderToContent: CGFloat = 8
    /// 10 (content bottom to container bottom)
    private static let discourseQuoteBottomPadding: CGFloat = 10

    // MARK: - List

    /// Mirrors `ListRenderer`. Two paths matching the renderer:
    /// - All items are paragraph-only → single combined attributed string.
    /// - Mixed items (some have nested blocks) → per-item itemStack with
    ///   bullet-or-bullet+text + indented child blocks.
    /// Returns nil if any nested child block type is itself unsupported.
    private static func listHeight(
        ordered: Bool,
        items: [CookedHTML.ListItem],
        config: NativeRenderConfig
    ) -> CGFloat? {
        let indent: CGFloat = ordered ? 20 : 12

        // Fast path: matches ListRenderer.renderCombinedFlatList.
        let allFlat = items.allSatisfy { item in
            item.blocks.allSatisfy { block in
                if case .paragraph = block { return true }
                return false
            }
        }
        if allFlat {
            let combined = NSMutableAttributedString()
            for (index, item) in items.enumerated() {
                if index > 0 { combined.append(NSAttributedString(string: "\n")) }
                var allInlines: [InlineNode] = []
                for (i, block) in item.blocks.enumerated() {
                    if case .paragraph(let inlines) = block {
                        if i > 0 { allInlines.append(.lineBreak) }
                        allInlines.append(contentsOf: inlines)
                    }
                }
                combined.append(makeListBulletAttributedString(
                    inlines: allInlines,
                    ordered: ordered,
                    index: index,
                    indent: indent,
                    config: config
                ))
            }
            return attributedTextHeight(combined, width: config.contentWidth)
        }

        // Mixed path: each item is its own vertical stack with spacing 4.
        // Items in the outer stack are also separated by spacing 4.
        let childConfig = NativeRenderConfig(
            baseFont: config.baseFont,
            baseColor: config.baseColor,
            linkColor: config.linkColor,
            codeFont: config.codeFont,
            codeBackgroundColor: config.codeBackgroundColor,
            contentWidth: config.contentWidth - indent,
            baseURL: config.baseURL,
            imageSizingMode: config.imageSizingMode
        )

        var itemHeights: [CGFloat] = []
        for (index, item) in items.enumerated() {
            guard let h = mixedListItemHeight(
                item: item,
                ordered: ordered,
                index: index,
                indent: indent,
                config: config,
                childConfig: childConfig
            ) else {
                return nil
            }
            itemHeights.append(h)
        }
        if itemHeights.isEmpty { return 0 }
        return itemHeights.reduce(0, +) + CGFloat(itemHeights.count - 1) * Self.listOuterSpacing
    }

    /// 4pt — matches `itemStack.spacing` and the outer list stack spacing.
    private static let listOuterSpacing: CGFloat = 4
    private static let listItemInternalSpacing: CGFloat = 4

    /// Per-item height for the mixed-path list (some non-paragraph blocks).
    /// Mirrors `ListRenderer.renderItem`'s control flow precisely.
    private static func mixedListItemHeight(
        item: CookedHTML.ListItem,
        ordered: Bool,
        index: Int,
        indent: CGFloat,
        config: NativeRenderConfig,
        childConfig: NativeRenderConfig
    ) -> CGFloat? {
        // If this single item happens to be all-paragraph, the renderer routes
        // it to renderFlatItem (one combined view) — match that.
        let allParagraphs = item.blocks.allSatisfy {
            if case .paragraph = $0 { return true }
            return false
        }
        if allParagraphs {
            var allInlines: [InlineNode] = []
            for (i, block) in item.blocks.enumerated() {
                if case .paragraph(let inlines) = block {
                    if i > 0 { allInlines.append(.lineBreak) }
                    allInlines.append(contentsOf: inlines)
                }
            }
            let attr = makeListBulletAttributedString(
                inlines: allInlines,
                ordered: ordered,
                index: index,
                indent: indent,
                config: config
            )
            return attributedTextHeight(attr, width: config.contentWidth)
        }

        var subviewHeights: [CGFloat] = []
        var isFirstBlock = true
        for block in item.blocks {
            if isFirstBlock, case .paragraph(let inlines) = block {
                isFirstBlock = false
                let attr = makeListBulletAttributedString(
                    inlines: inlines,
                    ordered: ordered,
                    index: index,
                    indent: indent,
                    config: config
                )
                subviewHeights.append(attributedTextHeight(attr, width: config.contentWidth))
            } else {
                if isFirstBlock {
                    isFirstBlock = false
                    let bullet = makeListBulletAttributedString(
                        inlines: [],
                        ordered: ordered,
                        index: index,
                        indent: indent,
                        config: config
                    )
                    subviewHeights.append(attributedTextHeight(bullet, width: config.contentWidth))
                }
                guard let childH = height(for: block, config: childConfig) else { return nil }
                subviewHeights.append(childH)
            }
        }

        // Edge case: item.blocks empty → just a bullet.
        if isFirstBlock {
            let bullet = makeListBulletAttributedString(
                inlines: [],
                ordered: ordered,
                index: index,
                indent: indent,
                config: config
            )
            subviewHeights.append(attributedTextHeight(bullet, width: config.contentWidth))
        }

        return subviewHeights.reduce(0, +) + CGFloat(max(0, subviewHeights.count - 1)) * Self.listItemInternalSpacing
    }

    /// Mirrors `ListRenderer.makeBulletedAttributedString` so the height
    /// calculation accounts for the bullet prefix, indent, and per-line spacing.
    private static func makeListBulletAttributedString(
        inlines: [InlineNode],
        ordered: Bool,
        index: Int,
        indent: CGFloat,
        config: NativeRenderConfig
    ) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacing = 4
        paragraphStyle.lineSpacing = config.baseFont.pointSize * 0.2
        paragraphStyle.headIndent = indent
        paragraphStyle.firstLineHeadIndent = 0
        paragraphStyle.tabStops = [NSTextTab(textAlignment: .left, location: indent, options: [:])]
        paragraphStyle.defaultTabInterval = indent

        let result = NSMutableAttributedString()
        let bullet = ordered ? "\(index + 1).\t" : "\u{2022}\t"
        result.append(NSAttributedString(string: bullet, attributes: [
            .font: config.baseFont,
            .foregroundColor: config.baseColor,
            .paragraphStyle: paragraphStyle,
        ]))

        if !inlines.isEmpty {
            result.append(inlines.attributedString(config: config.attributedStringConfig))
        }

        result.addAttribute(
            .paragraphStyle,
            value: paragraphStyle,
            range: NSRange(location: 0, length: result.length)
        )
        return result
    }

    // MARK: - Onebox

    /// Mirrors `OneboxCardView`. Three vertical sections:
    /// 1. Header — favicon + domain + 1px separator. Fixed-ish height (~33pt
    ///    when favicon present; we use 33 unconditionally as a safe upper bound).
    /// 2. Text stack — optional title (font 14, max 2 lines) + optional
    ///    description (font 13, max 3 lines), with 10pt top + bottom margins.
    /// 3. Optional image wrapper — full-width image with 12pt bottom inset.
    private static func oneboxHeight(
        title: String?,
        description: String?,
        imageURL: String?,
        imageWidth: Int?,
        imageHeight: Int?,
        config: NativeRenderConfig
    ) -> CGFloat {
        let containerWidth = config.contentWidth

        // Header height: 8 (top) + 16 (favicon-or-line-height max) + 8 (bottom) + 1 (separator)
        let headerH = Self.oneboxHeaderHeight

        // Text stack: 10 + items + 10 (margins). Items have 4pt spacing between them.
        let textWidth = containerWidth - 24
        var textItems: [CGFloat] = []
        if let title, !title.isEmpty {
            let font = FontManager.shared.font(size: 14, weight: .medium)
            textItems.append(cappedTextHeight(text: title, font: font, width: textWidth, maxLines: 2))
        }
        if let description, !description.isEmpty {
            let font = FontManager.shared.font(size: 13)
            textItems.append(cappedTextHeight(text: description, font: font, width: textWidth, maxLines: 3))
        }
        let textItemsTotal = textItems.reduce(0, +)
            + CGFloat(max(0, textItems.count - 1)) * Self.oneboxTextSpacing
        let textStackH = Self.oneboxTextVerticalMargins + textItemsTotal

        // Optional image wrapper.
        var imageBlockH: CGFloat = 0
        if let imageURL, URL(string: imageURL) != nil {
            let displayWidth = containerWidth - 24
            let imageH: CGFloat
            if let w = imageWidth, let h = imageHeight, w > 0 {
                imageH = displayWidth * CGFloat(h) / CGFloat(w)
            } else {
                imageH = displayWidth * 9.0 / 16.0
            }
            imageBlockH = imageH + Self.oneboxImageBottomInset
        }

        return headerH + textStackH + imageBlockH
    }

    /// 8 (top) + 16 (favicon / domain line) + 8 (bottom) + 1 (separator)
    private static let oneboxHeaderHeight: CGFloat = 33
    /// 10 (top margin) + 10 (bottom margin)
    private static let oneboxTextVerticalMargins: CGFloat = 20
    /// `textStack.spacing` between title and description
    private static let oneboxTextSpacing: CGFloat = 4
    /// imageView pinned to wrapper top with 0 inset and bottom with -12 inset
    private static let oneboxImageBottomInset: CGFloat = 12

    // MARK: - Spoiler

    /// Mirrors `SpoilerBlockView` — wraps an inner stack (spacing 8) inside a
    /// blur overlay with `layoutMargins = (4, 0, 4, 0)`. Width is unchanged.
    private static func spoilerHeight(blocks: [ContentBlock], config: NativeRenderConfig) -> CGFloat? {
        guard let innerH = nestedStackHeight(for: blocks, config: config, spacing: NativeContentRenderer.contentStackSpacing) else {
            return nil
        }
        return innerH + Self.spoilerVerticalMargins
    }

    /// 4 (top margin) + 4 (bottom margin)
    private static let spoilerVerticalMargins: CGFloat = 8

    // MARK: - TextKit Helpers

    /// Computes the rendered height of an attributed string at a fixed width.
    /// Uses `boundingRect`'s TextKit path to match `LinkTextView`, which is
    /// configured with `lineFragmentPadding = 0` and `textContainerInset = .zero`
    /// in `ParagraphRenderer.makeTextView`.
    ///
    /// Safe to call from any thread — each invocation builds its own
    /// `NSStringDrawingContext`.
    private static func attributedTextHeight(_ attr: NSAttributedString, width: CGFloat) -> CGFloat {
        guard attr.length > 0, width > 0 else { return 0 }
        let bounds = attr.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return ceil(bounds.height)
    }

    /// Plain-text height capped at `maxLines × lineHeight` to mirror UILabel's
    /// `numberOfLines` truncation. Used by onebox and other renderers that
    /// clamp line count.
    private static func cappedTextHeight(
        text: String,
        font: UIFont,
        width: CGFloat,
        maxLines: Int
    ) -> CGFloat {
        let attr = NSAttributedString(string: text, attributes: [.font: font])
        let natural = attributedTextHeight(attr, width: width)
        if maxLines <= 0 { return natural }
        let cap = ceil(font.lineHeight * CGFloat(maxLines))
        return min(natural, cap)
    }
}
