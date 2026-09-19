import Lightbox
import Photos
import SDWebImage
import UIKit

/// Lightbox owns a plain UIImageView for sizing and zooming. Overlay an
/// SDAnimatedImageView for formats whose frames must be decoded on demand.
nonisolated final class TopicLightboxImage: LightboxImage {
    @MainActor private weak var animationView: SDAnimatedImageView?

    override func addImageTo(_ imageView: UIImageView, completion: ((UIImage?) -> Void)? = nil) {
        guard let imageURL, ["gif", "webp"].contains(imageURL.pathExtension.lowercased()) else {
            super.addImageTo(imageView, completion: completion)
            return
        }

        MainActor.assumeIsolated {
            releaseAnimation()
            imageView.image = nil

            let animatedView = SDAnimatedImageView(frame: imageView.bounds)
            animatedView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            animatedView.contentMode = .scaleAspectFit
            animatedView.clipsToBounds = true
            animatedView.isUserInteractionEnabled = false
            imageView.addSubview(animatedView)
            animationView = animatedView

            animatedView.sd_setImage(
                with: imageURL,
                placeholderImage: nil,
                options: [.retryFailed, .highPriority, .refreshCached, .matchAnimatedImageClass],
                context: ImageCacheManager.shared.fullScreenContentContext,
                progress: nil
            ) { [weak imageView, weak animatedView] image, _, _, _ in
                MainActor.assumeIsolated {
                    guard let imageView, let animatedView, animatedView.superview === imageView else { return }
                    // Lightbox reads this image to calculate the zoomed frame. The
                    // child view renders the animation without materializing all frames.
                    imageView.image = image
                    completion?(image)
                }
            }
        }
    }

    @MainActor
    func releaseAnimation() {
        animationView?.sd_cancelCurrentImageLoad()
        animationView?.stopAnimating()
        animationView?.removeFromSuperview()
        animationView = nil
    }
}

final class ImageBrowserController: LightboxController {
    private let browserImages: [TopicLightboxImage]

    init(imageURLs: [URL], startIndex: Int) {
        browserImages = imageURLs.map { TopicLightboxImage(imageURL: $0) }
        super.init(images: browserImages, startIndex: startIndex)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private lazy var closeButton: UIButton = {
        let button = UIButton(type: .system)
        let symbol = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        button.setImage(UIImage(systemName: "xmark", withConfiguration: symbol), for: .normal)
        button.tintColor = .white
        button.addTarget(self, action: #selector(closeButtonTapped), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = String(localized: "action.close")
        return button
    }()

    private lazy var saveButton: UIButton = {
        var config = UIButton.Configuration.plain()
        let title = String(localized: "image_browser.save.button")
        config.attributedTitle = AttributedString(
            title,
            attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 15, weight: .semibold)])
        )
        config.baseForegroundColor = .white
        config.background.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        config.background.cornerRadius = 16
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
        let button = UIButton(configuration: config)
        button.addTarget(self, action: #selector(saveButtonTapped), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = title
        return button
    }()

    private lazy var pageControl: UIPageControl = {
        let pc = UIPageControl()
        pc.translatesAutoresizingMaskIntoConstraints = false
        pc.currentPageIndicatorTintColor = .white
        pc.pageIndicatorTintColor = UIColor.white.withAlphaComponent(0.4)
        pc.hidesForSinglePage = true
        pc.isUserInteractionEnabled = false
        return pc
    }()

    private var isSaving = false

    // MARK: - Interactive dismiss

    /// Distance (pt) past which a release ends in dismissal. Below this the
    /// gesture snaps back, letting the user freely drag in any direction and
    /// release without losing the viewer.
    private static let dismissTranslationThreshold: CGFloat = 120
    /// Vertical velocity (pt/s) that triggers dismissal regardless of distance —
    /// gives a quick flick the expected "throw it away" behavior.
    private static let dismissVelocityThreshold: CGFloat = 1400
    /// Distance at which the background reaches full fade.
    private static let fadeRange: CGFloat = 260
    /// Snapshot of the current page that rides with the finger during a drag.
    /// Using a snapshot (instead of transforming the internal scrollView) keeps
    /// horizontal paging undisturbed and lets the image travel partway off-screen.
    private var dragSnapshot: UIView?
    private weak var pageScrollView: UIScrollView?

