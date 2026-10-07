import CookedHTML
import Foundation
import UIKit

/// Immutable input handed to the background render pipeline. Keeping the
/// network Post model out of the worker avoids sending mutable UI state across
/// actors.
nonisolated struct PostRenderInput: Sendable, Hashable {
    let postId: Int
    let cookedHTML: String
    let contentVersion: UInt64

    init(postId: Int, cookedHTML: String) {
        self.postId = postId
        self.cookedHTML = cookedHTML
        contentVersion = Self.fnv1a64(cookedHTML.utf8)
    }

    private static func fnv1a64<S: Sequence>(_ bytes: S) -> UInt64 where S.Element == UInt8 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}

/// Every value that can change wrapping, height, or raster output. Cache
/// entries are never reused across different environments.
nonisolated struct RenderEnvironment: Hashable, Sendable {
    let contentWidthPixels: Int
    let displayScaleMilli: Int
    let fontRevision: Int
    let themeRevision: Int

    init(contentWidth: CGFloat, displayScale: CGFloat, fontRevision: Int, themeRevision: Int) {
        contentWidthPixels = Int((contentWidth * displayScale).rounded())
        displayScaleMilli = Int((displayScale * 1_000).rounded())
        self.fontRevision = fontRevision
        self.themeRevision = themeRevision
    }
}

/// Height chosen before a virtual item is published. Fixed units never ask
/// UIKit to measure themselves while scrolling. Deferred units keep a stable
/// placeholder until a renderer reports a genuine content-size change.
nonisolated enum RenderUnitHeightPolicy: Equatable, Sendable {
    case fixed(CGFloat)
    case deferred(CGFloat)

    var height: CGFloat {
        switch self {
        case .fixed(let height), .deferred(let height): height
        }
    }

    var acceptsDynamicUpdates: Bool {
        if case .deferred = self { return true }
        return false
    }
}

/// Immutable height table consumed by the timeline layout for one complete
/// rendering environment. Publishing this alongside a snapshot prevents new
/// cells from introducing estimated heights as they enter the viewport.
nonisolated struct PreparedTopicLayout: Sendable {
    let environment: RenderEnvironment
    let unitPolicies: [RenderUnitID: RenderUnitHeightPolicy]

    func policy(for unitId: RenderUnitID) -> RenderUnitHeightPolicy? {
        unitPolicies[unitId]
    }
}

/// Complete key for reusable unit-height measurements. `environment` is built
/// with the unit's effective content width, so tree indentation participates
/// in cache invalidation without requiring a separate depth field.
nonisolated struct RenderUnitHeightCacheKey: Hashable, Sendable {
    let unitId: RenderUnitID
    let environment: RenderEnvironment
    let dynamicStateRevision: Int
}

/// Coalesces renderer callbacks while the collection view is moving. The
/// newest size wins for each stable unit ID and the controller drains the
/// whole batch only after scrolling becomes idle.
nonisolated struct DynamicHeightUpdateBuffer: Sendable {
    private var values: [RenderUnitID: CGFloat] = [:]

    var isEmpty: Bool { values.isEmpty }
    var count: Int { values.count }

    mutating func enqueue(height: CGFloat, for unitId: RenderUnitID) {
        guard height.isFinite, height > 0 else { return }
        values[unitId] = height
    }

    mutating func removeAll(forPostId postId: Int) {
        values = values.filter { $0.key.postId != postId }
    }

    mutating func removeAll(keepingCapacity: Bool = true) {
        values.removeAll(keepingCapacity: keepingCapacity)
    }

    mutating func drain() -> [RenderUnitID: CGFloat] {
        let result = values
        values.removeAll(keepingCapacity: true)
        return result
    }
}

nonisolated struct RenderUnitID: Hashable, Sendable {
    let postId: Int
    let contentVersion: UInt64
    let ordinal: Int
}

