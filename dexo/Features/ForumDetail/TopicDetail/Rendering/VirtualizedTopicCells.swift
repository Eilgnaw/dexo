import CookedHTML
import SDWebImage
import UIKit

protocol RenderUnitSizeInvalidating: AnyObject {
    func renderUnitCell(_ cell: VirtualPostBlockCell, didResolveHeight height: CGFloat, for unitId: RenderUnitID)
}

/// Draws the vertical-only portion of a tree connector through virtualized
/// body/footer rows. The header owns the elbow into the avatar; every later
/// item repeats only the columns that must remain continuous.
final class VirtualTreeContinuationView: UIView {
    private var columns: [CGFloat] = []
    var lineColor: UIColor = .separator { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(state: TreeLineState?) {
        columns = Self.columns(for: state)
        isHidden = columns.isEmpty
        setNeedsDisplay()
    }

    static func columns(for state: TreeLineState?) -> [CGFloat] {
        guard let state else { return [] }
        var values: [CGFloat] = []
        for (index, continues) in state.ancestorTrails.enumerated().dropFirst() where continues {
            values.append(TreeLineView.columnX(forDepth: min(index + 1, PostNativeCell.treeMaxIndentLevels)))
        }
        if state.depth >= 2, !state.isLastSibling {
            values.append(TreeLineView.columnX(forDepth: min(state.depth, PostNativeCell.treeMaxIndentLevels)))
        }
        if state.depth >= 1, state.hasChildren, !state.isCollapsed {
            values.append(TreeLineView.columnX(forDepth: min(state.depth + 1, PostNativeCell.treeMaxIndentLevels)))
        }
        return Array(Set(values)).sorted()
    }

    override func draw(_ rect: CGRect) {
        guard !columns.isEmpty, let context = UIGraphicsGetCurrentContext() else { return }
        context.setStrokeColor(lineColor.cgColor)
        context.setLineWidth(1)
        context.setLineCap(.square)
        for x in columns {
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: rect.height))
        }
        context.strokePath()
    }
}

/// The expanded-subtree pill that sits on the child connector immediately
/// before the first child row. Virtualized posts span several cells, so the
/// pill is hosted by the post's final visible item rather than its header.
final class VirtualTreeCollapsePill: UIButton {
    static let size: CGFloat = 18
    static let bottomInset: CGFloat = 4

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = Self.size / 2
        layer.borderWidth = 1
        let symbol = UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        setPreferredSymbolConfiguration(symbol, forImageIn: .normal)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    static func leading(for state: TreeLineState?, isLastVisualItem: Bool) -> CGFloat? {
        guard let state,
              isLastVisualItem,
              state.depth >= 1,
              state.hasChildren,
              !state.isCollapsed
        else { return nil }
        let childDepth = min(state.depth + 1, PostNativeCell.treeMaxIndentLevels)
        return TreeLineView.columnX(forDepth: childDepth) - Self.size / 2
    }

    @discardableResult
    func configure(state: TreeLineState?, isLastVisualItem: Bool) -> CGFloat? {
        let leading = Self.leading(for: state, isLastVisualItem: isLastVisualItem)
        isHidden = leading == nil
        guard leading != nil else { return nil }
        setImage(UIImage(systemName: "minus"), for: .normal)
        backgroundColor = ThemeManager.shared.backgroundColor
        tintColor = .secondaryLabel
        layer.borderColor = UIColor.separator.cgColor
        accessibilityLabel = String(localized: "topic_detail.collapse")
        return leading
    }
}

protocol VirtualSelectionSurface where Self: UICollectionViewCell {
    var selectionText: String { get }
    var selectionTextLength: Int { get }
    func selectionOffset(at point: CGPoint) -> Int?
    func selectionWordRange(at point: CGPoint) -> NSRange?
    func applyExternalSelection(_ range: NSRange?)
    func selectionCaretRect(at offset: Int, downstream: Bool) -> CGRect?
}

enum VirtualTextSelectionGeometry {
    private static let highlightLayerName = "DexoExternalSelectionHighlight"

    static func textView(in root: UIView) -> UITextView? {
        if let textView = root as? UITextView { return textView }
        for subview in root.subviews {
            if let textView = textView(in: subview) { return textView }
        }
        return nil
    }

    static func offset(in textView: UITextView, at point: CGPoint) -> Int? {
        TopicTextInputGeometry.offset(in: textView, at: point)
    }

    static func wordRange(in textView: UITextView, at point: CGPoint) -> NSRange? {
        guard let index = TopicTextInputGeometry.characterRange(in: textView, at: point)?.location
            ?? offset(in: textView, at: point)
        else { return nil }
        let text = textView.attributedText.string
        let length = (text as NSString).length
        guard length > 0 else { return nil }
        let characterIndex = min(index, length - 1)
        var matchedRange: NSRange?
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.byWords, .substringNotRequired]
        ) { _, range, _, stop in
            let candidate = NSRange(range, in: text)
            if NSLocationInRange(characterIndex, candidate) {
                matchedRange = candidate
                stop = true
            }
        }
        if let matchedRange { return matchedRange }
        return (text as NSString).rangeOfComposedCharacterSequence(at: characterIndex)
    }

    static func apply(range: NSRange?, to textView: UITextView) {
        textView.layer.sublayers?.filter { $0.name == highlightLayerName }
            .forEach { $0.removeFromSuperlayer() }
        guard let range, range.length > 0,
              range.location >= 0,
              NSMaxRange(range) <= textView.attributedText.length
        else { return }

        let path = UIBezierPath()
        for rect in TopicTextInputGeometry.rects(in: textView, for: range) {
            path.append(UIBezierPath(roundedRect: rect, cornerRadius: 2))
        }
        let layer = CAShapeLayer()
        layer.name = highlightLayerName
        layer.frame = textView.bounds
        layer.bounds = textView.bounds
        layer.path = path.cgPath
        layer.fillColor = UIColor.systemBlue.withAlphaComponent(0.28).cgColor
        textView.layer.addSublayer(layer)
    }

    static func setExternalSelectionEnabled(_ enabled: Bool, in textView: UITextView) {
        if let linkTextView = textView as? LinkTextView {
            linkTextView.usesExternalSelectionInteraction = enabled
        } else {
            textView.isSelectable = !enabled
        }
        textView.gestureRecognizers?.forEach { gesture in
            if gesture is UILongPressGestureRecognizer
                || (((gesture as? UITapGestureRecognizer)?.numberOfTapsRequired ?? 0) > 1)
            {
                gesture.isEnabled = !enabled
            }
        }
        if !enabled { apply(range: nil, to: textView) }
    }

    static func caretRect(in textView: UITextView, at offset: Int) -> CGRect? {
        let clamped = max(0, min(offset, textView.attributedText.length))
        guard let position = textView.position(from: textView.beginningOfDocument, offset: clamped) else {
            return nil
        }
        return textView.caretRect(for: position)
    }

}

final class VirtualTopicTitleCell: UICollectionViewCell {
    static let reuseIdentifier = "VirtualTopicTitleCell"
    private static let horizontalInset: CGFloat = 16
    private static let tagHorizontalSpacing: CGFloat = 6
    private static let tagVerticalSpacing: CGFloat = 6

    private struct TagLayout {
        let frames: [CGRect]
        let height: CGFloat
    }