    override func viewDidLoad() {
        super.viewDidLoad()
        // Hide Lightbox's built-in top-right close button; replaced by our own top-left X.
        headerView.closeButton.isHidden = true

        pageDelegate = self
        imageTapDelegate = self
        releaseAnimationsOutsidePreload(around: currentPage)
        installCloseButton()
        view.addSubview(saveButton)
        view.addSubview(pageControl)

        pageControl.numberOfPages = images.count
        pageControl.currentPage = currentPage

        NSLayoutConstraint.activate([
            // Save button — right-aligned; bottom matches the page control baseline.
            saveButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            saveButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -2),

            // Dot indicator — centered horizontally; centerY matches save button.
            pageControl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pageControl.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
        ])

        installInteractiveDismissGesture()
    }

    private func releaseAnimationsOutsidePreload(around page: Int) {
        guard LightboxConfig.preload > 0 else { return }
        let lowerBound = max(0, page - LightboxConfig.preload)
        let upperBound = min(browserImages.count, page + LightboxConfig.preload)
        for (index, image) in browserImages.enumerated() where index < lowerBound || index >= upperBound {
            image.releaseAnimation()
        }
    }

    /// Lightbox's built-in pan-to-dismiss fires `dismiss(animated:)` the instant
    /// it detects any vertical movement, so even a tiny drag immediately
    /// triggers the close animation. We replace it with a gesture that renders
    /// a snapshot of the current page and lets the finger drag it freely in
    /// every direction — the image follows x/y, scales down with downward
    /// distance, and only actually dismisses when the release passes a
    /// distance or velocity threshold.
    private func installInteractiveDismissGesture() {
        guard let scrollView = view.subviews.compactMap({ $0 as? UIScrollView }).first else { return }
        pageScrollView = scrollView

        // Remove every non-built-in pan on the scrollView (the scrollView's own
        // pan — used for horizontal paging — is kept). The remaining one is
        // Lightbox's dismiss gesture.
        let pagingPan = scrollView.panGestureRecognizer
        for gr in scrollView.gestureRecognizers ?? [] where gr is UIPanGestureRecognizer && gr !== pagingPan {
            scrollView.removeGestureRecognizer(gr)
        }

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
        pan.delegate = self
        // Single-touch only — keeps two-finger pinch-to-zoom from also firing the dismiss pan.
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
    }

    /// Returns the inner zoom scroll view of the currently visible page, if any.
    /// Used to suppress the dismiss pan while the image is zoomed in (so the user
    /// can drag around inside the zoomed image instead of triggering dismissal).
    private func currentPageZoomScrollView() -> UIScrollView? {
        guard let paging = pageScrollView else { return nil }
        let midX = paging.contentOffset.x + paging.bounds.width / 2
        for page in paging.subviews where page.frame.contains(CGPoint(x: midX, y: page.frame.midY)) {
            if let sv = findScrollView(in: page) { return sv }
        }
        return nil
    }

    private func findScrollView(in view: UIView) -> UIScrollView? {
        if let sv = view as? UIScrollView { return sv }
        for sub in view.subviews {
            if let sv = findScrollView(in: sub) { return sv }
        }
        return nil
    }

    @objc private func handleDismissPan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)

        switch gesture.state {
        case .began:
            beginInteractiveDrag()

        case .changed:
            updateInteractiveDrag(translation: translation)

        case .ended:
            let shouldDismiss = translation.y > Self.dismissTranslationThreshold
                || velocity.y > Self.dismissVelocityThreshold
            if shouldDismiss {
                finishInteractiveDismiss()
            } else {
                cancelInteractiveDrag()
            }

        case .cancelled, .failed:
            cancelInteractiveDrag()

        default:
            break
        }
    }

    private func beginInteractiveDrag() {
        guard dragSnapshot == nil, let scrollView = pageScrollView else { return }
        guard let snapshot = scrollView.snapshotView(afterScreenUpdates: false) else { return }
        snapshot.frame = scrollView.convert(scrollView.bounds, to: view)
        view.insertSubview(snapshot, aboveSubview: scrollView)
        // Hide the live scrollView so the snapshot is the only thing that moves;
        // the paging state (contentOffset / currentPage) is preserved untouched.
        scrollView.isHidden = true
        dragSnapshot = snapshot
    }

    private func updateInteractiveDrag(translation: CGPoint) {
        guard let snap = dragSnapshot else { return }
        // Scale is driven by downward distance only — dragging up or sideways
        // translates without shrinking, which feels more like grabbing the photo.
        let downward = max(translation.y, 0)
        let progress = min(downward / Self.fadeRange, 1.0)
        let scale = 1 - 0.25 * progress

        snap.transform = CGAffineTransform(translationX: translation.x, y: translation.y)
            .scaledBy(x: scale, y: scale)

        view.backgroundColor = UIColor.black.withAlphaComponent(1 - 0.85 * progress)
        let chromeAlpha = 1 - progress
        closeButton.alpha = chromeAlpha
        saveButton.alpha = chromeAlpha
        pageControl.alpha = chromeAlpha
        headerView.alpha = chromeAlpha
        footerView.alpha = chromeAlpha
    }

    private func cancelInteractiveDrag() {
        guard let snap = dragSnapshot else { return }
        UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
            snap.transform = .identity
            self.view.backgroundColor = .black
            self.closeButton.alpha = 1
            self.saveButton.alpha = 1
            self.pageControl.alpha = 1
            self.headerView.alpha = 1
            self.footerView.alpha = 1
        } completion: { _ in
            self.pageScrollView?.isHidden = false
            snap.removeFromSuperview()
            self.dragSnapshot = nil
        }
    }

    private func finishInteractiveDismiss() {
        // The snapshot stays at its dragged position; the VC's dismiss transition
        // fades the whole hierarchy (including the snapshot) out together, so the
        // image doesn't snap back to the center before disappearing.
        dismiss(animated: true)
    }

    /// Installs the close button at top-left. Sized to match a navigation-bar
    /// button (44pt tap area, 17pt symbol). On iOS 26+ wraps it in a Liquid
    /// Glass `UIVisualEffectView` to match the native video player look;
    /// earlier OS versions show the bare icon (no background chrome).
    private func installCloseButton() {
        let size: CGFloat = 44

        if #available(iOS 26.0, *) {
            let effectView = UIVisualEffectView(effect: UIGlassEffect())
            effectView.layer.cornerRadius = size / 2
            effectView.clipsToBounds = true
            effectView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(effectView)
            effectView.contentView.addSubview(closeButton)

            NSLayoutConstraint.activate([
                effectView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
                effectView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
                effectView.widthAnchor.constraint(equalToConstant: size),
                effectView.heightAnchor.constraint(equalToConstant: size),

                closeButton.topAnchor.constraint(equalTo: effectView.contentView.topAnchor),
                closeButton.leadingAnchor.constraint(equalTo: effectView.contentView.leadingAnchor),
                closeButton.trailingAnchor.constraint(equalTo: effectView.contentView.trailingAnchor),
                closeButton.bottomAnchor.constraint(equalTo: effectView.contentView.bottomAnchor),
            ])
        } else {
            view.addSubview(closeButton)
            NSLayoutConstraint.activate([
                closeButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
                closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
                closeButton.widthAnchor.constraint(equalToConstant: size),
                closeButton.heightAnchor.constraint(equalToConstant: size),
            ])
        }
    }

    @objc private func closeButtonTapped() {
        dismiss(animated: true)
    }

    @objc private func saveButtonTapped() {
        guard !isSaving else { return }
        guard currentPage < images.count else { return }
        let target = images[currentPage]

        if let image = target.image {
            requestPermissionAndSave(image)
            return
        }

        guard let url = target.imageURL else { return }
        isSaving = true
        SDWebImageManager.shared.loadImage(
            with: url,
            options: [],
            context: ImageCacheManager.shared.fullScreenContentContext,
            progress: nil
        ) { [weak self] image, _, _, _, _, _ in
            guard let self else { return }
            self.isSaving = false
            guard let image else {
                self.showToast(String(localized: "image_browser.save.failed"))
                return
            }
            self.requestPermissionAndSave(image)
        }
    }

    private func requestPermissionAndSave(_ image: UIImage) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                switch status {
                case .authorized, .limited:
                    UIImageWriteToSavedPhotosAlbum(image, self, #selector(self.saveCompleted(_:error:context:)), nil)
                default:
                    self.showToast(String(localized: "image_browser.save.permission_denied"))
                }
            }
        }
    }

    @objc private func saveCompleted(_ image: UIImage, error: Error?, context: UnsafeRawPointer?) {
        if error != nil {
            showToast(String(localized: "image_browser.save.failed"))
        } else {
            showToast(String(localized: "image_browser.save.success"))
        }
    }

    private func showToast(_ text: String) {
        let container = UIView()
        container.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        container.layer.cornerRadius = 10
        container.layer.masksToBounds = true
        container.translatesAutoresizingMaskIntoConstraints = false
        container.alpha = 0

        let label = UILabel()
        label.text = text
        label.textColor = .white
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(label)
        view.addSubview(container)

        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            container.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            container.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.8),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])

        UIView.animate(withDuration: 0.2, animations: {
            container.alpha = 1
        }) { _ in
            UIView.animate(withDuration: 0.25, delay: 1.2, options: [], animations: {
                container.alpha = 0
            }, completion: { _ in
                container.removeFromSuperview()
            })
        }
    }
}

