import CookedHTML
import UIKit
import XCTest
@testable import dexo

final class TopicRenderPipelineTests: XCTestCase {
    @MainActor
    func testExternalSelectionPreservesTextKit2ParagraphGeometry() {
        guard #available(iOS 16.0, *) else { return }
        let config = NativeRenderConfig.default(contentWidth: 396)
        let inlines: [InlineNode] = [
            .text("我测试的时候貌似没发生过这种事情欸 "),
            .image(src: "https://example.com/emoji/roll_eyes.png", alt: ":roll_eyes:", width: 20, height: 20, isEmoji: true),
            .lineBreak, .lineBreak,
            .text("佬是在什么时候左键失效的，战斗中还是在营地里呀"),
        ]
        let textView = ParagraphRenderer.makeTextView(
            attributedText: inlines.attributedString(config: config.attributedStringConfig),
            config: config
        )
        let window = hostSelectionTextView(textView)
        defer { window.isHidden = true }
        VirtualTextSelectionGeometry.setExternalSelectionEnabled(true, in: textView)
        guard let manager = textView.textLayoutManager else { return XCTFail("Expected TextKit 2") }
        let originalFrame = textView.frame
        let originalOffset = textView.contentOffset
        let fullRange = NSRange(location: 0, length: textView.attributedText.length)
        let originalRects = TopicTextInputGeometry.rects(in: textView, for: fullRange)
        XCTAssertFalse(originalRects.isEmpty)

        XCTAssertNotNil(VirtualTextSelectionGeometry.offset(in: textView, at: CGPoint(x: 40, y: 10)))
        XCTAssertNotNil(VirtualTextSelectionGeometry.wordRange(in: textView, at: CGPoint(x: 40, y: 10)))
        VirtualTextSelectionGeometry.apply(range: fullRange, to: textView)
        XCTAssertNotNil(VirtualTextSelectionGeometry.caretRect(in: textView, at: fullRange.length))
        textView.layoutIfNeeded()

        XCTAssertTrue(textView.textLayoutManager === manager)
        XCTAssertEqual(textView.frame, originalFrame)
        XCTAssertEqual(textView.contentOffset, originalOffset)
        XCTAssertEqual(TopicTextInputGeometry.rects(in: textView, for: fullRange), originalRects)
        XCTAssertNil(textView.selectedTextRange)
        XCTAssertNotNil(textView.layer.sublayers?.first { $0.name == "DexoExternalSelectionHighlight" })
        VirtualTextSelectionGeometry.apply(range: nil, to: textView)
        XCTAssertFalse(textView.layer.sublayers?.contains { $0.name == "DexoExternalSelectionHighlight" } ?? false)
    }

    @MainActor
    func testTextInputSelectionHonorsInsetsAndUTF16Ranges() {
        guard #available(iOS 16.0, *) else { return }
        let textView = UITextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        textView.textContainer.lineFragmentPadding = 0
        textView.attributedText = NSAttributedString(
            string: "Markdown 标题 😀\n\n第二段链接",
            attributes: [.font: UIFont.systemFont(ofSize: 16)]
        )
        let window = hostSelectionTextView(textView)
        defer { window.isHidden = true }
        let manager = textView.textLayoutManager
        let range = (textView.attributedText.string as NSString).range(of: "第二段")
        let rects = TopicTextInputGeometry.rects(in: textView, for: range)
        guard let rect = rects.first else { return XCTFail("Missing text geometry") }
        XCTAssertGreaterThanOrEqual(rect.minX, 12)
        XCTAssertGreaterThanOrEqual(rect.minY, 8)
        let point = CGPoint(x: rect.midX, y: rect.midY)
        guard let offset = TopicTextInputGeometry.offset(in: textView, at: point) else {
            return XCTFail("Missing insertion position")
        }
        XCTAssertTrue((range.location...NSMaxRange(range)).contains(offset))
        XCTAssertNotNil(TopicTextInputGeometry.characterRange(in: textView, at: point))
        VirtualTextSelectionGeometry.apply(range: range, to: textView)
        XCTAssertTrue(textView.textLayoutManager === manager)
        XCTAssertTrue(TopicTextInputGeometry.rects(in: textView, for: NSRange(location: -1, length: 1)).isEmpty)
        XCTAssertTrue(TopicTextInputGeometry.rects(in: textView, for: NSRange(location: 0, length: Int.max)).isEmpty)
    }