    private let label = UILabel()
    private let tagsView = UIView()
    private var tagsHeightConstraint: NSLayoutConstraint!
    private var tags: [DiscourseTopicDetail.Tag] = []
    private var onTag: ((DiscourseTopicDetail.Tag) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        tagsView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        contentView.addSubview(tagsView)
        tagsHeightConstraint = tagsView.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            tagsView.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            tagsView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            tagsView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            tagsView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            tagsHeightConstraint,
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(
        title: String,
        tags: [DiscourseTopicDetail.Tag] = [],
        onTag: ((DiscourseTopicDetail.Tag) -> Void)? = nil
    ) {
        backgroundColor = ThemeManager.shared.cardBackgroundColor
        contentView.backgroundColor = ThemeManager.shared.cardBackgroundColor
        label.font = FontManager.shared.font(size: 20, weight: .bold)
        label.textColor = .label
        TopicCell.applyEmojiTitle(title, to: label)
        self.tags = tags
        self.onTag = onTag
        rebuildTagButtons()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        let availableWidth = max(0, contentView.bounds.width - Self.horizontalInset * 2)
        let buttons = tagsView.subviews.compactMap { $0 as? UIButton }
        let tagLayout = Self.tagLayout(for: buttons, width: availableWidth)
        tagsHeightConstraint.constant = tagLayout.height
        super.layoutSubviews()
        for (button, frame) in zip(buttons, tagLayout.frames) {
            button.frame = frame
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        tags = []
        onTag = nil
        tagsView.subviews.forEach { $0.removeFromSuperview() }
        tagsHeightConstraint.constant = 0
    }

    private func rebuildTagButtons() {
        tagsView.subviews.forEach { $0.removeFromSuperview() }
        for tag in tags {
            let button = Self.makeTagButton(title: tag.name) { [weak self] in
                self?.onTag?(tag)
            }
            tagsView.addSubview(button)
        }
        tagsView.isHidden = tags.isEmpty
        let availableWidth = max(0, contentView.bounds.width - Self.horizontalInset * 2)
        tagsHeightConstraint.constant = Self.tagLayout(
            for: tagsView.subviews.compactMap { $0 as? UIButton },
            width: availableWidth
        ).height
    }

    private static func makeTagButton(title: String, onTap: (() -> Void)? = nil) -> UIButton {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.image = UIImage(systemName: "tag")
        configuration.imagePadding = 4
        configuration.baseForegroundColor = ThemeManager.shared.accentColor
        configuration.baseBackgroundColor = ThemeManager.shared.codeBackgroundColor
        configuration.cornerStyle = .capsule
        configuration.contentInsets = .init(top: 4, leading: 10, bottom: 4, trailing: 10)
        configuration.preferredSymbolConfigurationForImage = .init(pointSize: 10, weight: .medium)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var copy = attributes
            copy.font = FontManager.shared.font(size: 13, weight: .medium)
            return copy
        }
        button.configuration = configuration
        button.titleLabel?.lineBreakMode = .byTruncatingTail
        if let onTap {
            button.addAction(UIAction { _ in onTap() }, for: .touchUpInside)
        }
        return button
    }

    private static func tagLayout(for buttons: [UIButton], width: CGFloat) -> TagLayout {
        guard !buttons.isEmpty, width > 0 else { return TagLayout(frames: [], height: 0) }
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var frames: [CGRect] = []
        for button in buttons {
            let measured = button.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            let size = CGSize(width: min(width, ceil(measured.width)), height: ceil(measured.height))
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + tagVerticalSpacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + tagHorizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
        return TagLayout(frames: frames, height: y + rowHeight)
    }

    static func height(title: String, tags: [DiscourseTopicDetail.Tag], width: CGFloat) -> CGFloat {
        let font = FontManager.shared.font(size: 20, weight: .bold)
        let titleRect = (title as NSString).boundingRect(
            with: CGSize(width: max(1, width - 32), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        guard !tags.isEmpty else { return ceil(titleRect.height) + 28 }
        let available = max(1, width - horizontalInset * 2)
        let buttons = tags.map { makeTagButton(title: $0.name) }
        let tagsHeight = tagLayout(for: buttons, width: available).height
        return ceil(titleRect.height) + 12 + 8 + tagsHeight + 8
    }
}

final class VirtualPostHeaderCell: UICollectionViewCell {
    static let reuseIdentifier = "VirtualPostHeaderCell"

    private let avatar = UIImageView()
    private let flair = SDAnimatedImageView()
    private let nameLabel = UILabel()
    private let usernameLabel = UILabel()
    private let userTitleLabel = UILabel()
    private let replyReferenceLabel = UILabel()
    private let timeLabel = UILabel()
    private let floorLabel = UILabel()
    private let treeLineView = TreeLineView()
    private var avatarLeadingConstraint: NSLayoutConstraint!
    private var avatarWidthConstraint: NSLayoutConstraint!
    private var avatarHeightConstraint: NSLayoutConstraint!
    private var flairWidthConstraint: NSLayoutConstraint!
    private var flairHeightConstraint: NSLayoutConstraint!
    private var username: String?
    var onAvatar: ((String) -> Void)?
    var onReplyReference: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        treeLineView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(treeLineView)
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.contentMode = .scaleAspectFill
        avatar.clipsToBounds = true
        avatar.isUserInteractionEnabled = true
        avatar.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(avatarTapped)))
        flair.translatesAutoresizingMaskIntoConstraints = false
        flair.contentMode = .scaleAspectFill
        flair.clipsToBounds = true
        flair.isHidden = true

        userTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        userTitleLabel.textColor = .secondaryLabel
        userTitleLabel.lineBreakMode = .byTruncatingTail
        replyReferenceLabel.translatesAutoresizingMaskIntoConstraints = false
        replyReferenceLabel.textColor = .secondaryLabel
        replyReferenceLabel.isHidden = true
        replyReferenceLabel.isUserInteractionEnabled = true
        replyReferenceLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(replyReferenceTapped)))

        for label in [nameLabel, usernameLabel, timeLabel, floorLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(label)
        }
        contentView.addSubview(avatar)
        contentView.addSubview(flair)
        contentView.addSubview(userTitleLabel)
        contentView.addSubview(replyReferenceLabel)

        avatarLeadingConstraint = avatar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12)
        avatarWidthConstraint = avatar.widthAnchor.constraint(equalToConstant: 32)
        avatarHeightConstraint = avatar.heightAnchor.constraint(equalToConstant: 32)
        flairWidthConstraint = flair.widthAnchor.constraint(equalToConstant: 14)
        flairHeightConstraint = flair.heightAnchor.constraint(equalToConstant: 14)
        NSLayoutConstraint.activate([
            treeLineView.topAnchor.constraint(equalTo: contentView.topAnchor),
            treeLineView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            treeLineView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            treeLineView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            avatarLeadingConstraint,
            avatar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            avatarWidthConstraint,
            avatarHeightConstraint,
            flair.trailingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 2),
            flair.bottomAnchor.constraint(equalTo: avatar.bottomAnchor, constant: 2),
            flairWidthConstraint,
            flairHeightConstraint,
            nameLabel.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 8),
            nameLabel.topAnchor.constraint(equalTo: avatar.topAnchor),
            userTitleLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 4),
            userTitleLabel.lastBaselineAnchor.constraint(equalTo: nameLabel.lastBaselineAnchor),
            userTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: replyReferenceLabel.leadingAnchor, constant: -8),
            usernameLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            usernameLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor),
            replyReferenceLabel.trailingAnchor.constraint(equalTo: floorLabel.leadingAnchor, constant: -8),
            replyReferenceLabel.centerYAnchor.constraint(equalTo: floorLabel.centerYAnchor),
            timeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            timeLabel.topAnchor.constraint(equalTo: floorLabel.bottomAnchor, constant: 2),
            floorLabel.trailingAnchor.constraint(equalTo: timeLabel.trailingAnchor),
            floorLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(
        post: DiscourseTopicDetail.Post,
        floor: Int,
        baseURL: String,
        isOP: Bool,
        treeState: TreeLineState?
    ) {
        backgroundColor = ThemeManager.shared.cardBackgroundColor
        contentView.backgroundColor = ThemeManager.shared.cardBackgroundColor
        username = post.username
        let avatarSize = FontManager.shared.scaled(32)
        let flairSize = FontManager.shared.scaled(14)
        avatarWidthConstraint.constant = avatarSize
        avatarHeightConstraint.constant = avatarSize
        flairWidthConstraint.constant = flairSize
        flairHeightConstraint.constant = flairSize
        nameLabel.font = FontManager.shared.font(size: 14, weight: .semibold)
        usernameLabel.font = FontManager.shared.font(size: 12)
        userTitleLabel.font = FontManager.shared.font(size: 12)
        replyReferenceLabel.font = FontManager.shared.font(size: 12)
        timeLabel.font = FontManager.shared.font(size: 12)
        floorLabel.font = FontManager.shared.monospacedDigitFont(size: 12)
        nameLabel.text = post.name ?? post.username
        nameLabel.textColor = isOP ? ThemeManager.shared.accentColor : .label
        nameLabel.backgroundColor = .clear
        nameLabel.layer.cornerRadius = 0
        nameLabel.clipsToBounds = false
        usernameLabel.text = post.username
        usernameLabel.textColor = .secondaryLabel
        let userTitle = post.userTitle?.isEmpty == false ? post.userTitle : nil
        if userTitle != nil || post.acceptedAnswer {
            let metadata = NSMutableAttributedString()
            if let userTitle {
                metadata.append(NSAttributedString(
                    string: "· \(userTitle)",
                    attributes: [.foregroundColor: UIColor.secondaryLabel]
                ))
            }
            if post.acceptedAnswer {
                if userTitle != nil {
                    metadata.append(NSAttributedString(string: "  "))
                }
                metadata.append(NSAttributedString(
                    string: "✓ \(String(localized: "solution.resolved"))",
                    attributes: [
                        .foregroundColor: ThemeManager.shared.accentColor,
                        .font: FontManager.shared.font(size: 12, weight: .semibold),
                    ]
                ))
            }
            userTitleLabel.attributedText = metadata
            userTitleLabel.isHidden = false
        } else {
            userTitleLabel.attributedText = nil
            userTitleLabel.isHidden = true
        }
        if let replyUser = post.replyToUser, treeState == nil {
            let attachment = NSTextAttachment()
            let symbolConfig = UIImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            attachment.image = UIImage(
                systemName: "arrowshape.turn.up.left.fill",
                withConfiguration: symbolConfig
            )?.withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)
            let attributedText = NSMutableAttributedString(attachment: attachment)
            attributedText.append(NSAttributedString(string: " @\(replyUser.username)"))
            replyReferenceLabel.attributedText = attributedText
            replyReferenceLabel.isHidden = false
        } else {
            replyReferenceLabel.attributedText = nil
            replyReferenceLabel.isHidden = true
        }
        timeLabel.text = Self.displayDate(post.createdAt)
        timeLabel.textColor = .secondaryLabel
        floorLabel.text = treeState == nil ? "#\(floor)" : nil
        floorLabel.isHidden = treeState != nil
        if let treeState {
            avatarLeadingConstraint.constant = 12 + PostNativeCell.treeAvatarIndent(forDepth: treeState.depth)
            treeLineView.state = treeState
            treeLineView.connectorY = 12 + avatarSize / 2
            treeLineView.avatarBottomY = 12 + avatarSize
            treeLineView.lineColor = .separator
            let drawsIncoming = treeState.depth >= 2
            let drawsOutgoing = treeState.hasChildren && !treeState.isCollapsed && treeState.depth >= 1
            treeLineView.isHidden = !(drawsIncoming || drawsOutgoing)
        } else {
            avatarLeadingConstraint.constant = 12
            treeLineView.state = nil
            treeLineView.isHidden = true
        }
        avatar.layer.cornerRadius = avatarSize / 2
        avatar.backgroundColor = .secondarySystemFill
        avatar.sd_cancelCurrentImageLoad()
        avatar.image = nil
        if let template = post.avatarTemplate {
            let sized = template.replacingOccurrences(of: "{size}", with: "96")
            avatar.sd_setImage(with: URL(string: sized.hasPrefix("http") ? sized : baseURL + sized), context: ImageCacheManager.shared.avatarContext)
        }
        flair.sd_cancelCurrentImageLoad()
        flair.image = nil
        flair.backgroundColor = nil
        flair.isHidden = true
        if let path = post.flairUrl, !path.isEmpty,
           let url = URL(string: path.hasPrefix("http") ? path : baseURL + path)
        {
            if let color = post.flairBgColor, !color.isEmpty { flair.backgroundColor = UIColor(hex: color) }
            flair.layer.cornerRadius = flairSize / 2
            flair.sd_setImage(with: url, context: ImageCacheManager.shared.avatarContext)
            flair.isHidden = false
        }
        if post.deletedPostPlaceholder {
            username = nil
            nameLabel.text = String(localized: "post.deleted_placeholder")
            nameLabel.textColor = .tertiaryLabel
            nameLabel.backgroundColor = .clear
            usernameLabel.isHidden = true
            userTitleLabel.isHidden = true
            replyReferenceLabel.isHidden = true
            timeLabel.isHidden = true
            floorLabel.isHidden = true
            avatar.sd_cancelCurrentImageLoad()
            avatar.image = nil
            flair.isHidden = true
        } else {
            usernameLabel.isHidden = false
            timeLabel.isHidden = false
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        avatar.sd_cancelCurrentImageLoad()
        avatar.image = nil
        flair.sd_cancelCurrentImageLoad()
        flair.image = nil
        flair.isHidden = true
        replyReferenceLabel.attributedText = nil
        replyReferenceLabel.isHidden = true
        onAvatar = nil
        onReplyReference = nil
    }

    @objc private func avatarTapped() {
        if let username { onAvatar?(username) }
    }

    @objc private func replyReferenceTapped() { onReplyReference?() }

    private static func displayDate(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value) else { return value }
        if abs(date.timeIntervalSinceNow) < 5 { return String(localized: "time.just_now") }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated
        return relative.localizedString(for: date, relativeTo: Date())
    }
}

