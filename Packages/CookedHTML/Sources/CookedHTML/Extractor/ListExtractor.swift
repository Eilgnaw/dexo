import SwiftSoup

/// Extracts list content from `<ul>` and `<ol>` elements.
enum ListExtractor {
    static func extract(from element: Element, ordered: Bool, options: ParseOptions) -> ContentBlock {
        var items: [ListItem] = []

        for child in element.children() {
            guard child.tagName().lowercased() == "li" else { continue }
            items.append(extractItem(from: child, options: options))
        }

        return .list(ordered: ordered, items: items)
    }

    private static func extractItem(from li: Element, options: ParseOptions) -> ListItem {
        // A list item is a regular mixed-flow block container. Reusing the shared
        // block pipeline keeps inline whitespace and arbitrary nested blocks
        // consistent with divs, quotes, details, and table cells.
        ListItem(blocks: BlockExtractor.extract(from: li, options: options))
    }
}