// MARK: - LightboxControllerPageDelegate

extension ImageBrowserController: LightboxControllerPageDelegate {
    func lightboxController(_ controller: LightboxController, didMoveToPage page: Int) {
        pageControl.currentPage = page
        releaseAnimationsOutsidePreload(around: page)
    }
}

// MARK: - LightboxControllerTapDelegate

extension ImageBrowserController: LightboxControllerTapDelegate {
    func lightboxController(_ controller: LightboxController, didTap image: LightboxImage, at index: Int) {
        dismiss(animated: true)
    }

    func lightboxController(_ controller: LightboxController, didDoubleTap image: LightboxImage, at index: Int) {
        // PageView has already toggled its zoom scale. Keeping this callback a
        // no-op prevents the single-tap close path from consuming a double tap.
    }
}

// MARK: - UIGestureRecognizerDelegate

extension ImageBrowserController: UIGestureRecognizerDelegate {
    /// Only start the dismiss pan when the initial motion is clearly vertical,
    /// so horizontal swipes still page through images.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        // While the current page is zoomed in, let the inner scroll view own the
        // pan so the user can drag the magnified image instead of dismissing.
        if let zoom = currentPageZoomScrollView(), zoom.zoomScale > zoom.minimumZoomScale + 0.001 {
            return false
        }
        let velocity = pan.velocity(in: view)
        // Velocity is more reliable at `.began` than translation (which is still near zero).
        return abs(velocity.y) > abs(velocity.x)
    }

    /// Allow the dismiss pan to coexist with the paging scrollView's own pan —
    /// without this UIKit picks one and the superview gesture loses to the
    /// deeper scrollView gesture, so the snapshot drag never gets a chance.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // The custom one-finger dismiss pan must never join the page's two-
        // finger pinch. Horizontal paging still needs simultaneous recognition.
        if gestureRecognizer is UIPinchGestureRecognizer || otherGestureRecognizer is UIPinchGestureRecognizer {
            return false
        }
        return true
    }
}