final class VirtualPostBlockCell: UICollectionViewCell, UITextViewDelegate, TopicPostIDProviding, VirtualSelectionSurface {
    static let reuseIdentifier = "VirtualPostBlockCell"
    weak var sizeDelegate: RenderUnitSizeInvalidating?
    private weak var postDelegate: PostCellDelegate?
    private var postId = 0
    var renderedPostId: Int { postId }
    private var hostedView: UIView?
    private var unitId: RenderUnitID?
    private var leadingConstraint: NSLayoutConstraint?
    private var hostedHeightConstraint: NSLayoutConstraint?
    private var selectionUsesTextSurface = false
    private weak var externalSelectionOverlay: UIView?
    private var acceptsDynamicHeightUpdates = false
    private var bottomSpacing: CGFloat = 8
    private var observationTokens: [NSObjectProtocol] = []
    private var inlineImageOperations: [SDWebImageOperation] = []
    private let treeContinuationView = VirtualTreeContinuationView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Deferred renderers may discover a larger intrinsic size while the
        // user is scrolling. Keep that content inside the stable placeholder
        // until the controller commits the queued height batch.
        contentView.clipsToBounds = true
        treeContinuationView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(treeContinuationView)
        NSLayoutConstraint.activate([
            treeContinuationView.topAnchor.constraint(equalTo: contentView.topAnchor),
            treeContinuationView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            treeContinuationView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            treeContinuationView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        let center = NotificationCenter.default
        for name in [
            TappableImageContainer.intrinsicHeightDidChangeNotification,
            Notification.Name("TopicDetailsHeightDidChange"),
        ] {
            observationTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, let sender = note.object as? UIView,
                      self.acceptsDynamicHeightUpdates,
                      sender === self.hostedView || sender.isDescendant(of: self.hostedView ?? UIView())
                else { return }
                self.measureHostedView()
            })
        }
    }

    deinit {
        for token in observationTokens { NotificationCenter.default.removeObserver(token) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(
        unit: RenderUnit,
        post: DiscourseTopicDetail.Post,
        config: NativeRenderConfig,
        delegate: PostCellDelegate?,
        leadingIndent: CGFloat,
        treeState: TreeLineState?,
        detailsExpanded: Bool,
        onDetailsExpansionChange: ((Bool) -> Void)?,
        pollPendingSelections: Set<String>?,
        onPollPendingSelectionsChange: ((Set<String>) -> Void)?,
        spoilerRevealed: Bool = false,
        onSpoilerRevealChange: ((Bool) -> Void)? = nil,
        heightPolicy: RenderUnitHeightPolicy
    ) {
        backgroundColor = ThemeManager.shared.cardBackgroundColor
        contentView.backgroundColor = ThemeManager.shared.cardBackgroundColor
        tearDownHostedView()
        postId = post.id
        unitId = unit.id
        switch unit.block {
        case .paragraph, .heading, .codeBlock, .list, .rawHTML:
            selectionUsesTextSurface = true
        default:
            selectionUsesTextSurface = false
        }
        postDelegate = delegate
        acceptsDynamicHeightUpdates = heightPolicy.acceptsDynamicUpdates
        bottomSpacing = unit.bottomSpacing
        if !acceptsDynamicHeightUpdates { sizeDelegate = nil }
        treeContinuationView.configure(state: treeState)

        let annotated = AnnotatedBlock(block: unit.block, sourceHTML: unit.sourceHTML)
        let views = TopicRenderMetrics.measure("ConfigureRenderUnitCell") {
            NativeContentRenderer.renderBlocks(
                [annotated],
                config: config,
                delegate: delegate,
                pollProvider: { name in
                    guard let poll = post.polls.first(where: { $0.name == name }) else { return nil }
                    return (poll, Set(post.pollsVotes[name] ?? []), post)
                }
            )
        }
        let view = views.first ?? UIView()
        hostedView = view
        if let detailsView = findDetailsView(in: view) {
            detailsView.setExpanded(detailsExpanded)
            detailsView.onExpansionChange = onDetailsExpansionChange
        }
        if let pollView = findPollView(in: view) {
            if let pollPendingSelections { pollView.restorePendingSelections(pollPendingSelections) }
            pollView.onPendingSelectionsChange = onPollPendingSelectionsChange
        }
        if let spoiler = findSpoilerView(in: view) {
            spoiler.setRevealed(spoilerRevealed)
            spoiler.onRevealChange = onSpoilerRevealChange
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(view)
        let leading = view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12 + leadingIndent)
        leadingConstraint = leading
        var constraints = [
            view.topAnchor.constraint(equalTo: contentView.topAnchor),
            leading,
            view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
        ]
        if !heightPolicy.acceptsDynamicUpdates {
            let height = view.heightAnchor.constraint(equalToConstant: max(0, heightPolicy.height - unit.bottomSpacing))
            hostedHeightConstraint = height
            constraints.append(height)
        }
        NSLayoutConstraint.activate(constraints)
        configureTextViews(in: view)
        setNeedsLayout()
        if acceptsDynamicHeightUpdates {
            let configuredUnitId = unit.id
            DispatchQueue.main.async { [weak self] in
                guard let self, self.unitId == configuredUnitId else { return }
                self.measureHostedView()
            }
        }
    }

    private func measureHostedView() {
        guard acceptsDynamicHeightUpdates, let hostedView, let unitId,
              hostedView.bounds.width > 0 || contentView.bounds.width > 24
        else { return }
        let width = max(1, contentView.bounds.width - 24 - (leadingConstraint?.constant ?? 12) + 12)
        let size = hostedView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        if size.height > 0 {
            sizeDelegate?.renderUnitCell(self, didResolveHeight: ceil(size.height) + bottomSpacing, for: unitId)
        }
    }

    private func configureTextViews(in view: UIView) {
        if let textView = view as? UITextView {
            textView.delegate = self
            if let linkTextView = textView as? LinkTextView {
                linkTextView.configureSpoilerIfNeeded()
                linkTextView.onExternalLinkTap = { [weak self] url in
                    self?.postDelegate?.postCell(didTapLinkURL: url)
                }
            }
            loadInlineImages(in: textView)
        }
        for subview in view.subviews { configureTextViews(in: subview) }
    }

    var selectionTextLength: Int {
        guard let textView = selectionTextView else { return 0 }
        return textView.attributedText.length
    }

    var selectionText: String {
        guard let textView = selectionTextView else { return "" }
        return textView.attributedText.string
    }

    func selectionOffset(at point: CGPoint) -> Int? {
        guard hostedView != nil else { return nil }
        guard let textView = selectionTextView else { return nil }
        guard textView.bounds.contains(textView.convert(point, from: self)) else { return nil }
        return VirtualTextSelectionGeometry.offset(
            in: textView,
            at: textView.convert(point, from: self)
        )
    }

    func selectionWordRange(at point: CGPoint) -> NSRange? {
        guard let textView = selectionTextView else { return nil }
        return VirtualTextSelectionGeometry.wordRange(
            in: textView,
            at: textView.convert(point, from: self)
        )
    }

    func applyExternalSelection(_ range: NSRange?) {
        externalSelectionOverlay?.removeFromSuperview()
        externalSelectionOverlay = nil
        guard let hostedView else { return }
        guard let textView = selectionTextView else {
            guard let range, range.length > 0 else { return }
            let overlay = UIView(frame: hostedView.bounds)
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlay.isUserInteractionEnabled = false
            overlay.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.20)
            overlay.layer.cornerRadius = hostedView.layer.cornerRadius
            hostedView.addSubview(overlay)
            externalSelectionOverlay = overlay
            return
        }
        VirtualTextSelectionGeometry.apply(range: range, to: textView)
    }

    func setExternalSelectionEnabled(
        _ enabled: Bool,
        pressGesture: UIGestureRecognizer,
        doubleTapGesture: UITapGestureRecognizer
    ) {
        guard let textView = selectionTextView
        else { return }
        VirtualTextSelectionGeometry.setExternalSelectionEnabled(enabled, in: textView)
        if enabled {
            (textView as? LinkTextView)?.prioritizeExternalSelectionGestures(
                longPressGesture: pressGesture,
                doubleTapGesture: doubleTapGesture
            )
        }
    }

    func selectionCaretRect(at offset: Int, downstream: Bool) -> CGRect? {
        guard let hostedView else { return nil }
        guard let textView = selectionTextView else {
            let y = downstream ? hostedView.bounds.minY : hostedView.bounds.maxY
            return hostedView.convert(
                CGRect(x: hostedView.bounds.minX, y: y, width: 2, height: 1),
                to: self
            )
        }
        guard let rect = VirtualTextSelectionGeometry.caretRect(in: textView, at: offset) else { return nil }
        return textView.convert(rect, to: self)
    }

    private var selectionTextView: UITextView? {
        guard selectionUsesTextSurface, let hostedView else { return nil }
        return VirtualTextSelectionGeometry.textView(in: hostedView)
    }

    private func findDetailsView(in view: UIView) -> DetailsCardView? {
        if let details = view as? DetailsCardView { return details }
        for subview in view.subviews {
            if let details = findDetailsView(in: subview) { return details }
        }
        return nil
    }

    private func findPollView(in view: UIView) -> PollView? {
        if let poll = view as? PollView { return poll }
        for subview in view.subviews {
            if let poll = findPollView(in: subview) { return poll }
        }
        return nil
    }

    private func findSpoilerView(in view: UIView) -> SpoilerOverlayView? {
        if let spoiler = view as? SpoilerOverlayView { return spoiler }
        for subview in view.subviews {
            if let spoiler = findSpoilerView(in: subview) { return spoiler }
        }
        return nil
    }

    private func loadInlineImages(in textView: UITextView) {
        guard let text = textView.attributedText, text.length > 0 else { return }
        let full = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.cookedHTMLImageURL, in: full) { value, range, _ in
            guard let raw = value as? String, let url = URL(string: raw) else { return }
            let operation = SDWebImageManager.shared.loadImage(with: url, context: ImageCacheManager.shared.emojiContext, progress: nil) { [weak textView] image, _, _, _, _, _ in
                guard let image, let textView else { return }
                for location in range.location..<(range.location + range.length) {
                    guard let attachment = text.attribute(.attachment, at: location, effectiveRange: nil) as? NSTextAttachment else { continue }
                    attachment.image = image
                    textView.textStorage.edited(.editedAttributes, range: NSRange(location: location, length: 1), changeInLength: 0)
                }
            }
            if let operation { inlineImageOperations.append(operation) }
        }
    }

    func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
        postDelegate?.postCell(didTapLinkURL: URL)
        return false
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        tearDownHostedView()
        unitId = nil
        postId = 0
        postDelegate = nil
        sizeDelegate = nil
        acceptsDynamicHeightUpdates = false
        bottomSpacing = 8
    }

    private func tearDownHostedView() {
        for operation in inlineImageOperations { operation.cancel() }
        inlineImageOperations.removeAll(keepingCapacity: true)
        findDetailsView(in: hostedView ?? UIView())?.onExpansionChange = nil
        findPollView(in: hostedView ?? UIView())?.onPendingSelectionsChange = nil
        findSpoilerView(in: hostedView ?? UIView())?.onRevealChange = nil
        if let image = hostedView as? TappableImageContainer { image.cancelImageLoad() }
        if let onebox = hostedView as? OneboxCardView { onebox.cancelImageLoad() }
        if let video = hostedView as? VideoCardView { video.cancelImageLoad() }
        hostedView?.removeFromSuperview()
        hostedView = nil
        hostedHeightConstraint = nil
        selectionUsesTextSurface = false
        externalSelectionOverlay = nil
    }
}

