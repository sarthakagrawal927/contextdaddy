import ContextCore
import Foundation
import Observation

enum AppSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case skills = "Skills"
    case projects = "Projects"
    case telemetry = "Telemetry"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .overview: "Usage"
        case .telemetry: "OpenTelemetry"
        case .skills, .projects: rawValue
        }
    }
    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .skills: "square.stack.3d.up"
        case .projects: "folder.badge.gearshape"
        case .telemetry: "waveform.path.ecg"
        }
    }
}

enum SourcesMode: String, CaseIterable, Identifiable {
    case inventory = "Inventory"
    case diagnostics = "Diagnostics"
    var id: String { rawValue }
}

enum LocalHistorySource: String, CaseIterable, Identifiable {
    case agentLogs = "Agent logs"
    case devin = "Devin index"
    var id: String { rawValue }
}

enum SkillFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case automatic = "Automatic"
    case manual = "Manual only"
    case model = "Model only"
    case disabled = "Disabled"
    case notExposed = "Cannot discover"
    case review = "Needs review"

    var id: String { rawValue }
}

enum SkillsMode: String, CaseIterable, Identifiable {
    case ledger = "How skills run"
    case redundancy = "Redundancy review"
    var id: String { rawValue }
}

enum RedundancyKindFilter: String, CaseIterable, Identifiable {
    case review = "Review candidates"
    case exact = "Exact copies"
    case drift = "Version drift"
    case overlap = "Purpose overlap"
    case managed = "Managed cache"
    case all = "All evidence"
    var id: String { rawValue }
}

enum RedundancyAgentFilter: String, CaseIterable, Identifiable {
    case all = "All agents"
    case codex = "Codex"
    case claude = "Claude"
    case cursor = "Cursor"
    case devin = "Devin"
    case grok = "Grok"
    var id: String { rawValue }
    var runtime: AgentRuntime? { self == .all ? nil : AgentRuntime(rawValue: rawValue) }
}

@MainActor @Observable
final class ContextDaddyModel {
    var section: AppSection? = .overview
    var evidenceOpen = false
    var sourcesMode: SourcesMode = .inventory
    var catalog: SkillCatalogSnapshot? {
        didSet { redundancySummary = catalog.map { SkillRedundancyAnalyzer.analyze(records: $0.records) } }
    }
    var redundancySummary: SkillRedundancySummary?
    var skillIssueBaseline: SkillIssueBaseline?
    var skillIssueVerification: SkillIssueVerification?
    var isVerifyingSkillIssues = false
    var discoveryReport: AIContextDiscoveryReport?
    var projects: [AIContextProject] = []
    var telemetry: ObservabilitySnapshot = .unavailable
    var telemetryHistory: [ObservabilitySnapshot] = []
    var selectedTelemetryRuntime: AgentRuntime = .codex
    var isTelemetryLoading = false
    var usageReport: LocalUsageReport?
    var usageError: String?
    var isUsageLoading = false
    var isDevinLoading = false
    var quotaReceipt: ProviderQuotaReceipt?
    var quotaError: String?
    var quotaReceipts: [String: ProviderQuotaReceipt] = [:]
    var quotaErrors: [String: String] = [:]
    var isQuotaLoading = false
    var autoCheckAllowance = UserDefaults.standard.bool(forKey: "contextDaddyAutoCheckAllowance") {
        didSet { UserDefaults.standard.set(autoCheckAllowance, forKey: "contextDaddyAutoCheckAllowance") }
    }
    var lastAllowanceCheckAttempt = UserDefaults.standard.object(forKey: "contextDaddyLastAllowanceCheckAttempt") as? Date
    var usageService: UsageService = .codex {
        didSet { usageModel = nil; quotaError = nil }
    }
    var usageRange: UsageRange = .month {
        didSet { usageModel = nil }
    }
    var usageModel: String?
    var usageScale: UsageChartScale = .day
    var usageMetric: UsageChartMetric = .generated {
        didSet { if usageHistorySource == .devin && usageMetric == .estimatedCost { usageMetric = .generated } }
    }
    var usageHistoryGrouping: UsageHistoryGrouping = .model {
        didSet { if usageHistorySource == .devin && usageHistoryGrouping == .project { usageHistoryGrouping = .model } }
    }
    var usageHistoryAgents: Set<String> = []
    var usageHistorySource: LocalHistorySource = .agentLogs {
        didSet {
            if usageHistorySource == .devin {
                if usageHistoryGrouping == .project { usageHistoryGrouping = .model }
                if usageMetric == .estimatedCost { usageMetric = .generated }
            }
        }
    }
    var configurationHealth: ConfigurationHealthReport = .empty
    var configurationIssueBaseline: ConfigurationIssueBaseline?
    var configurationIssueVerification: ConfigurationIssueVerification?
    var isVerifyingConfigurationIssues = false
    var search = ""
    var filter: SkillFilter = .all
    var skillsMode: SkillsMode = .ledger
    var redundancyKindFilter: RedundancyKindFilter = .review
    var redundancyAgentFilter: RedundancyAgentFilter = .all
    var selectedRuntime: AgentRuntime = .codex
    var isLoading = false
    var loadStarted = Date()
    var discoveryStatus = "Not scanned yet"
    var lastError: String?
    var extraRoots: [String] = UserDefaults.standard.stringArray(forKey: "contextDaddySearchRoots") ?? [] {
        didSet { UserDefaults.standard.set(extraRoots, forKey: "contextDaddySearchRoots") }
    }
    @ObservationIgnored private var refreshGeneration = UUID()
    @ObservationIgnored private var usageGeneration = UUID()
    @ObservationIgnored private let discover: @Sendable ([URL]) throws -> AIContextDiscoveryReport
    private let snapshotStore = TelemetrySnapshotStore()

