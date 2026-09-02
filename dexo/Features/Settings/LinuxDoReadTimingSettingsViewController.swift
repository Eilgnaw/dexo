import UIKit

final class LinuxDoReadTimingSettingsViewController: BaseViewController {
    override var backgroundStyle: BackgroundStyle { .grouped }

    private enum Section: Int, CaseIterable {
        case reporting
        case reports
    }

    private let settings = AppSettings.shared
    private var successfulReportCount = 0
    private var failedReportCount = 0
    private lazy var reportingSwitch: UISwitch = {
        let reportingSwitch = UISwitch()
        reportingSwitch.accessibilityIdentifier = "settings.read_timings.switch"
        reportingSwitch.addTarget(
            self,
            action: #selector(reportingSwitchChanged(_:)),
            for: .valueChanged
        )
        return reportingSwitch
    }()

    private lazy var tableView: UITableView = {
        let tableView = ThemedTableView(frame: .zero, style: .insetGrouped)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        return tableView
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "settings.read_timings.linux_do.title")
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reportingSettingDidChange(_:)),
            name: .linuxDoReadTimingsSettingDidChange,
            object: nil
        )
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        synchronizeReportingSwitch()
        reloadReportSummary()
    }

    private func reloadReportSummary() {
        let reports = (
            try? DatabaseManager.shared.fetchTopicTimingReports(scope: .linuxDo)
        ) ?? []
        successfulReportCount = reports.count { $0.outcome == .success }
        failedReportCount = reports.count { $0.outcome != .success }
        tableView.reloadData()
    }

    @objc private func reportingSettingDidChange(_ notification: Notification) {
        guard isViewLoaded else { return }
        synchronizeReportingSwitch()
    }

    @objc private func reportingSwitchChanged(_ sender: UISwitch) {
        settings.linuxDoReadTimingsEnabled = sender.isOn
        synchronizeReportingSwitch()
    }

    private func synchronizeReportingSwitch() {
        reportingSwitch.setOn(settings.linuxDoReadTimingsEnabled, animated: false)
    }
}

extension LinuxDoReadTimingSettingsViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        1
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .reporting:
            return String(localized: "settings.section.read_timings")
        case .reports:
            return String(localized: "settings.read_timings.reports")
        }
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard Section(rawValue: section) == .reporting else { return nil }
        return String(localized: "settings.read_timings.footer")
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {
        case .reporting:
            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
            cell.textLabel?.font = FontManager.shared.font(size: 17)
            cell.detailTextLabel?.font = FontManager.shared.font(size: 13)
            cell.detailTextLabel?.textColor = .secondaryLabel
            cell.textLabel?.text = String(localized: "settings.read_timings.linux_do")
            cell.detailTextLabel?.text = String(localized: "settings.read_timings.linux_do.subtitle")
            cell.selectionStyle = .none
            synchronizeReportingSwitch()
            cell.accessoryView = reportingSwitch
            return cell

        case .reports:
            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
            cell.textLabel?.font = FontManager.shared.font(size: 17)
            cell.detailTextLabel?.font = FontManager.shared.font(size: 13)
            cell.detailTextLabel?.textColor = .secondaryLabel
            cell.textLabel?.text = String(localized: "settings.read_timings.reports")
            cell.detailTextLabel?.text = String(
                localized: "settings.read_timings.reports.summary \(successfulReportCount) \(failedReportCount)"
            )
            cell.imageView?.image = UIImage(systemName: "list.bullet.rectangle")
            cell.imageView?.tintColor = ThemeManager.shared.accentColor
            cell.accessoryType = .disclosureIndicator
            return cell
        }
    }
}

extension LinuxDoReadTimingSettingsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard Section(rawValue: indexPath.section) == .reports else { return }
        navigationController?.pushViewController(
            TopicTimingReportsViewController(scope: .linuxDo),
            animated: true
        )
    }
}