struct VirtualPostFooterButtonTints {
    let reply: UIColor
    let like: UIColor
    let boost: UIColor
    let more: UIColor

    static func resolve(isLiked: Bool, hasCurrentUserBoost: Bool) -> Self {
        Self(
            reply: .tertiaryLabel,
            like: isLiked ? .systemRed : .tertiaryLabel,
            boost: hasCurrentUserBoost ? .systemYellow : .tertiaryLabel,
            more: .tertiaryLabel
        )
    }
}

struct VirtualPostSeparatorPlacement: Equatable {
    let footer: Bool
    let boosts: Bool

    static func resolve(isTreeMode: Bool, hasExpandedBoosts: Bool) -> Self {
        guard !isTreeMode else { return Self(footer: false, boosts: false) }
        return hasExpandedBoosts
            ? Self(footer: false, boosts: true)
            : Self(footer: true, boosts: false)
    }
}

final class VirtualPostReactionSummaryView: UIStackView {
    private let reactionImageViews: [UIImageView] = (0..<3).map { _ in
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
        ])
        return imageView
    }
    private let countLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        axis = .horizontal
        spacing = 2
        alignment = .center
        isHidden = true
        for imageView in reactionImageViews {
            addArrangedSubview(imageView)
            imageView.isHidden = true
        }
        addArrangedSubview(countLabel)
        countLabel.isHidden = true
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    func configure(reactions: [DiscourseTopicDetail.Reaction], count: Int) {
        countLabel.font = FontManager.shared.font(size: 12)
        countLabel.textColor = .secondaryLabel
        guard !reactions.isEmpty else {
            reset()
            return
        }

        let visible = reactions.prefix(reactionImageViews.count)
        for (index, imageView) in reactionImageViews.enumerated() {
            guard index < visible.count else {
                clear(imageView)
                continue
            }
            let reaction = visible[visible.index(visible.startIndex, offsetBy: index)]
            if let urlString = EmojiStore.url(for: reaction.id) ?? EmojiStore.lookup(for: reaction.id),
               let url = URL(string: urlString)
            {
                imageView.sd_setImage(with: url, context: ImageCacheManager.shared.emojiContext)
            } else {
                imageView.sd_cancelCurrentImageLoad()
                imageView.image = nil
            }
            imageView.isHidden = false
        }

        countLabel.text = count > 0 ? "\(count)" : nil
        countLabel.isHidden = count <= 0
        isHidden = false
    }

    func reset() {
        for imageView in reactionImageViews { clear(imageView) }
        countLabel.text = nil
        countLabel.isHidden = true
        isHidden = true
    }

    var visibleReactionCount: Int { reactionImageViews.filter { !$0.isHidden }.count }
    var displayedCount: String? { countLabel.isHidden ? nil : countLabel.text }

    func playSuccessConfirmation() {
        ReactionFeedback.confirm(on: self, countView: countLabel)
    }

    private func clear(_ imageView: UIImageView) {
        imageView.sd_cancelCurrentImageLoad()
        imageView.image = nil
        imageView.isHidden = true
    }
}

enum VirtualPostFooterLayout {
    static func reactionLeading(for treeState: TreeLineState?) -> CGFloat {
        guard let treeState else { return 16 }
        let contentLeading = 12 + PostNativeCell.treeContentIndent(forDepth: treeState.depth)
        guard treeState.depth >= 1, treeState.hasChildren, !treeState.isCollapsed else {
            return contentLeading
        }
        let childDepth = min(treeState.depth + 1, PostNativeCell.treeMaxIndentLevels)
        return max(contentLeading, TreeLineView.columnX(forDepth: childDepth) + 15)
    }
}

enum VirtualPostReactionAction: Equatable {
    case toggleLike(Bool)
    case toggleReaction(String)
    case showPicker
    case none
}

enum VirtualPostReactionActionResolver {
    static func resolve(
        hasPlugin: Bool,
        currentReactionId: String?,
        currentReactionCanUndo: Bool?,
        isLiked: Bool,
        likeCanUndo: Bool?
    ) -> VirtualPostReactionAction {
        if hasPlugin {
            if let currentReactionId, currentReactionCanUndo == true {
                return .toggleReaction(currentReactionId)
            }
            return .showPicker
        }
        if isLiked, likeCanUndo == false { return .none }
        return .toggleLike(!isLiked)
    }
}

private final class VirtualReactionPickerViewController: UIViewController {
    private let reactions: [String]
    private let onSelect: (String, UIButton) -> Void

    init(reactions: [String], onSelect: @escaping (String, UIButton) -> Void) {
        self.reactions = reactions
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = ThemeManager.shared.cardBackgroundColor
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.18
        card.layer.shadowRadius = 12
        card.layer.shadowOffset = CGSize(width: 0, height: 4)
        view.addSubview(card)

        let rows = UIStackView()
        rows.translatesAutoresizingMaskIntoConstraints = false
        rows.axis = .vertical
        rows.alignment = .leading
        rows.spacing = 8
        card.addSubview(rows)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: view.topAnchor),
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            rows.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            rows.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
        ])

        let split = (reactions.count + 1) / 2
        for ids in [Array(reactions.prefix(split)), Array(reactions.dropFirst(split))] where !ids.isEmpty {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 8
            for id in ids { row.addArrangedSubview(makeButton(for: id)) }
            rows.addArrangedSubview(row)
        }
        view.layoutIfNeeded()
        let size = rows.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        preferredContentSize = CGSize(width: size.width + 32, height: size.height + 28)
    }

    private func makeButton(for reaction: String) -> UIButton {
        let button = UIButton(type: .custom)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = String(localized: "post.a11y.reaction \(reaction)")
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 32),
            button.heightAnchor.constraint(equalToConstant: 32),
        ])
        if let raw = EmojiStore.url(for: reaction) ?? EmojiStore.lookup(for: reaction),
           let url = URL(string: raw)
        {
            let image = UIImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.contentMode = .scaleAspectFit
            image.sd_setImage(with: url, context: ImageCacheManager.shared.emojiContext)
            button.addSubview(image)
            NSLayoutConstraint.activate([
                image.topAnchor.constraint(equalTo: button.topAnchor, constant: 2),
                image.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 2),
                image.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -2),
                image.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -2),
            ])
        } else {
            button.setTitle(":\(reaction):", for: .normal)
            button.setTitleColor(.label, for: .normal)
            button.titleLabel?.font = FontManager.shared.font(size: 11)
        }
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            onSelect(reaction, button)
            dismiss(animated: true)
        }, for: .touchUpInside)
        return button
    }
}

/// Native solved-answer preview rendered below the OP. Long content is clipped
/// behind a fade until the user explicitly expands it.
final class VirtualAcceptedAnswersCell: UICollectionViewCell, UITextViewDelegate {
    static let reuseIdentifier = "VirtualAcceptedAnswersCell"

    static let collapsedBodyHeight: CGFloat = 176
    private static let outerInset: CGFloat = 8
    private static let cardHorizontalInset: CGFloat = 16
    private static let bodyHorizontalInset: CGFloat = 12
    private static let headerHeight: CGFloat = 40
    private static let authorHeight: CGFloat = 48
    private static let bodyTopInset: CGFloat = 12
    private static let bodyBottomInset: CGFloat = 12
    private static let toggleHeight: CGFloat = 38
    static var cardContentHorizontalInsets: CGFloat {
        (cardHorizontalInset + bodyHorizontalInset) * 2
    }