/// Menu animations can finish after a drag starts or a new menu is presented.
/// Identify the presentation being dismissed instead of relying on a timeout.
nonisolated struct TopicSelectionMenuState {
    private(set) var currentID: UUID?
    private var retainedDismissals: Set<UUID> = []

    mutating func present() -> UUID {
        preserveSelectionOnDismissal()
        let id = UUID()
        currentID = id
        return id
    }

    mutating func preserveSelectionOnDismissal() {
        if let currentID { retainedDismissals.insert(currentID) }
    }

    mutating func shouldClearSelection(dismissing id: UUID?, isDragging: Bool) -> Bool {
        guard let id else { return false }
        let retained = retainedDismissals.remove(id) != nil
        guard id == currentID else { return false }
        currentID = nil
        return !retained && !isDragging
    }
}

/// Smallest independently virtualized piece of a post body.
nonisolated struct RenderUnit: Sendable {
    let id: RenderUnitID
    let block: ContentBlock
    let sourceHTML: String
    /// Space after this unit. Paragraphs split only for virtualization keep
    /// zero spacing between their internal chunks so they still read as one
    /// semantic paragraph.
    let bottomSpacing: CGFloat

    init(id: RenderUnitID, block: ContentBlock, sourceHTML: String, bottomSpacing: CGFloat = 8) {
        self.id = id
        self.block = block
        self.sourceHTML = sourceHTML
        self.bottomSpacing = bottomSpacing
    }

    var selectionText: String { block.selectionText }

    var isSelectionBoundary: Bool {
        switch block {
        case .blockquote, .discourseQuote:
            true
        default:
            false
        }
    }
}

nonisolated private extension InlineNode {
    var selectionText: String {
        switch self {
        case .text(let value), .styledText(let value, _), .code(let value):
            value
        case .link(_, let children), .spoiler(let children):
            children.map(\.selectionText).joined()
        case .image:
            "\u{FFFC}"
        case .lineBreak:
            "\n"
        case .mention(let username, _):
            "@\(username)"
        case .mentionGroup(let name, _):
            "@\(name)"
        case .hashtag(let text, _, _):
            "#\(text)"
        }
    }
}

nonisolated private extension Array where Element == InlineNode {
    var selectionText: String { map(\.selectionText).joined() }
}

nonisolated extension ContentBlock {
    var selectionText: String {
        switch self {
        case .paragraph(let inlines), .heading(_, let inlines):
            return inlines.selectionText
        case .codeBlock(_, let code):
            return code
        case .blockquote(let blocks), .spoiler(let blocks):
            return blocks.map(\.selectionText).joined(separator: "\n\n")
        case .discourseQuote(_, _, let topicTitle, _, _, _, let content):
            return ([topicTitle].compactMap { $0 } + content.map(\.selectionText))
                .joined(separator: "\n\n")
        case .image(_, let alt, _, _, _):
            return alt ?? ""
        case .onebox(let sourceURL, let title, let description, _, _, _, _):
            return [title, description, sourceURL].compactMap { $0 }.joined(separator: "\n")
        case .video(let url, _, let title, _, _, _, _):
            return [title, url].compactMap { $0 }.joined(separator: "\n")
        case .list(let ordered, let items):
            return items.enumerated().map { index, item in
                let marker = ordered ? "\(index + 1).\t" : "•\t"
                return marker + item.blocks.map(\.selectionText).joined(separator: "\n")
            }.joined(separator: "\n")
        case .table(let headers, let rows):
            let headerText = headers.map { $0.map(\.selectionText).joined(separator: " ") }
                .joined(separator: "\t")
            let rowText = rows.map { row in
                row.map { $0.map(\.selectionText).joined(separator: " ") }.joined(separator: "\t")
            }
            return ([headerText] + rowText).filter { !$0.isEmpty }.joined(separator: "\n")
        case .details(let summary, let content):
            return ([summary.selectionText] + content.map(\.selectionText))
                .filter { !$0.isEmpty }.joined(separator: "\n\n")
        case .poll(let name):
            return name
        case .divider:
            return ""
        case .rawHTML(let html):
            return html
        }
    }
}

