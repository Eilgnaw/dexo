import UIKit

final class TopicTimingReportsViewController: BaseViewController {
    override var backgroundStyle: BackgroundStyle { .grouped }

    private let scope: TopicTimingReportScope
    private var reports: [TopicTimingReport] = []
    private var filter: TopicTimingReportFilter = .all

    init(scope: TopicTimingReportScope = .allForums) {
        self.scope = scope
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private lazy var segmentedControl: UISegmentedControl = {
        let control = UISegmentedControl(items: [
            String(localized: "timing_reports.filter.all"),
            String(localized: "timing_reports.filter.success"),
            String(localized: "timing_reports.filter.failure"),
        ])
        control.selectedSegmentIndex = TopicTimingReportFilter.all.rawValue
        control.addTarget(self, action: #selector(filterChanged(_:)), for: .valueChanged)
        control.translatesAutoresizingMaskIntoConstraints = false
        return control
    }()

    private lazy var tableView: UITableView = {
        let table = ThemedTableView(frame: .zero, style: .insetGrouped)
        table.translatesAutoresizingMaskIntoConstraints = false
        table.dataSource = self
        table.delegate = self
        return table
    }()

    private let emptyLabel: UILabel = {
        let label = UILabel()
        label.text = String(localized: "timing_reports.empty")
        label.textColor = .secondaryLabel
        label.font = FontManager.shared.font(size: 17)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
        return label
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = scope == .linuxDo
            ? String(localized: "timing_reports.linux_do.title")
            : String(localized: "settings.read_timings.reports")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "action.clear"),
            style: .plain,
            target: self,
            action: #selector(clearTapped)
        )

        view.addSubview(segmentedControl)
        view.addSubview(tableView)
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            segmentedControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            segmentedControl.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            segmentedControl.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),

            tableView.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: tableView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: tableView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            emptyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])
        reloadReports()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadReports()
    }

    private func reloadReports() {
        reports = (
            try? DatabaseManager.shared.fetchTopicTimingReports(filter: filter, scope: scope)
        ) ?? []
        emptyLabel.isHidden = !reports.isEmpty
        navigationItem.rightBarButtonItem?.isEnabled = !reports.isEmpty
        tableView.reloadData()
    }

    @objc private func filterChanged(_ sender: UISegmentedControl) {
        guard let selected = TopicTimingReportFilter(rawValue: sender.selectedSegmentIndex) else { return }
        filter = selected
        reloadReports()
    }

    @objc private func clearTapped() {
        let alert = UIAlertController(
            title: String(localized: "timing_reports.clear.title"),
            message: scope == .linuxDo
                ? String(localized: "timing_reports.clear.linux_do.message")
                : String(localized: "timing_reports.clear.message"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "action.clear"), style: .destructive) { [weak self] _ in
            guard let self else { return }
            try? DatabaseManager.shared.clearTopicTimingReports(scope: self.scope)
            self.reloadReports()
        })
        present(alert, animated: true)
    }

    private func presentDetails(for report: TopicTimingReport) {
        var lines = [
            String(localized: "timing_reports.detail.forum \(Self.host(from: report.baseURL))"),
            String(localized: "timing_reports.detail.account \(report.accountName ?? String(localized: "timing_reports.account.anonymous"))"),
            String(localized: "timing_reports.detail.topic \(report.topicId)"),
            String(localized: "timing_reports.detail.attempted \(Self.dateFormatter.string(from: report.attemptedAt))"),
            String(localized: "timing_reports.detail.topic_time \(Self.duration(report.topicTime))"),
            String(localized: "timing_reports.detail.visible_time \(Self.duration(report.visibleTime))"),
            String(localized: "timing_reports.detail.posts \(report.postCount)"),
            String(localized: "timing_reports.detail.request_duration \(report.requestDuration)"),
            String(localized: "timing_reports.detail.status \(report.statusCode.map(String.init) ?? "—")"),
            String(localized: "timing_reports.detail.failures \(report.consecutiveFailureCount)"),
        ]
        if report.trippedBreaker {
            lines.append(String(localized: "timing_reports.detail.breaker"))
        }
        if let error = report.errorSummary, !error.isEmpty {
            lines.append(String(localized: "timing_reports.detail.error \(error)"))
        }
        let alert = UIAlertController(
            title: Self.outcomeTitle(report.outcome),
            message: lines.joined(separator: "\n"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "action.ok"), style: .default))
        present(alert, animated: true)
    }

    private static func host(from baseURL: String) -> String {
        URL(string: baseURL)?.host ?? baseURL
    }

    private static func outcomeTitle(_ outcome: TopicTimingOutcome) -> String {
        switch outcome {
        case .success: return String(localized: "timing_reports.status.success")
        case .failure: return String(localized: "timing_reports.status.failure")
        case .cloudflareChallenge: return String(localized: "timing_reports.status.challenge")
        }
    }

    private static func duration(_ milliseconds: Int) -> String {
        let seconds = Double(milliseconds) / 1000
        return String(localized: "timing_reports.duration \(String(format: "%.1f", seconds))")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

extension TopicTimingReportsViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        reports.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.font = FontManager.shared.font(size: 16, weight: .medium)
        cell.detailTextLabel?.font = FontManager.shared.font(size: 13)
        cell.detailTextLabel?.numberOfLines = 3
        let report = reports[indexPath.row]
        let symbol: String
        let tint: UIColor
        switch report.outcome {
        case .success:
            symbol = "checkmark.circle.fill"
            tint = .systemGreen
        case .failure:
            symbol = "xmark.circle.fill"
            tint = .systemRed
        case .cloudflareChallenge:
            symbol = "shield.lefthalf.filled"
            tint = .systemOrange
        }
        cell.imageView?.image = UIImage(systemName: symbol)
        cell.imageView?.tintColor = tint
        cell.textLabel?.text = "\(Self.host(from: report.baseURL)) · #\(report.topicId)"
        let status = report.statusCode.map { "HTTP \($0)" } ?? String(localized: "timing_reports.status.no_http")
        let account = report.accountName ?? String(localized: "timing_reports.account.anonymous")
        var detail = String(
            localized: "timing_reports.row.detail \(account) \(Self.outcomeTitle(report.outcome)) \(Self.dateFormatter.string(from: report.attemptedAt)) \(report.postCount) \(Self.duration(report.topicTime)) \(status)"
        )
        if let errorSummary = report.errorSummary,
           !errorSummary.isEmpty,
           report.outcome != .success
        {
            detail += "\n" + String(localized: "timing_reports.row.error \(errorSummary)")
        }
        cell.detailTextLabel?.text = detail
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.accessoryType = .disclosureIndicator
        return cell
    }
}

extension TopicTimingReportsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        presentDetails(for: reports[indexPath.row])
    }
}
