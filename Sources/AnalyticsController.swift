import Foundation

/// Owns the analytics store. Scans and snapshot builds run on a private serial utility queue;
/// every published property changes on the main queue, followed by `onChange`.
final class AnalyticsController: AnalyticsProviding {
    private(set) var snapshot: AnalyticsSnapshot?
    private(set) var status = AnalyticsScanStatus(isScanning: false, processedBytes: 0, totalBytes: 0, lastError: nil)
    private(set) var period: AnalyticsPeriod = .month
    var onChange: (() -> Void)?

    private let queue = DispatchQueue(label: "com.mohamedfuad.codexaccountswitcher.analytics", qos: .utility)
    private let persistence: AnalyticsPersistence
    private let roots: AnalyticsLogRoots
    private let pricing: AnalyticsPricing
    private var store: AnalyticsStore?
    private var isRefreshing = false
    private var refreshPending = false

    init(persistence: AnalyticsPersistence = AnalyticsPersistence(directory: AnalyticsPersistence.defaultDirectory),
         roots: AnalyticsLogRoots = .standard(),
         pricing: AnalyticsPricing = .shared) {
        self.persistence = persistence
        self.roots = roots
        self.pricing = pricing
    }

    func refresh() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.refresh() }
            return
        }
        guard !isRefreshing else {
            refreshPending = true
            return
        }
        isRefreshing = true
        publish(status: AnalyticsScanStatus(isScanning: true, processedBytes: 0, totalBytes: status.totalBytes, lastError: nil))
        let period = self.period
        queue.async { [weak self] in
            self?.scan(period: period)
        }
    }

    func select(_ period: AnalyticsPeriod) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.select(period) }
            return
        }
        self.period = period
        onChange?()
        queue.async { [weak self] in
            guard let self, let store = self.store else { return }
            let snapshot = self.build(store, period: period)
            DispatchQueue.main.async {
                guard self.period == period else { return }
                self.snapshot = snapshot
                self.onChange?()
            }
        }
    }

    // MARK: Queue work

    private func scan(period: AnalyticsPeriod) {
        if store == nil {
            store = persistence.load()
            if let store {
                let early = build(store, period: period)
                DispatchQueue.main.async { self.publish(snapshot: early) }
            }
        }
        var working = store ?? AnalyticsStore()
        let resolver = AnalyticsProjectResolver(cache: working.projects)
        let scanner = AnalyticsScanner(roots: roots, projects: resolver)
        let outcome = scanner.scan(&working) { [weak self] processed, total in
            DispatchQueue.main.async {
                self?.publish(status: AnalyticsScanStatus(isScanning: true, processedBytes: processed, totalBytes: total, lastError: nil))
            }
        }
        var lastError = outcome.errors.first
        if outcome.filesParsed > 0 || store == nil {
            do {
                try persistence.save(working)
            } catch {
                lastError = "Could not save analytics state: \(error.localizedDescription)"
            }
        }
        store = working
        let snapshot = build(working, period: period)
        DispatchQueue.main.async { [weak self] in
            self?.finish(snapshot: snapshot, period: period, error: lastError)
        }
    }

    private func build(_ store: AnalyticsStore, period: AnalyticsPeriod) -> AnalyticsSnapshot {
        AnalyticsSnapshotBuilder(pricing: pricing, timeZone: .current, now: Date())
            .build(store: store, sessions: AnalyticsScanner.sessionRecords(store), period: period)
    }

    // MARK: Main queue

    private func finish(snapshot: AnalyticsSnapshot, period: AnalyticsPeriod, error: String?) {
        if self.period == period { self.snapshot = snapshot }
        status = AnalyticsScanStatus(isScanning: false, processedBytes: status.totalBytes, totalBytes: status.totalBytes, lastError: error)
        isRefreshing = false
        onChange?()
        if self.period != period { select(self.period) }
        if refreshPending {
            refreshPending = false
            refresh()
        }
    }

    private func publish(status: AnalyticsScanStatus) {
        self.status = status
        onChange?()
    }

    private func publish(snapshot: AnalyticsSnapshot) {
        guard snapshot.period == period else { return }
        self.snapshot = snapshot
        onChange?()
    }
}