nonisolated struct PostRenderDocument: Sendable {
    let postId: Int
    let contentVersion: UInt64
    let annotatedBlocks: [AnnotatedBlock]
    let units: [RenderUnit]
}

/// Immutable, renderer-independent description of an image-browser session.
/// Keeping URL collection here guarantees that the legacy and virtualized
/// topic controllers use the same image order and starting page.
nonisolated struct TopicImageBrowserRequest: Equatable, Sendable {
    let imageURLs: [URL]
    let startIndex: Int

    static func make(annotatedBlocks: [AnnotatedBlock], tappedURL: URL) -> Self {
        var seen = Set<String>()
        var urls: [URL] = []
        for rawURL in ImageURLCollector.collectImageURLs(from: annotatedBlocks) {
            guard seen.insert(rawURL).inserted, let url = URL(string: rawURL) else { continue }
            urls.append(url)
        }

        let tappedString = tappedURL.absoluteString
        if let index = urls.firstIndex(where: { $0.absoluteString == tappedString }) {
            return Self(imageURLs: urls, startIndex: index)
        }

        if seen.insert(tappedString).inserted || urls.isEmpty {
            urls.append(tappedURL)
        }
        return Self(
            imageURLs: urls,
            startIndex: urls.firstIndex(where: { $0.absoluteString == tappedString }) ?? 0
        )
    }
}

/// Pure, actor-isolated HTML parsing and semantic paragraph slicing.
actor TopicRenderPipeline {
    static let shared = TopicRenderPipeline()

    private nonisolated struct CacheKey: Hashable, Sendable {
        let input: PostRenderInput
        let baseURL: String?
    }

    private var cache: [CacheKey: PostRenderDocument] = [:]
    private let maxCachedDocuments = 80

    func renderDocuments(inputs: [PostRenderInput], baseURL: String?) -> [Int: PostRenderDocument] {
        var output: [Int: PostRenderDocument] = [:]
        output.reserveCapacity(inputs.count)

        for input in inputs {
            let key = CacheKey(input: input, baseURL: baseURL)
            if let cached = cache[key] {
                output[input.postId] = cached
                continue
            }

            let (annotated, units) = TopicRenderMetrics.measure("ParseAndSlicePost") {
                let annotated = CookedHTMLParser.parseAnnotated(html: input.cookedHTML, baseURL: baseURL)
                let units = RenderUnitBuilder.build(
                    postId: input.postId,
                    contentVersion: input.contentVersion,
                    annotatedBlocks: annotated
                )
                return (annotated, units)
            }
            let document = PostRenderDocument(
                postId: input.postId,
                contentVersion: input.contentVersion,
                annotatedBlocks: annotated,
                units: units
            )
            cache[key] = document
            output[input.postId] = document
        }

        if cache.count > maxCachedDocuments {
            // Documents are cheap to recreate and immutable. A simple bounded
            // cache is preferable to retaining every topic visited this session.
            cache.removeAll(keepingCapacity: true)
            for input in inputs {
                if let document = output[input.postId] {
                    cache[CacheKey(input: input, baseURL: baseURL)] = document
                }
            }
        }
        return output
    }

    func invalidateAll() {
        cache.removeAll(keepingCapacity: true)
    }
}