    private let card = UIView()
    private let header = UIView()
    private let headerIcon = UIImageView(image: UIImage(systemName: "checkmark.square"))
    private let headerLabel = UILabel()
    private let authorRow = UIView()
    private let avatar = UIImageView()
    private let authorLabel = UILabel()
    private let timeLabel = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.up"))
    private let authorButton = UIButton(type: .system)
    private let bodyClipView = UIView()
    private let bodyStack = UIStackView()
    private let fadeView = UIView()
    private let fadeLayer = CAGradientLayer()
    private let toggleButton = UIButton(type: .system)
    private var bodyHeightConstraint: NSLayoutConstraint!
    private var toggleHeightConstraint: NSLayoutConstraint!
    private weak var postDelegate: PostCellDelegate?
    private var inlineImageOperations: [SDWebImageOperation] = []
    private var answerPostNumber = 0
    private var isExpanded = false

    var onSelect: ((Int) -> Void)?
    var onExpansionChange: ((Bool) -> Void)?

    static func height(naturalBodyHeight: CGFloat, expanded: Bool) -> CGFloat {
        let bodyHeight = expanded
            ? naturalBodyHeight
            : min(naturalBodyHeight, collapsedBodyHeight)
        let hasOverflow = naturalBodyHeight > collapsedBodyHeight + 1
        return outerInset * 2
            + headerHeight
            + authorHeight
            + bodyTopInset
            + ceil(bodyHeight)
            + (hasOverflow ? toggleHeight : bodyBottomInset)
    }

    static func measuredBodyHeight(
        document: PostRenderDocument,
        config: NativeRenderConfig
    ) -> CGFloat {
        let heights = BlockHeightCalculator.perBlockHeights(
            annotatedBlocks: document.annotatedBlocks,
            config: config
        )
        let resolved = heights.compactMap { $0 }
        if resolved.count == heights.count {
            let spacing = CGFloat(max(0, resolved.count - 1))
                * NativeContentRenderer.contentStackSpacing
            return max(1, resolved.reduce(0, +) + spacing)
        }

        let views = NativeContentRenderer.renderBlocks(
            document.annotatedBlocks,
            config: config,
            delegate: nil,
            precomputedBlockHeights: heights
        )
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.spacing = NativeContentRenderer.contentStackSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        let host = UIView()
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: config.contentWidth),
            stack.topAnchor.constraint(equalTo: host.topAnchor),
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        return max(1, ceil(host.systemLayoutSizeFitting(
            CGSize(width: config.contentWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height))
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        card.translatesAutoresizingMaskIntoConstraints = false
        card.layer.cornerRadius = 12
        card.layer.borderWidth = 1.0 / UIScreen.main.scale
        card.clipsToBounds = true
        contentView.addSubview(card)

        header.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(header)
        headerIcon.translatesAutoresizingMaskIntoConstraints = false
        headerIcon.contentMode = .scaleAspectFit
        header.addSubview(headerIcon)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerLabel.font = FontManager.shared.font(size: 14, weight: .bold)
        header.addSubview(headerLabel)

        authorRow.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(authorRow)
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.contentMode = .scaleAspectFill
        avatar.clipsToBounds = true
        authorRow.addSubview(avatar)
        authorLabel.translatesAutoresizingMaskIntoConstraints = false
        authorLabel.font = FontManager.shared.font(size: 14, weight: .semibold)
        authorRow.addSubview(authorLabel)
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = FontManager.shared.font(size: 13)
        authorRow.addSubview(timeLabel)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.contentMode = .scaleAspectFit
        authorRow.addSubview(chevron)
        authorButton.translatesAutoresizingMaskIntoConstraints = false
        authorButton.addTarget(self, action: #selector(authorTapped), for: .touchUpInside)
        authorRow.addSubview(authorButton)

        bodyClipView.translatesAutoresizingMaskIntoConstraints = false
        bodyClipView.clipsToBounds = true
        card.addSubview(bodyClipView)
        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        bodyStack.axis = .vertical
        bodyStack.spacing = NativeContentRenderer.contentStackSpacing
        bodyClipView.addSubview(bodyStack)
        fadeView.translatesAutoresizingMaskIntoConstraints = false
        fadeView.isUserInteractionEnabled = false
        fadeView.layer.addSublayer(fadeLayer)
        bodyClipView.addSubview(fadeView)

        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        toggleButton.contentHorizontalAlignment = .leading
        toggleButton.titleLabel?.font = FontManager.shared.font(size: 14, weight: .medium)
        toggleButton.addTarget(self, action: #selector(toggleTapped), for: .touchUpInside)
        card.addSubview(toggleButton)

        bodyHeightConstraint = bodyClipView.heightAnchor.constraint(equalToConstant: 1)
        toggleHeightConstraint = toggleButton.heightAnchor.constraint(equalToConstant: Self.bodyBottomInset)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Self.outerInset),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Self.cardHorizontalInset),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Self.cardHorizontalInset),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Self.outerInset),

            header.topAnchor.constraint(equalTo: card.topAnchor),
            header.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            headerIcon.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            headerIcon.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            headerIcon.widthAnchor.constraint(equalToConstant: 18),
            headerIcon.heightAnchor.constraint(equalToConstant: 18),
            headerLabel.leadingAnchor.constraint(equalTo: headerIcon.trailingAnchor, constant: 8),
            headerLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -12),

            authorRow.topAnchor.constraint(equalTo: header.bottomAnchor),
            authorRow.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            authorRow.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            authorRow.heightAnchor.constraint(equalToConstant: Self.authorHeight),
            avatar.leadingAnchor.constraint(equalTo: authorRow.leadingAnchor, constant: 12),
            avatar.centerYAnchor.constraint(equalTo: authorRow.centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 28),
            avatar.heightAnchor.constraint(equalToConstant: 28),
            authorLabel.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 8),
            authorLabel.centerYAnchor.constraint(equalTo: authorRow.centerYAnchor),
            timeLabel.leadingAnchor.constraint(equalTo: authorLabel.trailingAnchor, constant: 6),
            timeLabel.centerYAnchor.constraint(equalTo: authorRow.centerYAnchor),
            timeLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),
            chevron.trailingAnchor.constraint(equalTo: authorRow.trailingAnchor, constant: -12),
            chevron.centerYAnchor.constraint(equalTo: authorRow.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 12),
            authorButton.topAnchor.constraint(equalTo: authorRow.topAnchor),
            authorButton.leadingAnchor.constraint(equalTo: authorRow.leadingAnchor),
            authorButton.trailingAnchor.constraint(equalTo: authorRow.trailingAnchor),
            authorButton.bottomAnchor.constraint(equalTo: authorRow.bottomAnchor),

            bodyClipView.topAnchor.constraint(equalTo: authorRow.bottomAnchor, constant: Self.bodyTopInset),
            bodyClipView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Self.bodyHorizontalInset),
            bodyClipView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Self.bodyHorizontalInset),
            bodyHeightConstraint,
            bodyStack.topAnchor.constraint(equalTo: bodyClipView.topAnchor),
            bodyStack.leadingAnchor.constraint(equalTo: bodyClipView.leadingAnchor),
            bodyStack.trailingAnchor.constraint(equalTo: bodyClipView.trailingAnchor),
            fadeView.leadingAnchor.constraint(equalTo: bodyClipView.leadingAnchor),
            fadeView.trailingAnchor.constraint(equalTo: bodyClipView.trailingAnchor),
            fadeView.bottomAnchor.constraint(equalTo: bodyClipView.bottomAnchor),
            fadeView.heightAnchor.constraint(equalToConstant: 64),

            toggleButton.topAnchor.constraint(equalTo: bodyClipView.bottomAnchor),
            toggleButton.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Self.bodyHorizontalInset),
            toggleButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Self.bodyHorizontalInset),
            toggleButton.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            toggleHeightConstraint,
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(
        answer: DiscourseTopicDetail.AcceptedAnswer,
        document: PostRenderDocument,
        config: NativeRenderConfig,
        naturalBodyHeight: CGFloat,
        expanded: Bool,
        displayFloor: Int,
        baseURL: String,
        delegate: PostCellDelegate?
    ) {
        backgroundColor = ThemeManager.shared.cardBackgroundColor
        contentView.backgroundColor = ThemeManager.shared.cardBackgroundColor
        card.backgroundColor = ThemeManager.shared.cardBackgroundColor
        card.layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
        header.backgroundColor = ThemeManager.shared.codeBackgroundColor
        headerIcon.tintColor = ThemeManager.shared.accentColor
        headerLabel.textColor = ThemeManager.shared.accentColor
        headerLabel.text = String(localized: "solution.resolved")
        authorLabel.textColor = .label
        timeLabel.textColor = .secondaryLabel
        chevron.tintColor = .tertiaryLabel
        toggleButton.setTitleColor(ThemeManager.shared.accentColor, for: .normal)
        self.postDelegate = delegate
        answerPostNumber = answer.postNumber

        let displayName =
            answer.name.flatMap { $0.isEmpty ? nil : $0 }
            ?? (answer.username.isEmpty ? String(localized: "solution.unknown_author") : answer.username)
        authorLabel.text = displayName
        if let createdAt = answer.createdAt,
           let displayDate = Self.displayDate(createdAt)
        {
            timeLabel.text = "· \(displayDate)"
        } else {
            timeLabel.text = nil
        }
        let destinationFormat = String(localized: "solution.answer.row %@ %lld")
        authorButton.accessibilityLabel = String.localizedStringWithFormat(
            destinationFormat,
            displayName,
            displayFloor
        )
        authorButton.accessibilityHint = String(localized: "solution.answer.jump_hint")

        avatar.layer.cornerRadius = 14
        avatar.backgroundColor = ThemeManager.shared.codeBackgroundColor
        avatar.sd_cancelCurrentImageLoad()
        avatar.image = nil
        if let template = answer.avatarTemplate {
            let sized = template.replacingOccurrences(of: "{size}", with: "96")
            avatar.sd_setImage(
                with: URL(string: sized.hasPrefix("http") ? sized : baseURL + sized),
                context: ImageCacheManager.shared.avatarContext
            )
        }

        clearBody()
        let heights = BlockHeightCalculator.perBlockHeights(
            annotatedBlocks: document.annotatedBlocks,
            config: config
        )
        let views = NativeContentRenderer.renderBlocks(
            document.annotatedBlocks,
            config: config,
            delegate: delegate,
            precomputedBlockHeights: heights
        )
        for view in views {
            bodyStack.addArrangedSubview(view)
            configureTextViews(in: view)
        }

        let hasOverflow = naturalBodyHeight > Self.collapsedBodyHeight + 1
        isExpanded = expanded
        bodyHeightConstraint.constant = expanded
            ? naturalBodyHeight
            : min(naturalBodyHeight, Self.collapsedBodyHeight)
        fadeView.isHidden = expanded || !hasOverflow
        toggleButton.isHidden = !hasOverflow
        toggleButton.isUserInteractionEnabled = hasOverflow
        toggleHeightConstraint.constant = hasOverflow ? Self.toggleHeight : Self.bodyBottomInset
        toggleButton.setTitle(
            expanded
                ? String(localized: "solution.collapse")
                : String(localized: "solution.read_more"),
            for: .normal
        )

        let resolvedBackground = ThemeManager.shared.cardBackgroundColor.resolvedColor(with: traitCollection)
        fadeLayer.colors = [
            resolvedBackground.withAlphaComponent(0).cgColor,
            resolvedBackground.cgColor,
        ]
        fadeLayer.locations = [0, 0.78]
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onSelect = nil
        onExpansionChange = nil
        postDelegate = nil
        answerPostNumber = 0
        isExpanded = false
        avatar.sd_cancelCurrentImageLoad()
        clearBody()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fadeLayer.frame = fadeView.bounds
    }

    private func clearBody() {
        for operation in inlineImageOperations {
            operation.cancel()
        }
        inlineImageOperations.removeAll(keepingCapacity: true)
        for view in bodyStack.arrangedSubviews {
            bodyStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func configureTextViews(in view: UIView) {
        if let textView = view as? UITextView {
            textView.delegate = self
            (textView as? LinkTextView)?.configureSpoilerIfNeeded()
            loadInlineImages(in: textView)
        }
        for subview in view.subviews {
            configureTextViews(in: subview)
        }
    }

    private func loadInlineImages(in textView: UITextView) {
        guard let text = textView.attributedText, text.length > 0 else { return }
        let fullRange = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.cookedHTMLImageURL, in: fullRange) { value, range, _ in
            guard let raw = value as? String, let url = URL(string: raw) else { return }
            let operation = SDWebImageManager.shared.loadImage(
                with: url,
                context: ImageCacheManager.shared.emojiContext,
                progress: nil
            ) { [weak textView] image, _, _, _, _, _ in
                guard let image, let textView else { return }
                for location in range.location..<(range.location + range.length) {
                    guard let attachment = text.attribute(
                        .attachment,
                        at: location,
                        effectiveRange: nil
                    ) as? NSTextAttachment else { continue }
                    attachment.image = image
                    textView.textStorage.edited(
                        .editedAttributes,
                        range: NSRange(location: location, length: 1),
                        changeInLength: 0
                    )
                }
            }
            if let operation {
                inlineImageOperations.append(operation)
            }
        }
    }

    func textView(
        _ textView: UITextView,
        shouldInteractWith url: URL,
        in characterRange: NSRange,
        interaction: UITextItemInteraction
    ) -> Bool {
        postDelegate?.postCell(didTapLinkURL: url)
        return false
    }

    @objc private func authorTapped() {
        onSelect?(answerPostNumber)
    }

    @objc private func toggleTapped() {
        onExpansionChange?(!isExpanded)
    }

    private static func displayDate(_ value: String) -> String? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value) else { return nil }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated
        return relative.localizedString(for: date, relativeTo: Date())
    }
}

