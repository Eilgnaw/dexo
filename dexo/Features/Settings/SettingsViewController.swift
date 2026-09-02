import UIKit

final class SettingsViewController: ObservableViewController {
    override var backgroundStyle: BackgroundStyle { .grouped }

    private let settings = AppSettings.shared
    private let themeManager = ThemeManager.shared

    private lazy var tableView: UITableView = {
        let tv = ThemedTableView(frame: .zero, style: .insetGrouped)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.dataSource = self
        tv.delegate = self
        return tv
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "tab.settings")
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadNetworkSection()
    }

    override func updateUI() {
        // Read FontManager.revision so @Observable tracking triggers
        // a reload when font size changes.
        _ = FontManager.shared.scale
        // DoH is edited by a pushed child controller. Track its backing values
        // explicitly so the root subtitle is refreshed as soon as they change.
        _ = settings.dohEnabled
        _ = settings.dohServers
        _ = settings.defaultDoHServerID
        tableView.reloadData()
    }

    // MARK: - Rows

    private enum Section: Int, CaseIterable {
        case general
        case appearance
        case storage
        case about
        #if DEBUG
        case debug
        #endif
        case network
    }

    /// Sections actually shown in the table, in order.
    private var visibleSections: [Section] {
        #if DEBUG
        return [.general, .appearance, .network, .storage, .about, .debug]
        #else
        return [.general, .appearance, .network, .storage, .about]
        #endif
    }

    private enum AppearanceRow: Int, CaseIterable {
        case appearanceMode
        case theme
        case appIcon
        case fontSize
    }

    private enum GeneralRow: Int, CaseIterable {
        case autoOpen
        case boostDisplay
    }

    private enum AboutRow: Int, CaseIterable {
        case feedback
        case sourceCode
    }

    private func networkRows() -> [NetworkRow] {
        [.dohSettings]
    }

    private enum NetworkRow {
        case dohSettings
    }

    #if DEBUG
    private enum DebugRow: Int, CaseIterable {
        case renderPreview
        case webViewProxyTest
        case urlSessionProxyTest
    }
    #endif
}

// MARK: - UITableViewDataSource

extension SettingsViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        visibleSections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch visibleSections[section] {
        case .general: return GeneralRow.allCases.count
        case .appearance: return AppearanceRow.allCases.count
        case .storage: return 1
        case .about: return AboutRow.allCases.count
        case .network: return networkRows().count
        #if DEBUG
        case .debug: return DebugRow.allCases.count
        #endif
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch visibleSections[section] {
        case .general: return String(localized: "settings.section.general")
        case .appearance: return String(localized: "settings.section.appearance")
        case .storage: return String(localized: "settings.section.storage")
        case .about: return String(localized: "settings.section.about")
        case .network: return String(localized: "settings.section.network")
        #if DEBUG
        case .debug: return String(localized: "settings.section.debug")
        #endif
        }
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch visibleSections[section] {
        case .network:
            return String(localized: "settings.doh.root.footer")
        #if DEBUG
        case .debug:
            return nil
        #endif
        default:
            return nil
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch visibleSections[indexPath.section] {
        case .general:
            switch GeneralRow(rawValue: indexPath.row)! {
            case .autoOpen:
                return makeAutoOpenCell(tableView, indexPath: indexPath)
            case .boostDisplay:
                return makeBoostDisplayCell(tableView, indexPath: indexPath)
            }
        case .appearance:
            switch AppearanceRow(rawValue: indexPath.row)! {
            case .appearanceMode:
                return makeAppearanceCell(tableView, indexPath: indexPath)
            case .theme:
                return makeThemeCell(tableView, indexPath: indexPath)
            case .appIcon:
                return makeAppIconCell(tableView, indexPath: indexPath)
            case .fontSize:
                return makeFontSizeCell(tableView, indexPath: indexPath)
            }
        case .storage:
            return makeStorageCell(tableView, indexPath: indexPath)
        case .about:
            switch AboutRow(rawValue: indexPath.row)! {
            case .feedback:
                return makeFeedbackCell(tableView, indexPath: indexPath)
            case .sourceCode:
                return makeSourceCodeCell(tableView, indexPath: indexPath)
            }
        case .network:
            let row = networkRows()[indexPath.row]
            switch row {
            case .dohSettings:
                return makeDoHSettingsCell(tableView, indexPath: indexPath)
            }
        #if DEBUG
        case .debug:
            switch DebugRow(rawValue: indexPath.row)! {
            case .renderPreview:
                return makeRenderPreviewCell(tableView, indexPath: indexPath)
            case .webViewProxyTest:
                return makeWebViewProxyTestCell(tableView, indexPath: indexPath)
            case .urlSessionProxyTest:
                return makeURLSessionProxyTestCell(tableView, indexPath: indexPath)
            }
        #endif
        }
    }

