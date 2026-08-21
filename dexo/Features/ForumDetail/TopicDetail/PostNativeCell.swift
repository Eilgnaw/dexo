import CookedHTML
import SDWebImage
import UIKit

/// Per-post tree rendering metadata. Lives next to the cell because the cell
/// is the only consumer; populated by the view-model during DFS so that the
/// cell can draw the proper continuation / corner connectors without having
/// to walk the tree again at render time.
struct TreeLineState {
    /// 0 for the OP, +1 per nesting level.
    let depth: Int
    /// True when this post is the last child among its siblings — drives whether
    /// the column line stops at the avatar's horizontal or continues to the
    /// bottom of the cell.
    let isLastSibling: Bool
    /// Length `max(0, depth - 1)`. `ancestorTrails[i] == true` means the
    /// ancestor at depth `i + 1` still has siblings below the current row, so a
    /// vertical line should pass through this cell at that column.
    let ancestorTrails: [Bool]
    /// True when this post has any direct replies in the loaded window. Drives
    /// the visibility of the collapse / expand pill in tree mode.
    let hasChildren: Bool
    /// True when the user has toggled this subtree off; descendants are hidden
    /// elsewhere by the view-model, the cell only needs this to flip the pill
    /// icon between "−" and "+".
    let isCollapsed: Bool
}

/// Custom view that paints the tree-mode connector. Avatars indent per depth
/// but sit slightly to the right of the line column so the line has a gutter
/// on the avatar's left — that's where the incoming L-elbow lives. The pill
/// for cells with children sits on a separate "outgoing" column at one indent
/// step further right.
///
/// OP (depth 0) and column 1 are never drawn — direct replies to OP don't
/// need a line back to floor 1.
final class TreeLineView: UIView {
    var state: TreeLineState? {
        didSet { setNeedsDisplay() }
    }
    /// Y center for the L-elbow — aligned with the avatar's vertical middle.
    var connectorY: CGFloat = 28 {
        didSet { setNeedsDisplay() }
    }
    /// Y of the avatar's bottom edge; the outgoing column for children begins
    /// here so visually "the line comes out of the avatar's bottom".
    var avatarBottomY: CGFloat = 44 {
        didSet { setNeedsDisplay() }
    }
    var lineColor: UIColor = .tertiarySystemFill {
        didSet { setNeedsDisplay() }
    }
    /// Quarter-circle radius for the elbow curve.
    var cornerRadius: CGFloat = 6 {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isOpaque = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let state else { return }
        // OP and column-1 contexts produce no visible lines.
        let drawsIncoming = state.depth >= 2
        let drawsOutgoing = state.hasChildren && !state.isCollapsed && state.depth >= 1
        guard drawsIncoming || drawsOutgoing else { return }
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let cappedDepth = min(state.depth, PostNativeCell.treeMaxIndentLevels)
        ctx.setStrokeColor(lineColor.cgColor)
        ctx.setLineWidth(1)
        ctx.setLineCap(.square)

        if drawsIncoming {
            // Ancestor trails (skip column 1 → start at i == 1). Walk *every*
            // ancestor, but clamp each column to the max indent level: past the
            // cap all levels share one spine column, so a deep descendant row
            // must still redraw those ancestors' pass-through lines. Capping the
            // loop by depth (the old behaviour) dropped them, breaking an
            // ancestor's sibling spine wherever a deeper subtree sat between it
            // and its next sibling. Columns repeat once clamped — harmless
            // overdraw of the same vertical.
            for i in 1 ..< state.ancestorTrails.count where state.ancestorTrails[i] {
                let x = Self.columnX(forDepth: min(i + 1, PostNativeCell.treeMaxIndentLevels))
                ctx.move(to: CGPoint(x: x, y: 0))
                ctx.addLine(to: CGPoint(x: x, y: rect.height))
            }

            // Own connector at the current depth column.
            let x = Self.columnX(forDepth: cappedDepth)
            let stubEndX = x + PostNativeCell.treeIndentStep * 0.5
            let radius = min(cornerRadius, PostNativeCell.treeIndentStep * 0.5)
            if state.isLastSibling {
                // Last child: the spine drops in, rounds the corner, and runs
                // out to the avatar — nothing continues below.
                ctx.move(to: CGPoint(x: x, y: 0))
                ctx.addArc(
                    tangent1End: CGPoint(x: x, y: connectorY),
                    tangent2End: CGPoint(x: x + radius, y: connectorY),
                    radius: radius
                )
                ctx.addLine(to: CGPoint(x: stubEndX, y: connectorY))
            } else {
                // Non-last child: the spine passes straight through so the
                // sibling line stays unbroken, and a *curved* branch peels off
                // it into the avatar. Drawing the full spine first (rather than
                // routing it through the arc) is what closes the corner gap —
                // the branch just overlaps the spine at its start point.
                ctx.move(to: CGPoint(x: x, y: 0))
                ctx.addLine(to: CGPoint(x: x, y: rect.height))
                ctx.move(to: CGPoint(x: x, y: connectorY - radius))
                ctx.addArc(
                    tangent1End: CGPoint(x: x, y: connectorY),
                    tangent2End: CGPoint(x: x + radius, y: connectorY),
                    radius: radius
                )
                ctx.addLine(to: CGPoint(x: stubEndX, y: connectorY))
            }
        }

        if drawsOutgoing {
            // Outgoing column for this post's children, starting at the
            // avatar's bottom so it visually "drops out of" the avatar. The
            // pill drawn on top by the cell view sits at the midpoint of this
            // segment.
            let childCappedDepth = min(state.depth + 1, PostNativeCell.treeMaxIndentLevels)
            let childX = Self.columnX(forDepth: childCappedDepth)
            ctx.move(to: CGPoint(x: childX, y: avatarBottomY))
            ctx.addLine(to: CGPoint(x: childX, y: rect.height))
        }

        ctx.strokePath()
    }

