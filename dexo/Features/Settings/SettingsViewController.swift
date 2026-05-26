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

    override func updateUI() {
        // Read FontManager.revision so @Observable tracking triggers
        // a reload when font size changes.
        _ = FontManager.shared.scale
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
        return [.general, .appearance, .storage, .about, .debug]
        #else
        return [.general, .appearance, .storage, .about]
        #endif
    }


    private func networkRows() -> [NetworkRow] {
        var rows: [NetworkRow] = [.dohToggle]
        if settings.dohEnabled {
            rows.append(.dohProvider)
            if settings.dohProvider == .custom {
                rows.append(.dohCustomURL)
            }
        }
        return rows
    }

    private enum NetworkRow {
        case dohToggle
        case dohProvider
        case dohCustomURL
    }
}

// MARK: - UITableViewDataSource

extension SettingsViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        visibleSections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch visibleSections[section] {
        case .general: return 4
        case .appearance: return 3
        case .storage: return 1
        case .about: return 1
        case .network: return networkRows().count
        #if DEBUG
        case .debug: return 1
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
        case .debug: return "Debug"
        #endif
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch visibleSections[indexPath.section] {
        case .general:
            if indexPath.row == 0 {
                return makeAutoOpenCell(tableView, indexPath: indexPath)
            } else if indexPath.row == 1 {
                return makeBoostDisplayCell(tableView, indexPath: indexPath)
            } else if indexPath.row == 2 {
                return makeTopicReplyLayoutCell(tableView, indexPath: indexPath)
            } else {
                return makeMaxReplyIndentCell(tableView, indexPath: indexPath)
            }
        case .appearance:
            if indexPath.row == 0 {
                return makeAppearanceCell(tableView, indexPath: indexPath)
            } else if indexPath.row == 1 {
                return makeThemeCell(tableView, indexPath: indexPath)
            } else {
                return makeFontSizeCell(tableView, indexPath: indexPath)
            }
        case .storage:
            return makeStorageCell(tableView, indexPath: indexPath)
        case .about:
            return makeSourceCodeCell(tableView, indexPath: indexPath)
        case .network:
            let row = networkRows()[indexPath.row]
            switch row {
            case .dohToggle:
                return makeDohToggleCell(tableView, indexPath: indexPath)
            case .dohProvider:
                return makeDohProviderCell(tableView, indexPath: indexPath)
            case .dohCustomURL:
                return makeDohCustomURLCell(tableView, indexPath: indexPath)
            }
        #if DEBUG
        case .debug:
            return makeRenderPreviewCell(tableView, indexPath: indexPath)
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

    private func makeTopicReplyLayoutCell(_ tableView: UITableView, indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        applyFonts(to: cell)
        cell.textLabel?.text = String(localized: "settings.topic_reply_layout")
        cell.detailTextLabel?.text = settings.topicReplyLayoutMode.title
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    private func makeMaxReplyIndentCell(_ tableView: UITableView, indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        applyFonts(to: cell)
        cell.textLabel?.text = String(localized: "settings.max_reply_indent")
        cell.detailTextLabel?.text = "\(settings.maxTopicReplyIndentLevel)"
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    private func makeDohToggleCell(_ tableView: UITableView, indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        applyFonts(to: cell)
        cell.textLabel?.text = "DNS over HTTPS"
        cell.selectionStyle = .none
        let toggle = UISwitch()
        toggle.isOn = settings.dohEnabled
        toggle.addTarget(self, action: #selector(dohToggleChanged(_:)), for: .valueChanged)
        cell.accessoryView = toggle
        return cell
    }

    private func makeDohProviderCell(_ tableView: UITableView, indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        applyFonts(to: cell)
        cell.textLabel?.text = "Provider"
        cell.detailTextLabel?.text = settings.dohProvider.title
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    private func makeDohCustomURLCell(_ tableView: UITableView, indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        applyFonts(to: cell)
        cell.textLabel?.text = "Custom URL"
        cell.detailTextLabel?.text = settings.dohCustomURL.isEmpty ? "Not Set" : settings.dohCustomURL
        cell.detailTextLabel?.textColor = settings.dohCustomURL.isEmpty ? .placeholderText : .secondaryLabel
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

    #if DEBUG
    private func makeRenderPreviewCell(_ tableView: UITableView, indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        applyFonts(to: cell)
        cell.textLabel?.text = "Render Preview"
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
            if indexPath.row == 1 {
                showBoostDisplayPicker(from: sourceView)
            } else if indexPath.row == 2 {
                showTopicReplyLayoutPicker(from: sourceView)
            } else if indexPath.row == 3 {
                showMaxReplyIndentPicker(from: sourceView)
            }
        case .appearance:
            if indexPath.row == 0 {
                showAppearancePicker(from: sourceView)
            } else if indexPath.row == 1 {
                let vc = ThemePickerViewController()
                navigationController?.pushViewController(vc, animated: true)
            } else {
                let vc = FontSizeViewController()
                navigationController?.pushViewController(vc, animated: true)
            }
        case .storage:
            let vc = CacheViewController()
            navigationController?.pushViewController(vc, animated: true)
        case .about:
            if let url = URL(string: "https://github.com/Eilgnaw/dexo") {
                UIApplication.shared.open(url)
            }
        case .network:
            let row = networkRows()[indexPath.row]
            switch row {
            case .dohProvider:
                showDohProviderPicker(from: sourceView)
            case .dohCustomURL:
                showCustomURLInput()
            default:
                break
            }
        #if DEBUG
        case .debug:
            showRenderPreviewInput()
        #endif
        }
    }
}

// MARK: - Actions

extension SettingsViewController {
    @objc private func autoOpenToggleChanged(_ sender: UISwitch) {
        settings.autoOpenLastForum = sender.isOn
    }

    @objc private func dohToggleChanged(_ sender: UISwitch) {
        settings.dohEnabled = sender.isOn
//        if sender.isOn {
//            ProxyManager.shared.restart()
//        } else {
//            ProxyManager.shared.disable()
//            DoHResolver.shared.clearCache()
//        }
        reloadNetworkSection()
    }

    private func reloadNetworkSection() {
        if let idx = visibleSections.firstIndex(of: .network) {
            tableView.reloadSections(IndexSet(integer: idx), with: .automatic)
        }
    }

    private func showAppearancePicker(from sourceView: UIView?) {
        let alert = UIAlertController(title: String(localized: "settings.dark_mode"), message: nil, preferredStyle: .actionSheet)
        for mode in AppSettings.AppearanceMode.allCases {
            let action = UIAlertAction(title: mode.title, style: .default) { [weak self] _ in
                self?.settings.appearanceMode = mode
                self?.tableView.reloadSections(IndexSet(integer: Section.appearance.rawValue), with: .none)
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

    private func showTopicReplyLayoutPicker(from sourceView: UIView?) {
        let alert = UIAlertController(title: String(localized: "settings.topic_reply_layout"), message: nil, preferredStyle: .actionSheet)
        for mode in AppSettings.TopicReplyLayoutMode.allCases {
            let action = UIAlertAction(title: mode.title, style: .default) { [weak self] _ in
                self?.settings.topicReplyLayoutMode = mode
                if let idx = self?.visibleSections.firstIndex(of: .general) {
                    self?.tableView.reloadSections(IndexSet(integer: idx), with: .none)
                }
            }
            if mode == settings.topicReplyLayoutMode {
                action.setValue(true, forKey: "checked")
            }
            alert.addAction(action)
        }
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        Self.anchorPopover(alert, to: sourceView)
        present(alert, animated: true)
    }

    private func showMaxReplyIndentPicker(from sourceView: UIView?) {
        let alert = UIAlertController(title: String(localized: "settings.max_reply_indent"), message: nil, preferredStyle: .actionSheet)
        for level in 1...8 {
            let action = UIAlertAction(title: "\(level)", style: .default) { [weak self] _ in
                self?.settings.maxTopicReplyIndentLevel = level
                if let idx = self?.visibleSections.firstIndex(of: .general) {
                    self?.tableView.reloadSections(IndexSet(integer: idx), with: .none)
                }
            }
            if level == settings.maxTopicReplyIndentLevel {
                action.setValue(true, forKey: "checked")
            }
            alert.addAction(action)
        }
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        Self.anchorPopover(alert, to: sourceView)
        present(alert, animated: true)
    }

    private func showDohProviderPicker(from sourceView: UIView?) {
        let alert = UIAlertController(title: "DoH Provider", message: nil, preferredStyle: .actionSheet)
        for provider in AppSettings.DoHProvider.allCases {
            let action = UIAlertAction(title: provider.title, style: .default) { [weak self] _ in
                self?.settings.dohProvider = provider
//                DoHResolver.shared.clearCache()
//                ProxyManager.shared.restart()
                self?.reloadNetworkSection()
            }
            if provider == settings.dohProvider {
                action.setValue(true, forKey: "checked")
            }
            alert.addAction(action)
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
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
        let alert = UIAlertController(title: "Render Preview", message: "Enter Topic URL", preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = "https://linux.do/t/topic/12345"
            textField.keyboardType = .URL
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Open", style: .default) { [weak self] _ in
            guard let self,
                  let text = alert.textFields?.first?.text,
                  let url = URL(string: text),
                  let host = url.host,
                  let topicId = url.pathComponents.last.flatMap(Int.init)
            else { return }
            let scheme = url.scheme ?? "https"
            let baseURL = "\(scheme)://\(host)"
            let api = DiscourseAPI(baseURL: baseURL)
            let vc = TopicDetailViewController(api: api, topicId: topicId)
            self.navigationController?.pushViewController(vc, animated: true)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }
    #endif

    private func showCustomURLInput() {
        let alert = UIAlertController(title: "Custom DoH URL", message: "Enter DNS over HTTPS server address", preferredStyle: .alert)
        alert.addTextField { [weak self] textField in
            textField.text = self?.settings.dohCustomURL
            textField.placeholder = "https://example.com/dns-query"
            textField.keyboardType = .URL
            textField.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            if let url = alert.textFields?.first?.text {
                self?.settings.dohCustomURL = url
//                DoHResolver.shared.clearCache()
//                ProxyManager.shared.restart()
                self?.reloadNetworkSection()
            }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }
}