    @MainActor
    func testWrappedSpoilerKeepsTextKit2() {
        guard #available(iOS 16.0, *) else { return }
        let config = NativeRenderConfig.default(contentWidth: 396)
        let inlines: [InlineNode] = [.spoiler(children: [.text(String(repeating: "中文隐藏内容和换行测试。", count: 6))])]
        let textView = ParagraphRenderer.makeTextView(
            attributedText: inlines.attributedString(config: config.attributedStringConfig),
            config: config
        )
        let window = hostSelectionTextView(textView)
        defer { window.isHidden = true }
        let manager = textView.textLayoutManager
        textView.configureSpoilerIfNeeded()
        textView.setNeedsLayout()
        textView.layoutIfNeeded()
        let settled = expectation(description: "Spoiler overlays laid out")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        let overlays = textView.subviews.filter { view in
            view.subviews.contains { $0 is UIVisualEffectView }
        }
        XCTAssertGreaterThan(overlays.count, 1)
        XCTAssertTrue(overlays.allSatisfy { !$0.frame.isEmpty })
        XCTAssertTrue(textView.textLayoutManager === manager)
    }

    @MainActor
    func testTextInputSelectionAlsoSupportsLegacyTextKit() {
        guard #available(iOS 16.0, *) else { return }
        let textView = UITextView(usingTextLayoutManager: false)
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.text = "Legacy paragraph\n\n第二段"
        let window = hostSelectionTextView(textView)
        defer { window.isHidden = true }
        let range = NSRange(location: 0, length: (textView.text as NSString).length)
        XCTAssertFalse(TopicTextInputGeometry.rects(in: textView, for: range).isEmpty)
        XCTAssertNotNil(TopicTextInputGeometry.offset(in: textView, at: CGPoint(x: 20, y: 12)))
        VirtualTextSelectionGeometry.apply(range: range, to: textView)
        XCTAssertNil(textView.textLayoutManager)
    }

