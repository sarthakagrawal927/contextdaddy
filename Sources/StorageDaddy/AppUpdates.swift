import AppKit
import Combine
import Sparkle

@MainActor final class AppUpdates: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published var canCheck = false
    @Published var automaticallyChecks = true {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }
    @Published var waitingForIdle = false
    private var controller: SPUStandardUpdaterController?
    private weak var model: ExplorerModel?
    private var deferredInstall: (() -> Void)?
    private var pendingCheck = false
    private var subscriptions: Set<AnyCancellable> = []

    func start(model: ExplorerModel) {
        guard controller == nil,
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") is String else { return }
        self.model = model
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        model.objectWillChange.merge(with: model.conversationArchive.objectWillChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.resumeWhenIdle() }.store(in: &subscriptions)
        controller.startUpdater()
    }

    var isIdle: Bool {
        guard let model else { return false }
        return !model.busy && !model.monitoring && model.staged.isEmpty
            && !model.conversationArchive.busy && !model.snapshotBusy && !model.showCleanup
    }

    func check() { controller?.checkForUpdates(nil) }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard isIdle else {
            if updateCheck == .updatesInBackground { pendingCheck = true }
            throw NSError(domain: "StorageDaddy.Updates", code: 1, userInfo: [NSLocalizedDescriptionKey: "Finish the current scan, export or cleanup review before checking for updates."])
        }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard !isIdle else { return false }
        deferredInstall = installHandler
        waitingForIdle = true
        return true
    }

    private func resumeWhenIdle() {
        guard isIdle else { return }
        if pendingCheck {
            pendingCheck = false
            controller?.updater.checkForUpdatesInBackground()
        }
        guard let install = deferredInstall else { return }
        deferredInstall = nil
        waitingForIdle = false
        install()
    }
}
