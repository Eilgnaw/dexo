import CookedHTML
import SDWebImage
import UIKit

protocol TopicPostIDProviding: AnyObject {
    var renderedPostId: Int { get }
}

enum TopicPostIDResolver {
    static func postId(startingAt view: UIView?) -> Int {
        var current = view
        while let candidate = current {
            if let provider = candidate as? TopicPostIDProviding {
                return provider.renderedPostId
            }
            current = candidate.superview
        }
        return 0
    }
}

// MARK: - TappableImageContainer

final class TappableImageContainer: UIView {
    static let intrinsicHeightDidChangeNotification = Notification.Name("TopicContentImageHeightDidChange")
    /// URL used when tapped — prefers the full-size href over the img src.
    var imageURL: URL?
    weak var delegate: PostCellDelegate?

    /// The actual image view. GIF and WebP may contain animation; for static
    /// JPEG/PNG we use plain `UIImageView`, which is several
    /// times cheaper to instantiate (no animation state, no frame timer, no
    /// `SDAnimatedImageProvider` plumbing).
    /// Exposed for zoom transition animations.
    var displayedImageView: UIImageView { imageView }
    private let imageView: UIImageView
    private let sourceURL: URL
    private let containerWidth: CGFloat
    private let hasOriginalSize: Bool

    private var imageHeightConstraint: NSLayoutConstraint!
    private var imageWidthConstraint: NSLayoutConstraint!

    /// Discourse renders images at a reference width of 690px.
    /// Images narrower than this are displayed proportionally smaller on screen.
    private static let referenceWidth: CGFloat = 690

    private static func isLikelyAnimated(_ url: URL) -> Bool {
        ["gif", "webp"].contains(url.pathExtension.lowercased())
    }

