import CookedHTML
import SDWebImage
import UIKit

/// Shared identity, statistics, and image backdrop for personal and public profiles.
final class ProfileHeaderView: UIView {
    enum StatType: Int {
        case topics, posts, likes, days
    }

    enum MessageAction {
        case inbox, compose
    }
    var onStatTapped: ((ProfileHeaderView.StatType) -> Void)?
    var onMessageTapped: (() -> Void)?
    var onAppearanceChanged: (() -> Void)?

    var avatarHeight: CGFloat { avatarSize.constant }
    var pagePalette: ProfilePagePalette { ThemeManager.shared.profilePagePalette(imageTint: imageTint) }

    private let avatar = UIImageView()
    private let avatarFallback = UILabel()
    private let avatarContainer = UIView()
    private let nameLabel = UILabel()
    private let identityTextStack = UIStackView()
    private let detailsStack = UIStackView()
    private let messageButton = UIButton(type: .system)
    private let messageUnreadDot = UIView()
    private var messageButtonSize: NSLayoutConstraint!
    private let usernameLabel = UILabel()
    private let titleLabel = UILabel()
    private let bioLabel = UILabel()
    private let joinedLabel = UILabel()
    private let identityRow = UIStackView()
    private let statsGrid = UIStackView()
    private let content = UIStackView()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)
    private let cardBackgroundContainer = UIView()
    private let cardBackgroundImage = UIImageView()
    private let cardBackgroundLoader = UIImageView()
    private let cardBackgroundScrim = UIView()
    private let cardBackgroundFade = CAGradientLayer()
    private var cardBackgroundURL: URL?
    private var backgroundRequestID = 0
    private var isLoadingBackground = false
    private var imageTint: UIColor?
    private var backgroundTopInset: CGFloat = 0
    private var backgroundPullDistance: CGFloat = 0
    private var avatarSize: NSLayoutConstraint!
    private var avatarURL: URL?
    private let stats: [MeProfileStatControl] = [
        MeProfileStatControl(type: .topics, title: String(localized: "me.stats.topics")),
        MeProfileStatControl(type: .posts, title: String(localized: "me.stats.posts")),
        MeProfileStatControl(type: .likes, title: String(localized: "me.stats.likes")),
        MeProfileStatControl(type: .days, title: String(localized: "me.stats.days")),
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "me.profile.header"
        setupLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupLayout() {
        cardBackgroundContainer.isUserInteractionEnabled = false
        cardBackgroundContainer.accessibilityElementsHidden = true
        cardBackgroundContainer.clipsToBounds = true
        cardBackgroundContainer.accessibilityIdentifier = "me.profile.backdrop"
        cardBackgroundImage.contentMode = .scaleToFill
        cardBackgroundImage.clipsToBounds = true
        cardBackgroundImage.accessibilityIdentifier = "me.profile.card_background"
        cardBackgroundScrim.accessibilityIdentifier = "me.profile.scrim"
        addSubview(cardBackgroundContainer)
        for view in [cardBackgroundImage, cardBackgroundScrim] {
            cardBackgroundContainer.addSubview(view)
        }
        cardBackgroundFade.locations = [0, 0.18, 0.65, 1]
        cardBackgroundFade.startPoint = CGPoint(x: 0.5, y: 0)
        cardBackgroundFade.endPoint = CGPoint(x: 0.5, y: 1)
        cardBackgroundContainer.layer.addSublayer(cardBackgroundFade)

        avatar.contentMode = .scaleAspectFill
        avatar.clipsToBounds = true
        avatarContainer.clipsToBounds = true
        avatarFallback.textAlignment = .center
        for view in [avatarFallback, avatar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            avatarContainer.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: avatarContainer.topAnchor),
                view.bottomAnchor.constraint(equalTo: avatarContainer.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: avatarContainer.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: avatarContainer.trailingAnchor),
            ])
        }
        avatarContainer.isAccessibilityElement = false
        avatarContainer.accessibilityIdentifier = "me.profile.avatar"
        avatarFallback.isAccessibilityElement = false
        avatar.isAccessibilityElement = false
        avatarContainer.translatesAutoresizingMaskIntoConstraints = false
        avatarSize = avatarContainer.widthAnchor.constraint(equalToConstant: 64)
        NSLayoutConstraint.activate([
            avatarSize,
            avatarContainer.heightAnchor.constraint(equalTo: avatarContainer.widthAnchor),
        ])

        messageButton.accessibilityIdentifier = "me.messages"
        messageButton.accessibilityLabel = String(localized: "me.messages")
        messageButton.translatesAutoresizingMaskIntoConstraints = false
        messageButtonSize = messageButton.widthAnchor.constraint(equalToConstant: 44)
        NSLayoutConstraint.activate([
            messageButtonSize,
            messageButton.heightAnchor.constraint(equalTo: messageButton.widthAnchor),
        ])
        messageButton.addAction(UIAction { [weak self] _ in self?.onMessageTapped?() }, for: .touchUpInside)
        messageUnreadDot.translatesAutoresizingMaskIntoConstraints = false
        messageUnreadDot.isUserInteractionEnabled = false
        messageUnreadDot.isAccessibilityElement = false
        messageUnreadDot.layer.cornerRadius = 5
        messageUnreadDot.layer.borderWidth = 2
        messageButton.addSubview(messageUnreadDot)
        NSLayoutConstraint.activate([
            messageUnreadDot.widthAnchor.constraint(equalToConstant: 10),
            messageUnreadDot.heightAnchor.constraint(equalToConstant: 10),
            messageUnreadDot.topAnchor.constraint(equalTo: messageButton.topAnchor, constant: 2),
            messageUnreadDot.trailingAnchor.constraint(equalTo: messageButton.trailingAnchor, constant: -2),
        ])
        nameLabel.accessibilityIdentifier = "me.profile.name"
        usernameLabel.accessibilityIdentifier = "me.profile.username"
        joinedLabel.accessibilityIdentifier = "me.profile.joined"
        identityTextStack.axis = .vertical
        identityTextStack.distribution = .equalSpacing
        identityTextStack.spacing = 2
        identityTextStack.addArrangedSubview(nameLabel)
        identityTextStack.addArrangedSubview(usernameLabel)
        identityTextStack.addArrangedSubview(joinedLabel)
        // The avatar, not the message button or optional profile details,
        // defines both edges of the identity text block.
        detailsStack.axis = .vertical
        detailsStack.spacing = 6
        [titleLabel, bioLabel].forEach { detailsStack.addArrangedSubview($0) }
        for label in [nameLabel, usernameLabel, titleLabel, bioLabel, joinedLabel] {
            label.numberOfLines = 0
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        nameLabel.accessibilityTraits = .header
        usernameLabel.numberOfLines = 1
        joinedLabel.numberOfLines = 1
        joinedLabel.adjustsFontSizeToFitWidth = true
        joinedLabel.minimumScaleFactor = 0.8
        joinedLabel.lineBreakMode = .byTruncatingTail
        nameLabel.lineBreakMode = .byTruncatingTail
        usernameLabel.lineBreakMode = .byTruncatingTail
        identityRow.axis = .horizontal
        identityRow.alignment = .center
        identityRow.spacing = 16
        identityRow.addArrangedSubview(avatarContainer)
        identityRow.addArrangedSubview(identityTextStack)
        identityTextStack.heightAnchor.constraint(equalTo: avatarContainer.heightAnchor).isActive = true

        statsGrid.distribution = .fillEqually
        statsGrid.spacing = 16
        for pair in [Array(stats.prefix(2)), Array(stats.suffix(2))] {
            let row = UIStackView(arrangedSubviews: pair)
            row.distribution = .fillEqually
            row.spacing = 12
            statsGrid.addArrangedSubview(row)
        }
        for stat in stats {
            stat.addAction(UIAction { [weak self, weak stat] _ in
                guard let stat else { return }
                self?.onStatTapped?(stat.type)
            }, for: .touchUpInside)
        }

        content.addArrangedSubview(identityRow)
        content.addArrangedSubview(detailsStack)
        content.addArrangedSubview(statsGrid)
        content.axis = .vertical
        content.spacing = 22
        content.setCustomSpacing(12, after: identityRow)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            content.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -24),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -30),
        ])
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.hidesWhenStopped = true
        loadingIndicator.accessibilityLabel = String(localized: "me.loading_profile")
        addSubview(loadingIndicator)
        NSLayoutConstraint.activate([
            loadingIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            loadingIndicator.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            loadingIndicator.widthAnchor.constraint(equalToConstant: 20),
            loadingIndicator.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    func configure(
        user: DiscourseCurrentUser?,
        profile: DiscourseUserProfile?,
        summary: DiscourseUserSummary?,
        isAuthenticated: Bool,
        fallbackUsername: String?,
        assetBaseURL: String,
        unreadMessages: Bool = false,
        messageAction: MessageAction = .inbox,
        showsMessageButton: Bool = true
    ) {
        let fonts = FontManager.shared
        let palette = pagePalette.header
        backgroundColor = palette.background
        nameLabel.font = fonts.font(size: 24, weight: .bold)
        nameLabel.numberOfLines = isAuthenticated ? 1 : 0
        usernameLabel.font = fonts.font(size: 14)
        titleLabel.font = fonts.font(size: 13, weight: .medium)
        bioLabel.font = fonts.font(size: 14)
        joinedLabel.font = fonts.font(size: 12)
        nameLabel.textColor = palette.foreground
        titleLabel.textColor = palette.foreground
        bioLabel.textColor = palette.foreground
        usernameLabel.textColor = palette.secondaryForeground
        joinedLabel.textColor = palette.secondaryForeground
        avatarContainer.backgroundColor = palette.foreground.withAlphaComponent(0.16)
        avatarFallback.textColor = palette.foreground
        avatarFallback.font = fonts.font(size: 28, weight: .medium)
        statsGrid.axis = fonts.scale >= 1.35 ? .vertical : .horizontal
        let showsMessages = isAuthenticated && showsMessageButton
        if showsMessages, !identityRow.arrangedSubviews.contains(messageButton) {
            identityRow.addArrangedSubview(messageButton)
        } else if !showsMessages, identityRow.arrangedSubviews.contains(messageButton) {
            identityRow.removeArrangedSubview(messageButton)
            messageButton.removeFromSuperview()
        }
        messageButtonSize.constant = max(44, fonts.scaled(44))
        var messageConfiguration = UIButton.Configuration.plain()
        messageConfiguration.image = UIImage(systemName: "envelope")
        messageConfiguration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: fonts.scaled(16), weight: .light
        )
        messageConfiguration.baseForegroundColor = palette.foreground
        messageConfiguration.background.backgroundColor = palette.foreground.withAlphaComponent(0.12)
        messageConfiguration.cornerStyle = .capsule
        messageConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
        messageButton.configuration = messageConfiguration
        messageButton.accessibilityLabel = messageAction == .inbox
            ? String(localized: "me.messages") : String(localized: "user.send_message")
        messageButton.accessibilityValue = isAuthenticated && unreadMessages ? String(localized: "me.unread") : nil
        messageUnreadDot.backgroundColor = .systemRed
        messageUnreadDot.isHidden = !isAuthenticated || !unreadMessages

        let username = isAuthenticated ? (user?.username ?? fallbackUsername) : nil
        let displayName = [profile?.name, user?.name, username]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        nameLabel.text = isAuthenticated
            ? (displayName ?? String(localized: "tab.me"))
            : String(localized: "me.guest.title")
        usernameLabel.text = username.map { "@\($0)" }
        usernameLabel.isHidden = username == nil
        titleLabel.text = isAuthenticated ? profile?.title : nil
        titleLabel.isHidden = titleLabel.text?.isEmpty != false
        avatarFallback.text = displayName.map { String($0.prefix(1)).uppercased() }
        if !isAuthenticated { avatarFallback.text = nil }

        bioLabel.attributedText = isAuthenticated ? renderedBio(profile?.bioCooked, color: palette.foreground) : nil
        if !isAuthenticated { bioLabel.text = String(localized: "me.login_prompt") }
        bioLabel.isHidden = bioLabel.text?.isEmpty != false
        joinedLabel.text = isAuthenticated ? joinedDate(profile?.createdAt) : nil
        joinedLabel.isHidden = joinedLabel.text == nil
        let dateHeight = joinedLabel.isHidden ? 0 : joinedLabel.font.lineHeight
        let minimumTextHeight = nameLabel.font.lineHeight + usernameLabel.font.lineHeight + dateHeight + 4
        avatarSize.constant = max(fonts.scaled(64), ceil(minimumTextHeight))
        avatarContainer.layer.cornerRadius = avatarSize.constant / 2
        detailsStack.isHidden = titleLabel.isHidden && bioLabel.isHidden

        let showsStats = isAuthenticated && summary != nil
        if showsStats, !content.arrangedSubviews.contains(statsGrid) {
            content.addArrangedSubview(statsGrid)
        } else if !showsStats, content.arrangedSubviews.contains(statsGrid) {
            content.removeArrangedSubview(statsGrid)
            statsGrid.removeFromSuperview()
        }
        if let summary, isAuthenticated {
            let values = [summary.topicCount, summary.postCount, summary.likesReceived, summary.daysVisited]
            for (stat, value) in zip(stats, values) { stat.configure(value: value, palette: palette) }
        }

        let template = isAuthenticated ? (profile?.avatarTemplate ?? user?.avatarTemplate) : nil
        let path = template?.replacingOccurrences(of: "{size}", with: "240")
        let url = path.flatMap { URL(string: $0.hasPrefix("http") ? $0 : assetBaseURL + $0) }
        if url != avatarURL {
            avatar.sd_cancelCurrentImageLoad()
            avatarURL = url
            avatar.image = nil
            avatarFallback.isHidden = false
            if let url {
                avatar.sd_setImage(with: url, placeholderImage: nil, options: [], context: ImageCacheManager.shared.avatarContext, progress: nil) { [weak self] image, _, _, completedURL in
                    guard let self, self.avatarURL == completedURL else { return }
                    self.avatarFallback.isHidden = image != nil
                }
            }
        }
        if !isAuthenticated || (displayName == nil && url == nil) {
            avatar.image = UIImage(systemName: "person.fill")
            avatar.tintColor = palette.foreground
            avatar.contentMode = .scaleAspectFit
        } else {
            avatar.contentMode = .scaleAspectFill
            if url == nil { avatar.image = nil }
        }
        updateCardBackground(isAuthenticated ? profile?.cardBackgroundURL(relativeTo: assetBaseURL) : nil)
    }

    private func updateCardBackground(_ url: URL?) {
        if url == cardBackgroundURL, cardBackgroundImage.image != nil || isLoadingBackground {
            applyCardBackgroundAppearance()
            return
        }
        backgroundRequestID += 1
        let requestID = backgroundRequestID
        let hadImage = cardBackgroundImage.image != nil
        cardBackgroundLoader.sd_cancelCurrentImageLoad()
        cardBackgroundLoader.image = nil
        cardBackgroundImage.image = nil
        imageTint = nil
        cardBackgroundURL = url
        isLoadingBackground = url != nil
        applyCardBackgroundAppearance()
        if hadImage { notifyAppearanceChanged() }
        guard let url else { return }
        cardBackgroundLoader.sd_setImage(
            with: url,
            placeholderImage: nil,
            options: [.scaleDownLargeImages, .retryFailed],
            context: ImageCacheManager.shared.contentContext,
            progress: nil
        ) { [weak self] image, _, _, _ in
            guard let self, self.backgroundRequestID == requestID else { return }
            guard let image, let source = image.cgImage else {
                self.isLoadingBackground = false
                self.applyCardBackgroundAppearance()
                return
            }
            let orientation = MeHeaderImageProcessor.exifOrientation(for: image.imageOrientation)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let prepared = MeHeaderImageProcessor.prepare(source, exifOrientation: orientation)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.backgroundRequestID == requestID else { return }
                    self.isLoadingBackground = false
                    self.cardBackgroundLoader.image = nil
                    guard let prepared, let tint = prepared.tint else {
                        // No visual change to publish. Publishing an empty result
                        // would reconfigure the header and retry the same image.
                        self.applyCardBackgroundAppearance()
                        return
                    }
                    self.cardBackgroundImage.image = UIImage(cgImage: prepared.image)
                    self.imageTint = UIColor(red: tint.red, green: tint.green, blue: tint.blue, alpha: 1)
                    self.applyCardBackgroundAppearance()
                    self.notifyAppearanceChanged()
                }
            }
        }
    }

    private func notifyAppearanceChanged() {
        // Clearing an old image can occur inside the controller's updateUI.
        // Deliver its palette change on the next turn to avoid reentrant binding.
        DispatchQueue.main.async { [weak self] in self?.onAppearanceChanged?() }
    }

    private func applyCardBackgroundAppearance() {
        let palette = pagePalette.header
        let hasImage = cardBackgroundImage.image != nil
        cardBackgroundImage.isHidden = !hasImage
        backgroundColor = palette.background
        cardBackgroundContainer.backgroundColor = palette.background
        cardBackgroundScrim.isHidden = !hasImage
        cardBackgroundScrim.backgroundColor = palette.imageScrim
        // Keep more than three quarters of the photograph visible. Text gets
        // its own small shadow instead of darkening or whitening the whole image.
        cardBackgroundScrim.alpha = 0.32
        nameLabel.textColor = palette.foreground
        titleLabel.textColor = palette.foreground
        bioLabel.textColor = palette.foreground
        if let biography = bioLabel.attributedText {
            let attributed = NSMutableAttributedString(attributedString: biography)
            attributed.addAttribute(.foregroundColor, value: palette.foreground, range: NSRange(location: 0, length: attributed.length))
            bioLabel.attributedText = attributed
        }
        avatarFallback.textColor = palette.foreground
        avatar.tintColor = palette.foreground
        avatarContainer.backgroundColor = palette.foreground.withAlphaComponent(0.16)
        var messageConfiguration = messageButton.configuration
        messageConfiguration?.baseForegroundColor = palette.foreground
        messageConfiguration?.background.backgroundColor = palette.foreground.withAlphaComponent(0.12)
        messageButton.configuration = messageConfiguration
        messageUnreadDot.layer.borderColor = palette.background.resolvedColor(with: traitCollection).cgColor
        loadingIndicator.color = palette.foreground
        usernameLabel.textColor = palette.secondaryForeground
        joinedLabel.textColor = palette.secondaryForeground
        for label in [nameLabel, usernameLabel, joinedLabel, titleLabel, bioLabel] {
            ProfileTextReadability.apply(to: label, palette: palette, onImage: hasImage)
        }
        for stat in stats { stat.applyColors(palette: palette, onImage: hasImage) }
        layoutBackground()
        updateBackgroundFade()
    }

    func updateBackdrop(topInset: CGFloat, pullDistance: CGFloat) {
        backgroundTopInset = max(0, topInset)
        backgroundPullDistance = max(0, pullDistance)
        layoutBackground()
    }

    func setLoading(_ loading: Bool) {
        if loading { loadingIndicator.startAnimating() } else { loadingIndicator.stopAnimating() }
    }

    private func layoutBackground() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cardBackgroundContainer.frame = MeHeaderScrollGeometry.backdropFrame(
            headerSize: bounds.size, topInset: backgroundTopInset, pullDistance: backgroundPullDistance
        )
        if let image = cardBackgroundImage.image {
            cardBackgroundImage.frame = MeHeaderScrollGeometry.imageFrame(
                imageSize: image.size, viewport: cardBackgroundContainer.bounds.size, pullDistance: backgroundPullDistance
            )
        } else {
            cardBackgroundImage.frame = cardBackgroundContainer.bounds
        }
        cardBackgroundScrim.frame = cardBackgroundContainer.bounds
        cardBackgroundFade.frame = cardBackgroundContainer.bounds
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutBackground()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            applyCardBackgroundAppearance()
        }
    }

    private func updateBackgroundFade() {
        let color = pagePalette.header.background.resolvedColor(with: traitCollection)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cardBackgroundFade.frame = cardBackgroundContainer.bounds
        cardBackgroundFade.colors = [
            color.withAlphaComponent(0.08).cgColor, color.withAlphaComponent(0).cgColor,
            color.withAlphaComponent(0.04).cgColor, color.cgColor,
        ]
        CATransaction.commit()
    }

    private func renderedBio(_ cooked: String?, color: UIColor) -> NSAttributedString? {
        guard let cooked, !cooked.isEmpty else { return nil }
        let config = AttributedStringConfig(
            baseFont: FontManager.shared.font(size: 14),
            baseColor: color,
            codeFont: FontManager.shared.monospacedFont(size: 13),
            codeBackgroundColor: color.withAlphaComponent(0.12)
        )
        let result = NSMutableAttributedString()
        for block in CookedHTMLParser.parse(html: cooked) {
            guard case .paragraph(let inlines) = block else { continue }
            if result.length > 0 { result.append(NSAttributedString(string: "\n")) }
            result.append(inlines.attributedString(config: config))
        }
        // Biography links use the same contrasting foreground on the accent surface.
        result.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: result.length))
        return result.length > 0 ? result : nil
    }

    private func joinedDate(_ value: String?) -> String? {
        guard let value else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: value) ?? ISO8601DateFormatter().date(from: value) else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return String(localized: "me.joined_date \(formatter.string(from: date))")
    }
}