final class VirtualPostFooterCell: UICollectionViewCell, UIPopoverPresentationControllerDelegate {
    static let reuseIdentifier = "VirtualPostFooterCell"
    private let solution = UIButton(type: .system)
    private let reply = UIButton(type: .system)
    private let like = UIButton(type: .system)
    private let boost = UIButton(type: .system)
    private let more = UIButton(type: .system)
    private let showReplies = UIButton(type: .system)
    private let currentReactionImageView = UIImageView()
    private let treeContinuationView = VirtualTreeContinuationView()
    private let collapsePill = VirtualTreeCollapsePill()
    private let reactionSummaryView = VirtualPostReactionSummaryView()
    private let separatorLine = UIView()
    private var collapseLeadingConstraint: NSLayoutConstraint!
    private var reactionLeadingConstraint: NSLayoutConstraint!
    private var currentPost: DiscourseTopicDetail.Post?
    private var validReactions: [String] = []
    private var pendingReactionFeedbackSource: ReactionFeedback.CapturedSource?
    var onReply: (() -> Void)?
    var onLike: (() -> Void)?
    var onReaction: ((String) -> Void)?
    var onBoost: (() -> Void)?
    var onCreateBoost: (() -> Void)?
    var onShowReplies: (() -> Void)?
    var onCollapse: (() -> Void)?
    var onSolutionToggle: ((Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        treeContinuationView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(treeContinuationView)
        separatorLine.translatesAutoresizingMaskIntoConstraints = false
        separatorLine.backgroundColor = .separator
        contentView.addSubview(separatorLine)
        solution.setImage(UIImage(systemName: "checkmark.square"), for: .normal)
        reply.setImage(UIImage(systemName: "arrowshape.turn.up.left"), for: .normal)
        like.setImage(UIImage(systemName: "heart"), for: .normal)
        boost.setImage(UIImage(named: "roket.symbols"), for: .normal)
        more.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        solution.accessibilityLabel = String(localized: "solution.accept")
        reply.accessibilityLabel = String(localized: "reply.title")
        like.accessibilityLabel = String(localized: "post.a11y.like")
        boost.accessibilityLabel = String(localized: "post.a11y.boost")
        more.accessibilityLabel = String(localized: "action.more")
        solution.addTarget(self, action: #selector(solutionTapped), for: .touchUpInside)
        reply.addTarget(self, action: #selector(replyTapped), for: .touchUpInside)
        like.addTarget(self, action: #selector(likeTapped), for: .touchUpInside)
        boost.addTarget(self, action: #selector(boostTapped), for: .touchUpInside)
        like.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(likeLongPressed(_:))))
        boost.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(boostLongPressed(_:))))
        more.showsMenuAsPrimaryAction = true
        let stack = UIStackView(arrangedSubviews: [solution, boost, like, reply, more])
        stack.axis = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        reactionSummaryView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(reactionSummaryView)
        showReplies.translatesAutoresizingMaskIntoConstraints = false
        showReplies.titleLabel?.font = FontManager.shared.font(size: 12)
        showReplies.setTitleColor(.secondaryLabel, for: .normal)
        showReplies.addTarget(self, action: #selector(showRepliesTapped), for: .touchUpInside)
        contentView.addSubview(showReplies)
        currentReactionImageView.translatesAutoresizingMaskIntoConstraints = false
        currentReactionImageView.contentMode = .scaleAspectFit
        currentReactionImageView.isUserInteractionEnabled = false
        currentReactionImageView.isHidden = true
        like.addSubview(currentReactionImageView)
        collapsePill.addTarget(self, action: #selector(collapseTapped), for: .touchUpInside)
        contentView.addSubview(collapsePill)
        collapseLeadingConstraint = collapsePill.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        reactionLeadingConstraint = reactionSummaryView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        NSLayoutConstraint.activate([
            treeContinuationView.topAnchor.constraint(equalTo: contentView.topAnchor),
            treeContinuationView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            treeContinuationView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            treeContinuationView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            reactionLeadingConstraint,
            reactionSummaryView.centerYAnchor.constraint(equalTo: stack.centerYAnchor),
            showReplies.leadingAnchor.constraint(equalTo: reactionSummaryView.trailingAnchor, constant: 8),
            showReplies.centerYAnchor.constraint(equalTo: stack.centerYAnchor),
            showReplies.trailingAnchor.constraint(lessThanOrEqualTo: stack.leadingAnchor, constant: -8),
            currentReactionImageView.centerXAnchor.constraint(equalTo: like.centerXAnchor),
            currentReactionImageView.centerYAnchor.constraint(equalTo: like.centerYAnchor),
            currentReactionImageView.widthAnchor.constraint(equalToConstant: 20),
            currentReactionImageView.heightAnchor.constraint(equalToConstant: 20),
            separatorLine.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            separatorLine.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separatorLine.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            separatorLine.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),
            collapseLeadingConstraint,
            collapsePill.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -VirtualTreeCollapsePill.bottomInset),
            collapsePill.widthAnchor.constraint(equalToConstant: VirtualTreeCollapsePill.size),
            collapsePill.heightAnchor.constraint(equalToConstant: VirtualTreeCollapsePill.size),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(
        post: DiscourseTopicDetail.Post,
        menu: UIMenu,
        validReactions: [String] = [],
        hidesLikeButton: Bool,
        treeState: TreeLineState?,
        isLastVisualItem: Bool,
        showsSeparator: Bool
    ) {
        backgroundColor = ThemeManager.shared.cardBackgroundColor
        contentView.backgroundColor = ThemeManager.shared.cardBackgroundColor
        currentPost = post
        self.validReactions = validReactions
        separatorLine.backgroundColor = .separator
        reactionLeadingConstraint.constant = VirtualPostFooterLayout.reactionLeading(for: treeState)
        reactionSummaryView.configure(reactions: post.reactions, count: post.reactionUsersCount)
        reply.isHidden = false
        more.isHidden = false
        let canUnacceptSolution =
            post.acceptedAnswer && (post.canUnacceptAnswer || post.canAcceptAnswer)
        let canAcceptSolution =
            !post.acceptedAnswer && post.canAcceptAnswer && !post.topicAcceptedAnswer
        solution.isHidden = !(post.acceptedAnswer || canAcceptSolution)
        solution.isEnabled = true
        solution.isUserInteractionEnabled = canAcceptSolution || canUnacceptSolution
        solution.setImage(
            UIImage(systemName: post.acceptedAnswer ? "checkmark.square.fill" : "checkmark.square"),
            for: .normal
        )
        solution.tintColor = post.acceptedAnswer
            ? ThemeManager.shared.accentColor
            : .secondaryLabel
        solution.accessibilityLabel = String(
            localized: canUnacceptSolution ? "solution.unaccept" : (
                post.acceptedAnswer ? "solution.accepted" : "solution.accept"
            )
        )
        solution.accessibilityTraits =
            (canAcceptSolution || canUnacceptSolution) ? .button : .staticText
        let liked = post.likeAction?.acted == true
        let reactionsPluginActive = !validReactions.isEmpty
        let canAct = post.likeAction?.canAct == true
        let buttonTints = VirtualPostFooterButtonTints.resolve(
            isLiked: liked && !reactionsPluginActive,
            hasCurrentUserBoost: post.boosts.contains { $0.canDelete == true }
        )
        like.setImage(UIImage(systemName: liked && !reactionsPluginActive ? "heart.fill" : "heart"), for: .normal)
        applyButtonTints(buttonTints)
        configureCurrentReaction(post.currentUserReaction, pluginActive: reactionsPluginActive)
        like.isEnabled = reactionsPluginActive || canAct || liked
        like.isHidden = hidesLikeButton || (!reactionsPluginActive && !canAct && !liked)
        like.accessibilityValue = post.likeCount > 0 ? "\(post.likeCount)" : nil
        boost.isHidden = !post.canBoost && post.boosts.isEmpty
        boost.isEnabled = post.canBoost || !post.boosts.isEmpty
        boost.setTitle(post.boosts.isEmpty ? nil : " \(post.boosts.count)", for: .normal)
        boost.accessibilityValue = post.boosts.isEmpty ? nil : "\(post.boosts.count)"
        let showsReplyCount = post.replyCount > 0 && treeState == nil
        showReplies.isHidden = !showsReplyCount
        showReplies.setTitle(
            showsReplyCount ? String(localized: "post.replies \(post.replyCount)") : nil,
            for: .normal
        )
        more.menu = menu
        treeContinuationView.configure(state: treeState)
        collapseLeadingConstraint.constant = collapsePill.configure(
            state: treeState,
            isLastVisualItem: isLastVisualItem
        ) ?? 0
        separatorLine.isHidden = !showsSeparator
        if post.deletedPostPlaceholder {
            for button in [solution, reply, like, boost, more, showReplies] { button.isHidden = true }
            reactionSummaryView.reset()
        }
    }

    var appliedButtonTints: VirtualPostFooterButtonTints {
        VirtualPostFooterButtonTints(
            reply: reply.tintColor,
            like: like.tintColor,
            boost: boost.tintColor,
            more: more.tintColor
        )
    }

    var moreMenuSourceView: UIView { more }

    func applyButtonTints(_ tints: VirtualPostFooterButtonTints) {
        reply.tintColor = tints.reply
        like.tintColor = tints.like
        boost.tintColor = tints.boost
        more.tintColor = tints.more
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onReply = nil
        onLike = nil
        onReaction = nil
        onBoost = nil
        onCreateBoost = nil
        onShowReplies = nil
        onCollapse = nil
        onSolutionToggle = nil
        more.menu = nil
        reactionSummaryView.reset()
        currentReactionImageView.sd_cancelCurrentImageLoad()
        currentReactionImageView.image = nil
        currentReactionImageView.isHidden = true
        currentPost = nil
        validReactions = []
        pendingReactionFeedbackSource = nil
        collapsePill.configure(state: nil, isLastVisualItem: false)
    }

    @objc private func replyTapped() { onReply?() }

    @objc private func solutionTapped() {
        guard let post = currentPost else { return }
        let accepting = !post.acceptedAnswer
        solution.isEnabled = false
        onSolutionToggle?(accepting)
    }

    func playReactionSuccessFeedback(animated: Bool) {
        guard animated else {
            pendingReactionFeedbackSource = nil
            return
        }
        if let source = pendingReactionFeedbackSource {
            pendingReactionFeedbackSource = nil
            ReactionFeedback.play(captured: source, to: reactionSummaryView)
        } else {
            ReactionFeedback.play(from: like, to: reactionSummaryView)
        }
    }

    func playReactionDestinationFeedback() {
        if reactionSummaryView.isHidden {
            ReactionFeedback.confirm(on: like)
        } else {
            reactionSummaryView.playSuccessConfirmation()
        }
    }

    @objc private func likeTapped() {
        guard let post = currentPost else { return }
        pendingReactionFeedbackSource = nil
        let action = VirtualPostReactionActionResolver.resolve(
            hasPlugin: !validReactions.isEmpty,
            currentReactionId: post.currentUserReaction?.id,
            currentReactionCanUndo: post.currentUserReaction?.canUndo,
            isLiked: post.isLikedByCurrentUser,
            likeCanUndo: post.likeAction?.canUndo
        )
        switch action {
        case .toggleLike: onLike?()
        case .toggleReaction(let reaction): onReaction?(reaction)
        case .showPicker: presentReactionPicker()
        case .none: break
        }
    }
    @objc private func boostTapped() { onBoost?() }
    @objc private func showRepliesTapped() { onShowReplies?() }
    @objc private func collapseTapped() { onCollapse?() }

    @objc private func likeLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, like.isEnabled else { return }
        pendingReactionFeedbackSource = nil
        if validReactions.isEmpty { likeTapped() } else { presentReactionPicker() }
    }

    @objc private func boostLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        onCreateBoost?()
    }

    private func configureCurrentReaction(_ reaction: DiscourseTopicDetail.Reaction?, pluginActive: Bool) {
        currentReactionImageView.sd_cancelCurrentImageLoad()
        currentReactionImageView.image = nil
        currentReactionImageView.isHidden = true
        guard pluginActive, let reaction,
              let urlString = EmojiStore.url(for: reaction.id) ?? EmojiStore.lookup(for: reaction.id),
              let url = URL(string: urlString)
        else { return }
        like.tintColor = .clear
        currentReactionImageView.isHidden = false
        currentReactionImageView.sd_setImage(with: url, context: ImageCacheManager.shared.emojiContext)
    }

    private func presentReactionPicker() {
        guard !validReactions.isEmpty else { return }
        let picker = VirtualReactionPickerViewController(reactions: validReactions) { [weak self] reaction, sourceButton in
            self?.pendingReactionFeedbackSource = ReactionFeedback.capture(sourceButton)
            self?.onReaction?(reaction)
        }
        picker.modalPresentationStyle = .popover
        if let popover = picker.popoverPresentationController {
            popover.sourceView = like
            popover.sourceRect = like.bounds
            popover.permittedArrowDirections = [.up, .down]
            popover.backgroundColor = .clear
            popover.delegate = self
        }
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let controller = next as? UIViewController {
                controller.present(picker, animated: true)
                return
            }
            responder = next
        }
    }

    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle { .none }
}

final class VirtualTopicMessageCell: UICollectionViewCell {
    static let reuseIdentifier = "VirtualTopicMessageCell"
    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = FontManager.shared.font(size: 13, weight: .medium)
        label.textColor = .secondaryLabel
        label.numberOfLines = 2
        spinner.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(spinner)
        contentView.addSubview(label)
        contentView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        NSLayoutConstraint.activate([
            spinner.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 16),
            spinner.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor, constant: 12),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func configure(text: String, isLoading: Bool = false) {
        backgroundColor = ThemeManager.shared.cardBackgroundColor
        contentView.backgroundColor = ThemeManager.shared.cardBackgroundColor
        label.text = text
        isUserInteractionEnabled = !isLoading
        accessibilityTraits = isLoading ? [] : .button
        if isLoading { spinner.startAnimating() } else { spinner.stopAnimating() }
    }
    override func prepareForReuse() {
        super.prepareForReuse()
        onTap = nil
        spinner.stopAnimating()
        isUserInteractionEnabled = true
    }
    @objc private func tapped() { onTap?() }
}

final class VirtualPostCollapsedCell: UICollectionViewCell {
    static let reuseIdentifier = "VirtualPostCollapsedCell"

