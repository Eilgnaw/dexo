import SDWebImage
import UIKit

final class CacheViewController: BaseViewController {
    override var backgroundStyle: BackgroundStyle { .grouped }

    // MARK: - UI

    private lazy var tableView: UITableView = {
        let tv = ThemedTableView(frame: .zero, style: .insetGrouped)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.dataSource = self
        tv.delegate = self
        tv.isScrollEnabled = false
        return tv
    }()

    /// Circular progress ring that animates while calculating cache size.
    private let ringLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = UIColor.clear.cgColor
        layer.lineWidth = 6
        layer.lineCap = .round
        return layer
    }()

    private let sizeLabel: UILabel = {
        let label = UILabel()
        label.font = .monospacedDigitSystemFont(ofSize: 36, weight: .bold)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let unitLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let ringContainer: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let countLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 13)
        label.textColor = .tertiaryLabel
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let contentLayoutGuide = UILayoutGuide()

    // MARK: - State

    private struct CacheRow {
        let titleKey: String
        /// nil for the catch-all "other caches" row (URLCache, WKWebView, etc.)
        /// — those have no individual SDImageCache and can only be cleared via
        /// "Clear All".
        let cache: SDImageCache?
        var count: UInt = 0
        var bytes: UInt = 0
    }

    private let cacheManager = ImageCacheManager.shared
    private var rows: [CacheRow] = []
    private var totalBytes: UInt = 0
    private var totalCount: UInt = 0
    private var isCalculating = true
    private var clearingIndex: Int?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "settings.clear_cache")

        rows = [
            CacheRow(titleKey: "cache.avatars", cache: cacheManager.avatarCache),
            CacheRow(titleKey: "cache.emoji", cache: cacheManager.emojiCache),
            CacheRow(titleKey: "cache.content", cache: cacheManager.contentCache),
            CacheRow(titleKey: "cache.other", cache: nil),
        ]

        view.addSubview(ringContainer)
        ringContainer.addSubview(sizeLabel)
        ringContainer.addSubview(unitLabel)
        view.addSubview(countLabel)
        view.addSubview(tableView)

        let ringSize: CGFloat = 160
        let safeArea = view.safeAreaLayoutGuide
        view.addLayoutGuide(contentLayoutGuide)
        NSLayoutConstraint.activate([
            contentLayoutGuide.topAnchor.constraint(equalTo: safeArea.topAnchor),
            contentLayoutGuide.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            contentLayoutGuide.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentLayoutGuide.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            ringContainer.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor, constant: 40),
            ringContainer.centerXAnchor.constraint(equalTo: safeArea.centerXAnchor),
            ringContainer.widthAnchor.constraint(equalToConstant: ringSize),
            ringContainer.heightAnchor.constraint(equalToConstant: ringSize),

            sizeLabel.centerXAnchor.constraint(equalTo: ringContainer.centerXAnchor),
            sizeLabel.centerYAnchor.constraint(equalTo: ringContainer.centerYAnchor, constant: -8),

            unitLabel.topAnchor.constraint(equalTo: sizeLabel.bottomAnchor, constant: 2),
            unitLabel.centerXAnchor.constraint(equalTo: ringContainer.centerXAnchor),

            countLabel.topAnchor.constraint(equalTo: ringContainer.bottomAnchor, constant: 12),
            countLabel.centerXAnchor.constraint(equalTo: safeArea.centerXAnchor),

            tableView.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 20),
            tableView.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor),
        ])

        ringContainer.layer.addSublayer(ringLayer)

        sizeLabel.text = "…"
        unitLabel.text = ""
        countLabel.text = ""

        calculateCacheSize()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = ringContainer.bounds
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) / 2 - ringLayer.lineWidth / 2
        let path = UIBezierPath(arcCenter: center, radius: radius,
                                startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: true)
        ringLayer.path = path.cgPath
        ringLayer.frame = bounds
    }

    // MARK: - Cache Calculation

    private func calculateCacheSize() {
        isCalculating = true
        ringLayer.strokeColor = ThemeManager.shared.accentColor.cgColor
        startSpinAnimation()

        cacheManager.calculateSizes { [weak self] infos in
            guard let self else { return }
            for (i, info) in infos.enumerated() {
                self.rows[i].count = info.count
                self.rows[i].bytes = info.bytes
            }
            // Total from disk scan captures everything Clear All wipes
            // (URLCache, WKWebView, misc). The "other" row absorbs whatever
            // isn't accounted for by the three SDImageCache namespaces so the
            // rows always sum to the ring total.
            let imageBytes = infos.reduce(0) { $0 + $1.bytes }
            let diskTotal = Self.directorySize(url: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
                + Self.directorySize(url: URL(fileURLWithPath: NSTemporaryDirectory()))
            let otherIndex = self.rows.count - 1
            self.rows[otherIndex].bytes = diskTotal > imageBytes ? diskTotal - imageBytes : 0
            self.rows[otherIndex].count = 0
            self.totalBytes = self.rows.reduce(0) { $0 + $1.bytes }
            self.totalCount = infos.reduce(0) { $0 + $1.count }
            self.isCalculating = false
            self.stopSpinAnimation()
            self.animateSizeLabel(bytes: self.totalBytes, count: self.totalCount)
            self.tableView.reloadData()
        }
    }

    // MARK: - Ring Animation

    private func startSpinAnimation() {
        ringLayer.strokeStart = 0
        ringLayer.strokeEnd = 0.3

        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = CGFloat.pi * 2
        rotation.duration = 1.0
        rotation.repeatCount = .infinity
        ringLayer.add(rotation, forKey: "spin")
    }

    private func stopSpinAnimation() {
        ringLayer.removeAnimation(forKey: "spin")
        ringLayer.transform = CATransform3DIdentity
        // Animate ring to full circle
        ringLayer.strokeStart = 0
        let anim = CABasicAnimation(keyPath: "strokeEnd")
        anim.fromValue = 0.3
        anim.toValue = 1.0
        anim.duration = 0.5
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        ringLayer.add(anim, forKey: "fill")
        ringLayer.strokeEnd = 1.0
    }

    // MARK: - Size Label Animation

    private func animateSizeLabel(bytes: UInt, count: UInt) {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file

        let steps = 20
        let duration: TimeInterval = 0.6
        for step in 0...steps {
            let fraction = Double(step) / Double(steps)
            let current = Int64(Double(bytes) * fraction)
            DispatchQueue.main.asyncAfter(deadline: .now() + duration * fraction) { [weak self] in
                guard let self else { return }
                let formatted = formatter.string(fromByteCount: current)
                let parts = formatted.split(separator: " ", maxSplits: 1)
                self.sizeLabel.text = String(parts.first ?? "0")
                self.unitLabel.text = parts.count > 1 ? String(parts.last!) : ""

                if step == steps {
                    self.countLabel.text = String(localized: "cache.image_count \(count)")
                }
            }
        }
    }

    // MARK: - Clear

    private func clearSingleCache(at index: Int) {
        guard clearingIndex == nil, let cache = rows[index].cache else { return }
        clearingIndex = index
        tableView.reloadRows(at: [IndexPath(row: index, section: 0)], with: .none)

        cache.clearMemory()
        cache.clearDisk { [weak self] in
            guard let self else { return }
            self.rows[index].count = 0
            self.rows[index].bytes = 0
            self.clearingIndex = nil
            self.recalculateTotal()
            self.tableView.reloadData()
        }
    }

    private func clearAllCaches() {
        guard clearingIndex == nil else { return }
        clearingIndex = -1
        tableView.reloadData()

        let anim = CABasicAnimation(keyPath: "strokeEnd")
        anim.fromValue = 1.0
        anim.toValue = 0.0
        anim.duration = 0.8
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        ringLayer.add(anim, forKey: "clear")

        cacheManager.clearAll { [weak self] in
            guard let self else { return }
            self.clearingIndex = nil
            for i in self.rows.indices {
                self.rows[i].count = 0
                self.rows[i].bytes = 0
            }
            self.totalBytes = 0
            self.totalCount = 0

            self.ringLayer.strokeEnd = 0
            self.ringLayer.removeAnimation(forKey: "clear")

            UIView.animate(withDuration: 0.3) {
                self.sizeLabel.text = "0"
                self.unitLabel.text = "KB"
                self.countLabel.text = String(localized: "cache.image_count \(0)")
            }

            self.ringLayer.strokeColor = UIColor.systemGreen.cgColor
            let fillAnim = CABasicAnimation(keyPath: "strokeEnd")
            fillAnim.fromValue = 0
            fillAnim.toValue = 1.0
            fillAnim.duration = 0.5
            fillAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fillAnim.fillMode = .forwards
            fillAnim.isRemovedOnCompletion = false
            self.ringLayer.add(fillAnim, forKey: "done")
            self.ringLayer.strokeEnd = 1.0

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                self.ringLayer.strokeColor = ThemeManager.shared.accentColor.cgColor
                self.tableView.reloadData()
            }
        }
    }

    private func confirmClear(title: String, action: @escaping () -> Void) {
        let alert = UIAlertController(
            title: title,
            message: String(localized: "cache.clear_confirm"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "cache.clear_action"), style: .destructive) { _ in
            action()
        })
        present(alert, animated: true)
    }

    private func recalculateTotal() {
        totalBytes = rows.reduce(0) { $0 + $1.bytes }
        totalCount = rows.reduce(0) { $0 + $1.count }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let formatted = formatter.string(fromByteCount: Int64(totalBytes))
        let parts = formatted.split(separator: " ", maxSplits: 1)
        sizeLabel.text = String(parts.first ?? "0")
        unitLabel.text = parts.count > 1 ? String(parts.last!) : ""
        countLabel.text = String(localized: "cache.image_count \(totalCount)")
    }

    private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    private static func directorySize(url: URL?) -> UInt {
        guard let url else { return 0 }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        var total: UInt = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += UInt(size)
            }
        }
        return total
    }
}