nonisolated enum RenderUnitBuilder {
    static let maxParagraphUTF16 = 400

    static func build(
        postId: Int,
        contentVersion: UInt64,
        annotatedBlocks: [AnnotatedBlock]
    ) -> [RenderUnit] {
        var units: [RenderUnit] = []
        var ordinal = 0

        for annotated in annotatedBlocks {
            if case .paragraph(let inlines) = annotated.block {
                let chunks = InlineNodeChunker.chunk(inlines, maximumUTF16Length: maxParagraphUTF16)
                let nonemptyChunks = chunks.filter { !$0.isEmpty }
                for (index, chunk) in nonemptyChunks.enumerated() {
                    units.append(RenderUnit(
                        id: RenderUnitID(postId: postId, contentVersion: contentVersion, ordinal: ordinal),
                        block: .paragraph(chunk),
                        sourceHTML: annotated.sourceHTML,
                        bottomSpacing: index == nonemptyChunks.count - 1 ? 8 : 0
                    ))
                    ordinal += 1
                }
            } else {
                units.append(RenderUnit(
                    id: RenderUnitID(postId: postId, contentVersion: contentVersion, ordinal: ordinal),
                    block: annotated.block,
                    sourceHTML: annotated.sourceHTML
                ))
                ordinal += 1
            }
        }
        return units
    }
}

/// Splits long inline trees without dropping styling or interaction wrappers.
/// Text nodes may be divided; links and spoilers are re-wrapped around each
/// resulting child chunk.
nonisolated enum InlineNodeChunker {
    static func chunk(_ nodes: [InlineNode], maximumUTF16Length limit: Int) -> [[InlineNode]] {
        precondition(limit > 0)
        let atoms = nodes.flatMap { split(node: $0, maximumUTF16Length: limit) }
        var chunks: [[InlineNode]] = []
        var current: [InlineNode] = []
        var currentLength = 0

        for atom in atoms {
            let length = max(1, utf16Length(of: atom))
            if !current.isEmpty, currentLength + length > limit {
                chunks.append(current)
                current = []
                currentLength = 0
            }
            current.append(atom)
            currentLength += length
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.isEmpty ? [[]] : chunks
    }

    private static func split(node: InlineNode, maximumUTF16Length limit: Int) -> [InlineNode] {
        switch node {
        case .text(let text):
            return split(text: text, maximumUTF16Length: limit).map(InlineNode.text)
        case .styledText(let text, let style):
            return split(text: text, maximumUTF16Length: limit).map { .styledText($0, style) }
        case .code(let text):
            return split(text: text, maximumUTF16Length: limit).map(InlineNode.code)
        case .link(let href, let children):
            return chunk(children, maximumUTF16Length: limit).map { .link(href: href, children: $0) }
        case .spoiler(let children):
            return chunk(children, maximumUTF16Length: limit).map { .spoiler(children: $0) }
        case .image, .lineBreak, .mention, .mentionGroup, .hashtag:
            return [node]
        }
    }

    private static func split(text: String, maximumUTF16Length limit: Int) -> [String] {
        guard text.utf16.count > limit else { return text.isEmpty ? [] : [text] }
        var output: [String] = []
        var start = text.startIndex

        while start < text.endIndex {
            var end = start
            var length = 0
            var preferredBreak: String.Index?
            while end < text.endIndex {
                let next = text.index(after: end)
                let characterLength = text[end..<next].utf16.count
                if length + characterLength > limit { break }
                length += characterLength
                if text[end].isWhitespace || text[end].isPunctuation {
                    preferredBreak = next
                }
                end = next
            }
            if let preferredBreak, preferredBreak > start,
               text.distance(from: preferredBreak, to: end) < limit / 3
            {
                end = preferredBreak
            }
            if end == start { end = text.index(after: start) }
            output.append(String(text[start..<end]))
            start = end
        }
        return output
    }

    static func utf16Length(of node: InlineNode) -> Int {
        switch node {
        case .text(let value), .code(let value): return value.utf16.count
        case .styledText(let value, _): return value.utf16.count
        case .link(_, let children), .spoiler(let children):
            return children.reduce(0) { $0 + utf16Length(of: $1) }
        case .mention(let username, _): return username.utf16.count + 1
        case .mentionGroup(let name, _): return name.utf16.count + 1
        case .hashtag(let text, _, _): return text.utf16.count + 1
        case .image, .lineBreak: return 1
        }
    }
}