    private let treeLineView = TreeLineView()
    private let avatar = UIImageView()
    private let expandButton = UIButton(type: .system)
    private let summaryLabel = UILabel()
    private var avatarLeadingConstraint: NSLayoutConstraint!
    private var postId = 0
    var onExpand: ((Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        treeLineView.translatesAutoresizingMaskIntoConstraints = false
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.contentMode = .scaleAspectFill
        avatar.clipsToBounds = true
        avatar.backgroundColor = .secondarySystemFill
        avatar.isUserInteractionEnabled = true
        avatar.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(expandTapped)))

        expandButton.translatesAutoresizingMaskIntoConstraints = false
        expandButton.backgroundColor = .clear
        expandButton.layer.cornerRadius = 9
        expandButton.layer.borderWidth = 1
        expandButton.tintColor = .secondaryLabel
        expandButton.setImage(UIImage(systemName: "plus"), for: .normal)
        expandButton.setPreferredSymbolConfiguration(.init(pointSize: 9, weight: .bold), forImageIn: .normal)
        expandButton.accessibilityLabel = String(localized: "topic_detail.expand")
        expandButton.addTarget(self, action: #selector(expandTapped), for: .touchUpInside)

        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.font = FontManager.shared.font(size: 13, weight: .medium)
        summaryLabel.textColor = .secondaryLabel
        summaryLabel.lineBreakMode = .byTruncatingTail

        contentView.addSubview(treeLineView)
        contentView.addSubview(avatar)
        contentView.addSubview(expandButton)
        contentView.addSubview(summaryLabel)
        avatarLeadingConstraint = avatar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12)
        NSLayoutConstraint.activate([
            treeLineView.topAnchor.constraint(equalTo: contentView.topAnchor),
            treeLineView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            treeLineView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            treeLineView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            avatarLeadingConstraint,
            avatar.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 32),
            avatar.heightAnchor.constraint(equalToConstant: 32),
            expandButton.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 8),
            expandButton.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
            expandButton.widthAnchor.constraint(equalToConstant: 18),
            expandButton.heightAnchor.constraint(equalToConstant: 18),
            summaryLabel.leadingAnchor.constraint(equalTo: expandButton.trailingAnchor, constant: 8),
            summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -12),
            summaryLabel.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(post: DiscourseTopicDetail.Post, depth: Int, treeState: TreeLineState?, baseURL: String) {
        backgroundColor = ThemeManager.shared.cardBackgroundColor
        contentView.backgroundColor = ThemeManager.shared.cardBackgroundColor
        postId = post.id
        avatarLeadingConstraint.constant = 12 + PostNativeCell.treeAvatarIndent(forDepth: depth)
        let format = String(localized: "topic_detail.collapsed_summary %@ %lld")
        summaryLabel.text = String.localizedStringWithFormat(format, post.name ?? post.username, post.replyCount)
        expandButton.layer.borderColor = UIColor.separator.cgColor

        if let treeState, treeState.depth >= 2 {
            treeLineView.isHidden = false
            treeLineView.state = treeState
            treeLineView.connectorY = PostCollapsedCell.cellHeight / 2
            treeLineView.avatarBottomY = (PostCollapsedCell.cellHeight + 32) / 2
            treeLineView.lineColor = .separator
        } else {
            treeLineView.isHidden = true
            treeLineView.state = nil
        }
        if let template = post.avatarTemplate {
            let path = template.replacingOccurrences(of: "{size}", with: "96")
            avatar.sd_setImage(with: URL(string: path.hasPrefix("http") ? path : baseURL + path), context: ImageCacheManager.shared.avatarContext)
        } else {
            avatar.image = nil
        }
        avatar.layer.cornerRadius = 16
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        avatar.sd_cancelCurrentImageLoad()
        avatar.image = nil
        postId = 0
        onExpand = nil
    }

