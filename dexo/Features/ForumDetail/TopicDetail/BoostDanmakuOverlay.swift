import CookedHTML
import DanmakuKit
import SDWebImage
import UIKit

// MARK: - Cell Model

final class BoostDanmakuCellModel: DanmakuCellModel {
    var identifier = ""
    var boost: DiscourseTopicDetail.Boost?
    var assetBaseURL = ""

    var cellClass: DanmakuCell.Type { BoostDanmakuCell.self }
    var size: CGSize = .zero
    var track: UInt?
    var displayTime: Double = 6
    var type: DanmakuCellType = .floating

    func isEqual(to cellModel: DanmakuCellModel) -> Bool {
        identifier == cellModel.identifier
    }
}

// MARK: - Cell

private enum BoostDanmakuLayout {
    static let horizontalPadding: CGFloat = 10
    static let trailingPadding: CGFloat = 10
    static let minimumTextWidth: CGFloat = 10
    static let minimumChipHeight: CGFloat = 26
    static let verticalPadding: CGFloat = 2
}

final class BoostDanmakuCell: DanmakuCell {
    private let textFont = FontManager.shared.font(size: 13)

    private let textView: UITextView = {
        let tv = UITextView()
        tv.isEditable = false
        tv.isScrollEnabled = false
        tv.isUserInteractionEnabled = false
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainer.maximumNumberOfLines = 1
        tv.textContainer.lineBreakMode = .byTruncatingTail
        tv.backgroundColor = .clear
        return tv
    }()

    required init(frame: CGRect) {
        super.init(frame: frame)
        displayAsync = false
        addSubview(textView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func willDisplay() {
        guard let model = model as? BoostDanmakuCellModel,
              let boost = model.boost else { return }

        backgroundColor = ThemeManager.shared.codeBackgroundColor.withAlphaComponent(0.78)

        let baseURL = model.assetBaseURL

        // Text
        let inlineNodes = Self.inlineNodes(from: boost.cooked, baseURL: baseURL)
        let attributedText = inlineNodes.attributedString(
            config: AttributedStringConfig(
                baseFont: textFont,
                baseColor: .label,
                linkColor: .link,
                codeFont: FontManager.shared.monospacedFont(size: textFont.pointSize),
                codeBackgroundColor: .secondarySystemBackground
            )
        )
        textView.attributedText = attributedText
        loadInlineImages(in: textView)

        layer.cornerRadius = bounds.height / 2
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let textX = BoostDanmakuLayout.horizontalPadding
        let textWidth = max(BoostDanmakuLayout.minimumTextWidth, bounds.width - textX - BoostDanmakuLayout.trailingPadding)
        let textHeight = max(ceil(textFont.lineHeight),
                             ceil(textView.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height))
        textView.frame = CGRect(
            x: textX,
            y: (bounds.height - textHeight) / 2,
            width: textWidth,
            height: textHeight
        )
    }

    // MARK: - Helpers

    static func inlineNodes(from cooked: String, baseURL: String) -> [InlineNode] {
        let blocks = CookedHTMLParser.parse(html: cooked, baseURL: baseURL)
        guard let first = blocks.first else { return [.text("")] }
        switch first {
        case .paragraph(let inlines) where !inlines.isEmpty:
            return inlines.flatMap { node -> [InlineNode] in
                node == .lineBreak ? [.text(" ")] : [node]
            }.trimmedWhitespace()
        case .image(let src, let alt, let width, let height, _):
            return [.image(src: src, alt: alt, width: width, height: height, isEmoji: true)]
        default:
            return [.text("")]
        }
    }

    private func loadInlineImages(in textView: UITextView) {
        guard let attributedText = textView.attributedText else { return }
        let fullRange = NSRange(location: 0, length: attributedText.length)

        var entries: [(attachment: NSTextAttachment, location: Int, url: URL)] = []
        attributedText.enumerateAttribute(.cookedHTMLImageURL, in: fullRange) { value, range, _ in
            guard let urlString = value as? String,
                  let url = URL(string: urlString) else { return }
            for i in 0 ..< range.length {
                let loc = range.location + i
                if let attachment = attributedText.attribute(.attachment, at: loc, effectiveRange: nil) as? NSTextAttachment {
                    entries.append((attachment, loc, url))
                }
            }
        }

        for entry in entries {
            SDWebImageManager.shared.loadImage(with: entry.url, options: [], context: ImageCacheManager.shared.emojiContext, progress: nil) { [weak textView] image, _, _, _, _, _ in
                guard let textView, let image else { return }
                entry.attachment.image = image
                textView.textStorage.edited(.editedAttributes, range: NSRange(location: entry.location, length: 1), changeInLength: 0)
            }
        }
    }
}

// MARK: - Overlay

final class BoostDanmakuOverlay {
    private weak var hostView: UIView?
    private var danmakuView: DanmakuView?
    private var cleanupToken = 0

    init(hostView: UIView) {
        self.hostView = hostView
    }

    func shoot(boosts: [DiscourseTopicDetail.Boost], assetBaseURL: String, top: CGFloat, bottom: CGFloat) {
        guard let hostView, !boosts.isEmpty else { return }

        // Clear any running danmaku first
        stop()
        let token = cleanupToken

        let safeFrame = hostView.safeAreaLayoutGuide.layoutFrame
        let frame = CGRect(
            x: safeFrame.minX,
            y: top,
            width: safeFrame.width,
            height: bottom - top
        )

        let dv = DanmakuView(frame: frame)
        dv.isUserInteractionEnabled = false
        dv.backgroundColor = .clear
        hostView.addSubview(dv)
        danmakuView = dv
        dv.play()

        let textFont = FontManager.shared.font(size: 13)
        for (i, boost) in boosts.enumerated() {
            let model = BoostDanmakuCellModel()
            model.identifier = "\(boost.id)"
            model.boost = boost
            model.assetBaseURL = assetBaseURL
            model.size = Self.chipSize(for: boost, font: textFont, baseURL: assetBaseURL)

            let delay = Double(i) * 0.4
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.cleanupToken == token else { return }
                self.danmakuView?.shoot(danmaku: model)
            }
        }

        let totalDuration = Double(boosts.count) * 0.4 + 7
        DispatchQueue.main.asyncAfter(deadline: .now() + totalDuration) { [weak self] in
            guard let self, self.cleanupToken == token else { return }
            self.stop()
        }
    }

    func stop() {
        // Invalidate delayed shots from the previous run before replacing or
        // removing its view. Otherwise they would be delivered to a later run.
        cleanupToken += 1
        danmakuView?.stop()
        danmakuView?.removeFromSuperview()
        danmakuView = nil
    }

    private static func chipSize(for boost: DiscourseTopicDetail.Boost, font: UIFont, baseURL: String) -> CGSize {
        let inlineNodes = BoostDanmakuCell.inlineNodes(from: boost.cooked, baseURL: baseURL)
        let attr = inlineNodes.attributedString(
            config: AttributedStringConfig(
                baseFont: font,
                baseColor: .label,
                linkColor: .link,
                codeFont: FontManager.shared.monospacedFont(size: font.pointSize),
                codeBackgroundColor: .secondarySystemBackground
            )
        )
        let textSize = attr.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: 26),
            options: .usesLineFragmentOrigin,
            context: nil
        ).size
        let width = BoostDanmakuLayout.horizontalPadding + ceil(textSize.width) + BoostDanmakuLayout.trailingPadding
        let height = max(BoostDanmakuLayout.minimumChipHeight, ceil(textSize.height) + BoostDanmakuLayout.verticalPadding * 2)
        return CGSize(width: width, height: height)
    }
}