    init(
        url: URL,
        width: Int?,
        height: Int?,
        containerWidth: CGFloat,
        href: URL? = nil,
        sizingMode: NativeImageSizingMode = .discourseResponsive
    ) {
        sourceURL = url
        self.containerWidth = containerWidth
        hasOriginalSize = width.map { $0 > 0 } == true && height.map { $0 > 0 } == true
        imageURL = href ?? url
        let iv: UIImageView = Self.isLikelyAnimated(url) ? SDAnimatedImageView() : UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.translatesAutoresizingMaskIntoConstraints = false
        imageView = iv
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        addSubview(imageView)

        let displaySize = Self.displaySize(
            width: width,
            height: height,
            containerWidth: containerWidth,
            sizingMode: sizingMode
        )
        let isFullWidth = displaySize.width >= containerWidth

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        imageWidthConstraint = imageView.widthAnchor.constraint(equalToConstant: displaySize.width)
        imageWidthConstraint.isActive = !isFullWidth
        if isFullWidth {
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
        }
        imageHeightConstraint = imageView.heightAnchor.constraint(equalToConstant: displaySize.height)
        imageHeightConstraint.isActive = true

        backgroundColor = .clear
        imageView.layer.cornerRadius = 4
        imageView.clipsToBounds = true

        if let animatedView = imageView as? SDAnimatedImageView {
            // A 1536px RGBA frame is about 9 MiB. Keep at most roughly one
            // decoded frame ahead and release it as soon as playback stops.
            animatedView.autoPlayAnimatedImage = false
            animatedView.maxBufferSize = UInt(ImageCacheManager.contentAnimationMaxBufferBytes)
            animatedView.clearBufferWhenStopped = true
        }

        startImageLoad()

        let tap = UITapGestureRecognizer(target: self, action: #selector(imageTapped))
        addGestureRecognizer(tap)
        isUserInteractionEnabled = true
    }

    private func startImageLoad() {
        let isAnimated = imageView is SDAnimatedImageView
        let options: SDWebImageOptions = isAnimated ? [.matchAnimatedImageClass] : []
        let context = isAnimated
            ? ImageCacheManager.shared.animatedContentContext
            : ImageCacheManager.shared.contentContext
        imageView.sd_setImage(
            with: sourceURL,
            placeholderImage: nil,
            options: options,
            context: context,
            progress: { [weak imageView] received, expected, _ in
                guard isAnimated,
                      max(Int64(received), Int64(expected)) > ImageCacheManager.maxAnimatedDownloadBytes
                else { return }
                DispatchQueue.main.async {
                    imageView?.sd_cancelCurrentImageLoad()
                }
            }
        ) { [weak self] image, _, _, _ in
            guard let self, let image else { return }
            self.imageView.backgroundColor = .clear
            self.updateAnimationPlayback()
            if !self.hasOriginalSize, image.size.width > 0 {
                let ratio = self.containerWidth / image.size.width
                self.imageHeightConstraint.constant = image.size.height * ratio
                self.scheduleCoalescedHeightUpdate()
            }
        }
    }

    static func displaySize(
        width: Int?,
        height: Int?,
        containerWidth: CGFloat,
        sizingMode: NativeImageSizingMode
    ) -> CGSize {
        guard let width, let height, width > 0, height > 0 else {
            return CGSize(width: containerWidth, height: containerWidth * 9.0 / 16.0)
        }

        let displayWidth: CGFloat
        switch sizingMode {
        case .discourseResponsive:
            let fraction = min(CGFloat(width) / Self.referenceWidth, 1)
            displayWidth = containerWidth * fraction
        case .fitWithoutUpscaling:
            displayWidth = min(CGFloat(width), containerWidth)
        }
        return CGSize(
            width: displayWidth,
            height: CGFloat(height) * displayWidth / CGFloat(width)
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Last tapped container, used by the zoom transition to find the source frame.
    static weak var lastTapped: TappableImageContainer?

    @objc private func imageTapped() {
        guard let imageURL else { return }
        Self.lastTapped = self
        let postId = findPostId()
        delegate?.postCell(didTapImageURL: imageURL, inPostId: postId)
    }

    private func findPostId() -> Int {
        TopicPostIDResolver.postId(startingAt: superview)
    }

    func cancelImageLoad() {
        imageView.sd_cancelCurrentImageLoad()
    }

    // MARK: - Coalesced Height Updates

    /// Table views that already have a pending height update scheduled.
    /// Multiple image loads resolving in the same run-loop pass are coalesced
    /// into a single beginUpdates/endUpdates call.
    private static var pendingUpdateTableViews = Set<ObjectIdentifier>()

    private func scheduleCoalescedHeightUpdate() {
        let postId = findPostId()
        NotificationCenter.default.post(
            name: Self.intrinsicHeightDidChangeNotification,
            object: self,
            userInfo: postId == 0 ? nil : ["postId": postId]
        )
        guard let tableView = findTableView() else { return }
        let id = ObjectIdentifier(tableView)
        guard !Self.pendingUpdateTableViews.contains(id) else { return }
        Self.pendingUpdateTableViews.insert(id)
        DispatchQueue.main.async { [weak tableView] in
            Self.pendingUpdateTableViews.remove(id)
            guard let tableView else { return }
            let t0 = CACurrentMediaTime()
            let offset = tableView.contentOffset
            tableView.beginUpdates()
            tableView.endUpdates()
            if abs(tableView.contentOffset.y - offset.y) > 1 {
                tableView.contentOffset = offset
            }
            let ms = (CACurrentMediaTime() - t0) * 1000
            if ms > 3 { FrameDropDetector.shared.log("imageHeightUpdate \(String(format: "%.1f", ms))ms") }
        }
    }

    private func findTableView() -> UITableView? {
        var view: UIView? = superview
        while let v = view {
            if let tv = v as? UITableView { return tv }
            view = v.superview
        }
        return nil
    }

    // MARK: - Animation Control

    private var shouldPlayAnimation: Bool {
        guard window != nil, !isHidden, alpha > 0, !bounds.isEmpty else { return false }
        var ancestor = superview
        while let view = ancestor {
            if view.isHidden || view.alpha <= 0 { return false }
            if let scrollView = view as? UIScrollView,
               scrollView is UITableView || scrollView is UICollectionView
            {
                if scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating {
                    return false
                }
                if !convert(bounds, to: scrollView).intersects(scrollView.bounds) {
                    return false
                }
            }
            ancestor = view.superview
        }
        return true
    }

    private func updateAnimationPlayback() {
        guard let animatedView = imageView as? SDAnimatedImageView else { return }
        if shouldPlayAnimation {
            if !animatedView.isAnimating { animatedView.startAnimating() }
        } else if animatedView.isAnimating {
            animatedView.stopAnimating()
        }
    }

    static func updateVisibleAnimations(in root: UIView, paused: Bool) {
        if let image = root as? TappableImageContainer {
            if paused {
                (image.imageView as? SDAnimatedImageView)?.stopAnimating()
            } else {
                image.updateAnimationPlayback()
            }
            return
        }
        for subview in root.subviews {
            updateVisibleAnimations(in: subview, paused: paused)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            if imageView.image == nil {
                imageView.backgroundColor = ThemeManager.shared.imagePlaceholderColor
                startImageLoad()
            } else {
                imageView.backgroundColor = .clear
            }
            updateAnimationPlayback()
        } else {
            (imageView as? SDAnimatedImageView)?.stopAnimating()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateAnimationPlayback()
    }
}

// MARK: - ImageRenderer

enum ImageRenderer: BlockRenderer {
    static func canRender(_ block: ContentBlock) -> Bool {
        if case .image = block { return true }
        return false
    }

    static func render(_ block: ContentBlock, config: NativeRenderConfig, delegate: PostCellDelegate?) -> UIView {
        guard case .image(let src, _, let width, let height, let href) = block,
              let url = URL(string: src)
        else {
            return UIView()
        }

        let hrefURL: URL? = {
            guard let href, !href.isEmpty else { return nil }
            return URL(string: href)
        }()

        let container = TappableImageContainer(
            url: url,
            width: width,
            height: height,
            containerWidth: config.contentWidth,
            href: hrefURL,
            sizingMode: config.imageSizingMode
        )
        container.delegate = delegate
        return container
    }
}