    /// Pixel x for the vertical line at a given tree depth's INCOMING side —
    /// i.e. the avatar.center of the parent at depth (D - 1). Anchoring on the
    /// parent's avatar.center means every line emerges from the parent
    /// avatar's bottom-center, which is what users intuitively expect.
    static func columnX(forDepth depth: Int) -> CGFloat {
        // 12 (cell leading) + parent avatar.leading shift + 16 (half avatar).
        let parentIndent = PostNativeCell.treeAvatarIndent(forDepth: depth - 1)
        return 12 + parentIndent + 16
    }
}

final class PostNativeCell: UITableViewCell, TopicPostIDProviding {
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

    /// Pixels of avatar leading-indent applied per tree depth. The step is
    /// wider than the avatar's half-width so the parent's avatar.center line
    /// column ends up just to the left of the child's avatar, leaving room
    /// for the L-elbow's horizontal stub.
    static let treeIndentStep: CGFloat = 22
    static let treeMaxIndentLevels: Int = 5
    /// Extra horizontal offset from the avatar's leading edge to where the
    /// content stack starts in tree mode. Keeps the post body well clear of
    /// the outgoing column line (at avatar.center) so the body never visually
    /// touches the spine.
    static let treeContentExtraShift: CGFloat = 28

    /// Leading offset for the avatar in tree mode. OP (depth 0) and direct
    /// replies to OP (depth 1) share the same x — the spine doesn't reach
    /// floor 1, so there's no reason to indent floor-1 avatars.
    static func treeAvatarIndent(forDepth depth: Int) -> CGFloat {
        guard depth >= 2 else { return 0 }
        let cappedSteps = min(depth - 1, treeMaxIndentLevels - 1)
        return CGFloat(cappedSteps) * treeIndentStep
    }

    /// Leading offset for the content stack in tree mode. Equal to the
    /// avatar's indent plus an extra shift so the body text never overlaps the
    /// outgoing line column. OP is exempt — it isn't part of the tree.
    static func treeContentIndent(forDepth depth: Int) -> CGFloat {
        guard depth >= 1 else { return 0 }
        return treeAvatarIndent(forDepth: depth) + treeContentExtraShift
    }