    init(discover: @escaping @Sendable ([URL]) throws -> AIContextDiscoveryReport = { roots in
        try AIContextDiscovery.discover(configuration: .init(additionalRoots: roots))
    }) {
        self.discover = discover
    }

    func show(_ destination: AppSection) {
        section = destination
        evidenceOpen = false
    }

    func showEvidence(_ mode: SourcesMode = .inventory) {
        sourcesMode = mode
        evidenceOpen = true
    }

    var inventory: [AIContextItem] { discoveryReport?.items ?? [] }
    var folderRankings: [AIContextFolderRanking] { discoveryReport?.folderRankings ?? [] }
    var governanceSummary: SkillGovernanceSummary? { catalog?.governance(for: selectedRuntime) }
    var sharingSummary: SkillSharingSummary? { catalog?.sharing }
    var usageModels: [String] { usageReport?.models(for: usageService, range: usageRange) ?? [] }
    var usageSlice: UsageSlice? { usageReport?.slice(service: usageService, model: usageModel, range: usageRange) }
    var usageDashboard: UsageDashboardProjection? {
        usageReport.map { UsageDashboardProjection(report: $0, service: usageService, model: usageModel,
                                                   range: usageRange, scale: usageScale, metric: usageMetric) }
    }
    var quotaStatus: ProviderQuotaStatus? {
        guard let key = usageService.quotaKey else { return nil }
        return quotaStatus(for: key)
    }
    func quotaStatus(for key: String) -> ProviderQuotaStatus? {
        quotaReceipts[key]?.providers.first { $0.provider == key }
            ?? quotaReceipt?.providers.first { $0.provider == key }
    }
    var usageHistory: UsageHistoryProjection? {
        guard let usageReport else { return nil }
        if usageHistorySource == .devin {
            guard let devin = usageReport.devin, devin.status == "ready" || devin.status == "empty" else { return nil }
            return UsageHistoryProjection(devin: devin, range: usageRange, scale: usageScale,
                                          grouping: usageHistoryGrouping, metric: usageMetric)
        }
        return UsageHistoryProjection(report: usageReport, agents: usageHistoryAgents,
                                      range: usageRange, scale: usageScale,
                                      grouping: usageHistoryGrouping, metric: usageMetric)
    }

