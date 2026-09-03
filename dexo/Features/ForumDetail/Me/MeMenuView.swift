import UIKit

/// The rounded functional sheet below the accent-colored profile header.
final class MeMenuView: ProfileMenuSheetView {
    enum Action: String {
        case messages, notifications, following, bookmarks, read
        case localBlocklist = "local_blocklist"
        case pushNotifications = "push_notifications"
        case readTimings = "read_timings"
        case challenge, login, logout

        var title: String {
            switch self {
            case .messages: return String(localized: "me.messages")
            case .notifications: return String(localized: "me.notifications")
            case .following: return String(localized: "me.following")
            case .bookmarks: return String(localized: "me.bookmarks")
            case .read: return String(localized: "me.read")
            case .localBlocklist: return String(localized: "me.local_blocklist")
            case .pushNotifications: return String(localized: "push.settings.title")
            case .readTimings: return String(localized: "settings.read_timings.linux_do.title")
            case .challenge: return String(localized: "me.challenge")
            case .login: return String(localized: "me.login")
            case .logout: return String(localized: "me.logout")
            }
        }

        var symbol: String {
            switch self {
            case .messages: return "envelope"
            case .notifications: return "bell"
            case .following: return "person.2"
            case .bookmarks: return "bookmark"
            case .read: return "checkmark.circle"
            case .localBlocklist: return "person.crop.circle.badge.xmark"
            case .pushNotifications: return "bell.badge"
            case .readTimings: return "clock"
            case .challenge: return "shield"
            case .login, .logout: return "person.crop.circle"
            }
        }
    }

    var onAction: ((Action) -> Void)?
    private var controls: [Action: ProfileMenuControl] = [:]
    private var sectionLabels: [UILabel] = []
    private var rowGroups: [UIStackView] = []
    private var accountSections: [UIView] = []
    private let sessionButton = UIButton(type: .system)
    private var sessionAction: Action = .login

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "me.menu"
        let community = makeRows(actions: [.notifications, .following])
        let reading = makeSection(
            title: String(localized: "me.section.reading"),
            actions: [.bookmarks, .read]
        )
        let preferences = makeSection(
            title: String(localized: "me.section.preferences"),
            actions: [.localBlocklist, .pushNotifications, .readTimings, .challenge]
        )
        accountSections = [community, reading, preferences]
        accountSections.forEach { content.addArrangedSubview($0) }
        content.addArrangedSubview(sessionButton)
        sessionButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        sessionButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onAction?(self.sessionAction)
        }, for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func makeControl(_ action: Action) -> ProfileMenuControl {
        let control = ProfileMenuControl(title: action.title, symbol: action.symbol, identifier: "me.\(action.rawValue)")
        controls[action] = control
        control.addAction(UIAction { [weak self] _ in self?.onAction?(action) }, for: .touchUpInside)
        return control
    }

    private func makeSection(title: String, actions: [Action]) -> UIView {
        let label = UILabel()
        label.text = title
        label.numberOfLines = 0
        label.accessibilityTraits = .header
        sectionLabels.append(label)
        let rows = makeRows(actions: actions)
        let section = UIStackView(arrangedSubviews: [label, rows])
        section.axis = .vertical
        section.spacing = 10
        return section
    }

    private func makeRows(actions: [Action]) -> UIStackView {
        let rows = makeGroup(actions.map { makeControl($0) })
        rowGroups.append(rows)
        return rows
    }

    func configure(
        isAuthenticated: Bool,
        showsFollowing: Bool,
        showsChallenge: Bool,
        showsReadTimings: Bool = false,
        readTimingsStatus: ReadTimingReportingStatus = .enabled,
        blockedCount: Int,
        unreadNotifications: Bool,
        palette: ProfilePagePalette? = nil
    ) {
        let theme = ThemeManager.shared
        let fonts = FontManager.shared
        let palette = palette ?? theme.profilePagePalette()
        configureSurface(palette: palette)
        for (index, section) in accountSections.enumerated() {
            setVisible(isAuthenticated, view: section, in: content, at: index)
        }
        if let following = controls[.following], let community = rowGroups.first {
            setVisible(showsFollowing, view: following, in: community, at: 1)
        }
        if let readTimings = controls[.readTimings], let preferences = rowGroups.last {
            setVisible(showsReadTimings, view: readTimings, in: preferences, at: 2)
        }
        if let challenge = controls[.challenge], let preferences = rowGroups.last {
            setVisible(showsChallenge, view: challenge, in: preferences, at: 3)
        }
        for (action, control) in controls {
            let unread = action == .notifications && unreadNotifications
            let detail: String?
            switch action {
            case .localBlocklist:
                detail = String(localized: "me.local_blocklist.count \(blockedCount)")
            case .readTimings:
                switch readTimingsStatus {
                case .enabled:
                    detail = String(localized: "settings.read_timings.status.enabled")
                case .disabled:
                    detail = String(localized: "settings.read_timings.status.disabled")
                case .verificationRequired:
                    detail = String(localized: "settings.read_timings.status.verification_required")
                }
            default:
                detail = nil
            }
            control.configure(detail: detail, unread: unread, palette: palette)
        }
        sectionLabels.forEach {
            $0.font = fonts.font(size: 15, weight: .semibold)
            $0.textColor = UIColor.label.withAlphaComponent(0.8)
        }

        sessionAction = isAuthenticated ? .logout : .login
        var configuration = isAuthenticated ? UIButton.Configuration.plain() : .filled()
        configuration.title = sessionAction.title
        configuration.baseForegroundColor = isAuthenticated ? .systemRed : theme.profileHeaderPalette.foreground
        configuration.baseBackgroundColor = theme.profileHeaderPalette.background
        configuration.cornerStyle = .large
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var attributes = incoming
            attributes.font = fonts.font(size: 16, weight: isAuthenticated ? .regular : .semibold)
            return attributes
        }
        sessionButton.configuration = configuration
        sessionButton.accessibilityIdentifier = "me.\(sessionAction.rawValue)"
    }

    private func setVisible(_ visible: Bool, view: UIView, in stack: UIStackView, at index: Int) {
        // Removing optional sections avoids zero-size hiding constraints fighting
        // the minimum touch targets inside nested stack views.
        if visible, !stack.arrangedSubviews.contains(view) {
            stack.insertArrangedSubview(view, at: min(index, stack.arrangedSubviews.count))
        } else if !visible, stack.arrangedSubviews.contains(view) {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }
}
