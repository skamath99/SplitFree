import Combine
import CoreData
import CloudKit

/// Publishes an always-truthful summary of whether iCloud sync can actually
/// work, so the UI can warn the user. Two signals feed it: the account status
/// (`CKContainer.accountStatus`) and finished mirroring events
/// (`NSPersistentCloudKitContainer.eventChangedNotification`) whose CKError
/// reveals a problem the account status doesn't — a full account frequently
/// still reports status `.available`, so a `quotaExceeded` event wins over it.
@MainActor
final class CloudSyncStatus: ObservableObject {
    static let shared = CloudSyncStatus()

    enum State: Equatable {
        case healthy
        case noAccount
        case unavailable   // restricted / temporarilyUnavailable / couldNotDetermine
        case storageFull
    }

    @Published private(set) var state: State = .healthy

    private var accountState: State = .healthy
    private var eventState: State?
    private var failingEventType: NSPersistentCloudKitContainer.EventType?
    private var observers: [NSObjectProtocol] = []

    private init() {
        // Under --local-store there is no CloudKit to report on: stay healthy
        // forever and register nothing.
        guard PersistenceController.shared.isCloudBacked else { return }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.checkAccountStatus() }
        })
        observers.append(center.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification,
                                            object: nil, queue: nil) { [weak self] note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { return }
            Task { @MainActor in self?.handle(event) }
        })

        checkAccountStatus()
    }

    private func checkAccountStatus() {
        CKContainer(identifier: PersistenceController.cloudKitContainerID).accountStatus { [weak self] status, _ in
            Task { @MainActor in self?.apply(status) }
        }
    }

    private func apply(_ status: CKAccountStatus) {
        switch status {
        case .available: accountState = .healthy
        case .noAccount: accountState = .noAccount
        case .restricted, .temporarilyUnavailable, .couldNotDetermine: accountState = .unavailable
        @unknown default: accountState = .unavailable
        }
        recompute()
    }

    private func handle(_ event: NSPersistentCloudKitContainer.Event) {
        guard event.endDate != nil else { return }   // only finished events carry a verdict
        if let error = event.error as? CKError {
            if error.containsQuotaExceeded {
                eventState = .storageFull
                failingEventType = event.type
            } else if error.code == .notAuthenticated {
                eventState = .noAccount
                failingEventType = event.type
            }
            recompute()
        } else if event.succeeded, event.type == failingEventType {
            // The same kind of event that failed now succeeded: clear the
            // event-derived warning and re-derive from the account status.
            eventState = nil
            failingEventType = nil
            recompute()
            checkAccountStatus()
        }
    }

    private func recompute() {
        state = eventState ?? accountState
    }
}

private extension CKError {
    /// True for a direct quota error or a partial failure that contains one.
    var containsQuotaExceeded: Bool {
        if code == .quotaExceeded { return true }
        guard code == .partialFailure,
              let partials = partialErrorsByItemID?.values else { return false }
        return partials.contains { ($0 as? CKError)?.code == .quotaExceeded }
    }
}