    // MARK: - Cell Factories

    private func applyFonts(to cell: UITableViewCell) {
        let fm = FontManager.shared
        cell.textLabel?.font = fm.font(size: 17)
        cell.detailTextLabel?.font = fm.font(size: 17)
    }

    private func makeAutoOpenCell(_ tableView: UITableView, indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        applyFonts(to: cell)
        cell.textLabel?.text = String(localized: "settings.auto_open_last_forum")
        cell.selectionStyle = .none
        let toggle = UISwitch()
        toggle.isOn = settings.autoOpenLastForum
        toggle.addTarget(self, action: #selector(autoOpenToggleChanged(_:)), for: .valueChanged)
        cell.accessoryView = toggle
        return cell
    }

    private func makeAppearanceCell(_ tableView: UITableView, indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        applyFonts(to: cell)
        cell.textLabel?.text = String(localized: "settings.dark_mode")
        cell.detailTextLabel?.text = settings.appearanceMode.title
        cell.accessoryType = .disclosureIndicator

        return cell
    }

    private func makeThemeCell(_ tableView: UITableView, indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        applyFonts(to: cell)
        cell.textLabel?.text = String(localized: "settings.theme")
        cell.detailTextLabel?.text = themeManager.currentTheme.name
        cell.accessoryType = .disclosureIndicator

        return cell
    }

    private func makeAppIconCell(_ tableView: UITableView, indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        applyFonts(to: cell)
        cell.textLabel?.text = String(localized: "settings.app_icon")
        cell.detailTextLabel?.text = AppIconOption.current.title
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    private func makeFontSizeCell(_ tableView: UITableView, indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        applyFonts(to: cell)
        cell.textLabel?.text = String(localized: "settings.font_size")
        let level = settings.fontSizeLevel
        cell.detailTextLabel?.text = level == 0
            ? String(localized: "font_size.default")
            : "\(level > 0 ? "+" : "")\(level)"
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    private func makeBoostDisplayCell(_ tableView: UITableView, indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        applyFonts(to: cell)
        cell.textLabel?.text = String(localized: "settings.boost_display")
        cell.detailTextLabel?.text = settings.boostDisplayMode.title
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    private func makeDoHSettingsCell(_ tableView: UITableView, indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        applyFonts(to: cell)
        cell.textLabel?.text = String(localized: "settings.doh.enabled")
        cell.detailTextLabel?.font = FontManager.shared.font(size: 13)
        cell.detailTextLabel?.textColor = .secondaryLabel
        if settings.dohEnabled, let server = settings.defaultDoHServer {
            cell.detailTextLabel?.text = String(
                format: String(localized: "settings.doh.root.enabled_format"),
                server.name
            )
        } else {
            cell.detailTextLabel?.text = String(localized: "settings.doh.status.disabled")
        }
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    private func makeStorageCell(_ tableView: UITableView, indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        applyFonts(to: cell)
        cell.textLabel?.text = String(localized: "settings.clear_cache")
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    private func makeSourceCodeCell(_ tableView: UITableView, indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        applyFonts(to: cell)
        cell.textLabel?.text = String(localized: "settings.source_code")
        cell.detailTextLabel?.text = "GitHub"
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    private func makeFeedbackCell(_ tableView: UITableView, indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        applyFonts(to: cell)
        cell.textLabel?.text = String(localized: "feedback.title")
        cell.detailTextLabel?.font = FontManager.shared.font(size: 13)
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.text = String(localized: "feedback.settings.subtitle")
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    #if DEBUG
    private func makeRenderPreviewCell(_ tableView: UITableView, indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        applyFonts(to: cell)
        cell.textLabel?.text = String(localized: "settings.debug.render_preview")
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    private func makeWebViewProxyTestCell(_ tableView: UITableView, indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        applyFonts(to: cell)
        cell.textLabel?.text = String(localized: "settings.debug.webview_proxy_test")
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    private func makeURLSessionProxyTestCell(_ tableView: UITableView, indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        applyFonts(to: cell)
        cell.textLabel?.text = String(localized: "settings.debug.urlsession_proxy_test")
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    #endif
}

// MARK: - UITableViewDelegate

extension SettingsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        let sourceView = tableView.cellForRow(at: indexPath)
        switch visibleSections[indexPath.section] {
        case .general:
            switch GeneralRow(rawValue: indexPath.row)! {
            case .autoOpen:
                break
            case .boostDisplay:
                showBoostDisplayPicker(from: sourceView)
            }
        case .appearance:
            switch AppearanceRow(rawValue: indexPath.row)! {
            case .appearanceMode:
                showAppearancePicker(from: sourceView)
            case .theme:
                let vc = ThemePickerViewController()
                navigationController?.pushViewController(vc, animated: true)
            case .appIcon:
                let vc = AppIconPickerViewController()
                vc.onSelectionChanged = { [weak self] in
                    self?.reloadAppearanceSection()
                }
                navigationController?.pushViewController(vc, animated: true)
            case .fontSize:
                let vc = FontSizeViewController()
                navigationController?.pushViewController(vc, animated: true)
            }
        case .storage:
            let vc = CacheViewController()
            navigationController?.pushViewController(vc, animated: true)
        case .about:
            switch AboutRow(rawValue: indexPath.row)! {
            case .feedback:
                FeedbackCoordinator.shared.openFeedback(from: self, presentation: .push)
            case .sourceCode:
                if let url = URL(string: "https://github.com/Eilgnaw/dexo") {
                    UIApplication.shared.open(url)
                }
            }
        case .network:
            let viewController = DoHSettingsViewController()
            navigationController?.pushViewController(viewController, animated: true)
        #if DEBUG
        case .debug:
            switch DebugRow(rawValue: indexPath.row)! {
            case .renderPreview:
                showRenderPreviewInput()
            case .webViewProxyTest:
                let viewController = WebViewProxyTestViewController()
                navigationController?.pushViewController(viewController, animated: true)
            case .urlSessionProxyTest:
                let viewController = URLSessionProxyTestViewController()
                navigationController?.pushViewController(viewController, animated: true)
            }
        #endif
        }
    }
}

// MARK: - Actions

extension SettingsViewController {
    @objc private func autoOpenToggleChanged(_ sender: UISwitch) {
        settings.autoOpenLastForum = sender.isOn
    }

    private func reloadAppearanceSection() {
        if let idx = visibleSections.firstIndex(of: .appearance) {
            tableView.reloadSections(IndexSet(integer: idx), with: .none)
        }
    }

    private func reloadNetworkSection() {
        guard isViewLoaded,
              let index = visibleSections.firstIndex(of: .network)
        else { return }
        tableView.reloadSections(IndexSet(integer: index), with: .none)
    }

    private func showAppearancePicker(from sourceView: UIView?) {
        let alert = UIAlertController(title: String(localized: "settings.dark_mode"), message: nil, preferredStyle: .actionSheet)
        for mode in AppSettings.AppearanceMode.allCases {
            let action = UIAlertAction(title: mode.title, style: .default) { [weak self] _ in
                self?.settings.appearanceMode = mode
                self?.reloadAppearanceSection()
            }
            if mode == settings.appearanceMode {
                action.setValue(true, forKey: "checked")
            }
            alert.addAction(action)
        }
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        Self.anchorPopover(alert, to: sourceView)
        present(alert, animated: true)
    }

    private func showBoostDisplayPicker(from sourceView: UIView?) {
        let alert = UIAlertController(title: String(localized: "settings.boost_display"), message: nil, preferredStyle: .actionSheet)
        for mode in AppSettings.BoostDisplayMode.allCases {
            let action = UIAlertAction(title: mode.title, style: .default) { [weak self] _ in
                self?.settings.boostDisplayMode = mode
                if let idx = self?.visibleSections.firstIndex(of: .general) {
                    self?.tableView.reloadSections(IndexSet(integer: idx), with: .none)
                }
            }
            if mode == settings.boostDisplayMode {
                action.setValue(true, forKey: "checked")
            }
            alert.addAction(action)
        }
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        Self.anchorPopover(alert, to: sourceView)
        present(alert, animated: true)
    }

    private static func anchorPopover(_ alert: UIAlertController, to view: UIView?) {
        guard let view, let popover = alert.popoverPresentationController else { return }
        popover.sourceView = view
        popover.sourceRect = view.bounds
        popover.permittedArrowDirections = [.up, .down]
    }

    #if DEBUG
    private func showRenderPreviewInput() {
        let alert = UIAlertController(
            title: String(localized: "settings.debug.render_preview"),
            message: String(localized: "settings.debug.render_preview.message"),
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.placeholder = "https://linux.do/t/topic/12345"
            textField.keyboardType = .URL
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: String(localized: "action.open"), style: .default) { [weak self] _ in
            guard let self,
                  let text = alert.textFields?.first?.text,
                  let url = URL(string: text),
                  let host = url.host,
                  let topicId = url.pathComponents.last.flatMap(Int.init)
            else { return }
            let scheme = url.scheme ?? "https"
            let baseURL = "\(scheme)://\(host)"
            let api = DiscourseAPI(baseURL: baseURL)
            let vc = TopicDetailControllerFactory.make(api: api, topicId: topicId)
            self.navigationController?.pushViewController(vc, animated: true)
        })
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        present(alert, animated: true)
    }
    #endif

}
