import UIKit

protocol PostCellDelegate: AnyObject {
    var supportsPostEditing: Bool { get }
    func postCellShouldUseTopicEditor(for post: DiscourseTopicDetail.Post) -> Bool
    func postCell(didTapImageURL url: URL, inPostId postId: Int)
    func postCell(didTapLinkURL url: URL)
    func postCell(didTapShowRepliesForPostId postId: Int)
    func postCell(didTapToggleDetails detailsIndex: Int, postId: Int)
    func postCell(didTapReplyToPost post: DiscourseTopicDetail.Post)
    /// Tap the "↩︎ @username" badge on a reply cell to preview the post being replied to.
    func postCell(didTapReplyReferenceForPost post: DiscourseTopicDetail.Post)
    /// Tap the "−" / "+" pill on the tree-mode column line to collapse or
    /// re-expand this post's subtree.
    func postCell(didToggleCollapseForPostId postId: Int)
    /// Tap the tree-mode "view N more replies" row to fetch the direct replies
    /// the server didn't inline under `parentPostId`.
    func postCell(didTapLoadMoreChildrenForParentId parentPostId: Int)
    func postCell(didToggleBookmarkForPost post: DiscourseTopicDetail.Post, isBookmarked: Bool)
    func postCell(didTapAvatarForUsername username: String)
    func postCell(didTapReaction reactionId: String, forPost post: DiscourseTopicDetail.Post)
    func postCell(didToggleLikeForPost post: DiscourseTopicDetail.Post, liked: Bool)
    func postCell(didTapBoostForPost post: DiscourseTopicDetail.Post)
    func postCell(didTapDeleteBoost boost: DiscourseTopicDetail.Boost)
    func postCell(didTapToggleBoostsForPost post: DiscourseTopicDetail.Post, sourceView: UIView)
    func postCell(didVotePoll pollName: String, options: [String], forPost post: DiscourseTopicDetail.Post)
    func postCell(didRemovePollVote pollName: String, forPost post: DiscourseTopicDetail.Post)
    func postCell(didTapFlagPost post: DiscourseTopicDetail.Post, sourceView: UIView)
    func postCell(didTapEditPost post: DiscourseTopicDetail.Post)
    func postCell(didLongPressPost post: DiscourseTopicDetail.Post)
}

extension PostCellDelegate {
    var supportsPostEditing: Bool { false }
    func postCellShouldUseTopicEditor(for post: DiscourseTopicDetail.Post) -> Bool { false }
    func postCell(didTapEditPost post: DiscourseTopicDetail.Post) {}
}