/// Fixed compact units keep all four statistics readable in narrow columns.
enum ProfileStatFormatter {
    private static let decimalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    private static let scientificFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .scientific
        formatter.positiveFormat = "0.#E0"
        formatter.negativeFormat = "-0.#E0"
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    static func string(for value: Int) -> String {
        var amount = Double(value.magnitude)
        guard amount >= 1_000 else { return value.formatted() }
        var unit = 0
        while amount >= 1_000, unit < 4 {
            amount /= 1_000
            unit += 1
        }
        amount = (amount * 10).rounded() / 10
        // Promote rounding boundaries, e.g. 999,950 -> 1M instead of 1000k.
        if amount >= 1_000 {
            amount /= 1_000
            unit += 1
        }
        if unit > 4 {
            return scientificFormatter.string(from: NSNumber(value: value)) ?? value.formatted()
        }
        let signedAmount = value < 0 ? -amount : amount
        let number = decimalFormatter.string(from: NSNumber(value: signedAmount)) ?? value.formatted()
        switch unit {
        case 1: return String(localized: "me.stats.compact.thousands \(number)")
        case 2: return String(localized: "me.stats.compact.millions \(number)")
        case 3: return String(localized: "me.stats.compact.billions \(number)")
        default: return String(localized: "me.stats.compact.trillions \(number)")
        }
    }
}

