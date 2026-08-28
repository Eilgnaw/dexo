import UIKit

/// A quiet loading placeholder matching the personal center's two-part layout.
final class MeSkeletonView: UIView {
    private let header = UIView()
    private let sheet = UIView()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let loadingLabel = UILabel()
    private var headerMarks: [UIView] = []
    private var sheetMarks: [UIView] = []
    private var cards: [UIView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "me.loading"
        setupLayout()
        setLoading(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func mark(width: CGFloat? = nil, height: CGFloat, onHeader: Bool = false) -> UIView {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.layer.cornerRadius = min(height / 2, 6)
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        if let width { view.widthAnchor.constraint(equalToConstant: width).isActive = true }
        if onHeader { headerMarks.append(view) } else { sheetMarks.append(view) }
        return view
    }

    private func setupLayout() {
        let avatar = mark(width: 64, height: 64, onHeader: true)
        avatar.layer.cornerRadius = 32
        let names = UIStackView(arrangedSubviews: [
            mark(width: 112, height: 26, onHeader: true),
            mark(width: 80, height: 16, onHeader: true),
            mark(width: 120, height: 12, onHeader: true),
        ])
        names.axis = .vertical
        names.alignment = .leading
        names.distribution = .equalSpacing
        let message = mark(width: 44, height: 44, onHeader: true)
        message.layer.cornerRadius = 22
        let identity = UIStackView(arrangedSubviews: [avatar, names, message])
        names.heightAnchor.constraint(equalTo: avatar.heightAnchor).isActive = true
        identity.alignment = .center
        identity.spacing = 16
        let stats = UIStackView()
        stats.distribution = .fillEqually
        stats.spacing = 16
        for _ in 0..<4 {
            let stat = UIStackView(arrangedSubviews: [
                mark(width: 36, height: 22, onHeader: true),
                mark(width: 42, height: 10, onHeader: true),
            ])
            stat.axis = .vertical
            stat.alignment = .center
            stat.spacing = 8
            stats.addArrangedSubview(stat)
        }
        let headerContent = UIStackView(arrangedSubviews: [identity, stats])
        headerContent.axis = .vertical
        headerContent.spacing = 12
        headerContent.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerContent)

        let sheetContent = UIStackView()
        sheetContent.axis = .vertical
        sheetContent.spacing = 20
        loadingLabel.text = String(localized: "me.loading_profile")
        loadingLabel.numberOfLines = 0
        loadingLabel.textAlignment = .center
        loadingLabel.accessibilityTraits = .updatesFrequently
        activityIndicator.isAccessibilityElement = false
        let loadingRow = UIStackView(arrangedSubviews: [activityIndicator, loadingLabel])
        loadingRow.alignment = .center
        loadingRow.spacing = 10
        loadingRow.translatesAutoresizingMaskIntoConstraints = false
        let loadingContainer = UIView()
        loadingContainer.addSubview(loadingRow)
        NSLayoutConstraint.activate([
            loadingRow.centerXAnchor.constraint(equalTo: loadingContainer.centerXAnchor),
            loadingRow.leadingAnchor.constraint(greaterThanOrEqualTo: loadingContainer.leadingAnchor),
            loadingRow.trailingAnchor.constraint(lessThanOrEqualTo: loadingContainer.trailingAnchor),
            loadingRow.topAnchor.constraint(equalTo: loadingContainer.topAnchor, constant: 8),
            loadingRow.bottomAnchor.constraint(equalTo: loadingContainer.bottomAnchor, constant: -8),
            loadingContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        sheetContent.addArrangedSubview(loadingContainer)
        accessibilityElements = [loadingLabel]
        for count in [1, 2, 3] {
            let rows = UIStackView()
            rows.axis = .vertical
            for _ in 0..<count {
                let row = UIStackView(arrangedSubviews: [
                    mark(width: 18, height: 18), mark(height: 14),
                ])
                row.alignment = .center
                row.spacing = 16
                row.isLayoutMarginsRelativeArrangement = true
                row.layoutMargins = UIEdgeInsets(top: 19, left: 16, bottom: 19, right: 32)
                rows.addArrangedSubview(row)
            }
            rows.layer.cornerRadius = 16
            rows.clipsToBounds = true
            cards.append(rows)
            sheetContent.addArrangedSubview(rows)
        }
        sheetContent.translatesAutoresizingMaskIntoConstraints = false
        sheet.addSubview(sheetContent)
        sheet.layer.cornerRadius = 28
        sheet.layer.cornerCurve = .continuous
        sheet.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        sheet.clipsToBounds = true

        for surface in [header, sheet] {
            surface.translatesAutoresizingMaskIntoConstraints = false
            addSubview(surface)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerContent.topAnchor.constraint(equalTo: header.topAnchor, constant: 18),
            headerContent.leadingAnchor.constraint(equalTo: header.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            headerContent.trailingAnchor.constraint(equalTo: header.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            headerContent.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -30),
            sheet.topAnchor.constraint(equalTo: header.bottomAnchor),
            sheet.leadingAnchor.constraint(equalTo: leadingAnchor),
            sheet.trailingAnchor.constraint(equalTo: trailingAnchor),
            sheet.bottomAnchor.constraint(equalTo: bottomAnchor),
            sheetContent.topAnchor.constraint(equalTo: sheet.topAnchor, constant: 16),
            sheetContent.leadingAnchor.constraint(equalTo: sheet.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            sheetContent.trailingAnchor.constraint(equalTo: sheet.safeAreaLayoutGuide.trailingAnchor, constant: -20),
        ])
    }

    func configureTheme() {
        let theme = ThemeManager.shared
        let palette = theme.profileHeaderPalette
        backgroundColor = palette.background
        header.backgroundColor = palette.background
        sheet.backgroundColor = theme.backgroundColor
        headerMarks.forEach { $0.backgroundColor = palette.foreground.withAlphaComponent(0.18) }
        sheetMarks.forEach { $0.backgroundColor = theme.accentColor.withAlphaComponent(0.12) }
        cards.forEach { $0.backgroundColor = theme.cardBackgroundColor }
        activityIndicator.color = theme.accentColor
        loadingLabel.font = FontManager.shared.font(size: 15)
        loadingLabel.textColor = .secondaryLabel
    }

    func setLoading(_ loading: Bool) {
        isHidden = !loading
        if loading {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }
    }
}
