import Foundation
import SwiftSoup

/// Extracts a `[ContentBlock]` array from the children of a DOM element.
enum BlockExtractor {
    /// Tags treated as block-level elements.
    private static let blockTags: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6",
        "pre", "blockquote", "aside",
        "ul", "ol",
        "table",
        "details",
        "hr",
        "div", "figure",
        "video",
    ]

    /// Extract content blocks from a parent element's children.
    static func extract(from parent: Element, options: ParseOptions) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        for child in parent.getChildNodes() {
            blocks.append(contentsOf: extractNode(child, options: options))
        }
        return mergeInlineImageBlocks(blocks).compactMap { trimBlock($0) }
    }

    /// Extract annotated blocks (block + source HTML) from a parent element's children.
    static func extractAnnotated(from parent: Element, options: ParseOptions) -> [AnnotatedBlock] {
        var raw: [AnnotatedBlock] = []
        for child in parent.getChildNodes() {
            let blocks = extractNode(child, options: options).compactMap { trimBlock($0) }
            guard !blocks.isEmpty else { continue }
            let sourceHTML: String
            if let element = child as? Element {
                sourceHTML = (try? element.outerHtml()) ?? ""
            } else if let textNode = child as? TextNode {
                sourceHTML = textNode.getWholeText()
            } else {
                sourceHTML = ""
            }
            for block in blocks {
                raw.append(AnnotatedBlock(block: block, sourceHTML: sourceHTML))
            }
        }
        // Apply the same inline-image merging as extract(), preserving sourceHTML by
        // concatenating the HTML of merged siblings.
        guard raw.count > 1 else { return raw }
        var result: [AnnotatedBlock] = []
        for annotated in raw {
            guard let lastIndex = result.indices.last else {
                result.append(annotated)
                continue
            }
            let prev = result[lastIndex]
            // Case 1: small image → inline emoji at end of preceding paragraph
            if case .image(let src, let alt, let w, let h, _) = annotated.block,
               let w, let h, w <= 80, h <= 80,
               case .paragraph(let inlines) = prev.block
            {
                let merged = ContentBlock.paragraph(inlines + [.image(src: src, alt: alt, width: w, height: h, isEmoji: true)])
                result[lastIndex] = AnnotatedBlock(block: merged, sourceHTML: prev.sourceHTML + annotated.sourceHTML)
                continue
            }
            // Case 1b: paragraph following a small image → fold the image in as leading inline
            if case .paragraph(let newInlines) = annotated.block,
               case .image(let src, let alt, let w, let h, _) = prev.block,
               let w, let h, w <= 80, h <= 80
            {
                let merged = ContentBlock.paragraph([.image(src: src, alt: alt, width: w, height: h, isEmoji: true)] + newInlines)
                result[lastIndex] = AnnotatedBlock(block: merged, sourceHTML: prev.sourceHTML + annotated.sourceHTML)
                continue
            }
            // Case 2: paragraph following a paragraph that ends with inline emoji → merge
            if case .paragraph(let newInlines) = annotated.block,
               case .paragraph(let prevInlines) = prev.block,
               case .image(_, _, _, _, let isEmoji) = prevInlines.last, isEmoji
            {
                let merged = ContentBlock.paragraph(prevInlines + newInlines)
                result[lastIndex] = AnnotatedBlock(block: merged, sourceHTML: prev.sourceHTML + annotated.sourceHTML)
                continue
            }
            result.append(annotated)
        }
        return result
    }

    /// Extract content blocks from a single DOM node.
    static func extractNode(_ node: Node, options: ParseOptions) -> [ContentBlock] {
        if let textNode = node as? TextNode {
            let raw = textNode.getWholeText()
            // Trim leading whitespace/newlines but preserve meaningful trailing spaces
            // (they serve as word separators when adjacent inline elements are merged).
            let text = raw.replacingOccurrences(of: "^[\\s]+", with: "", options: .regularExpression)
            if text.isEmpty { return [] }
            return [.paragraph([.text(text)])]
        }

        guard let element = node as? Element else { return [] }
        let tagName = element.tagName().lowercased()

        switch tagName {
        case "p":
            return extractParagraph(from: element, options: options)

        case "h1", "h2", "h3", "h4", "h5", "h6":
            guard let lastChar = tagName.last, let level = Int(String(lastChar)) else { return [] }
            return extractHeading(from: element, level: level, options: options)

        case "pre":
            return extractCodeBlock(from: element)

        case "blockquote":
            let inner = extract(from: element, options: options)
            if inner.isEmpty { return [] }
            return [.blockquote(blocks: inner)]

        case "aside":
            return extractAside(from: element, options: options)

        case "ul":
            return [ListExtractor.extract(from: element, ordered: false, options: options)]

        case "ol":
            return [ListExtractor.extract(from: element, ordered: true, options: options)]

        case "table":
            return [TableExtractor.extract(from: element, options: options)]

        case "details":
            return extractDetails(from: element, options: options)

        case "br":
            // Bare <br> at block level is a DOM artifact from SwiftSoup splitting block-in-inline;
            // ignore it rather than emitting a lineBreak paragraph.
            return []

        case "hr":
            return [.divider]

        case "img":
            return extractBlockImage(from: element, options: options)

        case "video":
            return extractRawVideo(from: element, options: options)

        case "div", "figure", "section", "article":
            // Check for specific div patterns first, otherwise recurse
            return extractDiv(from: element, options: options)

        default:
            // Unknown block-level or inline elements at top level
            if isBlockElement(element) {
                return extract(from: element, options: options)
            }
            // Inline spoiler at block level (e.g. <span class="spoiler"> wrapping block children in a <td>)
            let classAttr = (try? element.attr("class")) ?? ""
            if classAttr.contains("spoiler") {
                let inner = extract(from: element, options: options)
                if inner.isEmpty { return [] }
                return [.spoiler(blocks: inner)]
            }
            // Inline element at block level — extract as inline node preserving tag semantics (bold, link, etc.)
            let inlines = InlineExtractor.extractNode(element, options: options)
            if inlines.isEmpty { return [] }
            return [.paragraph(inlines)]
        }
    }

    // MARK: - Specific extractors

    private static func extractParagraph(from element: Element, options: ParseOptions) -> [ContentBlock] {
        // Check if paragraph only contains a single image
        let children = element.children()
        if children.size() == 1,
           let onlyChild = children.first(),
           element.textNodes().allSatisfy({ $0.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        {
            let childTag = onlyChild.tagName().lowercased()

            // <p><img></p>
            if childTag == "img" {
                return extractBlockImage(from: onlyChild, options: options)
            }

            // <p><a><img></a></p>
            if childTag == "a",
               onlyChild.children().size() == 1,
               let innerImg = onlyChild.children().first(),
               innerImg.tagName().lowercased() == "img"
            {
                let href = URLResolver.resolve((try? onlyChild.attr("href")) ?? "", baseURL: options.baseURL)
                return extractBlockImage(from: innerImg, options: options, href: href.isEmpty ? nil : href)
            }

            // <p><div class="lightbox-wrapper">...</div></p>
            if childTag == "div" || childTag == "figure" {
                return extractDiv(from: onlyChild, options: options)
            }
        }

        // Raw <video> nested in a <p> (e.g. `<p>caption<br><video>...</video></p>`).
        // The inline extractor has no concept of videos, so split them out here
        // before the paragraph collapses to inlines and drops the video URL.
        if children.first(where: { $0.tagName().lowercased() == "video" }) != nil {
            return splitOutRawVideos(from: element, options: options)
        }

        let inlines = InlineExtractor.extract(from: element, options: options)
        if inlines.isEmpty { return [] }

        // Split large non-emoji images out of mixed paragraphs into block-level images.
        // e.g. <p>some text<br><img width="281" height="500"></p>
        //   → .paragraph("some text") + .image(...)
        return splitLargeImages(from: inlines)
    }

    /// Splits a list of inline nodes: text portions become `.paragraph`, large images become `.image`.
    private static func splitLargeImages(from inlines: [InlineNode]) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        var pending: [InlineNode] = []

        func flushPending() {
            // Trim trailing lineBreaks
            while pending.last == .lineBreak { pending.removeLast() }
            let trimmed = pending.trimmedWhitespace()
            if !trimmed.isEmpty {
                blocks.append(.paragraph(trimmed))
            }
            pending.removeAll()
        }

        for node in inlines {
            if case .image(let src, let alt, let width, let height, let isEmoji) = node,
               !isEmoji, let w = width, let h = height, w > 80 || h > 80 {
                flushPending()
                blocks.append(.image(src: src, alt: alt, width: w, height: h))
            } else {
                pending.append(node)
            }
        }
        flushPending()

        return blocks.isEmpty ? [.paragraph(inlines)] : blocks
    }

    private static func extractHeading(from element: Element, level: Int, options: ParseOptions) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        var pendingInlineNodes: [InlineNode] = []

        func flushHeading() {
            let inlines = sanitizeInlineNodes(pendingInlineNodes).trimmedWhitespace()
            guard !inlines.isEmpty else { return }
            blocks.append(.heading(level: level, content: inlines))
            pendingInlineNodes.removeAll()
        }

        for child in element.getChildNodes() {
            if let childElement = child as? Element, isBlockElement(childElement) {
                flushHeading()
                blocks.append(contentsOf: extractNode(childElement, options: options))
                continue
            }
            pendingInlineNodes.append(contentsOf: InlineExtractor.extractNode(child, options: options))
        }

        flushHeading()
        return blocks
    }

    private static func extractCodeBlock(from element: Element) -> [ContentBlock] {
        let codeElement = element.children().first { $0.tagName().lowercased() == "code" }
            ?? element

        let language: String? = {
            guard let cls = try? codeElement.attr("class"), !cls.isEmpty else { return nil }
            // Discourse uses class="lang-xxx" or "language-xxx"
            let parts = cls.split(separator: " ")
            for part in parts {
                let s = String(part)
                if s.hasPrefix("lang-") { return String(s.dropFirst(5)) }
                if s.hasPrefix("language-") { return String(s.dropFirst(9)) }
            }
            return nil
        }()

        let code = (try? codeElement.text()) ?? ""
        return [.codeBlock(language: language, code: code)]
    }

    private static func extractAside(from element: Element, options: ParseOptions) -> [ContentBlock] {
        let classAttr = (try? element.attr("class")) ?? ""
        if classAttr.contains("quote") {
            return [QuoteExtractor.extract(from: element, options: options)]
        }
        if classAttr.contains("onebox") {
            return [OneboxExtractor.extract(from: element, options: options)]
        }
        // Generic aside — recurse
        return extract(from: element, options: options)
    }

    private static func extractDetails(from element: Element, options: ParseOptions) -> [ContentBlock] {
        let summaryEl = element.children().first { $0.tagName().lowercased() == "summary" }
        let summaryInlines: [InlineNode]
        if let summaryEl {
            summaryInlines = InlineExtractor.extract(from: summaryEl, options: options).trimmedWhitespace()
        } else {
            summaryInlines = [.text("Details")]
        }

        // Content is everything except the summary element
        var contentBlocks: [ContentBlock] = []
        for child in element.getChildNodes() {
            if let el = child as? Element, el.tagName().lowercased() == "summary" { continue }
            contentBlocks.append(contentsOf: extractNode(child, options: options))
        }

        return [.details(summary: summaryInlines, content: contentBlocks)]
    }

    private static func extractBlockImage(from element: Element, options: ParseOptions, href: String? = nil) -> [ContentBlock] {
        let src = URLResolver.resolve((try? element.attr("src")) ?? "", baseURL: options.baseURL)
        let alt = try? element.attr("alt")
        let width = Int((try? element.attr("width")) ?? "")
        let height = Int((try? element.attr("height")) ?? "")
        return [.image(src: src, alt: alt, width: width, height: height, href: href)]
    }

    private static func extractDiv(from element: Element, options: ParseOptions) -> [ContentBlock] {
        let classAttr = (try? element.attr("class")) ?? ""

        // Lightbox wrapper
        if classAttr.contains("lightbox-wrapper") {
            if let img = try? element.select("img").first() {
                let href: String? = {
                    guard let anchor = try? element.select("a").first() else { return nil }
                    let h = URLResolver.resolve((try? anchor.attr("href")) ?? "", baseURL: options.baseURL)
                    return h.isEmpty ? nil : h
                }()
                return extractBlockImage(from: img, options: options, href: href)
            }
        }

        // Video embed (youtube-onebox, lazy-video-container, etc.)
        if classAttr.contains("lazy-video-container") || classAttr.contains("video-container") {
            return extractVideo(from: element, options: options)
        }

        // Discourse poll block
        if classAttr.contains("poll") {
            let pollName = (try? element.attr("data-poll-name")) ?? "poll"
            return [.poll(name: pollName)]
        }

        // Block-level spoiler: wrap all child blocks in a single .spoiler container
        if classAttr.contains("spoiler") {
            let inner = extract(from: element, options: options)
            if inner.isEmpty { return [] }
            return [.spoiler(blocks: inner)]
        }

        // Generic div — recurse into children
        let inner = extract(from: element, options: options)
        if inner.isEmpty { return [] }
        return inner
    }

    private static func extractVideo(from element: Element, options: ParseOptions) -> [ContentBlock] {
        let videoId = (try? element.attr("data-video-id")) ?? ""
        let title: String? = {
            let t = (try? element.attr("data-video-title")) ?? ""
            return t.isEmpty ? nil : t
        }()
        let provider: String? = {
            let p = (try? element.attr("data-provider-name")) ?? ""
            return p.isEmpty ? nil : p
        }()

        // URL from <a> href
        let url: String = {
            if let anchor = try? element.select("a").first() {
                let href = (try? anchor.attr("href")) ?? ""
                if !href.isEmpty { return href }
            }
            return ""
        }()

        // Thumbnail from <img>
        var thumbnailURL: String?
        var width: Int?
        var height: Int?
        if let img = try? element.select("img").first() {
            let src = (try? img.attr("src")) ?? ""
            if !src.isEmpty {
                thumbnailURL = URLResolver.resolve(src, baseURL: options.baseURL)
            }
            if let w = try? img.attr("width"), let wInt = Int(w) { width = wInt }
            if let h = try? img.attr("height"), let hInt = Int(h) { height = hInt }
        }

        return [.video(
            url: url,
            thumbnailURL: thumbnailURL,
            title: title,
            width: width,
            height: height,
            videoId: videoId.isEmpty ? nil : videoId,
            provider: provider
        )]
    }

    /// Raw `<video>` element (not the Discourse onebox wrapper) — reads the
    /// playable URL from `src` or the first `<source src>` child, and the
    /// poster image if present. `width="100%"` is common, so width/height are
    /// dropped unless they parse as integers (the renderer falls back to 16:9).
    private static func extractRawVideo(from element: Element, options: ParseOptions) -> [ContentBlock] {
        var url = (try? element.attr("src")) ?? ""
        if url.isEmpty, let source = try? element.select("source").first() {
            url = (try? source.attr("src")) ?? ""
        }
        let resolvedURL = URLResolver.resolve(url, baseURL: options.baseURL)
        guard !resolvedURL.isEmpty else { return [] }

        let poster = (try? element.attr("poster")) ?? ""
        let thumbnailURL = poster.isEmpty ? nil : URLResolver.resolve(poster, baseURL: options.baseURL)

        let width = Int((try? element.attr("width")) ?? "")
        let height = Int((try? element.attr("height")) ?? "")

        return [.video(
            url: resolvedURL,
            thumbnailURL: thumbnailURL,
            title: nil,
            width: width,
            height: height,
            videoId: nil,
            provider: nil
        )]
    }

    /// Walks a paragraph's children, emitting a `.paragraph` for inline runs and
    /// a standalone `.video` block for each `<video>` child, so the video URL
    /// isn't lost when the paragraph collapses to inlines.
    private static func splitOutRawVideos(from element: Element, options: ParseOptions) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        var pendingInlines: [InlineNode] = []

        func flushPending() {
            let trimmed = pendingInlines.trimmedWhitespace()
            pendingInlines.removeAll()
            if trimmed.isEmpty { return }
            blocks.append(contentsOf: splitLargeImages(from: trimmed))
        }

        for child in element.getChildNodes() {
            if let el = child as? Element, el.tagName().lowercased() == "video" {
                flushPending()
                blocks.append(contentsOf: extractRawVideo(from: el, options: options))
            } else {
                pendingInlines.append(contentsOf: InlineExtractor.extractNode(child, options: options))
            }
        }
        flushPending()
        return blocks
    }

    // MARK: - Helpers

    private static func sanitizeInlineNodes(_ nodes: [InlineNode]) -> [InlineNode] {
        nodes.compactMap { node in
            switch node {
            case .link(let href, let children):
                let sanitizedChildren = sanitizeInlineNodes(children)
                if href.isEmpty && sanitizedChildren.isEmpty {
                    return nil
                }
                return .link(href: href, children: sanitizedChildren)
            case .spoiler(let children):
                return .spoiler(children: sanitizeInlineNodes(children))
            default:
                return node
            }
        }
    }

    private static func isBlockElement(_ element: Element) -> Bool {
        blockTags.contains(element.tagName().lowercased())
    }

    /// Trim empty blocks (whitespace-only paragraphs, empty lists).
    ///
    /// Handles three kinds of "visually blank" paragraphs the extractor can emit:
    /// 1. Paragraphs made up entirely of whitespace-only text/styled-text nodes.
    /// 2. Paragraphs containing only `.lineBreak`s (e.g. from `<p><br></p>` or
    ///    chains of `<br>` between real content — common in quote excerpts).
    /// 3. Leading/trailing whitespace and `.lineBreak`s that would render as empty
    ///    space around the real text. Interior whitespace and line breaks are
    ///    preserved since they separate inline nodes and intentional soft breaks.
    private static func trimBlock(_ block: ContentBlock) -> ContentBlock? {
        switch block {
        case .paragraph(let inlines):
            var trimmed = inlines

            trimLeading: while let first = trimmed.first {
                switch first {
                case .lineBreak:
                    trimmed.removeFirst()
                case .text(let text):
                    let value = text.replacingOccurrences(
                        of: "^[\\s]+",
                        with: "",
                        options: .regularExpression
                    )
                    if value.isEmpty {
                        trimmed.removeFirst()
                    } else {
                        trimmed[0] = .text(value)
                        break trimLeading
                    }
                case .styledText(let text, let style):
                    let value = text.replacingOccurrences(
                        of: "^[\\s]+",
                        with: "",
                        options: .regularExpression
                    )
                    if value.isEmpty {
                        trimmed.removeFirst()
                    } else {
                        trimmed[0] = .styledText(value, style)
                        break trimLeading
                    }
                default:
                    break trimLeading
                }
            }

            trimTrailing: while let last = trimmed.last {
                switch last {
                case .lineBreak:
                    trimmed.removeLast()
                case .text(let text):
                    let value = text.replacingOccurrences(
                        of: "[\\s]+$",
                        with: "",
                        options: .regularExpression
                    )
                    if value.isEmpty {
                        trimmed.removeLast()
                    } else {
                        trimmed[trimmed.count - 1] = .text(value)
                        break trimTrailing
                    }
                case .styledText(let text, let style):
                    let value = text.replacingOccurrences(
                        of: "[\\s]+$",
                        with: "",
                        options: .regularExpression
                    )
                    if value.isEmpty {
                        trimmed.removeLast()
                    } else {
                        trimmed[trimmed.count - 1] = .styledText(value, style)
                        break trimTrailing
                    }
                default:
                    break trimTrailing
                }
            }

            return trimmed.isEmpty ? nil : .paragraph(trimmed)
        case .list(_, let items):
            return items.isEmpty ? nil : block
        case .blockquote(let blocks):
            return blocks.isEmpty ? nil : block
        default:
            return block
        }
    }

    /// Merge blocks that result from SwiftSoup splitting inline content into separate top-level nodes.
    /// Handles three cases:
    /// 1. Small (emoji-sized) `.image` blocks following a `.paragraph` → merged as trailing inline.
    /// 1b. `.paragraph` following a small (emoji-sized) `.image` block → small image folded as leading inline.
    ///     This catches e.g. a table cell like `<td><img class="emoji"> text</td>` whose children are parsed
    ///     as two siblings; without this case the small image would stay as a block and get rescaled up.
    /// 2. Consecutive `.paragraph` blocks that are bare siblings (no intervening block) → merged.
    private static func mergeInlineImageBlocks(_ blocks: [ContentBlock]) -> [ContentBlock] {
        guard blocks.count > 1 else { return blocks }
        var result: [ContentBlock] = []
        for block in blocks {
            guard let lastIndex = result.indices.last else {
                result.append(block)
                continue
            }
            // Case 1: small image following a paragraph → inline emoji at end
            if case .image(let src, let alt, let w, let h, _) = block,
               let w, let h, w <= 80, h <= 80,
               case .paragraph(let inlines) = result[lastIndex]
            {
                result[lastIndex] = .paragraph(inlines + [.image(src: src, alt: alt, width: w, height: h, isEmoji: true)])
                continue
            }
            // Case 1b: paragraph following a small image → fold the image in as leading inline
            if case .paragraph(let newInlines) = block,
               case .image(let src, let alt, let w, let h, _) = result[lastIndex],
               let w, let h, w <= 80, h <= 80
            {
                result[lastIndex] = .paragraph([.image(src: src, alt: alt, width: w, height: h, isEmoji: true)] + newInlines)
                continue
            }
            // Case 2: bare text/inline paragraph following a paragraph that ends with an inline image
            // (handles SwiftSoup splitting "text<img>text" into separate top-level nodes)
            if case .paragraph(let newInlines) = block,
               case .paragraph(let prevInlines) = result[lastIndex],
               case .image(_, _, _, _, let isEmoji) = prevInlines.last, isEmoji
            {
                result[lastIndex] = .paragraph(prevInlines + newInlines)
                continue
            }
            result.append(block)
        }
        return result
    }
}