private final class MeProfileStatControl: UIControl {
    let type: ProfileHeaderView.StatType
    private let valueLabel = UILabel()
    private let captionLabel = UILabel()

    init(type: ProfileHeaderView.StatType, title: String) {
        self.type = type
        super.init(frame: .zero)
        captionLabel.text = title
        valueLabel.accessibilityIdentifier = "me.stats.\(type).value"
        captionLabel.numberOfLines = 0
        captionLabel.textAlignment = .center
        valueLabel.textAlignment = .center
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.65
        let content = UIStackView(arrangedSubviews: [valueLabel, captionLabel])
        content.axis = .vertical
        content.spacing = 5
        content.isUserInteractionEnabled = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        isAccessibilityElement = true
        let isLink = type == .topics || type == .posts
        accessibilityTraits = isLink ? .button : .staticText
        isUserInteractionEnabled = isLink
        accessibilityIdentifier = "me.stats.\(type)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    func configure(value: Int, palette: ProfileHeaderPalette) {
        valueLabel.text = ProfileStatFormatter.string(for: value)
        valueLabel.font = FontManager.shared.monospacedDigitFont(size: 22, weight: .semibold)
        captionLabel.font = FontManager.shared.font(size: 12)
        applyColors(palette: palette, onImage: false)
        accessibilityLabel = "\(value.formatted()), \(captionLabel.text ?? "")"
    }

    func applyColors(palette: ProfileHeaderPalette, onImage: Bool) {
        valueLabel.textColor = palette.foreground
        captionLabel.textColor = onImage ? palette.foreground : palette.secondaryForeground
        for label in [valueLabel, captionLabel] {
            ProfileTextReadability.apply(to: label, palette: palette, onImage: onImage)
        }
    }
}

private enum ProfileTextReadability {
    static func apply(to label: UILabel, palette: ProfileHeaderPalette, onImage: Bool) {
        let foreground = palette.foreground.resolvedColor(with: label.traitCollection)
        label.layer.shadowColor = (foreground == .white ? UIColor.black : UIColor.white).cgColor
        label.layer.shadowOffset = CGSize(width: 0, height: 1)
        label.layer.shadowRadius = 2
        label.layer.shadowOpacity = onImage ? 0.4 : 0
        label.layer.masksToBounds = false
    }
}
