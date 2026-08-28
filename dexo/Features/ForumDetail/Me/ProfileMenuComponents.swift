import UIKit

/// Common rounded, image-tinted sheet for both profile destinations.
class ProfileMenuSheetView: UIView {
    let content = UIStackView()
    private let backgroundEffect = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    private var groups: [UIStackView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 28
        layer.cornerCurve = .continuous
        layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        clipsToBounds = true
        backgroundEffect.translatesAutoresizingMaskIntoConstraints = false
        backgroundEffect.isUserInteractionEnabled = false
        backgroundEffect.accessibilityElementsHidden = true
        addSubview(backgroundEffect)
        content.axis = .vertical
        content.spacing = 20
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            backgroundEffect.topAnchor.constraint(equalTo: topAnchor),
            backgroundEffect.bottomAnchor.constraint(equalTo: bottomAnchor),
            backgroundEffect.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundEffect.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            content.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -20),
            content.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func makeGroup(_ views: [UIView]) -> UIStackView {
        let rows = UIStackView(arrangedSubviews: views)
        rows.axis = .vertical
        rows.spacing = 1 / UIScreen.main.scale
        rows.layer.cornerRadius = 16
        rows.layer.cornerCurve = .continuous
        rows.clipsToBounds = true
        groups.append(rows)
        return rows
    }

    func configureSurface(palette: ProfilePagePalette) {
        backgroundColor = palette.background
        backgroundEffect.isHidden = !palette.usesImageColors || UIAccessibility.isReduceTransparencyEnabled
        backgroundEffect.contentView.backgroundColor = palette.background.withAlphaComponent(0.65)
        groups.forEach { $0.backgroundColor = ThemeManager.shared.accentColor.withAlphaComponent(0.10) }
    }
}

final class ProfileMenuControl: UIControl {
    private let icon = UIImageView()
    private let unreadDot = UIView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let textStack = UIStackView()
    private let content = UIStackView()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let iconSize: NSLayoutConstraint

    init(title: String, symbol: String, identifier: String) {
        let iconContainer = UIView()
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconSize = iconContainer.widthAnchor.constraint(equalToConstant: 18)
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = title
        accessibilityIdentifier = identifier
        titleLabel.text = title
        titleLabel.numberOfLines = 0
        titleLabel.textAlignment = .natural
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.numberOfLines = 0
        detailLabel.setContentHuggingPriority(.required, for: .horizontal)
        detailLabel.font = FontManager.shared.font(size: 14)
        icon.image = UIImage(systemName: symbol)
        icon.accessibilityIdentifier = "\(identifier).icon"
        chevron.accessibilityIdentifier = "\(identifier).chevron"
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.addSubview(icon)
        unreadDot.translatesAutoresizingMaskIntoConstraints = false
        unreadDot.layer.cornerRadius = 4
        iconContainer.addSubview(unreadDot)
        NSLayoutConstraint.activate([
            iconSize,
            iconContainer.heightAnchor.constraint(equalTo: iconContainer.widthAnchor),
            icon.topAnchor.constraint(equalTo: iconContainer.topAnchor),
            icon.bottomAnchor.constraint(equalTo: iconContainer.bottomAnchor),
            icon.leadingAnchor.constraint(equalTo: iconContainer.leadingAnchor),
            icon.trailingAnchor.constraint(equalTo: iconContainer.trailingAnchor),
            unreadDot.widthAnchor.constraint(equalToConstant: 8),
            unreadDot.heightAnchor.constraint(equalToConstant: 8),
            unreadDot.topAnchor.constraint(equalTo: iconContainer.topAnchor, constant: -2),
            unreadDot.trailingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 3),
        ])
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(detailLabel)
        activityIndicator.hidesWhenStopped = true
        activityIndicator.isHidden = true
        let items: [UIView] = [iconContainer, textStack, activityIndicator, chevron]
        items.forEach { content.addArrangedSubview($0) }
        content.axis = .horizontal
        content.alignment = .center
        content.spacing = 14
        content.isUserInteractionEnabled = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
        ])
        chevron.contentMode = .scaleAspectFit
        chevron.widthAnchor.constraint(equalToConstant: 8).isActive = true
        chevron.heightAnchor.constraint(equalToConstant: 12).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.55 : 1 }
    }

    func configure(
        detail: String?, unread: Bool, palette: ProfilePagePalette,
        title: String? = nil, symbol: String? = nil,
        actionLabel: String? = nil, selected: Bool = false, isLoading: Bool = false
    ) {
        let theme = ThemeManager.shared
        let fonts = FontManager.shared
        backgroundColor = palette.cardBackground
        if let title { titleLabel.text = title; accessibilityLabel = title }
        if let symbol { icon.image = UIImage(systemName: symbol) }
        if let actionLabel { accessibilityLabel = actionLabel }
        accessibilityTraits = selected ? [.button, .selected] : .button
        isEnabled = !isLoading
        activityIndicator.color = theme.accentColor
        if isLoading { activityIndicator.startAnimating() } else { activityIndicator.stopAnimating() }
        chevron.isHidden = isLoading
        icon.tintColor = theme.accentColor
        iconSize.constant = fonts.scaled(18)
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: fonts.scaled(18))
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 11)
        titleLabel.font = fonts.font(size: 17)
        titleLabel.textColor = .label
        detailLabel.font = fonts.font(size: 14)
        detailLabel.textColor = .secondaryLabel
        detailLabel.text = detail
        detailLabel.isHidden = detail == nil
        textStack.axis = fonts.scale >= 1.3 ? .vertical : .horizontal
        textStack.alignment = fonts.scale >= 1.3 ? .fill : .center
        textStack.spacing = fonts.scale >= 1.3 ? 4 : 12
        chevron.tintColor = .tertiaryLabel
        unreadDot.backgroundColor = theme.accentColor
        unreadDot.isHidden = !unread
        accessibilityValue = unread ? String(localized: "me.unread") : detail
    }
}