    var visibleSkills: [SkillRecord] {
        guard let records = catalog?.records else { return [] }
        return records.filter { record in
            let matchesSearch = search.isEmpty || record.name.localizedCaseInsensitiveContains(search)
                || record.description.localizedCaseInsensitiveContains(search)
                || record.exposures.contains { $0.logicalPath.localizedCaseInsensitiveContains(search) }
            let matchesFilter = switch filter {
            case .all: true
            case .automatic: record.policy(for: selectedRuntime)?.mode == .automatic
            case .manual: record.policy(for: selectedRuntime)?.mode == .manualOnly
            case .model: record.policy(for: selectedRuntime)?.mode == .modelOnly
            case .disabled: record.policy(for: selectedRuntime)?.mode == .disabled
            case .notExposed: record.policy(for: selectedRuntime)?.isExposed != true
            case .review: record.needsReview(for: selectedRuntime)
            }
            return matchesSearch && matchesFilter
        }
    }

    var visibleRedundancyFindings: [SkillRedundancyFinding] {
        guard let findings = redundancySummary?.findings else { return [] }
        return findings.filter { finding in
            let matchesKind = switch redundancyKindFilter {
            case .review: !finding.isManagedCacheOnly
            case .exact: finding.kind == .exactCopy && !finding.isManagedCacheOnly
            case .drift: finding.kind == .versionDrift
            case .overlap: finding.kind == .semanticOverlap
            case .managed: finding.isManagedCacheOnly
            case .all: true
            }
            let matchesAgent = redundancyAgentFilter.runtime.map { finding.affectedRuntimes.contains($0) } ?? true
            let matchesSearch = search.isEmpty
                || finding.members.contains {
                    $0.name.localizedCaseInsensitiveContains(search)
                        || $0.description.localizedCaseInsensitiveContains(search)
                        || $0.id.localizedCaseInsensitiveContains(search)
                }
                || finding.evidence.contains { $0.localizedCaseInsensitiveContains(search) }
            return matchesKind && matchesAgent && matchesSearch
        }
    }

    func captureSkillIssues() {
        skillIssueBaseline = SkillIssueBaseline(findings: redundancySummary?.actionableFindings ?? [])
        skillIssueVerification = nil
    }

    func verifySkillIssues() async {
        guard let baseline = skillIssueBaseline, !isVerifyingSkillIssues else { return }
        isVerifyingSkillIssues = true
        defer { isVerifyingSkillIssues = false }
        await refresh()
        skillIssueVerification = baseline.verify(
            against: lastError == nil ? redundancySummary : nil,
            scannedRecordIDs: lastError == nil ? catalog.map { Set($0.records.map(\.id)) } : nil)
    }

    func captureConfigurationIssues() {
        configurationIssueBaseline = ConfigurationIssueBaseline(issues: configurationHealth.issues)
        configurationIssueVerification = nil
    }

    func verifyConfigurationIssues() async {
        guard let baseline = configurationIssueBaseline, !isVerifyingConfigurationIssues else { return }
        isVerifyingConfigurationIssues = true
        defer { isVerifyingConfigurationIssues = false }
        await refresh()
        configurationIssueVerification = baseline.verify(against: configurationHealth)
    }

    func refresh() async {
        Task { await refreshUsage() }
        let request = UUID()
        refreshGeneration = request
        isLoading = true
        loadStarted = Date()
        discoveryStatus = discoveryReport == nil ? "Reading local context metadata…" : "Refreshing while previous results remain available…"
        lastError = nil
        defer {
            if refreshGeneration == request { isLoading = false }
        }
        let roots = extraRoots.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let discover = self.discover
        async let loadedContext = Task.detached(priority: .userInitiated) {
            let report = try discover(roots)
            return (report, SkillPolicyResolver.resolve(report: report), AIContextProjectCatalog.projects(from: report))
        }.value
        async let loadedTelemetry = LocalObservabilityClient().load()
        async let loadedConfigurationHealth = Task.detached(priority: .utility) {
            AgentConfigurationAuditor.audit()
        }.value
        let nextTelemetry = await loadedTelemetry
        let nextConfigurationHealth = await loadedConfigurationHealth
        var nextHistory = await snapshotStore.load()
        guard refreshGeneration == request else { return }
        telemetry = nextTelemetry
        configurationHealth = nextConfigurationHealth
        telemetryHistory = nextHistory
        if nextTelemetry.collectorReachable {
            do {
                nextHistory = try await snapshotStore.append(nextTelemetry)
                guard refreshGeneration == request else { return }
                telemetryHistory = nextHistory
            } catch {
                lastError = "Telemetry was measured but could not be retained: \(error.localizedDescription)"
            }
        }
        do {
            let loaded = try await loadedContext
            guard refreshGeneration == request else { return }
            discoveryReport = loaded.0
            catalog = loaded.1
            projects = loaded.2
            discoveryStatus = "\(loaded.2.count.formatted()) projects · \(loaded.0.items.count.formatted()) file locations · \(String(format: "%.1f", loaded.0.elapsed)) s"
        } catch {
            guard refreshGeneration == request else { return }
            lastError = error.localizedDescription
            discoveryStatus = discoveryReport == nil ? "Discovery needs attention" : "Refresh failed · showing previous results"
        }
    }

