import CookedHTML
import SafariServices
import UIKit

/// Bottom-sheet preview shown when the user taps the "↩︎ @username" badge on
/// a reply cell. Renders the single post being replied to using a stripped-
/// down `PostNativeCell` so the user can read it without losing their scroll
/// position in the topic.
final class ReplyPreviewViewController: BaseViewController {
    private let api: DiscourseAPI
    private let post: DiscourseTopicDetail.Post
    private let topicId: Int
    private let baseURL: String
    private let assetBaseURL: String
    private let validReactions: [String]
    private let hidesLikeButton: Bool
    private let floorNumber: Int
    private var parsedBlocks: [AnnotatedBlock] = []

    private lazy var tableView: UITableView = {
        let tv = ThemedTableView(frame: .zero, style: .plain)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.register(PostNativeCell.self, forCellReuseIdentifier: PostNativeCell.reuseIdentifier)
        tv.dataSource = self
        tv.delegate = self
        tv.separatorStyle = .none
        tv.estimatedRowHeight = 200
        tv.rowHeight = UITableView.automaticDimension
        return tv
    }()

    init(
        api: DiscourseAPI,
        post: DiscourseTopicDetail.Post,
        topicId: Int,
        validReactions: [String],
        floorNumber: Int
    ) {
        self.api = api
        self.post = post
        self.topicId = topicId
        self.baseURL = api.baseURL
        self.assetBaseURL = api.assetBaseURL
        self.validReactions = validReactions
        self.hidesLikeButton = ForumPolicy.hidesLikeButton(baseURL: api.baseURL)
        self.floorNumber = floorNumber
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "reply.preview.title \(post.username)")

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close, target: self, action: #selector(close)
        )

        parsedBlocks = CookedHTMLParser.parseAnnotated(html: post.cooked, baseURL: baseURL)

        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    @objc private func close() {
        dismiss(animated: true)
    }
}

extension ReplyPreviewViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: PostNativeCell.reuseIdentifier, for: indexPath) as? PostNativeCell else {
            return UITableViewCell()
        }
        let postLink = "\(baseURL)/t/\(topicId)/\(post.postNumber)"
        let config = NativeRenderConfig.default(contentWidth: tableView.bounds.width - 24, baseURL: baseURL)
        cell.configure(
            with: post,
            annotatedBlocks: parsedBlocks,
            cachedContentViews: nil,
            config: config,
            delegate: self,
            floorNumber: floorNumber,
            postLink: postLink,
            baseURL: baseURL,
            assetBaseURL: assetBaseURL,
            validReactions: validReactions,
            isBoostsExpanded: false,
            showsSeparator: false,
            hidesLikeButton: hidesLikeButton
        )
        return cell
    }
}

// MARK: - PostCellDelegate

extension ReplyPreviewViewController: PostCellDelegate {
    func postCell(didTapImageURL url: URL, inPostId postId: Int) {
        openExternalURL(url)
    }

    func postCell(didTapLinkURL url: URL) {
        if let route = ForumTopicLinkParser.parse(url, baseURL: baseURL) {
            let detail = TopicDetailControllerFactory.make(
                api: api,
                topicId: route.topicId,
                initialFloor: route.floor
            )
            if let navigationController {
                navigationController.pushViewController(detail, animated: true)
            } else {
                present(UINavigationController(rootViewController: detail), animated: true)
            }
            return
        }
        let scheme = url.scheme?.lowercased()
        if scheme == "http" || scheme == "https" {
            presentForumWebView(url, forumBaseURL: baseURL)
        } else {
            UIApplication.shared.open(url)
        }
    }

    private func openExternalURL(_ url: URL) {
        let scheme = url.scheme?.lowercased()
        if scheme == "http" || scheme == "https" {
            let safari = SFSafariViewController(url: url)
            present(safari, animated: true)
        } else {
            UIApplication.shared.open(url)
        }
    }

    // Stubs — preview is read-only.
    func postCell(didTapShowRepliesForPostId postId: Int) {}
    func postCell(didTapToggleDetails detailsIndex: Int, postId: Int) {}
    func postCell(didTapReplyToPost post: DiscourseTopicDetail.Post) {}
    func postCell(didTapReplyReferenceForPost post: DiscourseTopicDetail.Post) {}
    func postCell(didToggleCollapseForPostId postId: Int) {}
    func postCell(didTapLoadMoreChildrenForParentId parentPostId: Int) {}
    func postCell(didToggleBookmarkForPost post: DiscourseTopicDetail.Post, isBookmarked: Bool) {}
    func postCell(didTapAvatarForUsername username: String) {}
    func postCell(didTapReaction reactionId: String, forPost post: DiscourseTopicDetail.Post) {}
    func postCell(didToggleLikeForPost post: DiscourseTopicDetail.Post, liked: Bool) {}
    func postCell(didTapBoostForPost post: DiscourseTopicDetail.Post) {}
    func postCell(didTapDeleteBoost boost: DiscourseTopicDetail.Boost) {}
    func postCell(didTapToggleBoostsForPost post: DiscourseTopicDetail.Post, sourceView: UIView) {}
    func postCell(didVotePoll pollName: String, options: [String], forPost post: DiscourseTopicDetail.Post) {}
    func postCell(didRemovePollVote pollName: String, forPost post: DiscourseTopicDetail.Post) {}
    func postCell(didTapFlagPost post: DiscourseTopicDetail.Post, sourceView: UIView) {}
    func postCell(didLongPressPost post: DiscourseTopicDetail.Post) {}
}
