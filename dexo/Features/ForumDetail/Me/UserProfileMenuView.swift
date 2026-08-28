import UIKit

/// Public-profile actions share the personal center's rows, without account settings.
final class UserProfileMenuView: ProfileMenuSheetView {
    enum Action { case follow, localBlock, topics, posts, retry }
    var onAction: ((Action) -> Void)?
    private let follow = ProfileMenuControl(title: String(localized: "user.follow"), symbol: "person.badge.plus", identifier: "user.follow")
    private let block = ProfileMenuControl(title: String(localized: "user.local_block"), symbol: "person.crop.circle.badge.xmark", identifier: "user.local_block")
    private let topics = ProfileMenuControl(title: String(localized: "user.topics_title"), symbol: "text.bubble", identifier: "user.topics")
    private let posts = ProfileMenuControl(title: String(localized: "user.posts_title"), symbol: "text.quote", identifier: "user.posts")
    private let retry = ProfileMenuControl(title: String(localized: "action.retry"), symbol: "arrow.clockwise", identifier: "user.retry")
    private let errorLabel = UILabel()
    private var relationships: UIStackView!
    private var activity: UIStackView!
    private var retryGroup: UIStackView!

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "user.menu"
        relationships = makeGroup([follow, block])
        activity = makeGroup([topics, posts])
        retryGroup = makeGroup([retry])
        errorLabel.numberOfLines = 0
        errorLabel.accessibilityIdentifier = "user.profile.error"
        for (control, action) in [(follow, Action.follow), (block, .localBlock), (topics, .topics), (posts, .posts), (retry, .retry)] {
            control.addAction(UIAction { [weak self] _ in self?.onAction?(action) }, for: .touchUpInside)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        hasProfile: Bool, showsFollow: Bool, isFollowing: Bool, isFollowLoading: Bool,
        showsLocalBlock: Bool, isLocallyBlocked: Bool, errorMessage: String?, palette: ProfilePagePalette
    ) {
        configureSurface(palette: palette)
        follow.configure(
            detail: nil, unread: false, palette: palette,
            title: isFollowing ? String(localized: "user.following") : String(localized: "user.follow"),
            symbol: isFollowing ? "checkmark" : "person.badge.plus",
            actionLabel: isFollowing ? String(localized: "user.unfollow") : String(localized: "user.follow"),
            selected: isFollowing, isLoading: isFollowLoading
        )
        block.configure(
            detail: nil, unread: false, palette: palette,
            title: isLocallyBlocked ? String(localized: "user.local_blocked") : String(localized: "user.local_block"),
            symbol: isLocallyBlocked ? "checkmark" : "person.crop.circle.badge.xmark",
            actionLabel: isLocallyBlocked ? String(localized: "user.local_unblock") : String(localized: "user.local_block"),
            selected: isLocallyBlocked
        )
        for row in [topics, posts, retry] { row.configure(detail: nil, unread: false, palette: palette) }
        errorLabel.text = errorMessage
        errorLabel.font = FontManager.shared.font(size: 15)
        errorLabel.textColor = .secondaryLabel
        setVisible(showsFollow, view: follow, in: relationships, at: 0)
        setVisible(showsLocalBlock, view: block, in: relationships, at: 1)
        setVisible(hasProfile && (showsFollow || showsLocalBlock), view: relationships, in: content, at: 0)
        setVisible(hasProfile, view: activity, in: content, at: content.arrangedSubviews.count)
        setVisible(errorMessage != nil, view: errorLabel, in: content, at: content.arrangedSubviews.count)
        setVisible(errorMessage != nil, view: retryGroup, in: content, at: content.arrangedSubviews.count)
    }

    private func setVisible(_ visible: Bool, view: UIView, in stack: UIStackView, at index: Int) {
        if visible, !stack.arrangedSubviews.contains(view) {
            stack.insertArrangedSubview(view, at: min(index, stack.arrangedSubviews.count))
        } else if !visible, stack.arrangedSubviews.contains(view) {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }
}
