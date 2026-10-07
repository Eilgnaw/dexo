import CookedHTML
import UIKit

enum TableRenderer: BlockRenderer {
    // MARK: - Constants

    /// 8pt top + bottom inside each cell.
    static let cellPaddingV: CGFloat = 8
    /// 12pt left + right inside each cell.
    static let cellPaddingH: CGFloat = 12
    /// Soft cap on a column's *content* width (excludes padding). Without this
    /// a single cell with a long unbroken token (URL, code) would force the
    /// whole table to that width; clamping makes such text wrap inside the
    /// column instead.
    static let maxColumnContentWidth: CGFloat = 320
    /// Floor so columns with a single short token ("y"/"n") don't collapse.
    static let minColumnContentWidth: CGFloat = 24
    /// Inner stack spacing for complex (non-paragraph) cells — matches the
    /// stack created in `makeCellView`.
    static let cellStackSpacing: CGFloat = 4

    // MARK: - BlockRenderer

    static func canRender(_ block: ContentBlock) -> Bool {
        if case .table = block { return true }
        return false
    }

    static func render(_ block: ContentBlock, config: NativeRenderConfig, delegate: PostCellDelegate?) -> UIView {
        guard case .table(let headers, let rows) = block,
              let layout = computeLayout(headers: headers, rows: rows, config: config)
        else { return UIView() }
        let built = makeView(layout: layout, config: config, delegate: delegate)
        return wrapWithExpandButton(
            built.scrollView,
            firstRow: built.firstRow,
            block: block,
            baseConfig: config,
            delegate: delegate
        )
    }

    /// Renders just the scroll-view-wrapped bordered table — no expand-button
    /// overlay. `TableFullscreenViewController` calls this so its already-
    /// fullscreen presentation doesn't redundantly show an expand button.
    /// Returns `nil` when the block isn't a `.table` or has zero columns.
    static func renderBare(_ block: ContentBlock, config: NativeRenderConfig, delegate: PostCellDelegate?) -> UIView? {
        guard case .table(let headers, let rows) = block,
              let layout = computeLayout(headers: headers, rows: rows, config: config)
        else { return nil }
        return makeView(layout: layout, config: config, delegate: delegate).scrollView
    }

    // MARK: - Layout model

    private struct CellMeasurement {
        let prebuiltAttr: NSAttributedString?
        let blocks: [ContentBlock]
    }

    private struct Layout {
        let columnContentWidths: [CGFloat]   // per column, excludes 2*paddingH
        let columnWidths: [CGFloat]          // per column, includes 2*paddingH
        let measurements: [[CellMeasurement]]
        let allRows: [[[ContentBlock]]]      // headers first if present, then rows
        let isHeaderRow: [Bool]
    }