    @objc private func expandTapped() { onExpand?(postId) }
}

final class VirtualBlockedPostCell: UICollectionViewCell {
    static let reuseIdentifier = "VirtualBlockedPostCell"
    static let cellHeight: CGFloat = 64

    private let treeLineView = TreeLineView()
    private let hiddenIcon = UIImageView(image: UIImage(systemName: "eye.slash"))
    private let summaryLabel = UILabel()
    private let unblockButton = UIButton(type: .system)
    private var iconLeadingConstraint: NSLayoutConstraint!
    var onUnblock: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        treeLineView.translatesAutoresizingMaskIntoConstraints = false

        hiddenIcon.translatesAutoresizingMaskIntoConstraints = false
        hiddenIcon.contentMode = .scaleAspectFit
        hiddenIcon.setContentCompressionResistancePriority(.required, for: .horizontal)

        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.font = FontManager.shared.font(size: 13, weight: .medium)
        summaryLabel.textColor = .secondaryLabel
        summaryLabel.lineBreakMode = .byTruncatingTail

        unblockButton.translatesAutoresizingMaskIntoConstraints = false
        unblockButton.setTitle(String(localized: "user.local_unblock"), for: .normal)
        unblockButton.titleLabel?.font = FontManager.shared.font(size: 13, weight: .medium)
        unblockButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        unblockButton.addTarget(self, action: #selector(unblockTapped), for: .touchUpInside)

        contentView.addSubview(treeLineView)
        contentView.addSubview(hiddenIcon)
        contentView.addSubview(summaryLabel)
        contentView.addSubview(unblockButton)
        iconLeadingConstraint = hiddenIcon.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12)

        NSLayoutConstraint.activate([
            treeLineView.topAnchor.constraint(equalTo: contentView.topAnchor),
            treeLineView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            treeLineView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            treeLineView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            iconLeadingConstraint,
            hiddenIcon.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            hiddenIcon.widthAnchor.constraint(equalToConstant: 24),
            hiddenIcon.heightAnchor.constraint(equalToConstant: 24),
            summaryLabel.leadingAnchor.constraint(equalTo: hiddenIcon.trailingAnchor, constant: 8),
            summaryLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            unblockButton.leadingAnchor.constraint(greaterThanOrEqualTo: summaryLabel.trailingAnchor, constant: 8),
            unblockButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            unblockButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(username: String, depth: Int, treeState: TreeLineState?) {
        let theme = ThemeManager.shared
        backgroundColor = theme.cardBackgroundColor
        contentView.backgroundColor = theme.cardBackgroundColor
        hiddenIcon.tintColor = theme.accentColor
        unblockButton.tintColor = theme.accentColor
        iconLeadingConstraint.constant = 12 + PostNativeCell.treeAvatarIndent(forDepth: depth)
        summaryLabel.text = String(localized: "topic_detail.local_blocked_post \(username)")
        accessibilityLabel = summaryLabel.text

        if let treeState, treeState.depth >= 2 {
            treeLineView.isHidden = false
            treeLineView.state = treeState
            treeLineView.connectorY = Self.cellHeight / 2
            treeLineView.avatarBottomY = (Self.cellHeight + 24) / 2
            treeLineView.lineColor = theme.quoteBarColor
        } else {
            treeLineView.isHidden = true
            treeLineView.state = nil
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onUnblock = nil
        summaryLabel.text = nil
        treeLineView.state = nil
    }

    @objc private func unblockTapped() { onUnblock?() }
}

final class VirtualLoadMoreChildrenCell: UICollectionViewCell {
    static let reuseIdentifier = "VirtualLoadMoreChildrenCell"

    private let treeLineView = TreeLineView()
    private let glyph = UIImageView(image: UIImage(systemName: "arrow.turn.down.right"))
    private let titleLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var glyphLeadingConstraint: NSLayoutConstraint!
    private var parentPostId = 0
    var onLoad: ((Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        treeLineView.translatesAutoresizingMaskIntoConstraints = false
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.contentMode = .center
        glyph.preferredSymbolConfiguration = .init(pointSize: 12, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = FontManager.shared.font(size: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true

        contentView.addSubview(treeLineView)
        contentView.addSubview(glyph)
        contentView.addSubview(titleLabel)
        contentView.addSubview(spinner)
        contentView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(loadTapped)))
        glyphLeadingConstraint = glyph.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12)
        NSLayoutConstraint.activate([
            treeLineView.topAnchor.constraint(equalTo: contentView.topAnchor),
            treeLineView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            treeLineView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            treeLineView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            glyphLeadingConstraint,
            glyph.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 18),
            glyph.heightAnchor.constraint(equalToConstant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -12),
            titleLabel.centerYAnchor.constraint(equalTo: glyph.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: glyph.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: glyph.centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(load: PendingChildLoad, isLoading: Bool) {
        backgroundColor = ThemeManager.shared.cardBackgroundColor
        contentView.backgroundColor = ThemeManager.shared.cardBackgroundColor
        parentPostId = load.parentPostId
        glyphLeadingConstraint.constant = 12 + PostNativeCell.treeAvatarIndent(forDepth: load.depth)
        let format = String(localized: "topic_detail.view_more_replies %lld")
        titleLabel.text = String.localizedStringWithFormat(format, load.remaining)
        titleLabel.textColor = ThemeManager.shared.accentColor
        glyph.tintColor = ThemeManager.shared.accentColor
        treeLineView.state = load.treeLineState
        treeLineView.connectorY = LoadMoreChildrenCell.cellHeight / 2
        treeLineView.avatarBottomY = LoadMoreChildrenCell.cellHeight
        treeLineView.lineColor = .separator
        treeLineView.isHidden = load.treeLineState.depth < 2
        setLoading(isLoading)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        parentPostId = 0
        onLoad = nil
        setLoading(false)
    }

    private func setLoading(_ loading: Bool) {
        if loading { spinner.startAnimating() } else { spinner.stopAnimating() }
        glyph.isHidden = loading
        titleLabel.alpha = loading ? 0.5 : 1
    }

    @objc private func loadTapped() {
        guard !spinner.isAnimating else { return }
        setLoading(true)
        onLoad?(parentPostId)
    }
}

final class VirtualBoostsCell: UICollectionViewCell {
    static let reuseIdentifier = "VirtualBoostsCell"

    private let hostedCell = BoostCell(style: .default, reuseIdentifier: nil)
    private let treeContinuationView = VirtualTreeContinuationView()
    private let collapsePill = VirtualTreeCollapsePill()
    private var hostedLeadingConstraint: NSLayoutConstraint!
    private var collapseLeadingConstraint: NSLayoutConstraint!
    var onCollapse: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        treeContinuationView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(treeContinuationView)
        hostedCell.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(hostedCell)
        collapsePill.addTarget(self, action: #selector(collapseTapped), for: .touchUpInside)
        contentView.addSubview(collapsePill)
        hostedLeadingConstraint = hostedCell.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        collapseLeadingConstraint = collapsePill.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        NSLayoutConstraint.activate([
            treeContinuationView.topAnchor.constraint(equalTo: contentView.topAnchor),
            treeContinuationView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            treeContinuationView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            treeContinuationView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            hostedCell.topAnchor.constraint(equalTo: contentView.topAnchor),
            hostedLeadingConstraint,
            hostedCell.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            hostedCell.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            collapseLeadingConstraint,
            collapsePill.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -VirtualTreeCollapsePill.bottomInset),
            collapsePill.widthAnchor.constraint(equalToConstant: VirtualTreeCollapsePill.size),
            collapsePill.heightAnchor.constraint(equalToConstant: VirtualTreeCollapsePill.size),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(
        post: DiscourseTopicDetail.Post,
        delegate: PostCellDelegate?,
        assetBaseURL: String,
        contentWidth: CGFloat,
        leadingIndent: CGFloat,
        treeState: TreeLineState?,
        showsSeparator: Bool
    ) {
        backgroundColor = ThemeManager.shared.cardBackgroundColor
        contentView.backgroundColor = ThemeManager.shared.cardBackgroundColor
        hostedLeadingConstraint.constant = leadingIndent
        treeContinuationView.configure(state: treeState)
        collapseLeadingConstraint.constant = collapsePill.configure(
            state: treeState,
            isLastVisualItem: true
        ) ?? 0
        hostedCell.configure(
            post: post,
            delegate: delegate,
            assetBaseURL: assetBaseURL,
            contentWidth: max(1, contentWidth - 24 - leadingIndent),
            showsSeparator: showsSeparator
        )
        setNeedsLayout()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onCollapse = nil
        collapsePill.configure(state: nil, isLastVisualItem: false)
    }

    @objc private func collapseTapped() { onCollapse?() }
}
