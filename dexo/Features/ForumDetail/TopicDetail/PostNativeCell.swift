import CookedHTML
import SDWebImage
import UIKit

final class PostNativeCell: UITableViewCell {
    static let reuseIdentifier = "PostNativeCell"
    static let headerHeight: CGFloat = 44
    static let bottomBarHeight: CGFloat = 30
    /// Baseline chrome height wrapping the content stack, for callers that
    /// precompute `heightForRowAt` instead of going through
    /// `systemLayoutSizeFitting`. Mirrors the top/bottom constraint constants
    /// in `setupViews`: 12 (top) + avatar + 12 (gap) on top, 10 + bottomBar +
    /// 6 + 1 (separator) on bottom.
    static func chromeHeight() -> CGFloat {
        let avatarSize = FontManager.shared.scaled(baseAvatarSize)
        return 24 + avatarSize + 17 + bottomBarHeight
    }
    private static let symbolConfig = UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)

    // Pre-rendered fallback images so the hot configure / prepareForReuse paths
    // don't re-allocate them on every cell reuse.
    private static let heartImage = UIImage(systemName: "heart", withConfiguration: symbolConfig)
    private static let heartFillImage = UIImage(systemName: "heart.fill", withConfiguration: symbolConfig)
    private static let boostFallbackImage = UIImage(named: "roket.symbols", in: nil, with: symbolConfig)

    /// Pre-rendered OP badge image with rounded corners (cached once).
    private static let opBadgeImage: UIImage = {
        let text = "OP"
        let font = FontManager.shared.font(size: 10, weight: .bold)
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let padding = UIEdgeInsets(top: 1.5, left: 4, bottom: 1.5, right: 4)
        let size = CGSize(
            width: ceil(textSize.width + padding.left + padding.right),
            height: ceil(textSize.height + padding.top + padding.bottom)
        )
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let rect = CGRect(origin: .zero, size: size)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 3)
            UIColor.systemBlue.setFill()
            path.fill()
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            text.draw(in: rect.inset(by: padding), withAttributes: [
                .font: font,
                .foregroundColor: UIColor.white,
                .paragraphStyle: style,
            ])
        }
    }()

    weak var delegate: PostCellDelegate?
    private(set) var postId: Int = 0
    /// Tracks which post's content views are currently rendered in contentStackView.
    /// Kept separate from `postId` so prepareForReuse can reset metadata without
    /// forcing a full content rebuild on the next configure call.
    private var renderedContentPostId: Int = 0
    private var postLink: String?
    private var currentPost: DiscourseTopicDetail.Post?
    private var validReactions: [String] = []

    // MARK: - Header UI

    private static let baseAvatarSize: CGFloat = 32
    private static let baseFlairSize: CGFloat = 14
    private var avatarWidthConstraint: NSLayoutConstraint!
    private var avatarHeightConstraint: NSLayoutConstraint!
    private var flairWidthConstraint: NSLayoutConstraint!
    private var flairHeightConstraint: NSLayoutConstraint!
    private var avatarLeadingConstraint: NSLayoutConstraint!
    private var nameLeadingConstraint: NSLayoutConstraint!
    private var usernameLeadingConstraint: NSLayoutConstraint!
    private var contentLeadingConstraint: NSLayoutConstraint!
    private var bottomLeftLeadingConstraint: NSLayoutConstraint!

    private let threadLineView: UIView = {
        let view = UIView()
        view.backgroundColor = .separator
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        return view
    }()

    private let avatarImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.backgroundColor = .secondarySystemFill
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let flairImageView: SDAnimatedImageView = {
        let iv = SDAnimatedImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.layer.borderWidth = 1
        iv.layer.borderColor = UIColor.systemBackground.cgColor
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.isHidden = true
        iv.autoPlayAnimatedImage = true
        // Bound the per-view animation buffer so a 512×512 multi-frame flair
        // can't pin its full decoded set in RAM. SDAnimatedImage decodes
        // frames lazily; with a small cap it keeps only the active + a
        // couple buffered frames and re-decodes the rest on demand. CPU
        // hit is negligible for a 14pt badge; memory stays bounded
        // regardless of source resolution.
        iv.maxBufferSize = 1 * 1024 * 1024
        // Free the decoded buffer when offscreen / cell is reused.
        iv.clearBufferWhenStopped = true
        return iv
    }()

    private let nameLabel: UILabel = {
        let label = UILabel()
        label.font = FontManager.shared.font(size: 14, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let usernameLabel: UILabel = {
        let label = UILabel()
        label.font = FontManager.shared.font(size: 12)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let userTitleLabel: UILabel = {
        let label = UILabel()
        label.font = FontManager.shared.font(size: 12)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
        return label
    }()

    private let timeLabel: UILabel = {
        let label = UILabel()
        label.font = FontManager.shared.font(size: 12)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let floorLabel: UILabel = {
        let label = UILabel()
        label.font = FontManager.shared.monospacedDigitFont(size: 12)
        label.textColor = .tertiaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()


    private let replyToLabel: UILabel = {
        let label = UILabel()
        label.font = FontManager.shared.font(size: 12)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
        label.isUserInteractionEnabled = true
        return label
    }()

    // MARK: - Content

    private let contentStackView: UIStackView = {
        let sv = UIStackView()
        sv.axis = .vertical
        sv.spacing = NativeContentRenderer.contentStackSpacing
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    // MARK: - Bottom Bar

    private let showRepliesButton: UIButton = {
        let button = UIButton(type: .system)
        button.titleLabel?.font = FontManager.shared.font(size: 12, weight: .medium)
        button.tintColor = .secondaryLabel
        button.contentHorizontalAlignment = .leading
        button.isHidden = true
        return button
    }()

    private let reactionStackView: UIStackView = {
        let sv = UIStackView()
        sv.axis = .horizontal
        sv.spacing = 2
        sv.alignment = .center
        sv.isHidden = true
        return sv
    }()

    // Pre-created reaction views to avoid alloc/dealloc churn during scroll
    private let reactionImageViews: [UIImageView] = (0 ..< 3).map { _ in
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iv.widthAnchor.constraint(equalToConstant: 16),
            iv.heightAnchor.constraint(equalToConstant: 16),
        ])
        return iv
    }

    private let reactionCountLabel: UILabel = {
        let label = UILabel()
        label.font = FontManager.shared.font(size: 12)
        label.textColor = .secondaryLabel
        return label
    }()

    private let bottomLeftStack: UIStackView = {
        let sv = UIStackView()
        sv.axis = .horizontal
        sv.spacing = 4
        sv.alignment = .center
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    private let reactButton: UIButton = {
        let button = UIButton(type: .system)
        let config = PostNativeCell.symbolConfig
        button.setImage(UIImage(systemName: "heart", withConfiguration: config), for: .normal)
        button.titleLabel?.font = FontManager.shared.monospacedDigitFont(size: 11, weight: .medium)
        button.tintColor = .tertiaryLabel
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    /// Overlay shown on top of the heart symbol when the user has a current
    /// reaction. Constrained to a fixed size so a large source emoji image
    /// can't bloat the button frame and shove sibling buttons (boost) around.
    private let userReactionImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.isUserInteractionEnabled = false
        iv.isHidden = true
        return iv
    }()

    private let boostButton: UIButton = {
        let button = UIButton(type: .system)
        button.titleLabel?.font = FontManager.shared.monospacedDigitFont(size: 11, weight: .medium)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let moreButton: UIButton = {
        let button = UIButton(type: .system)
        let config = PostNativeCell.symbolConfig
        button.setImage(UIImage(systemName: "ellipsis", withConfiguration: config), for: .normal)
        button.tintColor = .tertiaryLabel
        button.translatesAutoresizingMaskIntoConstraints = false
        button.showsMenuAsPrimaryAction = true
        return button
    }()

    private let replyButton: UIButton = {
        let button = UIButton(type: .system)
        let config = PostNativeCell.symbolConfig
        button.setImage(UIImage(systemName: "arrowshape.turn.up.left", withConfiguration: config), for: .normal)
        button.tintColor = .tertiaryLabel
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let separatorLine: UIView = {
        let view = UIView()
        view.backgroundColor = .separator
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        let t0 = CACurrentMediaTime()
        super.layoutSubviews()
        let ms = (CACurrentMediaTime() - t0) * 1000
        if ms > 3 { FrameDropDetector.shared.log("layoutSubviews post#\(postId) \(String(format: "%.1f", ms))ms") }
    }

    override func systemLayoutSizeFitting(_ targetSize: CGSize, withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority, verticalFittingPriority: UILayoutPriority) -> CGSize {
        let t0 = CACurrentMediaTime()
        let size = super.systemLayoutSizeFitting(targetSize, withHorizontalFittingPriority: horizontalFittingPriority, verticalFittingPriority: verticalFittingPriority)
        let ms = (CACurrentMediaTime() - t0) * 1000
        if ms > 1 { debugLog("sizeFitting post#\(postId) \(String(format: "%.1f", ms))ms → h=\(String(format: "%.0f", size.height))") }
        return size
    }

    private func setupViews() {
        contentView.addSubview(avatarImageView)
        contentView.addSubview(threadLineView)
        contentView.addSubview(flairImageView)
        contentView.addSubview(nameLabel)
        contentView.addSubview(usernameLabel)
        contentView.addSubview(userTitleLabel)
        contentView.addSubview(timeLabel)
        contentView.addSubview(floorLabel)
        contentView.addSubview(replyToLabel)
        contentView.addSubview(contentStackView)
        bottomLeftStack.addArrangedSubview(showRepliesButton)
        for iv in reactionImageViews {
            reactionStackView.addArrangedSubview(iv)
            iv.isHidden = true
        }
        reactionStackView.addArrangedSubview(reactionCountLabel)
        reactionCountLabel.isHidden = true
        bottomLeftStack.addArrangedSubview(reactionStackView)
        contentView.addSubview(bottomLeftStack)
        contentView.addSubview(reactButton)
        reactButton.addSubview(userReactionImageView)
        contentView.addSubview(boostButton)
        contentView.addSubview(moreButton)
        contentView.addSubview(replyButton)
        contentView.addSubview(separatorLine)

        replyButton.accessibilityLabel = String(localized: "reply.title")
        moreButton.accessibilityLabel = String(localized: "action.more")
        reactButton.accessibilityLabel = String(localized: "post.a11y.like")
        boostButton.accessibilityLabel = String(localized: "post.a11y.boost")

        avatarWidthConstraint = avatarImageView.widthAnchor.constraint(equalToConstant: Self.baseAvatarSize)
        avatarHeightConstraint = avatarImageView.heightAnchor.constraint(equalToConstant: Self.baseAvatarSize)
        flairWidthConstraint = flairImageView.widthAnchor.constraint(equalToConstant: Self.baseFlairSize)
        flairHeightConstraint = flairImageView.heightAnchor.constraint(equalToConstant: Self.baseFlairSize)
        avatarLeadingConstraint = avatarImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12)
        nameLeadingConstraint = nameLabel.leadingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 8)
        usernameLeadingConstraint = usernameLabel.leadingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 8)
        contentLeadingConstraint = contentStackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12)
        bottomLeftLeadingConstraint = bottomLeftStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16)

        NSLayoutConstraint.activate([
            avatarImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            avatarLeadingConstraint,
            avatarWidthConstraint,
            avatarHeightConstraint,

            threadLineView.topAnchor.constraint(equalTo: avatarImageView.bottomAnchor, constant: 4),
            threadLineView.centerXAnchor.constraint(equalTo: avatarImageView.centerXAnchor),
            threadLineView.bottomAnchor.constraint(equalTo: separatorLine.topAnchor),
            threadLineView.widthAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),

            flairImageView.bottomAnchor.constraint(equalTo: avatarImageView.bottomAnchor, constant: 2),
            flairImageView.trailingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 2),
            flairWidthConstraint,
            flairHeightConstraint,

            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            nameLeadingConstraint,

            usernameLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor),
            usernameLeadingConstraint,

            userTitleLabel.lastBaselineAnchor.constraint(equalTo: nameLabel.lastBaselineAnchor),
            userTitleLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 4),
            userTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: replyToLabel.leadingAnchor, constant: -8),

            replyToLabel.centerYAnchor.constraint(equalTo: floorLabel.centerYAnchor),
            replyToLabel.trailingAnchor.constraint(equalTo: floorLabel.leadingAnchor, constant: -8),

            floorLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            floorLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            timeLabel.topAnchor.constraint(equalTo: floorLabel.bottomAnchor, constant: 2),
            timeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            contentStackView.topAnchor.constraint(equalTo: avatarImageView.bottomAnchor, constant: 12),
            contentLeadingConstraint,
            contentStackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),

            bottomLeftStack.topAnchor.constraint(equalTo: contentStackView.bottomAnchor, constant: 10),
            bottomLeftLeadingConstraint,
            bottomLeftStack.heightAnchor.constraint(equalToConstant: Self.bottomBarHeight),

            moreButton.topAnchor.constraint(equalTo: contentStackView.bottomAnchor, constant: 10),
            moreButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            moreButton.heightAnchor.constraint(equalToConstant: Self.bottomBarHeight),
            moreButton.widthAnchor.constraint(equalToConstant: 28),
            { let c = moreButton.bottomAnchor.constraint(equalTo: separatorLine.topAnchor, constant: -6); c.priority = .init(999); return c }(),

            replyButton.topAnchor.constraint(equalTo: contentStackView.bottomAnchor, constant: 10),
            replyButton.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor),
            replyButton.heightAnchor.constraint(equalToConstant: Self.bottomBarHeight),
            replyButton.widthAnchor.constraint(equalToConstant: 28),

            reactButton.topAnchor.constraint(equalTo: contentStackView.bottomAnchor, constant: 10),
            reactButton.trailingAnchor.constraint(equalTo: boostButton.leadingAnchor),
            reactButton.heightAnchor.constraint(equalToConstant: Self.bottomBarHeight),
            // Match the visual rhythm of the other 28pt buttons; allow growth
            // so the like count " N" still fits when no reactions plugin.
            reactButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 28),

            userReactionImageView.widthAnchor.constraint(equalToConstant: 14),
            userReactionImageView.heightAnchor.constraint(equalToConstant: 14),
            userReactionImageView.centerYAnchor.constraint(equalTo: reactButton.centerYAnchor),
            // Centered like the heart symbol so the swap looks in-place.
            userReactionImageView.centerXAnchor.constraint(equalTo: reactButton.centerXAnchor),

            boostButton.topAnchor.constraint(equalTo: contentStackView.bottomAnchor, constant: 10),
            boostButton.trailingAnchor.constraint(equalTo: replyButton.leadingAnchor),
            boostButton.heightAnchor.constraint(equalToConstant: Self.bottomBarHeight),

            separatorLine.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            separatorLine.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separatorLine.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            separatorLine.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),
        ])

        showRepliesButton.addTarget(self, action: #selector(repliesButtonTapped), for: .touchUpInside)
        replyButton.addTarget(self, action: #selector(replyButtonTapped), for: .touchUpInside)
        reactButton.addTarget(self, action: #selector(reactButtonTapped), for: .touchUpInside)
        let reactLongPress = UILongPressGestureRecognizer(target: self, action: #selector(reactButtonLongPressed(_:)))
        reactButton.addGestureRecognizer(reactLongPress)
        boostButton.addTarget(self, action: #selector(boostButtonTapped), for: .touchUpInside)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(boostButtonLongPressed(_:)))
        boostButton.addGestureRecognizer(longPress)

        avatarImageView.isUserInteractionEnabled = true
        let avatarTap = UITapGestureRecognizer(target: self, action: #selector(avatarTapped))
        avatarImageView.addGestureRecognizer(avatarTap)

        let replyRefTap = UITapGestureRecognizer(target: self, action: #selector(replyReferenceTapped))
        replyToLabel.addGestureRecognizer(replyRefTap)

        let cellLongPress = UILongPressGestureRecognizer(target: self, action: #selector(cellLongPressed(_:)))
        contentView.addGestureRecognizer(cellLongPress)
    }

    /// The current content block views in the stack, for VC-level caching.
    var currentContentViews: [UIView] {
        contentStackView.arrangedSubviews
    }

    /// Force the next `configure(...)` call to skip the Tier 1 / Tier 2 reuse paths
    /// and rebuild the content stack from scratch. Needed when the underlying post
    /// data has changed in a way that stateful renderers (poll, details) hold
    /// internally and won't pick up via simple reparenting.
    func markContentDirty() {
        renderedContentPostId = 0
    }

    func configure(
        with post: DiscourseTopicDetail.Post,
        annotatedBlocks: [AnnotatedBlock],
        cachedContentViews: [UIView]?,
        config: NativeRenderConfig,
        delegate: PostCellDelegate?,
        floorNumber: Int,
        postLink: String?,
        baseURL: String,
        assetBaseURL: String,
        validReactions: [String],
        isBoostsExpanded: Bool,
        showsSeparator: Bool,
        precomputedBlockHeights: [CGFloat?]? = nil,
        hidesLikeButton: Bool = false,
        isOP: Bool = false,
        replyIndentLevel: Int = 0,
        showsThreadLine: Bool = false,
        nestedRepliesAreCollapsed: Bool = false,
        usesNestedReplyToggle: Bool = false
    ) {
        let fm = FontManager.shared
        applyReplyIndent(level: replyIndentLevel, showsThreadLine: showsThreadLine)
        let avatarSize = fm.scaled(Self.baseAvatarSize)
        avatarWidthConstraint.constant = avatarSize
        avatarHeightConstraint.constant = avatarSize
        avatarImageView.layer.cornerRadius = avatarSize / 2
        let flairSize = fm.scaled(Self.baseFlairSize)
        flairWidthConstraint.constant = flairSize
        flairHeightConstraint.constant = flairSize
        flairImageView.layer.cornerRadius = flairSize / 2

        postId = post.id
        self.postLink = postLink
        currentPost = post
        self.delegate = delegate
        self.validReactions = validReactions
        separatorLine.isHidden = !showsSeparator

        if isOP {
            let attr = NSMutableAttributedString(
                string: post.name ?? post.username,
                attributes: [.font: FontManager.shared.font(size: 14, weight: .semibold)]
            )
            attr.append(NSAttributedString(string: "  "))
            let attachment = NSTextAttachment()
            attachment.image = Self.opBadgeImage
            let nameFont = FontManager.shared.font(size: 14, weight: .semibold)
            attachment.bounds = CGRect(
                x: 0,
                y: (nameFont.capHeight - Self.opBadgeImage.size.height) / 2,
                width: Self.opBadgeImage.size.width,
                height: Self.opBadgeImage.size.height
            )
            attr.append(NSAttributedString(attachment: attachment))
            nameLabel.attributedText = attr
        } else {
            nameLabel.attributedText = nil
            nameLabel.text = post.name
        }
        usernameLabel.text = post.username
        timeLabel.text = Self.formatDate(post.createdAt)
        floorLabel.text = "#\(floorNumber)"

        // User title
        if let userTitle = post.userTitle, !userTitle.isEmpty {
            userTitleLabel.text = "\u{00B7} \(userTitle)"
            userTitleLabel.isHidden = false
        } else {
            userTitleLabel.isHidden = true
        }

        // Flair badge — animated when the source is GIF / WebP. We let
        // SDWebImage do its native multi-frame decode (no
        // `imageThumbnailPixelSize`, which collapses animated decodes to a
        // single frame in this version). Memory is bounded at the view
        // level via `maxBufferSize` + `clearBufferWhenStopped` on the
        // SDAnimatedImageView declaration above — the source GIF stays in
        // `avatarCache` (~few MiB) but the decoded-frame working set per
        // cell is capped to ~1 MiB regardless of source resolution.
        if let flairUrl = post.flairUrl, !flairUrl.isEmpty {
            let urlString = flairUrl.hasPrefix("http") ? flairUrl : baseURL + flairUrl
            if let url = URL(string: urlString) {
                if let bgColor = post.flairBgColor, !bgColor.isEmpty {
                    flairImageView.backgroundColor = UIColor(hex: bgColor)
                }
                flairImageView.sd_setImage(with: url, context: ImageCacheManager.shared.avatarContext)
                flairImageView.isHidden = false
            }
        }

        if let replyUser = post.replyToUser {
            let attachment = NSTextAttachment()
            let symbolConfig = UIImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            attachment.image = UIImage(systemName: "arrowshape.turn.up.left.fill", withConfiguration: symbolConfig)?.withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)
            let attrStr = NSMutableAttributedString(attachment: attachment)
            attrStr.append(NSAttributedString(string: " @\(replyUser.username)"))
            replyToLabel.attributedText = attrStr
            replyToLabel.isHidden = false
        } else {
            replyToLabel.isHidden = true
        }

        let hasReplies = post.replyCount > 0
        showRepliesButton.isHidden = !hasReplies
        if hasReplies {
            if usesNestedReplyToggle {
                showRepliesButton.setTitle(
                    nestedRepliesAreCollapsed
                        ? String(localized: "post.replies.expand \(post.replyCount)")
                        : String(localized: "post.replies.collapse \(post.replyCount)"),
                    for: .normal
                )
            } else {
                showRepliesButton.setTitle(String(localized: "post.replies \(post.replyCount)"), for: .normal)
            }
        }

        // Reactions
        configureReactions(post.reactions, count: post.reactionUsersCount, baseURL: baseURL)

        // Heart / like button state — driven by actions_summary id==2
        let likeAction = post.likeAction
        let liked = likeAction?.acted == true
        let canAct = likeAction?.canAct == true
        let likeCount = likeAction?.count ?? 0
        // When the reactions plugin is active (validReactions non-empty), the
        // reactionStackView owns the count + "liked" indication —
        // `reaction_users_count == actions_summary[id==2].count`. Keep the
        // heart button as a plain action affordance: no count, no red fill.
        let reactionsPluginActive = !validReactions.isEmpty
        reactButton.setTitle(nil, for: .normal)
        // Always set the heart symbol — overlay (userReactionImageView) hides
        // it when needed but preserves the button's intrinsic size.
        let heartImage = (liked && !reactionsPluginActive) ? Self.heartFillImage : Self.heartImage
        reactButton.setImage(heartImage, for: .normal)

        if reactionsPluginActive, let userReaction = post.currentUserReaction {
            applyUserReactionImage(userReaction.id)
        } else {
            cancelUserReactionImageLoad()
            if !reactionsPluginActive, likeCount > 0 {
                reactButton.setTitle(" \(likeCount)", for: .normal)
            }
            reactButton.tintColor = (liked && !reactionsPluginActive) ? .systemRed : .tertiaryLabel
        }
        // Enabled when the user can like, or has already liked (and may undo).
        reactButton.isEnabled = canAct || liked
        // Hide entirely when there's nothing to show — own post with zero likes
        // and no reactions plugin to provide the affordance. Caller can also
        // force-hide (e.g., a forum where the like affordance is suppressed).
        reactButton.isHidden = hidesLikeButton || (!canAct && !liked && likeCount == 0 && !reactionsPluginActive)
        if hidesLikeButton {
            reactButton.isEnabled = false
            cancelUserReactionImageLoad()
        }

        reactButton.accessibilityLabel = liked
            ? String(localized: "post.a11y.liked")
            : String(localized: "post.a11y.like")
        reactButton.accessibilityValue = likeCount > 0 ? "\(likeCount)" : nil

        // Boost
        let boostCount = post.boosts.count
        let hasMine = post.boosts.contains { $0.canDelete == true }
        boostButton.setImage(Self.boostFallbackImage, for: .normal)
        boostButton.setTitle(boostCount > 0 ? " \(boostCount)" : nil, for: .normal)
        boostButton.tintColor = hasMine ? .systemYellow : .tertiaryLabel
        // Keep the button tappable when existing boosts are present (e.g. the user has
        // already boosted this post — one per user — and wants to expand the list to
        // inspect/delete theirs) even though `canBoost` is false in that case.
        boostButton.isHidden = !post.canBoost && boostCount == 0
        boostButton.isEnabled = post.canBoost || boostCount > 0
        boostButton.accessibilityValue = boostCount > 0 ? "\(boostCount)" : nil

        // More menu (copy link, bookmark, flag)
        updateMoreMenu()

        // Render content blocks — three tiers of reuse:
        // 1. Same cell + same post → skip entirely (cheapest)
        // 2. VC-level cached views → reparent existing views (no renderBlocks)
        // 3. Full render from scratch (most expensive)
        if post.id == renderedContentPostId {
            // Tier 1: same cell, same post — just fix up delegates
            FrameDropDetector.shared.log("reuse post#\(post.id) (same cell)")
            reassignTextViewDelegates(in: contentStackView)
        } else if let cached = cachedContentViews {
            // Tier 2: views were rendered before, reparent them
            let t0 = CACurrentMediaTime()
            cancelContentImageLoads()
            contentStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for view in cached {
                contentStackView.addArrangedSubview(view)
            }
            reassignTextViewDelegates(in: contentStackView)
            renderedContentPostId = post.id
            let ms = (CACurrentMediaTime() - t0) * 1000
            FrameDropDetector.shared.log("cached post#\(post.id): reparent=\(String(format: "%.1f", ms))ms views=\(cached.count)")
        } else {
            // Tier 3: full render
            let t0 = CACurrentMediaTime()
            cancelContentImageLoads()
            contentStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
            let t1 = CACurrentMediaTime()

            let views = NativeContentRenderer.renderBlocks(
                annotatedBlocks,
                config: config,
                delegate: delegate,
                pollProvider: { name in
                    guard let poll = post.polls.first(where: { $0.name == name }) else { return nil }
                    let voted = Set(post.pollsVotes[name] ?? [])
                    return (poll, voted, post)
                },
                precomputedBlockHeights: precomputedBlockHeights
            )
            let t2 = CACurrentMediaTime()

            var allTextViews: [UITextView] = []
            for view in views {
                collectTextViews(in: view, into: &allTextViews)
                contentStackView.addArrangedSubview(view)
            }
            for tv in allTextViews {
                tv.delegate = self
                (tv as? LinkTextView)?.configureSpoilerIfNeeded()
            }
            loadInlineImagesBatched(in: allTextViews)
            let t3 = CACurrentMediaTime()
            renderedContentPostId = post.id
            FrameDropDetector.shared.log("render post#\(post.id): teardown=\(String(format: "%.1f", (t1-t0)*1000))ms renderBlocks=\(String(format: "%.1f", (t2-t1)*1000))ms addViews=\(String(format: "%.1f", (t3-t2)*1000))ms total=\(String(format: "%.1f", (t3-t0)*1000))ms")
        }

        if let template = post.avatarTemplate {
            let sized = template.replacingOccurrences(of: "{size}", with: "96")
            let urlString = sized.hasPrefix("http") ? sized : baseURL + sized
            if let url = URL(string: urlString) {
                avatarImageView.sd_setImage(with: url, context: ImageCacheManager.shared.avatarContext)
            }
        }
    }

    private func applyReplyIndent(level: Int, showsThreadLine: Bool) {
        let clamped = max(0, min(level, 8))
        let offset = CGFloat(clamped) * 28
        avatarLeadingConstraint.constant = 12 + offset
        contentLeadingConstraint.constant = 12 + offset
        bottomLeftLeadingConstraint.constant = 16 + offset
        nameLeadingConstraint.constant = 8
        usernameLeadingConstraint.constant = 8
        threadLineView.isHidden = !showsThreadLine
    }

    /// Show the user's chosen reaction emoji as an overlay on top of the
    /// (transparent) heart symbol. Using a fixed-size overlay keeps the
    /// button's intrinsic size stable so neighbouring buttons (boost) don't
    /// shift around when the source emoji image is large.
    private func applyUserReactionImage(_ reactionId: String) {
        userReactionImageView.sd_cancelCurrentImageLoad()
        userReactionImageView.isHidden = false
        // Hide the heart symbol underneath without losing the button's frame.
        reactButton.tintColor = .clear
        guard let urlString = EmojiStore.url(for: reactionId) ?? EmojiStore.lookup(for: reactionId),
              let url = URL(string: urlString)
        else {
            // No mapping — restore the heart instead of leaving the slot blank.
            cancelUserReactionImageLoad()
            return
        }
        userReactionImageView.sd_setImage(with: url, context: ImageCacheManager.shared.emojiContext)
    }

    private func cancelUserReactionImageLoad() {
        userReactionImageView.sd_cancelCurrentImageLoad()
        userReactionImageView.image = nil
        userReactionImageView.isHidden = true
    }

    private func configureReactions(_ reactions: [DiscourseTopicDetail.Reaction], count: Int, baseURL: String) {
        guard !reactions.isEmpty else {
            reactionStackView.isHidden = true
            return
        }

        let visible = reactions.prefix(3)
        for (i, iv) in reactionImageViews.enumerated() {
            if i < visible.count {
                let reaction = visible[visible.index(visible.startIndex, offsetBy: i)]
                if let url = URL(string: EmojiStore.lookup(for: reaction.id) ?? "") {
                    iv.sd_setImage(with: url, context: ImageCacheManager.shared.emojiContext)
                } else {
                    iv.sd_cancelCurrentImageLoad()
                    iv.image = nil
                }
                iv.isHidden = false
            } else {
                iv.isHidden = true
                iv.sd_cancelCurrentImageLoad()
                iv.image = nil
            }
        }

        if count > 0 {
            reactionCountLabel.text = "\(count)"
            reactionCountLabel.isHidden = false
        } else {
            reactionCountLabel.isHidden = true
        }

        reactionStackView.isHidden = false
    }

    // MARK: - Content Reuse Helpers

    private func cancelContentImageLoads() {
        for view in contentStackView.arrangedSubviews {
            if let container = view as? TappableImageContainer {
                container.cancelImageLoad()
            } else if let onebox = view as? OneboxCardView {
                onebox.cancelImageLoad()
            } else if let video = view as? VideoCardView {
                video.cancelImageLoad()
            }
        }
    }

    /// Re-attach UITextViewDelegate on existing content views after cell reuse
    /// (delegate is nilled out in prepareForReuse).
    private func reassignTextViewDelegates(in container: UIView) {
        if let textView = container as? UITextView {
            textView.delegate = self
            return
        }
        for subview in container.subviews {
            reassignTextViewDelegates(in: subview)
        }
    }

    // MARK: - View Setup

    /// Recursively collect all UITextViews under `view` without doing any setup work.
    private func collectTextViews(in view: UIView, into out: inout [UITextView]) {
        if let tv = view as? UITextView {
            out.append(tv)
            return
        }
        for subview in view.subviews {
            collectTextViews(in: subview, into: &out)
        }
    }

    // MARK: - Inline Image Loading

    /// Held briefly while batching inline-image loads. Explicitly `nonisolated`
    /// to opt out of the project-wide default `@MainActor` isolation — the
    /// back-deployed Swift Concurrency runtime (used because deployment target
    /// is < iOS 17) crashes inside `swift_task_deinitOnExecutorMainActorBackDeploy`
    /// → `TaskLocal::StopLookupScope::~StopLookupScope` when actor-isolated
    /// classes are deinitted in this code path. A pure-data holder doesn't
    /// need actor isolation anyway.
    private nonisolated final class InlineImageEntry {
        let attachment: NSTextAttachment
        let location: Int
        weak var textView: UITextView?
        init(attachment: NSTextAttachment, location: Int, textView: UITextView) {
            self.attachment = attachment
            self.location = location
            self.textView = textView
        }
    }

    /// Batch inline-image loading across every textView in the post, deduped by URL.
    /// A post with N identical emoji URLs collapses from N SDWebImage calls to 1.
    private func loadInlineImagesBatched(in textViews: [UITextView]) {
        var byURL: [URL: [InlineImageEntry]] = [:]
        for textView in textViews {
            guard let attrText = textView.attributedText else { continue }
            let full = NSRange(location: 0, length: attrText.length)
            attrText.enumerateAttribute(.cookedHTMLImageURL, in: full) { value, range, _ in
                guard let urlString = value as? String,
                      let url = URL(string: urlString) else { return }
                // enumerateAttribute merges adjacent same-URL chars into one range —
                // iterate char-by-char so each attachment gets its own entry.
                for i in 0 ..< range.length {
                    let loc = range.location + i
                    if let attachment = attrText.attribute(.attachment, at: loc, effectiveRange: nil) as? NSTextAttachment {
                        byURL[url, default: []].append(InlineImageEntry(attachment: attachment, location: loc, textView: textView))
                    }
                }
            }
        }

        for (url, entries) in byURL {
            SDWebImageManager.shared.loadImage(with: url, options: [], context: ImageCacheManager.shared.emojiContext, progress: nil) { image, _, _, _, _, _ in
                guard let image else { return }
                for entry in entries {
                    entry.attachment.image = image
                    if let tv = entry.textView {
                        // Keep the bounds already set by the attributed string builder
                        let charRange = NSRange(location: entry.location, length: 1)
                        tv.textStorage.edited(.editedAttributes, range: charRange, changeInLength: 0)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    @objc private func repliesButtonTapped() {
        delegate?.postCell(didTapShowRepliesForPostId: postId)
    }

    @objc private func replyButtonTapped() {
        guard let post = currentPost else { return }
        delegate?.postCell(didTapReplyToPost: post)
    }

    @objc private func avatarTapped() {
        guard let username = currentPost?.username else { return }
        delegate?.postCell(didTapAvatarForUsername: username)
    }

    @objc private func replyReferenceTapped() {
        guard let post = currentPost, post.replyToPostNumber != nil else { return }
        delegate?.postCell(didTapReplyReferenceForPost: post)
    }

    @objc private func cellLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let post = currentPost else { return }
        delegate?.postCell(didLongPressPost: post)
    }

    private func updateMoreMenu() {
        guard let post = currentPost else { return }
        var actions: [UIAction] = []

        // Copy Link
        actions.append(UIAction(
            title: String(localized: "post.copy_link"),
            image: UIImage(systemName: "link")
        ) { [weak self] _ in
            guard let link = self?.postLink else { return }
            UIPasteboard.general.string = link
        })

        // Bookmark
        let isBookmarked = post.bookmarked
        actions.append(UIAction(
            title: isBookmarked ? String(localized: "post.remove_bookmark") : String(localized: "post.bookmark"),
            image: UIImage(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
        ) { [weak self] _ in
            guard let self, let post = self.currentPost else { return }
            self.delegate?.postCell(didToggleBookmarkForPost: post, isBookmarked: !isBookmarked)
        })

        // Flag / Report — only if the server says we can
        if post.canFlag {
            actions.append(UIAction(
                title: String(localized: "post.flag"),
                image: UIImage(systemName: "flag"),
                attributes: .destructive
            ) { [weak self] _ in
                guard let self, let post = self.currentPost else { return }
                self.delegate?.postCell(didTapFlagPost: post, sourceView: self.moreButton)
            })
        }

        moreButton.menu = UIMenu(children: actions)
    }

    @objc private func reactButtonTapped() {
        guard let post = currentPost else { return }

        // Reactions plugin path. The standard like is undone via DELETE
        // /post_actions, but any non-heart reaction can only be cleared via
        // the reactions toggle endpoint — keep the cancel path consistent
        // and route every interaction through toggleReaction.
        if !validReactions.isEmpty {
            if let userReaction = post.currentUserReaction {
                // Already reacted — tap clears it (if still within the undo
                // window). Past the window, show the picker so the user can
                // pick again or no-op.
                if userReaction.canUndo == true {
                    delegate?.postCell(didTapReaction: userReaction.id, forPost: post)
                } else {
                    presentReactionPicker(for: post)
                }
            } else {
                presentReactionPicker(for: post)
            }
            return
        }

        // No reactions plugin — tap toggles the standard like.
        let wasLiked = post.likeAction?.acted == true
        let liked = !wasLiked

        // Past the unlike grace window — Discourse rejects the DELETE.
        if !liked, post.likeAction?.canUndo == false { return }

        // Optimistic UI — server state will reconcile on next refresh.
        if liked {
            reactButton.setImage(Self.heartFillImage, for: .normal)
            reactButton.tintColor = .systemRed
        } else {
            reactButton.setImage(Self.heartImage, for: .normal)
            reactButton.tintColor = .tertiaryLabel
        }

        delegate?.postCell(didToggleLikeForPost: post, liked: liked)
    }

    @objc private func reactButtonLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let post = currentPost else { return }
        // Respect the same gating as a tap — own posts shouldn't open the picker.
        guard reactButton.isEnabled else { return }

        if validReactions.isEmpty {
            // No reactions plugin — long press behaves the same as tap.
            let wasLiked = post.likeAction?.acted == true
            delegate?.postCell(didToggleLikeForPost: post, liked: !wasLiked)
            return
        }

        presentReactionPicker(for: post)
    }

    private func presentReactionPicker(for post: DiscourseTopicDetail.Post) {
        // Build emoji picker as a 2-row grid in a popover.
        let pickerVC = UIViewController()
        let emojiSize: CGFloat = 32
        let hSpacing: CGFloat = 6
        let vSpacing: CGFloat = 6
        let hPadding: CGFloat = 12
        let vPadding: CGFloat = 10

        // Split reactions into two roughly-equal rows; first row gets the
        // ceiling so an odd count keeps the longer row on top.
        let total = validReactions.count
        let firstRowCount = (total + 1) / 2
        let row1 = Array(validReactions.prefix(firstRowCount))
        let row2 = Array(validReactions.dropFirst(firstRowCount))

        let outerStack = UIStackView()
        outerStack.axis = .vertical
        outerStack.spacing = vSpacing
        outerStack.alignment = .leading
        outerStack.translatesAutoresizingMaskIntoConstraints = false
        pickerVC.view.addSubview(outerStack)
        NSLayoutConstraint.activate([
            outerStack.topAnchor.constraint(equalTo: pickerVC.view.topAnchor, constant: vPadding),
            outerStack.leadingAnchor.constraint(equalTo: pickerVC.view.leadingAnchor, constant: hPadding),
            // Don't pin trailing/bottom — let the stack size to its intrinsic
            // content so we can read the real layout size below.
        ])

        for rowIds in [row1, row2] where !rowIds.isEmpty {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = hSpacing
            row.alignment = .center
            for reactionId in rowIds {
                row.addArrangedSubview(makeReactionButton(reactionId: reactionId, size: emojiSize, presenter: pickerVC))
            }
            outerStack.addArrangedSubview(row)
        }

        // Force a layout pass and read the resulting content size — avoids
        // the bottom row getting clipped when manual math drifts from the
        // real stack geometry (button insets, baseline alignment, etc.).
        pickerVC.view.layoutIfNeeded()
        let fittingSize = outerStack.systemLayoutSizeFitting(
            UIView.layoutFittingCompressedSize,
            withHorizontalFittingPriority: .fittingSizeLevel,
            verticalFittingPriority: .fittingSizeLevel
        )
        pickerVC.preferredContentSize = CGSize(
            width: fittingSize.width + hPadding * 2,
            height: fittingSize.height + vPadding * 2
        )
        pickerVC.modalPresentationStyle = .popover
        if let popover = pickerVC.popoverPresentationController {
            popover.sourceView = reactButton
            popover.sourceRect = reactButton.bounds
            popover.permittedArrowDirections = [.down, .up]
            popover.delegate = self
        }

        // Find presenting view controller
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let vc = next as? UIViewController {
                vc.present(pickerVC, animated: true)
                break
            }
            responder = next
        }
    }

    private func makeReactionButton(reactionId: String, size: CGFloat, presenter: UIViewController) -> UIButton {
        let button = UIButton(type: .custom)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: size),
            button.heightAnchor.constraint(equalToConstant: size),
        ])
        button.accessibilityLabel = String(localized: "post.a11y.reaction \(reactionId)")

        if let urlString = EmojiStore.url(for: reactionId) ?? EmojiStore.lookup(for: reactionId),
           let url = URL(string: urlString)
        {
            let iv = UIImageView()
            iv.contentMode = .scaleAspectFit
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.sd_setImage(with: url, context: ImageCacheManager.shared.emojiContext)
            iv.isUserInteractionEnabled = false
            button.addSubview(iv)
            NSLayoutConstraint.activate([
                iv.topAnchor.constraint(equalTo: button.topAnchor, constant: 2),
                iv.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -2),
                iv.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 2),
                iv.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -2),
            ])
        } else {
            button.setTitle(":\(reactionId):", for: .normal)
            button.titleLabel?.font = FontManager.shared.font(size: 11)
            button.setTitleColor(.label, for: .normal)
        }

        button.addAction(UIAction { [weak self, weak presenter] _ in
            guard let self, let post = self.currentPost else { return }
            presenter?.dismiss(animated: true)
            // Reactions plugin path — every emoji (heart included) goes
            // through the toggle endpoint, which handles add/remove.
            self.delegate?.postCell(didTapReaction: reactionId, forPost: post)
        }, for: .touchUpInside)

        return button
    }

    @objc private func boostButtonTapped() {
        guard let post = currentPost else { return }
        if post.boosts.isEmpty {
            delegate?.postCell(didTapBoostForPost: post)
        } else {
            delegate?.postCell(didTapToggleBoostsForPost: post, sourceView: boostButton)
        }
    }

    @objc private func boostButtonLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let post = currentPost else { return }
        delegate?.postCell(didTapBoostForPost: post)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // Keep content views alive — they will be reused if the same post is
        // reassigned, or torn down at the start of configure() otherwise.
        // renderedContentPostId is intentionally NOT reset.
        delegate = nil
        postId = 0
        postLink = nil
        currentPost = nil
        usernameLabel.text = nil
        timeLabel.text = nil
        floorLabel.text = nil
        replyToLabel.attributedText = nil
        replyToLabel.text = nil
        replyToLabel.isHidden = true
        showRepliesButton.isHidden = true
        showRepliesButton.setTitle(nil, for: .normal)
        avatarImageView.sd_cancelCurrentImageLoad()
        avatarImageView.image = nil
        nameLabel.attributedText = nil
        userTitleLabel.text = nil
        userTitleLabel.isHidden = true
        flairImageView.sd_cancelCurrentImageLoad()
        flairImageView.image = nil
        flairImageView.backgroundColor = nil
        flairImageView.isHidden = true
        reactionStackView.isHidden = true
        for iv in reactionImageViews {
            iv.sd_cancelCurrentImageLoad()
            iv.image = nil
            iv.isHidden = true
        }
        reactionCountLabel.isHidden = true
        validReactions = []
        cancelUserReactionImageLoad()
        reactButton.setImage(Self.heartImage, for: .normal)
        reactButton.setTitle(nil, for: .normal)
        reactButton.tintColor = .tertiaryLabel
        reactButton.isEnabled = true
        reactButton.isHidden = false
        boostButton.setImage(Self.boostFallbackImage, for: .normal)
        boostButton.setTitle(nil, for: .normal)
        boostButton.tintColor = .tertiaryLabel
        boostButton.isHidden = false
        boostButton.isEnabled = true
        moreButton.menu = nil
        separatorLine.isHidden = false
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private static func formatDate(_ isoString: String) -> String {
        guard let date = isoFormatter.date(from: isoString) else { return isoString }
        let now = Date()
        if abs(date.timeIntervalSince(now)) < 5 {
            return String(localized: "time.just_now")
        }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }
}

// MARK: - UITextViewDelegate

extension PostNativeCell: UITextViewDelegate {
    func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
        delegate?.postCell(didTapLinkURL: URL)
        return false
    }
}

// MARK: - UIPopoverPresentationControllerDelegate

extension PostNativeCell: UIPopoverPresentationControllerDelegate {
    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle {
        .none
    }
}