    private static func computeLayout(
        headers: [[ContentBlock]],
        rows: [[[ContentBlock]]],
        config: NativeRenderConfig
    ) -> Layout? {
        let columnCount = max(
            headers.count,
            rows.map(\.count).max() ?? 0
        )
        guard columnCount > 0 else { return nil }

        var allRows: [[[ContentBlock]]] = []
        var isHeaderRow: [Bool] = []
        if !headers.isEmpty {
            allRows.append(headers)
            isHeaderRow.append(true)
        }
        for row in rows {
            allRows.append(row)
            isHeaderRow.append(false)
        }

        let plainAttrConfig = config.attributedStringConfig
        let boldAttrConfig = AttributedStringConfig(
            baseFont: config.baseFont.withTraits(.traitBold),
            baseColor: config.baseColor,
            linkColor: config.linkColor,
            codeFont: config.codeFont,
            codeBackgroundColor: config.codeBackgroundColor
        )

        // Measure each cell's natural (unconstrained) width, then collapse to
        // per-column max widths clamped to [min, max]. Heights are left to
        // autolayout — the rendered TextKit height for CJK-heavy cells can differ
        // from `NSAttributedString.boundingRect`, so precomputing it would risk
        // clipping bottom rows.
        var columnContentWidths = Array(repeating: minColumnContentWidth, count: columnCount)
        var measurements: [[CellMeasurement]] = []
        for (rowIdx, row) in allRows.enumerated() {
            let attrCfg = isHeaderRow[rowIdx] ? boldAttrConfig : plainAttrConfig
            var rowMeas: [CellMeasurement] = []
            for col in 0..<columnCount {
                let cellBlocks = col < row.count ? row[col] : []
                var prebuiltAttr: NSAttributedString?
                let naturalWidth: CGFloat
                if cellBlocks.count == 1, case .paragraph(let inlines) = cellBlocks[0] {
                    let attr = inlines.attributedString(config: attrCfg)
                    prebuiltAttr = attr
                    naturalWidth = ceil(attr.boundingRect(
                        with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                        options: [.usesLineFragmentOrigin],
                        context: nil
                    ).width)
                } else {
                    naturalWidth = estimateNaturalWidth(of: cellBlocks, config: config)
                }
                rowMeas.append(CellMeasurement(
                    prebuiltAttr: prebuiltAttr,
                    blocks: cellBlocks
                ))
                let clamped = max(min(naturalWidth, maxColumnContentWidth), minColumnContentWidth)
                columnContentWidths[col] = max(columnContentWidths[col], clamped)
            }
            measurements.append(rowMeas)
        }

        let columnWidths = columnContentWidths.map { $0 + cellPaddingH * 2 }

        return Layout(
            columnContentWidths: columnContentWidths,
            columnWidths: columnWidths,
            measurements: measurements,
            allRows: allRows,
            isHeaderRow: isHeaderRow
        )
    }

    // MARK: - View construction

