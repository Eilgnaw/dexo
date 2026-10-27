import UIKit

final class FontSizeViewController: ObservableViewController {
    override var backgroundStyle: BackgroundStyle { .grouped }

    private let settings = AppSettings.shared
    private let fontManager = FontManager.shared

    private let previewLabel: UILabel = {
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let levelLabel: UILabel = {
        let label = UILabel()
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var slider: UISlider = {
        let s = UISlider()
        s.minimumValue = -3
        s.maximumValue = 4
        s.value = Float(settings.fontSizeLevel)
        s.translatesAutoresizingMaskIntoConstraints = false
        s.addTarget(self, action: #selector(sliderChanged(_:)), for: .valueChanged)
        return s
    }()

    private let smallALabel: UILabel = {
        let label = UILabel()
        label.text = "A"
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let largeALabel: UILabel = {
        let label = UILabel()
        label.text = "A"
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "settings.font_size")
        setupUI()
    }

    private func setupUI() {
        let safeArea = view.safeAreaLayoutGuide
        let card = UIView()
        card.backgroundColor = ThemeManager.shared.cardBackgroundColor
        card.layer.cornerRadius = 12
        card.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(card)
        card.addSubview(previewLabel)
        card.addSubview(levelLabel)

        let sliderContainer = UIView()
        sliderContainer.backgroundColor = ThemeManager.shared.cardBackgroundColor
        sliderContainer.layer.cornerRadius = 12
        sliderContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sliderContainer)

        sliderContainer.addSubview(smallALabel)
        sliderContainer.addSubview(slider)
        sliderContainer.addSubview(largeALabel)

        let toggleContainer = UIView()
        toggleContainer.backgroundColor = ThemeManager.shared.cardBackgroundColor
        toggleContainer.layer.cornerRadius = 12
        toggleContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toggleContainer)

        let toggleLabel = UILabel()
        toggleLabel.text = String(localized: "settings.font_size.follow_system")
        toggleLabel.font = .preferredFont(forTextStyle: .body)
        toggleLabel.translatesAutoresizingMaskIntoConstraints = false
        toggleContainer.addSubview(toggleLabel)

        let toggle = UISwitch()
        toggle.isOn = settings.followSystemFontSize
        toggle.addTarget(self, action: #selector(followSystemToggleChanged(_:)), for: .valueChanged)
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggleContainer.addSubview(toggle)

        let hintLabel = UILabel()
        hintLabel.text = String(localized: "settings.font_size.follow_system.hint")
        hintLabel.font = .preferredFont(forTextStyle: .footnote)
        hintLabel.textColor = .secondaryLabel
        hintLabel.numberOfLines = 0
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hintLabel)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: safeArea.topAnchor, constant: 20),
            card.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor, constant: 20),
            card.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor, constant: -20),

            previewLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            previewLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            previewLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),

            levelLabel.topAnchor.constraint(equalTo: previewLabel.bottomAnchor, constant: 16),
            levelLabel.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            levelLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),

            sliderContainer.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 20),
            sliderContainer.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor, constant: 20),
            sliderContainer.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor, constant: -20),

            smallALabel.leadingAnchor.constraint(equalTo: sliderContainer.leadingAnchor, constant: 16),
            smallALabel.centerYAnchor.constraint(equalTo: sliderContainer.centerYAnchor),

            slider.leadingAnchor.constraint(equalTo: smallALabel.trailingAnchor, constant: 12),
            slider.trailingAnchor.constraint(equalTo: largeALabel.leadingAnchor, constant: -12),
            slider.topAnchor.constraint(equalTo: sliderContainer.topAnchor, constant: 16),
            slider.bottomAnchor.constraint(equalTo: sliderContainer.bottomAnchor, constant: -16),

            largeALabel.trailingAnchor.constraint(equalTo: sliderContainer.trailingAnchor, constant: -16),
            largeALabel.centerYAnchor.constraint(equalTo: sliderContainer.centerYAnchor),

            toggleContainer.topAnchor.constraint(equalTo: sliderContainer.bottomAnchor, constant: 20),
            toggleContainer.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor, constant: 20),
            toggleContainer.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor, constant: -20),

            toggleLabel.leadingAnchor.constraint(equalTo: toggleContainer.leadingAnchor, constant: 16),
            toggleLabel.centerYAnchor.constraint(equalTo: toggleContainer.centerYAnchor),
            toggleLabel.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -12),

            toggle.trailingAnchor.constraint(equalTo: toggleContainer.trailingAnchor, constant: -16),
            toggle.topAnchor.constraint(equalTo: toggleContainer.topAnchor, constant: 12),
            toggle.bottomAnchor.constraint(equalTo: toggleContainer.bottomAnchor, constant: -12),

            hintLabel.topAnchor.constraint(equalTo: toggleContainer.bottomAnchor, constant: 8),
            hintLabel.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor, constant: 36),
            hintLabel.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor, constant: -36),
        ])
    }

    override func updateUI() {
        let fm = fontManager
        previewLabel.font = fm.font(size: 16)
        previewLabel.text = String(localized: "settings.font_size.preview")
        levelLabel.font = fm.font(size: 13, weight: .medium)
        levelLabel.textColor = .secondaryLabel
        levelLabel.text = fontSizeLevelName(settings.fontSizeLevel)
        smallALabel.font = fm.font(size: 13)
        largeALabel.font = fm.font(size: 22)
    }

    @objc private func followSystemToggleChanged(_ sender: UISwitch) {
        settings.followSystemFontSize = sender.isOn
        fontManager.notifyChange()
    }

    @objc private func sliderChanged(_ sender: UISlider) {
        let snapped = Int(roundf(sender.value))
        sender.value = Float(snapped)
        guard snapped != settings.fontSizeLevel else { return }
        settings.fontSizeLevel = snapped
        fontManager.notifyChange()
    }

    private func fontSizeLevelName(_ level: Int) -> String {
        switch level {
        case -3: return String(localized: "font_size.extra_small")
        case -2: return String(localized: "font_size.small")
        case -1: return String(localized: "font_size.slightly_small")
        case  0: return String(localized: "font_size.default")
        case  1: return String(localized: "font_size.slightly_large")
        case  2: return String(localized: "font_size.large")
        case  3: return String(localized: "font_size.extra_large")
        case  4: return String(localized: "font_size.maximum")
        default: return String(localized: "font_size.default")
        }
    }
}