    @MainActor
    private func hostSelectionTextView(_ textView: UITextView) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 420, height: 912))
        let controller = UIViewController()
        window.rootViewController = controller
        textView.frame = CGRect(x: 12, y: 180, width: 396, height: 200)
        controller.view.addSubview(textView)
        window.isHidden = false
        controller.view.layoutIfNeeded()
        textView.layoutIfNeeded()
        return window
    }

    @MainActor
    func testTextServicesExposeCompleteSelectionWithoutAdditionalHandles() {
        let service = TopicSelectionTextServicesView()
        let selectedText = "Markdown 标题\n\n第一段 😀\n\n第二段"
        service.prepare(selectedText: selectedText)
        guard let range = service.selectedTextRange else { return XCTFail("Missing selected text") }
        XCTAssertEqual(service.text(in: range), selectedText)
        XCTAssertTrue(service.selectionRects(for: range).isEmpty)
        XCTAssertEqual(service.caretRect(for: range.start), .zero)
        XCTAssertFalse(service.isEditable)
    }

    @MainActor
    func testTextServicesCopyAndSelectAllOperateOnPostSelection() {
        let service = TopicSelectionTextServicesView()
        service.prepare(selectedText: "Selected word")
        var copied = false
        var selectedAll = false
        service.onCopy = { copied = true }
        service.onSelectAll = { selectedAll = true }
        service.copy(nil)
        service.selectAll(nil)
        XCTAssertTrue(copied)
        XCTAssertTrue(selectedAll)
        service.canSelectAllContent = false
        XCTAssertFalse(service.canPerformAction(#selector(UIResponder.selectAll(_:)), withSender: nil))
        service.canSelectAllContent = true
        XCTAssertTrue(service.canPerformAction(#selector(UIResponder.selectAll(_:)), withSender: nil))
    }

    func testMenuDismissalWhileDraggingPreservesSelection() {
        var state = TopicSelectionMenuState()
        let menu = state.present()
        XCTAssertFalse(state.shouldClearSelection(dismissing: menu, isDragging: true))
    }

    func testDelayedProgrammaticDismissalPreservesSelectionAfterFingerLifts() {
        var state = TopicSelectionMenuState()
        let menu = state.present()
        state.preserveSelectionOnDismissal()
        // The dismissal animation completes after the handle gesture ended.
        XCTAssertFalse(state.shouldClearSelection(dismissing: menu, isDragging: false))
    }

    func testOldMenuCompletionCannotClearReplacementSelectionMenu() {
        var state = TopicSelectionMenuState()
        let first = state.present()
        let replacement = state.present()
        XCTAssertFalse(state.shouldClearSelection(dismissing: first, isDragging: false))
        XCTAssertEqual(state.currentID, replacement)
        XCTAssertTrue(state.shouldClearSelection(dismissing: replacement, isDragging: false))
    }

    func testOutsideTapDismissalClearsSelectionExactlyOnce() {
        var state = TopicSelectionMenuState()
        let menu = state.present()
        XCTAssertTrue(state.shouldClearSelection(dismissing: menu, isDragging: false))
        XCTAssertFalse(state.shouldClearSelection(dismissing: menu, isDragging: false))
    }

    func testLongParagraphIsSplitWithoutLosingText() {
        let text = String(repeating: "Swift 渲染性能测试。", count: 120)
        let annotated = [AnnotatedBlock(block: .paragraph([.text(text)]), sourceHTML: "<p>…</p>")]

        let units = RenderUnitBuilder.build(postId: 42, contentVersion: 7, annotatedBlocks: annotated)

        XCTAssertGreaterThan(units.count, 1)
        let rebuilt = units.compactMap { unit -> String? in
            guard case .paragraph(let nodes) = unit.block else { return nil }
            return nodes.compactMap {
                if case .text(let value) = $0 { return value }
                return nil
            }.joined()
        }.joined()
        XCTAssertEqual(rebuilt, text)
        for unit in units {
            guard case .paragraph(let nodes) = unit.block else { continue }
            XCTAssertLessThanOrEqual(nodes.reduce(0) { $0 + InlineNodeChunker.utf16Length(of: $1) }, RenderUnitBuilder.maxParagraphUTF16)
        }
        XCTAssertTrue(units.dropLast().allSatisfy { $0.bottomSpacing == 0 })
        XCTAssertEqual(units.last?.bottomSpacing, 8)
    }

    func testChunkingPreservesLinkAndSpoilerWrappers() {
        let linked = String(repeating: "linked ", count: 100)
        let hidden = String(repeating: "hidden ", count: 100)
        let chunks = InlineNodeChunker.chunk([
            .link(href: "https://example.com", children: [.text(linked)]),
            .spoiler(children: [.styledText(hidden, [.bold])]),
        ], maximumUTF16Length: 80)

        XCTAssertGreaterThan(chunks.count, 2)
        for node in chunks.flatMap({ $0 }) {
            switch node {
            case .link(let href, _): XCTAssertEqual(href, "https://example.com")
            case .spoiler: break
            default: XCTFail("Wrapper was lost while chunking: \(node)")
            }
        }
    }

    func testRenderUnitIDsAreStableAndVersioned() {
        let blocks = [AnnotatedBlock(block: .paragraph([.text("hello")]), sourceHTML: "<p>hello</p>")]
        let first = RenderUnitBuilder.build(postId: 1, contentVersion: 10, annotatedBlocks: blocks)
        let again = RenderUnitBuilder.build(postId: 1, contentVersion: 10, annotatedBlocks: blocks)
        let changed = RenderUnitBuilder.build(postId: 1, contentVersion: 11, annotatedBlocks: blocks)

        XCTAssertEqual(first.map(\.id), again.map(\.id))
        XCTAssertNotEqual(first.map(\.id), changed.map(\.id))
    }

    func testRenderEnvironmentInvalidatesEveryLayoutDimension() {
        let base = RenderEnvironment(contentWidth: 350, displayScale: 3, fontRevision: 1, themeRevision: 1)
        XCTAssertNotEqual(base, RenderEnvironment(contentWidth: 351, displayScale: 3, fontRevision: 1, themeRevision: 1))
        XCTAssertNotEqual(base, RenderEnvironment(contentWidth: 350, displayScale: 2, fontRevision: 1, themeRevision: 1))
        XCTAssertNotEqual(base, RenderEnvironment(contentWidth: 350, displayScale: 3, fontRevision: 2, themeRevision: 1))
        XCTAssertNotEqual(base, RenderEnvironment(contentWidth: 350, displayScale: 3, fontRevision: 1, themeRevision: 2))
    }

    func testHeightPoliciesSeparateFixedAndDeferredUnits() {
        let fixed = RenderUnitHeightPolicy.fixed(120)
        let deferred = RenderUnitHeightPolicy.deferred(180)

        XCTAssertEqual(fixed.height, 120)
        XCTAssertFalse(fixed.acceptsDynamicUpdates)
        XCTAssertEqual(deferred.height, 180)
        XCTAssertTrue(deferred.acceptsDynamicUpdates)
    }

    func testDynamicHeightBufferCoalescesLatestValueAndDrainsOnce() {
        let first = RenderUnitID(postId: 1, contentVersion: 1, ordinal: 0)
        let second = RenderUnitID(postId: 1, contentVersion: 1, ordinal: 1)
        var buffer = DynamicHeightUpdateBuffer()

        buffer.enqueue(height: 100, for: first)
        buffer.enqueue(height: 140, for: first)
        buffer.enqueue(height: 80, for: second)

        XCTAssertEqual(buffer.count, 2)
        let batch = buffer.drain()
        XCTAssertEqual(batch[first], 140)
        XCTAssertEqual(batch[second], 80)
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertTrue(buffer.drain().isEmpty)
    }

    func testHeightCacheKeyIncludesEffectiveEnvironmentAndStateRevision() {
        let id = RenderUnitID(postId: 1, contentVersion: 1, ordinal: 0)
        let compact = RenderEnvironment(contentWidth: 300, displayScale: 3, fontRevision: 1, themeRevision: 1)
        let wide = RenderEnvironment(contentWidth: 320, displayScale: 3, fontRevision: 1, themeRevision: 1)
        let base = RenderUnitHeightCacheKey(unitId: id, environment: compact, dynamicStateRevision: 0)

        XCTAssertNotEqual(base, RenderUnitHeightCacheKey(unitId: id, environment: wide, dynamicStateRevision: 0))
        XCTAssertNotEqual(base, RenderUnitHeightCacheKey(unitId: id, environment: compact, dynamicStateRevision: 1))
    }

    func testPipelineParsesBatchAndUsesStableDocuments() async {
        let input = PostRenderInput(postId: 9, cookedHTML: "<p>Hello <strong>world</strong></p>")
        let first = await TopicRenderPipeline.shared.renderDocuments(inputs: [input], baseURL: "https://example.com")
        let second = await TopicRenderPipeline.shared.renderDocuments(inputs: [input], baseURL: "https://example.com")

        XCTAssertEqual(first[9]?.contentVersion, input.contentVersion)
        XCTAssertEqual(first[9]?.units.map(\.id), second[9]?.units.map(\.id))
        XCTAssertEqual(first[9]?.units.count, 1)
    }

    func testImageBrowserRequestUsesAllUniqueImagesAndTappedIndex() {
        let blocks = [
            AnnotatedBlock(
                block: .image(src: "https://example.com/thumb-a.jpg", alt: nil, width: 10, height: 10, href: "https://example.com/a.jpg"),
                sourceHTML: ""
            ),
            AnnotatedBlock(
                block: .image(src: "https://example.com/b.jpg", alt: nil, width: nil, height: nil),
                sourceHTML: ""
            ),
            AnnotatedBlock(
                block: .image(src: "https://example.com/thumb-a.jpg", alt: nil, width: 10, height: 10, href: "https://example.com/a.jpg"),
                sourceHTML: ""
            ),
        ]

        let request = TopicImageBrowserRequest.make(
            annotatedBlocks: blocks,
            tappedURL: URL(string: "https://example.com/b.jpg")!
        )

        XCTAssertEqual(request.imageURLs.map(\.absoluteString), [
            "https://example.com/a.jpg",
            "https://example.com/b.jpg",
        ])
        XCTAssertEqual(request.startIndex, 1)
    }

    func testImageBrowserRequestFallsBackToTappedImage() {
        let tapped = URL(string: "https://example.com/only.jpg")!
        let request = TopicImageBrowserRequest.make(annotatedBlocks: [], tappedURL: tapped)

        XCTAssertEqual(request.imageURLs, [tapped])
        XCTAssertEqual(request.startIndex, 0)
    }

    func testVirtualItemsExposePostScrollAnchors() {
        let unitId = RenderUnitID(postId: 42, contentVersion: 1, ordinal: 0)
        XCTAssertEqual(VirtualTopicItem.header(42).postAnchorId, 42)
        XCTAssertEqual(VirtualTopicItem.unit(unitId).postAnchorId, 42)
        XCTAssertEqual(VirtualTopicItem.footer(42).postAnchorId, 42)
        XCTAssertEqual(VirtualTopicItem.boosts(42).postAnchorId, 42)
        XCTAssertEqual(VirtualTopicItem.collapsed(42).postAnchorId, 42)
        XCTAssertEqual(VirtualTopicItem.blocked(42).postAnchorId, 42)
        XCTAssertNil(VirtualTopicItem.title(1).postAnchorId)
        XCTAssertNil(VirtualTopicItem.loadMoreChildren(42).postAnchorId)
        XCTAssertNil(VirtualTopicItem.paginationStatus.postAnchorId)
    }

    func testObservedSnapshotIsSuppressedDuringPagination() {
        XCTAssertTrue(VirtualTopicObservedSnapshotPolicy.allowsApply(
            isReady: true,
            isReloadingTreeMode: false,
            isPerformingJump: false,
            isPaginating: false
        ))
        XCTAssertFalse(VirtualTopicObservedSnapshotPolicy.allowsApply(
            isReady: true,
            isReloadingTreeMode: false,
            isPerformingJump: false,
            isPaginating: true
        ))
    }

    func testPrependAnchorSkipsTopicTitleAndSelectsExistingPost() {
        let unitId = RenderUnitID(postId: 100, contentVersion: 1, ordinal: 0)
        let items: [VirtualTopicItem] = [
            .title(1),
            .header(100),
            .unit(unitId),
            .footer(100),
        ]

        XCTAssertEqual(VirtualTopicPrependAnchorSelector.firstPostItem(in: items), .header(100))
        XCTAssertEqual(VirtualTopicPrependAnchorSelector.firstPostItem(in: [
            .title(1),
            .blocked(100),
        ]), .blocked(100))
        XCTAssertNil(VirtualTopicPrependAnchorSelector.firstPostItem(in: [
            .title(1),
            .paginationStatus,
            .loadMoreChildren(100),
        ]))
    }
}

@MainActor
final class TopicRenderCacheTests: XCTestCase {
    func testLRUEvictsLeastRecentlyUsedEntry() {
        let cache = LRUCache<Int, String>(capacity: 2)
        cache[1] = "one"
        cache[2] = "two"
        _ = cache[1]
        cache[3] = "three"

        XCTAssertEqual(cache[1], "one")
        XCTAssertNil(cache[2])
        XCTAssertEqual(cache[3], "three")
    }

    func testParagraphPrecomputedHeightMatchesRenderedView() {
        let config = NativeRenderConfig.default(contentWidth: 320, baseURL: nil)
        let block = ContentBlock.paragraph([.text(String(repeating: "height parity ", count: 30))])
        let expected = try! XCTUnwrap(BlockHeightCalculator.height(for: block, config: config))
        let view = ParagraphRenderer.render(block, config: config, delegate: nil)
        let actual = view.systemLayoutSizeFitting(
            CGSize(width: 320, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        XCTAssertEqual(expected, actual, accuracy: 1)
    }

    func testLongChineseCodeWrapsIntoMultipleVisualLines() throws {
        let code = "请先只读检查 Windows Application 日志中是否持续出现 ChatGPT.exe、Event ID 1000、0xc06d007f，并确认是否指向 Codex Micro 的 serialport.node/HID.node。若不匹配就停止；若匹配，先检查更新并普通重启。仍复现时，再制作可回滚的 A/B 启动器：备份 Local Storage，通过 MSIX AUMID 启动，并仅对本次进程加入 host-resolver-rules。禁止删除任务数据、修改 hosts、WindowsApps、注册表或 .codex。"
        let textView = try renderCodeView(code: code)
        let codeFont = NativeRenderConfig.default(contentWidth: 320).codeFont

        XCTAssertTrue(textView.isScrollEnabled)
        XCTAssertTrue(textView.textContainer.widthTracksTextView)
        XCTAssertEqual(textView.bounds.width, 296, accuracy: 0.5)
        XCTAssertGreaterThan(textView.bounds.height, codeFont.lineHeight * 3)
        XCTAssertLessThanOrEqual(textView.contentSize.width, textView.bounds.width + 0.5)
    }

    func testWrappedCodeCanScrollVerticallyPastVisibleLineCap() throws {
        let line = "一段没有手动换行的中文内容也应该按代码块宽度自动折行并保持可以继续向下滚动查看。"
        let code = String(repeating: line, count: 20)
        let textView = try renderCodeView(code: code)

        XCTAssertGreaterThan(textView.contentSize.height, textView.bounds.height)
        let targetOffset = min(80, textView.contentSize.height - textView.bounds.height)
        textView.setContentOffset(CGPoint(x: 0, y: targetOffset), animated: false)
        XCTAssertEqual(textView.contentOffset.y, targetOffset, accuracy: 0.5)
    }

    func testPostIDResolverFindsVirtualizedContainer() {
        let provider = TestPostIDProviderView(postId: 77)
        let nested = UIView()
        provider.addSubview(nested)

        XCTAssertEqual(TopicPostIDResolver.postId(startingAt: nested), 77)
        XCTAssertEqual(TopicPostIDResolver.postId(startingAt: UIView()), 0)
    }

    private func firstTextView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView { return textView }
        for subview in view.subviews {
            if let textView = firstTextView(in: subview) { return textView }
        }
        return nil
    }

    private func renderCodeView(code: String, width: CGFloat = 320) throws -> UITextView {
        let config = NativeRenderConfig.default(contentWidth: width, baseURL: nil)
        let block = ContentBlock.codeBlock(language: nil, code: code)
        let height = try XCTUnwrap(BlockHeightCalculator.height(for: block, config: config))
        let view = CodeBlockRenderer.render(block, config: config, delegate: nil)
        let host = UIView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.layoutIfNeeded()
        return try XCTUnwrap(firstTextView(in: view))
    }

    func testTreeContinuationIncludesAncestorOwnAndChildColumns() {
        let state = TreeLineState(
            depth: 3,
            isLastSibling: false,
            ancestorTrails: [false, true],
            hasChildren: true,
            isCollapsed: false
        )

        XCTAssertEqual(VirtualTreeContinuationView.columns(for: state), [
            TreeLineView.columnX(forDepth: 2),
            TreeLineView.columnX(forDepth: 3),
            TreeLineView.columnX(forDepth: 4),
        ])
    }

    func testTreeContinuationHandlesEmptyAncestorTrail() {
        let opState = TreeLineState(
            depth: 0,
            isLastSibling: true,
            ancestorTrails: [],
            hasChildren: true,
            isCollapsed: false
        )
        let directReplyState = TreeLineState(
            depth: 1,
            isLastSibling: true,
            ancestorTrails: [],
            hasChildren: true,
            isCollapsed: false
        )

        XCTAssertEqual(VirtualTreeContinuationView.columns(for: opState), [])
        XCTAssertEqual(VirtualTreeContinuationView.columns(for: directReplyState), [
            TreeLineView.columnX(forDepth: 2),
        ])
    }

    func testTreeContinuationStopsOwnAndChildColumnsWhenRequired() {
        let state = TreeLineState(
            depth: 3,
            isLastSibling: true,
            ancestorTrails: [false, true],
            hasChildren: true,
            isCollapsed: true
        )

        XCTAssertEqual(VirtualTreeContinuationView.columns(for: state), [
            TreeLineView.columnX(forDepth: 2),
        ])
    }

    func testTreeContinuationClampsDeepColumnsToMaximumIndent() {
        let state = TreeLineState(
            depth: 9,
            isLastSibling: false,
            ancestorTrails: [false, true, true, true, true, true, true, true],
            hasChildren: true,
            isCollapsed: false
        )
        let columns = VirtualTreeContinuationView.columns(for: state)
        let maximumColumn = TreeLineView.columnX(forDepth: PostNativeCell.treeMaxIndentLevels)

        XCTAssertEqual(columns.last, maximumColumn)
        XCTAssertTrue(columns.allSatisfy { $0 <= maximumColumn })
        XCTAssertEqual(columns, Array(Set(columns)).sorted())
    }

    func testTreeCollapsePillOnlyAppearsOnEligibleLastVisualItem() {
        let parent = TreeLineState(
            depth: 2,
            isLastSibling: false,
            ancestorTrails: [false],
            hasChildren: true,
            isCollapsed: false
        )
        let leaf = TreeLineState(
            depth: 2,
            isLastSibling: false,
            ancestorTrails: [false],
            hasChildren: false,
            isCollapsed: false
        )

        XCTAssertNil(VirtualTreeCollapsePill.leading(for: nil, isLastVisualItem: true))
        XCTAssertNil(VirtualTreeCollapsePill.leading(for: leaf, isLastVisualItem: true))
        XCTAssertNil(VirtualTreeCollapsePill.leading(for: parent, isLastVisualItem: false))
        XCTAssertNotNil(VirtualTreeCollapsePill.leading(for: parent, isLastVisualItem: true))
    }

    func testTreeCollapsePillMovesFromFooterToExpandedBoost() {
        let parent = TreeLineState(
            depth: 1,
            isLastSibling: true,
            ancestorTrails: [],
            hasChildren: true,
            isCollapsed: false
        )

        let footerWithoutBoost = VirtualTreeCollapsePill.leading(for: parent, isLastVisualItem: true)
        let footerWithBoost = VirtualTreeCollapsePill.leading(for: parent, isLastVisualItem: false)
        let expandedBoost = VirtualTreeCollapsePill.leading(for: parent, isLastVisualItem: true)

        XCTAssertNotNil(footerWithoutBoost)
        XCTAssertNil(footerWithBoost)
        XCTAssertEqual(expandedBoost, footerWithoutBoost)
    }

    func testTreeCollapsePillUsesLegacyGeometryAndClampsDeepIndent() {
        let deepParent = TreeLineState(
            depth: 9,
            isLastSibling: true,
            ancestorTrails: [],
            hasChildren: true,
            isCollapsed: false
        )
        let expectedLeading = TreeLineView.columnX(forDepth: PostNativeCell.treeMaxIndentLevels)
            - VirtualTreeCollapsePill.size / 2

        XCTAssertEqual(VirtualTreeCollapsePill.size, 18)
        XCTAssertEqual(VirtualTreeCollapsePill.bottomInset, 4)
        XCTAssertEqual(
            VirtualTreeCollapsePill.leading(for: deepParent, isLastVisualItem: true),
            expectedLeading
        )
    }

    func testTreeCollapsePillClearsVisibilityWhenReused() {
        let parent = TreeLineState(
            depth: 1,
            isLastSibling: true,
            ancestorTrails: [],
            hasChildren: true,
            isCollapsed: false
        )
        let pill = VirtualTreeCollapsePill(frame: .zero)

        pill.configure(state: parent, isLastVisualItem: true)
        XCTAssertFalse(pill.isHidden)
        pill.configure(state: nil, isLastVisualItem: false)
        XCTAssertTrue(pill.isHidden)
    }

    func testVirtualCellBackgroundMatchesLegacyCardBackground() {
        let cell = VirtualTopicTitleCell(frame: .zero)
        cell.configure(title: "Topic")

        XCTAssertEqual(cell.backgroundColor, ThemeManager.shared.cardBackgroundColor)
        XCTAssertEqual(cell.contentView.backgroundColor, ThemeManager.shared.cardBackgroundColor)
    }

    func testVirtualTitleHeightIncludesWrappedTags() {
        let tags = [
            DiscourseTopicDetail.Tag(id: 1, name: "a-very-long-topic-tag", slug: "a"),
            DiscourseTopicDetail.Tag(id: 2, name: "another-long-topic-tag", slug: "b"),
        ]
        let plain = VirtualTopicTitleCell.height(title: "Topic", tags: [], width: 240)
        let tagged = VirtualTopicTitleCell.height(title: "Topic", tags: tags, width: 240)

        XCTAssertGreaterThan(tagged, plain)
    }

    func testVirtualTitleFirstLayoutKeepsAllTagsInsidePrecomputedHeight() {
        let width: CGFloat = 240
        let tags = [
            DiscourseTopicDetail.Tag(id: 1, name: "a-very-long-topic-tag", slug: "a"),
            DiscourseTopicDetail.Tag(id: 2, name: "another-long-topic-tag", slug: "b"),
            DiscourseTopicDetail.Tag(id: 3, name: "third-topic-tag", slug: "c"),
        ]
        let height = VirtualTopicTitleCell.height(title: "Topic", tags: tags, width: width)
        let cell = VirtualTopicTitleCell(frame: CGRect(x: 0, y: 0, width: width, height: height))

        cell.configure(title: "Topic", tags: tags)
        cell.layoutIfNeeded()

        let buttons = cell.contentView.subviews
            .flatMap(\.subviews)
            .compactMap { $0 as? UIButton }
        XCTAssertEqual(buttons.count, tags.count)
        for button in buttons {
            let frame = button.convert(button.bounds, to: cell.contentView)
            XCTAssertLessThanOrEqual(frame.maxX, width - 16 + 0.5)
            XCTAssertLessThanOrEqual(frame.maxY, height - 8 + 0.5)
        }
    }

    func testVirtualFooterButtonTintsMatchLegacyStates() {
        let normal = VirtualPostFooterButtonTints.resolve(isLiked: false, hasCurrentUserBoost: false)
        XCTAssertEqual(normal.reply, .tertiaryLabel)
        XCTAssertEqual(normal.like, .tertiaryLabel)
        XCTAssertEqual(normal.boost, .tertiaryLabel)
        XCTAssertEqual(normal.more, .tertiaryLabel)

        let liked = VirtualPostFooterButtonTints.resolve(isLiked: true, hasCurrentUserBoost: false)
        XCTAssertEqual(liked.like, .systemRed)
        XCTAssertEqual(liked.boost, .tertiaryLabel)

        let ordinaryBoost = VirtualPostFooterButtonTints.resolve(isLiked: false, hasCurrentUserBoost: false)
        XCTAssertEqual(ordinaryBoost.boost, .tertiaryLabel)

        let currentUserBoost = VirtualPostFooterButtonTints.resolve(isLiked: false, hasCurrentUserBoost: true)
        XCTAssertEqual(currentUserBoost.like, .tertiaryLabel)
        XCTAssertEqual(currentUserBoost.boost, .systemYellow)
    }

    func testVirtualFooterButtonTintsResetAfterReuseStateChange() {
        let cell = VirtualPostFooterCell(frame: .zero)
        cell.applyButtonTints(.resolve(isLiked: true, hasCurrentUserBoost: true))
        XCTAssertEqual(cell.appliedButtonTints.like, .systemRed)
        XCTAssertEqual(cell.appliedButtonTints.boost, .systemYellow)

        cell.applyButtonTints(.resolve(isLiked: false, hasCurrentUserBoost: false))
        XCTAssertEqual(cell.appliedButtonTints.reply, .tertiaryLabel)
        XCTAssertEqual(cell.appliedButtonTints.like, .tertiaryLabel)
        XCTAssertEqual(cell.appliedButtonTints.boost, .tertiaryLabel)
        XCTAssertEqual(cell.appliedButtonTints.more, .tertiaryLabel)
    }

    func testVirtualReactionActionMatchesLegacyPluginAndUndoRules() {
        XCTAssertEqual(
            VirtualPostReactionActionResolver.resolve(
                hasPlugin: true,
                currentReactionId: nil,
                currentReactionCanUndo: nil,
                isLiked: false,
                likeCanUndo: nil
            ),
            .showPicker
        )
        XCTAssertEqual(
            VirtualPostReactionActionResolver.resolve(
                hasPlugin: true,
                currentReactionId: "heart",
                currentReactionCanUndo: true,
                isLiked: true,
                likeCanUndo: true
            ),
            .toggleReaction("heart")
        )
        XCTAssertEqual(
            VirtualPostReactionActionResolver.resolve(
                hasPlugin: false,
                currentReactionId: nil,
                currentReactionCanUndo: nil,
                isLiked: false,
                likeCanUndo: nil
            ),
            .toggleLike(true)
        )
        XCTAssertEqual(
            VirtualPostReactionActionResolver.resolve(
                hasPlugin: false,
                currentReactionId: nil,
                currentReactionCanUndo: nil,
                isLiked: true,
                likeCanUndo: false
            ),
            .none
        )
    }

    func testBlockSpoilerRevealStateCanBeRestoredAfterReuse() {
        let overlay = SpoilerOverlayView(contentView: UIView())
        var observed: Bool?
        overlay.onRevealChange = { observed = $0 }

        overlay.setRevealed(true)

        XCTAssertTrue(overlay.isRevealed)
        XCTAssertEqual(observed, true)
    }

    func testVirtualReactionSummaryMatchesLegacyThreeIconLimitAndResets() {
        let view = VirtualPostReactionSummaryView(frame: .zero)
        let reactions = (0..<4).map {
            DiscourseTopicDetail.Reaction(id: "reaction-\($0)", type: "emoji", count: 1, canUndo: nil)
        }

        view.configure(reactions: reactions, count: 12)

        XCTAssertFalse(view.isHidden)
        XCTAssertEqual(view.visibleReactionCount, 3)
        XCTAssertEqual(view.displayedCount, "12")

        view.configure(reactions: [], count: 0)

        XCTAssertTrue(view.isHidden)
        XCTAssertEqual(view.visibleReactionCount, 0)
        XCTAssertNil(view.displayedCount)
    }

    func testVirtualReactionSummaryUsesLegacyTreeIndent() {
        let leaf = TreeLineState(
            depth: 3,
            isLastSibling: true,
            ancestorTrails: [false, false],
            hasChildren: false,
            isCollapsed: false
        )
        let parent = TreeLineState(
            depth: 3,
            isLastSibling: true,
            ancestorTrails: [false, false],
            hasChildren: true,
            isCollapsed: false
        )

        XCTAssertEqual(VirtualPostFooterLayout.reactionLeading(for: nil), 16)
        XCTAssertEqual(
            VirtualPostFooterLayout.reactionLeading(for: leaf),
            12 + PostNativeCell.treeContentIndent(forDepth: leaf.depth)
        )
        XCTAssertGreaterThanOrEqual(
            VirtualPostFooterLayout.reactionLeading(for: parent),
            TreeLineView.columnX(forDepth: parent.depth + 1) + 15
        )
    }

    func testVirtualPostSeparatorStaysAtEndOfPost() {
        XCTAssertEqual(
            VirtualPostSeparatorPlacement.resolve(isTreeMode: false, hasExpandedBoosts: false),
            VirtualPostSeparatorPlacement(footer: true, boosts: false)
        )
        XCTAssertEqual(
            VirtualPostSeparatorPlacement.resolve(isTreeMode: false, hasExpandedBoosts: true),
            VirtualPostSeparatorPlacement(footer: false, boosts: true)
        )
        XCTAssertEqual(
            VirtualPostSeparatorPlacement.resolve(isTreeMode: true, hasExpandedBoosts: false),
            VirtualPostSeparatorPlacement(footer: false, boosts: false)
        )
        XCTAssertEqual(
            VirtualPostSeparatorPlacement.resolve(isTreeMode: true, hasExpandedBoosts: true),
            VirtualPostSeparatorPlacement(footer: false, boosts: false)
        )
    }

    func testTimelineDynamicUpdateMovesOnlySuffixWithoutRemeasuring() {
        var geometry = TopicTimelineGeometry()
        geometry.rebuild(heights: [40, 50, 60], width: 320)
        XCTAssertEqual(geometry.frames[2].minY, 90)

        geometry.applyHeightUpdates([1: 80])

        XCTAssertEqual(geometry.frames[1].height, 80)
        XCTAssertEqual(geometry.frames[2].minY, 120)
    }

    func testTimelineFullReloadRebuildsHeightsWhenItemCountIsUnchanged() {
        var geometry = TopicTimelineGeometry()
        geometry.rebuild(heights: [40, 50, 60], width: 320)
        geometry.rebuild(heights: [70, 80, 90], width: 320)

        XCTAssertEqual(geometry.frames[0].height, 70)
        XCTAssertEqual(geometry.frames[2].minY, 150)
    }
}

private final class TestPostIDProviderView: UIView, TopicPostIDProviding {
    let renderedPostId: Int

    init(postId: Int) {
        renderedPostId = postId
        super.init(frame: .zero)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}