    private static func makeView(
        layout: Layout,
        config: NativeRenderConfig,
        delegate: PostCellDelegate?
    ) -> (scrollView: UIView, firstRow: UIView?) {
        let separatorColor = UIColor.separator
        let columnCount = layout.columnContentWidths.count
        var firstRow: UIView?

        func makeCellView(meas: CellMeasurement, columnWidth: CGFloat, isHeader: Bool) -> UIView {
            // Fast path: single-paragraph cell with a pre-built attributed string.
            // A single-paragraph cell can use one selectable text view directly.
            if let attr = meas.prebuiltAttr {
                let textView = ParagraphRenderer.makeTextView(attributedText: attr, config: config)
                textView.textContainerInset = UIEdgeInsets(
                    top: cellPaddingV, left: cellPaddingH,
                    bottom: cellPaddingV, right: cellPaddingH
                )
                return textView
            }

            let container = UIView()
            container.translatesAutoresizingMaskIntoConstraints = false

            let innerWidth = columnWidth - cellPaddingH * 2
            let cellConfig = NativeRenderConfig(
                baseFont: isHeader ? config.baseFont.withTraits(.traitBold) : config.baseFont,
                baseColor: config.baseColor,
                linkColor: config.linkColor,
                codeFont: config.codeFont,
                codeBackgroundColor: config.codeBackgroundColor,
                contentWidth: innerWidth,
                baseURL: config.baseURL,
                imageSizingMode: .fitWithoutUpscaling
            )

            let stack = UIStackView()
            stack.axis = .vertical
            stack.spacing = cellStackSpacing
            stack.translatesAutoresizingMaskIntoConstraints = false

            let views = NativeContentRenderer.renderBlocks(meas.blocks, config: cellConfig, delegate: delegate)
            for view in views {
                stack.addArrangedSubview(view)
            }

            container.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: container.topAnchor, constant: cellPaddingV),
                stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: cellPaddingH),
                stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -cellPaddingH),
                stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -cellPaddingV),
            ])
            return container
        }

        func makeSeparator() -> UIView {
            let sep = UIView()
            sep.translatesAutoresizingMaskIntoConstraints = false
            sep.backgroundColor = separatorColor
            sep.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
            return sep
        }

        let tableStack = UIStackView()
        tableStack.axis = .vertical
        tableStack.spacing = 0
        tableStack.translatesAutoresizingMaskIntoConstraints = false

        for (rowIndex, _) in layout.allRows.enumerated() {
            let isHeader = layout.isHeaderRow[rowIndex]

            let cells: [UIView] = (0..<columnCount).map { col in
                makeCellView(
                    meas: layout.measurements[rowIndex][col],
                    columnWidth: layout.columnWidths[col],
                    isHeader: isHeader
                )
            }

            let rowView = UIView()
            rowView.translatesAutoresizingMaskIntoConstraints = false

            for (col, cell) in cells.enumerated() {
                rowView.addSubview(cell)
                cell.topAnchor.constraint(equalTo: rowView.topAnchor).isActive = true
                cell.bottomAnchor.constraint(equalTo: rowView.bottomAnchor).isActive = true
                if col == 0 {
                    cell.leadingAnchor.constraint(equalTo: rowView.leadingAnchor).isActive = true
                } else {
                    cell.leadingAnchor.constraint(equalTo: cells[col - 1].trailingAnchor).isActive = true
                }
                cell.widthAnchor.constraint(equalToConstant: layout.columnWidths[col]).isActive = true
                if col == columnCount - 1 {
                    cell.trailingAnchor.constraint(equalTo: rowView.trailingAnchor).isActive = true
                }
            }

            if isHeader {
                // Warm, theme-aware header band — `.secondarySystemBackground`
                // reads as a cold lavender against the warm theme palette.
                // Mirror the `codeBackgroundColor` recipe (accent blended into
                // the card surface) but a touch stronger so the header stands
                // out as a header.
                let accent = ThemeManager.shared.accentColor
                let card = ThemeManager.shared.cardBackgroundColor
                rowView.backgroundColor = UIColor { tc in
                    accent.resolvedColor(with: tc)
                        .blended(into: card.resolvedColor(with: tc), ratio: 0.15)
                }
            }

            if rowIndex == 0 {
                firstRow = rowView
            }

            tableStack.addArrangedSubview(rowView)

            if rowIndex < layout.allRows.count - 1 {
                tableStack.addArrangedSubview(makeSeparator())
            }
        }

        let borderedContainer = UIView()
        borderedContainer.translatesAutoresizingMaskIntoConstraints = false
        borderedContainer.layer.borderWidth = 1 / UIScreen.main.scale
        borderedContainer.layer.borderColor = separatorColor.cgColor
        borderedContainer.layer.cornerRadius = 4
        borderedContainer.clipsToBounds = true
        borderedContainer.addSubview(tableStack)
        NSLayoutConstraint.activate([
            tableStack.topAnchor.constraint(equalTo: borderedContainer.topAnchor),
            tableStack.leadingAnchor.constraint(equalTo: borderedContainer.leadingAnchor),
            tableStack.trailingAnchor.constraint(equalTo: borderedContainer.trailingAnchor),
            tableStack.bottomAnchor.constraint(equalTo: borderedContainer.bottomAnchor),
        ])

        // Tables are no longer compressed to fit screen width — wide ones
        // scroll horizontally instead. The required equal-height constraint
        // below makes the scroll view's height resolve to the bordered
        // container's autolayout-resolved height, so the surrounding cell
        // stack gets a correctly-sized arranged subview without us having
        // to precompute a value (TextKit's intrinsic height for CJK-heavy
        // cells doesn't always match `NSAttributedString.boundingRect`).
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.addSubview(borderedContainer)

        // The bordered container's intrinsic height drives the scroll view's
        // height (required), so the cell stack always sees the *real* table
        // height through `IntrinsicHeightScrollView.intrinsicContentSize`.
        // Precomputed heights would only be a rough guess (TextKit's
        // autolayout-resolved height occasionally differs from boundingRect
        // by ~10pt for CJK text); if the cell stack pinned an undersized
        // value as required, the table would clip its lower rows. Leaving
        // this to intrinsicContentSize avoids the mismatch entirely.
        NSLayoutConstraint.activate([
            borderedContainer.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            borderedContainer.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            borderedContainer.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            borderedContainer.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            borderedContainer.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
        ])

        return (scrollView, firstRow)
    }

    // MARK: - Width Estimation

    /// Recursively estimate natural content width from blocks (for column sizing).
    private static func estimateNaturalWidth(of blocks: [ContentBlock], config: NativeRenderConfig) -> CGFloat {
        var maxWidth: CGFloat = 0
        for block in blocks {
            let width: CGFloat
            switch block {
            case .paragraph(let inlines):
                let attr = inlines.attributedString(config: config.attributedStringConfig)
                width = ceil(attr.boundingRect(
                    with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin],
                    context: nil
                ).width)
            case .heading(_, let inlines):
                let boldConfig = AttributedStringConfig(
                    baseFont: config.baseFont.withTraits(.traitBold),
                    baseColor: config.baseColor,
                    linkColor: config.linkColor,
                    codeFont: config.codeFont,
                    codeBackgroundColor: config.codeBackgroundColor
                )
                let attr = inlines.attributedString(config: boldConfig)
                width = ceil(attr.boundingRect(
                    with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin],
                    context: nil
                ).width)
            case .image(_, _, let w, _, _):
                width = CGFloat(w ?? 100)
            case .spoiler(let inner):
                width = estimateNaturalWidth(of: inner, config: config)
            case .blockquote(let inner):
                width = estimateNaturalWidth(of: inner, config: config) + 16
            default:
                width = 80
            }
            maxWidth = max(maxWidth, width)
        }
        return maxWidth
    }

    // MARK: - Expand Button

    /// Wraps the scroll-view-wrapped table in a container that overlays a
    /// small floating expand button in the top-right corner. The button
    /// stays put while the user scrolls the table horizontally — it lives
    /// outside the scroll view so it never moves with the content.
    private static func wrapWithExpandButton(
        _ scrollView: UIView,
        firstRow: UIView?,
        block: ContentBlock,
        baseConfig: NativeRenderConfig,
        delegate: PostCellDelegate?
    ) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let button = makeExpandButton()
        container.addSubview(button)
        // Vertically center the expand button on the (header) row's centerY
        // so it sits aligned with the header text instead of floating in the
        // top corner. Falls back to a fixed inset if there's no first row.
        let verticalConstraint: NSLayoutConstraint = firstRow.map {
            button.centerYAnchor.constraint(equalTo: $0.centerYAnchor)
        } ?? button.topAnchor.constraint(equalTo: container.topAnchor, constant: 4)
        NSLayoutConstraint.activate([
            verticalConstraint,
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            button.widthAnchor.constraint(equalToConstant: 30),
            button.heightAnchor.constraint(equalToConstant: 30),
        ])

        // Hold the delegate weakly inside the action closure so the table
        // doesn't keep the topic VC alive after dismissal.
        button.addAction(UIAction { [weak button, weak delegate] _ in
            guard let button else { return }
            presentFullscreen(from: button, block: block, baseConfig: baseConfig, delegate: delegate)
        }, for: .touchUpInside)

        return container
    }

    private static func makeExpandButton() -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        let symbol = UIImage(
            systemName: "arrow.up.left.and.arrow.down.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        )
        button.setImage(symbol, for: .normal)
        button.tintColor = .label
        button.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.9)
        button.layer.cornerRadius = 6
        button.layer.borderWidth = 1 / UIScreen.main.scale
        button.layer.borderColor = UIColor.separator.cgColor
        button.accessibilityLabel = String(localized: "table.expand")
        return button
    }

    private static func presentFullscreen(
        from sourceView: UIView,
        block: ContentBlock,
        baseConfig: NativeRenderConfig,
        delegate: PostCellDelegate?
    ) {
        var responder: UIResponder? = sourceView
        while let next = responder?.next {
            if let vc = next as? UIViewController {
                // Pass the table's *outer* container as the animation source so
                // the snapshot covers the whole inline table, not just the
                // expand button itself.
                let animationSource = sourceView.superview ?? sourceView
                let fullscreen = TableFullscreenViewController(
                    block: block,
                    baseConfig: baseConfig,
                    delegate: delegate,
                    sourceView: animationSource
                )
                vc.present(fullscreen, animated: true)
                return
            }
            responder = next
        }
    }
}

// MARK: - UIFont + Traits Helper

private extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits)) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }
}