    func refreshTelemetry() async {
        guard !isTelemetryLoading else { return }
        isTelemetryLoading = true
        defer { isTelemetryLoading = false }
        let next = await LocalObservabilityClient().load()
        telemetry = next
        guard next.collectorReachable else { return }
        do {
            telemetryHistory = try await snapshotStore.append(next)
        } catch {
            lastError = "Telemetry was measured but could not be retained: \(error.localizedDescription)"
        }
    }

    func refreshUsage(force: Bool = false) async {
        let request = UUID()
        usageGeneration = request
        isUsageLoading = true
        isDevinLoading = true
        let devinTask = Task {
            do { return try await DevinUsageClient().load() }
            catch { return DevinUsage.unavailable(message: error.localizedDescription) }
        }
        do {
            let report = try await CCUsageClient().loadUsage(refresh: force)
            guard usageGeneration == request else { return }
            usageReport = usageReport?.devin.map { report.withDevin($0) } ?? report
            usageError = report.error?.message
            if let usageModel, !report.models(for: usageService, range: usageRange).contains(usageModel) {
                self.usageModel = nil
            }
        } catch {
            guard usageGeneration == request else { return }
            usageError = error.localizedDescription
            // A transport failure must not discard the last valid local view.
            if usageReport == nil { usageReport = .unavailable(message: error.localizedDescription) }
        }
        isUsageLoading = false
        let devin = await devinTask.value
        guard usageGeneration == request else { return }
        if let usageReport { self.usageReport = usageReport.withDevin(devin) }
        isDevinLoading = false
    }

    func refreshQuota() async {
        let service = usageService
        guard service.quotaKey != nil else { return }
        isQuotaLoading = true
        quotaError = nil
        defer { isQuotaLoading = false }
        do {
            let receipt = try await ProviderQuotaClient().loadQuota(for: service)
            quotaReceipt = receipt
            if let key = service.quotaKey { quotaReceipts[key] = receipt; quotaErrors[key] = nil }
        } catch {
            quotaError = error.localizedDescription
            if let key = service.quotaKey { quotaErrors[key] = error.localizedDescription }
        }
    }

    /// Only called by the explicit Usage-page button; this may contact both providers.
    func refreshAllQuotas() async {
        guard !isQuotaLoading else { return }
        lastAllowanceCheckAttempt = Date()
        UserDefaults.standard.set(lastAllowanceCheckAttempt, forKey: "contextDaddyLastAllowanceCheckAttempt")
        isQuotaLoading = true
        defer { isQuotaLoading = false }
        for service in [UsageService.codex, .claude] {
            guard let key = service.quotaKey else { continue }
            do {
                quotaReceipts[key] = try await ProviderQuotaClient().loadQuota(for: service)
                quotaErrors[key] = nil
            } catch {
                quotaErrors[key] = error.localizedDescription
            }
        }
    }

    func autoRefreshQuotasIfNeeded(now: Date = Date()) async {
        guard AllowanceAutoCheckPolicy.shouldCheck(enabled: autoCheckAllowance,
                                                  lastAttempt: lastAllowanceCheckAttempt, now: now),
              !isQuotaLoading else { return }
        await refreshAllQuotas()
    }

    func addExtraRoots(_ urls: [URL]) {
        for url in urls {
            let path = url.standardizedFileURL.path
            if !extraRoots.contains(path) { extraRoots.append(path) }
        }
    }

    func removeExtraRoot(_ path: String) {
        extraRoots.removeAll { $0 == path }
    }
}