    private static let symbolConfig = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)

    // Pre-rendered fallback images so the hot configure / prepareForReuse paths
    // don't re-allocate them on every cell reuse.
    private static let heartImage = UIImage(systemName: "heart", withConfiguration: symbolConfig)
    private static let heartFillImage = UIImage(systemName: "heart.fill", withConfiguration: symbolConfig)
    private static let boostFallbackImage = UIImage(named: "roket.symbols", in: nil, with: symbolConfig)

    /// Horizontal / vertical padding applied to the OP name pill around `nameLabel`.
    /// Vertical is 0 — the label's intrinsic line height already overshoots
    /// the rendered glyph height, so any padding makes the pill look taller
    /// than the avatar's centerline and visually unbalanced.
    private static let opPillHorizontalPadding: CGFloat = 4
    private static let opPillVerticalPadding: CGFloat = 0

    weak var delegate: PostCellDelegate?
    private(set) var postId: Int = 0
    var renderedPostId: Int { postId }
    /// Tracks which post's content views are currently rendered in contentStackView.
    /// Kept separate from `postId` so prepareForReuse can reset metadata without
    /// forcing a full content rebuild on the next configure call.
    private var renderedContentPostId: Int = 0
    private var postLink: String?
    private var currentPost: DiscourseTopicDetail.Post?
    private var validReactions: [String] = []
    private var pendingReactionFeedbackSource: ReactionFeedback.CapturedSource?

    // MARK: - Header UI

    private static let baseAvatarSize: CGFloat = 32
    private static let baseFlairSize: CGFloat = 14
    private var avatarWidthConstraint: NSLayoutConstraint!
    private var avatarHeightConstraint: NSLayoutConstraint!
    private var flairWidthConstraint: NSLayoutConstraint!
    private var flairHeightConstraint: NSLayoutConstraint!

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

    /// Pill drawn behind `nameLabel` to mark the OP. Background tinted with the
    /// active theme accent; hidden for non-OP posts and collapses to zero
    /// padding so the layout matches the original.
    private let nameBackgroundView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.layer.cornerRadius = 6
        v.layer.cornerCurve = .continuous
        v.isHidden = true
        return v
    }()

    private var nameBgLeading: NSLayoutConstraint!
    private var nameBgTrailing: NSLayoutConstraint!
    private var nameBgTop: NSLayoutConstraint!
    private var nameBgBottom: NSLayoutConstraint!
    private var usernameLabelTop: NSLayoutConstraint!

    /// Leading anchors that shift right when rendering as a tree-mode reply.
    /// Their base `constant` (12pt for avatar / content / 16pt for the bottom
    /// bar) is preserved; configure adds the per-depth indent on top.
    private var avatarLeading: NSLayoutConstraint!
    private var contentStackLeading: NSLayoutConstraint!
    private var bottomLeftStackLeading: NSLayoutConstraint!

    /// Two pairs of constraints that govern where the time + reply badge land
    /// when the floor label is hidden in tree mode. In flat mode the floor
    /// sits at the top row with the reply badge alongside, and the time is
    /// the row below. In tree mode the floor is gone, so the reply badge
    /// takes its row at the top and time drops below — preserving the
    /// vertical stacking instead of squishing them onto the same row.
    private var timeLabelTopFlat: NSLayoutConstraint!
    private var timeLabelTopTree: NSLayoutConstraint!
    private var replyToCenterYFlat: NSLayoutConstraint!
    private var replyToTopTree: NSLayoutConstraint!

    /// Branch / corner connector overlay shown only in tree mode. Hidden + has
    /// no state when the cell is rendering a flat-mode post so the existing
    /// layout stays pixel-identical to before this feature.
    private let treeLineView: TreeLineView = {
        let v = TreeLineView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        return v
    }()

    /// Circle pill that sits on the children's column line and toggles the
    /// subtree visibility. Only shown in tree mode for posts that actually
    /// have replies in the loaded window.
    private let collapseButton: UIButton = {
        let b = UIButton(type: .system)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.backgroundColor = .systemBackground
        b.layer.cornerRadius = 9
        b.layer.borderWidth = 1
        b.tintColor = .secondaryLabel
        b.isHidden = true
        let cfg = UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        b.setPreferredSymbolConfiguration(cfg, forImageIn: .normal)
        b.accessibilityLabel = String(localized: "topic_detail.collapse")
        return b
    }()

    private var collapseLeading: NSLayoutConstraint!

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
        contentView.addSubview(treeLineView)
        contentView.addSubview(collapseButton)
        contentView.addSubview(avatarImageView)
        contentView.addSubview(flairImageView)
        contentView.addSubview(nameBackgroundView)
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

        // Pill's outer edges hug the avatar gap; nameLabel sits inside via these
        // constraints whose `constant` is toggled in `configure` between 0 and
        // the OP padding amount. Keeping the pill (not the text) anchored to
        // `avatar+8` means the visual gutter from avatar to the cell content
        // doesn't shift when the OP marker turns on/off.
        nameBgLeading = nameLabel.leadingAnchor.constraint(equalTo: nameBackgroundView.leadingAnchor)
        nameBgTrailing = nameBackgroundView.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor)
        nameBgTop = nameLabel.topAnchor.constraint(equalTo: nameBackgroundView.topAnchor)
        nameBgBottom = nameBackgroundView.bottomAnchor.constraint(equalTo: nameLabel.bottomAnchor)

        NSLayoutConstraint.activate([
            nameBgLeading, nameBgTrailing, nameBgTop, nameBgBottom,
        ])

        avatarLeading = avatarImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12)
        contentStackLeading = contentStackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12)
        bottomLeftStackLeading = bottomLeftStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16)

        // Pair A (flat): time + reply badge sit relative to the floor label.
        // Pair B (tree): floor is hidden, so the reply badge takes the top
        // row and the time stacks below it — keep them vertically separated.
        timeLabelTopFlat = timeLabel.topAnchor.constraint(equalTo: floorLabel.bottomAnchor, constant: 2)
        timeLabelTopTree = timeLabel.topAnchor.constraint(equalTo: replyToLabel.bottomAnchor, constant: 2)
        replyToCenterYFlat = replyToLabel.centerYAnchor.constraint(equalTo: floorLabel.centerYAnchor)
        replyToTopTree = replyToLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14)
        // Default to flat — `configure` swaps to the tree pair when in tree mode.
        NSLayoutConstraint.activate([timeLabelTopFlat, replyToCenterYFlat])

        // Collapse pill centerX is updated per-cell in `configure`; we anchor
        // the leading edge so a single stored constraint moves it horizontally
        // without rebuilding constraints each reuse.
        collapseLeading = collapseButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 0)

        NSLayoutConstraint.activate([
            treeLineView.topAnchor.constraint(equalTo: contentView.topAnchor),
            treeLineView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            treeLineView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            treeLineView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            collapseButton.widthAnchor.constraint(equalToConstant: 18),
            collapseButton.heightAnchor.constraint(equalToConstant: 18),
            collapseLeading,
            // Pill sits just inside the cell's bottom edge so it falls
            // immediately above the next (child) cell's avatar, on the line
            // about to enter that avatar.
            collapseButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),

            avatarImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            avatarLeading,
            avatarWidthConstraint,
            avatarHeightConstraint,

            flairImageView.bottomAnchor.constraint(equalTo: avatarImageView.bottomAnchor, constant: 2),
            flairImageView.trailingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 2),
            flairWidthConstraint,
            flairHeightConstraint,

            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            nameBackgroundView.leadingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 8),

            { usernameLabelTop = usernameLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor); return usernameLabelTop }(),
            usernameLabel.leadingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 8),

            userTitleLabel.lastBaselineAnchor.constraint(equalTo: nameLabel.lastBaselineAnchor),
            userTitleLabel.leadingAnchor.constraint(equalTo: nameBackgroundView.trailingAnchor, constant: 4),
            userTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: replyToLabel.leadingAnchor, constant: -8),

            replyToLabel.trailingAnchor.constraint(equalTo: floorLabel.leadingAnchor, constant: -8),

            floorLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            floorLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            timeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            contentStackView.topAnchor.constraint(equalTo: avatarImageView.bottomAnchor, constant: 12),
            contentStackLeading,
            contentStackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),

            bottomLeftStack.topAnchor.constraint(equalTo: contentStackView.bottomAnchor, constant: 10),
            bottomLeftStackLeading,
            bottomLeftStack.heightAnchor.constraint(equalToConstant: Self.bottomBarHeight),

            moreButton.topAnchor.constraint(equalTo: contentStackView.bottomAnchor, constant: 10),
            moreButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            moreButton.heightAnchor.constraint(equalToConstant: Self.bottomBarHeight),
            moreButton.widthAnchor.constraint(equalToConstant: 36),
            { let c = moreButton.bottomAnchor.constraint(equalTo: separatorLine.topAnchor, constant: -6); c.priority = .init(999); return c }(),

            replyButton.topAnchor.constraint(equalTo: contentStackView.bottomAnchor, constant: 10),
            replyButton.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor, constant: -4),
            replyButton.heightAnchor.constraint(equalToConstant: Self.bottomBarHeight),
            replyButton.widthAnchor.constraint(equalToConstant: 36),

            // Order (right→left): more, reply, react, boost. Keeping react
            // directly left of reply means a hidden boost button (posts that
            // don't support boost) leaves its gap on the far left where the
            // flexible space absorbs it — like and reply stay adjacent.
            reactButton.topAnchor.constraint(equalTo: contentStackView.bottomAnchor, constant: 10),
            reactButton.trailingAnchor.constraint(equalTo: replyButton.leadingAnchor, constant: -4),
            reactButton.heightAnchor.constraint(equalToConstant: Self.bottomBarHeight),
            reactButton.widthAnchor.constraint(equalToConstant: 36),

            userReactionImageView.widthAnchor.constraint(equalToConstant: 18),
            userReactionImageView.heightAnchor.constraint(equalToConstant: 18),
            userReactionImageView.centerYAnchor.constraint(equalTo: reactButton.centerYAnchor),
            // Centered like the heart symbol so the swap looks in-place.
            userReactionImageView.centerXAnchor.constraint(equalTo: reactButton.centerXAnchor),

            boostButton.topAnchor.constraint(equalTo: contentStackView.bottomAnchor, constant: 10),
            boostButton.trailingAnchor.constraint(equalTo: reactButton.leadingAnchor, constant: -4),
            boostButton.heightAnchor.constraint(equalToConstant: Self.bottomBarHeight),
            boostButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 36),

            separatorLine.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            separatorLine.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separatorLine.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            separatorLine.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),
        ])

        showRepliesButton.addTarget(self, action: #selector(repliesButtonTapped), for: .touchUpInside)
        collapseButton.addTarget(self, action: #selector(collapseButtonTapped), for: .touchUpInside)
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
        treeDepth: Int = 0,
        treeLineState: TreeLineState? = nil,
    ) {
        let fm = FontManager.shared
        let avatarSize = fm.scaled(Self.baseAvatarSize)
        avatarWidthConstraint.constant = avatarSize
        avatarHeightConstraint.constant = avatarSize
        avatarImageView.layer.cornerRadius = avatarSize / 2
        let flairSize = fm.scaled(Self.baseFlairSize)
        flairWidthConstraint.constant = flairSize
        flairHeightConstraint.constant = flairSize
        flairImageView.layer.cornerRadius = flairSize / 2

        // OP and depth-1 share the avatar x (depth-1 doesn't shift), while
        // depth-2+ steps right by `treeIndentStep` per level. Content is
        // pushed past the avatar so its body never overlaps the outgoing
        // column line drawn at the avatar's center.
        let avatarIndent = Self.treeAvatarIndent(forDepth: treeDepth)
        let contentIndent = Self.treeContentIndent(forDepth: treeDepth)
        avatarLeading.constant = 12 + avatarIndent
        contentStackLeading.constant = 12 + contentIndent
        // In tree mode, align the reactions/bottom-left row with the content
        // body's leading edge instead of the avatar's column.
        let defaultBottomLeading: CGFloat = treeLineState != nil ? (12 + contentIndent) : 16
        bottomLeftStackLeading.constant = defaultBottomLeading

        if let treeLineState {
            let drawsIncoming = treeLineState.depth >= 2
            let drawsOutgoing = treeLineState.hasChildren && !treeLineState.isCollapsed && treeLineState.depth >= 1
            treeLineView.isHidden = !(drawsIncoming || drawsOutgoing)
            treeLineView.state = treeLineState
            treeLineView.connectorY = 12 + avatarSize / 2
            treeLineView.avatarBottomY = 12 + avatarSize
            treeLineView.lineColor = .separator
            treeLineView.tintColor = .separator

            if treeLineState.hasChildren, treeLineState.depth >= 1 {
                collapseButton.isHidden = false
                let cappedChildDepth = min(treeLineState.depth + 1, Self.treeMaxIndentLevels)
                let childColumnX = TreeLineView.columnX(forDepth: cappedChildDepth)
                // Pill is 18pt wide; center it on the children's column.
                collapseLeading.constant = childColumnX - 9
                // Push the bottom action stack right so reactions / badges
                // don't collide with the pill's children column.
                bottomLeftStackLeading.constant = max(defaultBottomLeading, childColumnX + 9 + 6)
                let glyph = treeLineState.isCollapsed ? "plus" : "minus"
                collapseButton.setImage(UIImage(systemName: glyph), for: .normal)
                collapseButton.layer.borderColor = UIColor.separator.cgColor
                collapseButton.accessibilityLabel = treeLineState.isCollapsed
                    ? String(localized: "topic_detail.expand")
                    : String(localized: "topic_detail.collapse")
                collapseButton.backgroundColor = ThemeManager.shared.backgroundColor
            } else {
                collapseButton.isHidden = true
            }
        } else {
            treeLineView.isHidden = true
            treeLineView.state = nil
            collapseButton.isHidden = true
        }

        postId = post.id
        self.postLink = postLink
        currentPost = post
        self.delegate = delegate
        self.validReactions = validReactions
        separatorLine.isHidden = !showsSeparator

        nameLabel.attributedText = nil
        if isOP {
            let accent = ThemeManager.shared.accentColor
            nameLabel.text = post.name ?? post.username
            nameLabel.textColor = accent
            nameBackgroundView.isHidden = false
            nameBackgroundView.backgroundColor = accent.withAlphaComponent(0.12)
            nameBgLeading.constant = Self.opPillHorizontalPadding
            nameBgTrailing.constant = Self.opPillHorizontalPadding
            nameBgTop.constant = Self.opPillVerticalPadding
            nameBgBottom.constant = Self.opPillVerticalPadding
            usernameLabelTop.constant = Self.opPillVerticalPadding
        } else {
            nameLabel.text = post.name
            nameLabel.textColor = .label
            nameBackgroundView.isHidden = true
            nameBackgroundView.backgroundColor = nil
            nameBgLeading.constant = 0
            nameBgTrailing.constant = 0
            nameBgTop.constant = 0
            nameBgBottom.constant = 0
            usernameLabelTop.constant = 0
        }
        usernameLabel.text = post.username
        timeLabel.text = Self.formatDate(post.createdAt)
        // Tree mode reorders posts away from the canonical floor order, so the
        // floor number ("#42") would be confusing — hide it. Flat mode keeps
        // it visible as before.
        let inTreeModeForFloor = treeLineState != nil
        floorLabel.isHidden = inTreeModeForFloor
        floorLabel.text = inTreeModeForFloor ? nil : "#\(floorNumber)"
        // With the floor gone, the reply badge takes its row at the top and
        // the time drops below — same vertical stack flat mode had, just one
        // row shorter.
        if inTreeModeForFloor {
            NSLayoutConstraint.deactivate([timeLabelTopFlat, replyToCenterYFlat])
            NSLayoutConstraint.activate([timeLabelTopTree, replyToTopTree])
        } else {
            NSLayoutConstraint.deactivate([timeLabelTopTree, replyToTopTree])
            NSLayoutConstraint.activate([timeLabelTopFlat, replyToCenterYFlat])
        }

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

        // Tree mode already draws parent/child connector lines, so the reply
        // badge is redundant — hide it.
        if let replyUser = post.replyToUser, !inTreeModeForFloor {
            let attachment = NSTextAttachment()
            let symbolConfig = UIImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            attachment.image = UIImage(systemName: "arrowshape.turn.up.left.fill", withConfiguration: symbolConfig)?.withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)
            let attrStr = NSMutableAttributedString(attachment: attachment)
            attrStr.append(NSAttributedString(string: " @\(replyUser.username)"))
            replyToLabel.attributedText = attrStr
            replyToLabel.isHidden = false
        } else {
            replyToLabel.attributedText = nil
            replyToLabel.isHidden = true
        }

        let hasReplies = post.replyCount > 0
        // In tree mode the collapse pill sits in this same column at the
        // action-row level — hide the modal "N replies" button to avoid the
        // two affordances stacking on top of each other.
        let inTreeMode = treeLineState != nil
        showRepliesButton.isHidden = !hasReplies || inTreeMode
        if hasReplies, !inTreeMode {
            showRepliesButton.setTitle(String(localized: "post.replies \(post.replyCount)"), for: .normal)
        }

        // Reactions
        configureReactions(post.reactions, count: post.reactionUsersCount, baseURL: baseURL)

        // Heart / like button state — driven by actions_summary id==2
        let likeAction = post.likeAction
        let liked = likeAction?.acted == true
        let canAct = likeAction?.canAct == true
        let likeCount = likeAction?.count ?? 0
        // The reactions row already shows the count; keep the heart as a
        // plain action affordance with no inline number on the button.
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
            reactButton.tintColor = (liked && !reactionsPluginActive) ? .systemRed : .tertiaryLabel
        }
        // Enabled when the user can like, or has already liked (and may undo).
        reactButton.isEnabled = canAct || liked
        // Hide the button outright whenever it would be tappable-disabled —
        // a greyed-out heart adds noise without offering anything to do.
        // Exception: when the reactions plugin is active, always keep the
        // heart visible so tapping it can open the reaction picker, even on
        // posts where the plain like action isn't currently actionable.
        // `hidesLikeButton` is the external force-hide (e.g. forums where the
        // affordance is suppressed entirely).
        reactButton.isHidden = hidesLikeButton || (!canAct && !liked && !reactionsPluginActive)
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

        // Deleted-post placeholders are stand-in entries the nested-replies
        // endpoint emits so the tree topology stays intact. They carry no
        // author / content — render a slim "(deleted)" marker and hide every
        // affordance that doesn't apply.
        if post.deletedPostPlaceholder {
            applyDeletedPlaceholderChrome()
        }
    }

    private func applyDeletedPlaceholderChrome() {
        nameLabel.attributedText = nil
        nameLabel.text = String(localized: "post.deleted_placeholder")
        nameLabel.textColor = .tertiaryLabel
        nameBackgroundView.isHidden = true
        usernameLabel.isHidden = true
        timeLabel.isHidden = true
        floorLabel.isHidden = true
        replyToLabel.isHidden = true
        userTitleLabel.isHidden = true
        flairImageView.isHidden = true
        avatarImageView.sd_cancelCurrentImageLoad()
        avatarImageView.image = nil
        avatarImageView.backgroundColor = .tertiarySystemFill
        replyButton.isHidden = true
        reactButton.isHidden = true
        boostButton.isHidden = true
        moreButton.isHidden = true
        showRepliesButton.isHidden = true
        reactionStackView.isHidden = true
        cancelUserReactionImageLoad()
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

    @objc private func collapseButtonTapped() {
        delegate?.postCell(didToggleCollapseForPostId: postId)
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

        if post.isEditableByCurrentUser, delegate?.supportsPostEditing == true {
            let title = delegate?.postCellShouldUseTopicEditor(for: post) == true
                ? String(localized: "edit.topic.menu")
                : String(localized: "edit.post.menu")
            actions.append(UIAction(
                title: title,
                image: UIImage(systemName: "pencil")
            ) { [weak self] _ in
                guard let self, let post = self.currentPost else { return }
                self.delegate?.postCell(didTapEditPost: post)
            })
        }

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
        pendingReactionFeedbackSource = nil

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
        pendingReactionFeedbackSource = nil
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
        // Build emoji picker as a 2-row grid in a popover. The popover's own
        // chrome is hidden (clear background) so we can draw a tighter rounded
        // card ourselves with a corner radius and padding under our control.
        let pickerVC = UIViewController()
        let emojiSize: CGFloat = 32
        let hSpacing: CGFloat = 8
        let vSpacing: CGFloat = 8
        let hPadding: CGFloat = 16
        let vPadding: CGFloat = 14
        let cornerRadius: CGFloat = 14

        // Split reactions into two roughly-equal rows; first row gets the
        // ceiling so an odd count keeps the longer row on top.
        let total = validReactions.count
        let firstRowCount = (total + 1) / 2
        let row1 = Array(validReactions.prefix(firstRowCount))
        let row2 = Array(validReactions.dropFirst(firstRowCount))

        // Shadow wrapper (no clipping) → rounded card (clips content). Keeping
        // the shadow and the corner-clip on separate layers avoids the shadow
        // being trimmed by `clipsToBounds`.
        let shadowWrapper = UIView()
        shadowWrapper.translatesAutoresizingMaskIntoConstraints = false
        shadowWrapper.backgroundColor = .clear
        shadowWrapper.layer.shadowColor = UIColor.black.cgColor
        shadowWrapper.layer.shadowOpacity = 0.18
        shadowWrapper.layer.shadowRadius = 12
        shadowWrapper.layer.shadowOffset = CGSize(width: 0, height: 4)

        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = ThemeManager.shared.cardBackgroundColor
        card.layer.cornerRadius = cornerRadius
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true

        let outerStack = UIStackView()
        outerStack.axis = .vertical
        outerStack.spacing = vSpacing
        outerStack.alignment = .leading
        outerStack.translatesAutoresizingMaskIntoConstraints = false

        pickerVC.view.backgroundColor = .clear
        pickerVC.view.addSubview(shadowWrapper)
        shadowWrapper.addSubview(card)
        card.addSubview(outerStack)
        NSLayoutConstraint.activate([
            shadowWrapper.topAnchor.constraint(equalTo: pickerVC.view.topAnchor),
            shadowWrapper.leadingAnchor.constraint(equalTo: pickerVC.view.leadingAnchor),
            shadowWrapper.trailingAnchor.constraint(equalTo: pickerVC.view.trailingAnchor),
            shadowWrapper.bottomAnchor.constraint(equalTo: pickerVC.view.bottomAnchor),
            card.topAnchor.constraint(equalTo: shadowWrapper.topAnchor),
            card.leadingAnchor.constraint(equalTo: shadowWrapper.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: shadowWrapper.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: shadowWrapper.bottomAnchor),
            outerStack.topAnchor.constraint(equalTo: card.topAnchor, constant: vPadding),
            outerStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: hPadding),
            // Don't pin trailing/bottom — let the stack size to its intrinsic
            // content so `systemLayoutSizeFitting` below reads the real size.
            // The card fills the view (== preferredContentSize), so the
            // trailing/bottom padding ends up exactly hPadding/vPadding.
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
            // Hide the system popover chrome so only our rounded card shows.
            popover.backgroundColor = .clear
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
            self.pendingReactionFeedbackSource = ReactionFeedback.capture(button)
            presenter?.dismiss(animated: true)
            // Reactions plugin path — every emoji (heart included) goes
            // through the toggle endpoint, which handles add/remove.
            self.delegate?.postCell(didTapReaction: reactionId, forPost: post)
        }, for: .touchUpInside)

        return button
    }

    func playReactionSuccessFeedback(animated: Bool) {
        guard animated else {
            pendingReactionFeedbackSource = nil
            return
        }
        if let source = pendingReactionFeedbackSource {
            pendingReactionFeedbackSource = nil
            ReactionFeedback.play(captured: source, to: reactionStackView)
        } else {
            ReactionFeedback.play(from: reactButton, to: reactionStackView)
        }
    }

    func playReactionDestinationFeedback() {
        if reactionStackView.isHidden {
            ReactionFeedback.confirm(on: reactButton)
        } else {
            ReactionFeedback.confirm(on: reactionStackView, countView: reactionCountLabel)
        }
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
        pendingReactionFeedbackSource = nil
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
        moreButton.isHidden = false
        separatorLine.isHidden = false
        // Reset any deleted-placeholder customisations so the next cell reuse
        // sees a clean slate (nameLabel color, avatar background fill).
        nameLabel.textColor = .label
        avatarImageView.backgroundColor = nil
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