// MARK: - UITableViewDataSource

extension CacheViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int { 2 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? rows.count : 1
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let fm = FontManager.shared

        if indexPath.section == 1 {
            // "Clear All" row
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.font = fm.font(size: 17)
            cell.textLabel?.textAlignment = .center
            if clearingIndex != nil || isCalculating {
                cell.textLabel?.text = String(localized: "cache.clearing")
                cell.textLabel?.textColor = .secondaryLabel
                cell.selectionStyle = .none
            } else {
                cell.textLabel?.text = String(localized: "cache.clear_all")
                cell.textLabel?.textColor = .systemRed
                cell.selectionStyle = .default
            }
            return cell
        }

        // Cache category rows
        let row = rows[indexPath.row]
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.textLabel?.font = fm.font(size: 16)
        cell.detailTextLabel?.font = fm.font(size: 15)

        cell.textLabel?.text = String(localized: String.LocalizationValue(row.titleKey))

        if clearingIndex == indexPath.row {
            cell.detailTextLabel?.text = String(localized: "cache.clearing")
            cell.detailTextLabel?.textColor = .secondaryLabel
            cell.selectionStyle = .none
        } else if isCalculating {
            cell.detailTextLabel?.text = String(localized: "cache.calculating")
            cell.detailTextLabel?.textColor = .secondaryLabel
            cell.selectionStyle = .none
        } else {
            let sizeStr = Self.formatter.string(fromByteCount: Int64(row.bytes))
            // "Other" row has no item count and can't be cleared individually.
            if row.cache == nil {
                cell.detailTextLabel?.text = sizeStr
                cell.selectionStyle = .none
            } else {
                cell.detailTextLabel?.text = "\(sizeStr) · \(row.count)"
                cell.selectionStyle = row.bytes > 0 ? .default : .none
            }
            cell.detailTextLabel?.textColor = .secondaryLabel
        }
        return cell
    }
}

// MARK: - UITableViewDelegate

extension CacheViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !isCalculating, clearingIndex == nil else { return }

        if indexPath.section == 1 {
            confirmClear(title: String(localized: "cache.clear_all")) { [weak self] in
                self?.clearAllCaches()
            }
        } else if rows[indexPath.row].bytes > 0, rows[indexPath.row].cache != nil {
            let row = rows[indexPath.row]
            let name = String(localized: String.LocalizationValue(row.titleKey))
            confirmClear(title: name) { [weak self] in
                self?.clearSingleCache(at: indexPath.row)
            }
        }
    }
}
