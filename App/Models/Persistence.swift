import CoreData
import CloudKit
import OSLog
import UIKit

/// NSPersistentCloudKitContainer with two stores: the user's own groups live
/// in the private CloudKit database; groups that friends shared with them
/// arrive in the shared database. `--local-store` (UI tests) skips CloudKit
/// entirely and uses one plain on-disk store.
final class PersistenceController {
    static let shared = PersistenceController()
    static let cloudKitContainerID = "iCloud.com.sank.splitfree"

    let container: NSPersistentCloudKitContainer
    private(set) var privateStore: NSPersistentStore?
    private(set) var sharedStore: NSPersistentStore?
    let isCloudBacked: Bool

    init(forceLocal: Bool = CommandLine.arguments.contains("--local-store")) {
        container = NSPersistentCloudKitContainer(name: "SplitFree")

        let baseURL = NSPersistentContainer.defaultDirectoryURL()
        let privateDescription = NSPersistentStoreDescription(url: baseURL.appendingPathComponent("splitfree.sqlite"))
        privateDescription.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        privateDescription.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

        var descriptions = [privateDescription]
        if forceLocal {
            isCloudBacked = false
        } else {
            isCloudBacked = true
            let privateOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: Self.cloudKitContainerID)
            privateOptions.databaseScope = .private
            privateDescription.cloudKitContainerOptions = privateOptions

            let sharedDescription = NSPersistentStoreDescription(url: baseURL.appendingPathComponent("splitfree-shared.sqlite"))
            sharedDescription.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            sharedDescription.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            let sharedOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: Self.cloudKitContainerID)
            sharedOptions.databaseScope = .shared
            sharedDescription.cloudKitContainerOptions = sharedOptions
            descriptions.append(sharedDescription)
        }
        container.persistentStoreDescriptions = descriptions

        container.loadPersistentStores { description, error in
            if let error {
                // Don't take the app down over a sync store; the UI shows
                // whatever loaded. CloudKit-side errors surface in console.
                print("Store load failed: \(error)")
            }
        }
        for description in container.persistentStoreDescriptions {
            guard let url = description.url,
                  let store = container.persistentStoreCoordinator.persistentStore(for: url) else { continue }
            if description.cloudKitContainerOptions?.databaseScope == .shared {
                sharedStore = store
            } else {
                privateStore = store
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        if CommandLine.arguments.contains("--reset-data") {
            resetAllData()
        }

        #if DEBUG
        // Pushes the Core Data schema to the CloudKit development
        // environment so record types exist before real devices sync.
        // Cheap no-op once created; only meaningful on cloud-backed runs.
        if isCloudBacked && CommandLine.arguments.contains("--init-cloudkit-schema") {
            try? container.initializeCloudKitSchema(options: [])
        }
        #endif
    }

    func save() {
        let context = container.viewContext
        guard context.hasChanges else { return }
        try? context.save()
    }

    private func resetAllData() {
        let context = container.viewContext
        for entity in ["SpendingGroup", "Expense", "Member", "ExpenseShare", "LineItem", "Settlement"] {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: entity)
            fetch.includesPropertyValues = false
            if let objects = try? context.fetch(fetch) {
                objects.forEach(context.delete)
            }
        }
        try? context.save()
    }

    // MARK: - Sharing

    /// The CKShare for a group, if it has been shared.
    func existingShare(for group: SpendingGroup) -> CKShare? {
        guard isCloudBacked else { return nil }
        let shares = try? container.fetchShares(matching: [group.objectID])
        return shares?[group.objectID]
    }

    /// Creates (or returns) the share for a group so it can be handed to
    /// UICloudSharingController.
    func share(group: SpendingGroup) async throws -> CKShare {
        let log = Logger(subsystem: "com.sank.splitfree", category: "sharing")
        do {
            let share: CKShare
            if let existing = existingShare(for: group) {
                share = existing
            } else {
                (_, share, _) = try await container.share([group], to: nil)
            }
            return try await publish(share, title: group.name)
        } catch {
            log.error("Creating share failed: \(error, privacy: .public)")
            throw error
        }
    }

    /// Guarantees the share is live on the server, has its URL, and is
    /// link-joinable (anyone with the link, read-write — the owner can
    /// restrict it later via Manage sharing). Repairs shares that a previous
    /// build left half-created locally: the local mirror's copy can be stale
    /// or never exported, so the server's copy is fetched and saved directly
    /// rather than trusting the async mirroring export.
    private func publish(_ share: CKShare, title: String) async throws -> CKShare {
        if share.url != nil && share.publicPermission != .none { return share }

        let log = Logger(subsystem: "com.sank.splitfree", category: "sharing")
        let database = CKContainer(identifier: Self.cloudKitContainerID).privateCloudDatabase

        var record: CKShare
        do {
            record = try await database.record(for: share.recordID) as? CKShare ?? share
            log.log("publish: fetched server copy, url: \(record.url?.absoluteString ?? "nil", privacy: .public)")
        } catch {
            log.log("publish: no server copy (\(error, privacy: .public)); saving local one")
            record = share
        }
        record[CKShare.SystemFieldKey.title] = title as CKRecordValue
        record.publicPermission = .readWrite

        do {
            return try await save(record, to: database)
        } catch let error as CKError where error.code == .zoneNotFound {
            // The share's zone never made it to the server either.
            log.log("publish: creating missing zone")
            _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: share.recordID.zoneID)],
                                                     deleting: [])
            return try await save(record, to: database)
        }
    }

    private func save(_ record: CKShare, to database: CKDatabase) async throws -> CKShare {
        do {
            let saved = try await database.save(record) as? CKShare ?? record
            persistUpdatedShare(saved)
            return saved
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Another device raced us; apply our fields to the server's copy.
            guard let server = error.serverRecord as? CKShare else { throw error }
            server[CKShare.SystemFieldKey.title] = record[CKShare.SystemFieldKey.title]
            server.publicPermission = record.publicPermission
            let saved = try await database.save(server) as? CKShare ?? server
            persistUpdatedShare(saved)
            return saved
        }
    }

    /// Pushes share edits (title, participants, permissions) back into the
    /// local mirror so Core Data doesn't overwrite them with a stale copy.
    func persistUpdatedShare(_ share: CKShare) {
        guard let privateStore else { return }
        container.persistUpdatedShare(share, in: privateStore) { _, error in
            if let error {
                print("Persisting updated share failed: \(error)")
            }
        }
    }

    /// Whether this device's user owns the group (vs. it being shared to them).
    func isOwner(of group: SpendingGroup) -> Bool {
        guard let share = existingShare(for: group) else { return true }
        return share.currentUserParticipant == share.owner
    }

    /// A participant "deleting" a shared group must LEAVE it, not delete it:
    /// with read-write access their local `context.delete` would export and
    /// destroy the group in the owner's zone for everyone (confirmed against
    /// production). `purgeObjectsAndRecordsInZone` on the shared store is the
    /// documented way for a participant to stop participating — it drops only
    /// this device's mirror of the zone, without exporting deletions.
    func leave(group: SpendingGroup) async throws {
        guard let sharedStore,
              let zoneID = existingShare(for: group)?.recordID.zoneID else {
            throw CocoaError(.persistentStoreOperation)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.purgeObjectsAndRecordsInZone(with: zoneID, in: sharedStore) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Diagnostic: fetches and logs a share's metadata WITHOUT accepting —
    /// safe against live shares (read-only), works even with --local-store.
    func probeShare(from url: URL) async {
        let log = Logger(subsystem: "com.sank.splitfree", category: "sharing")
        do {
            let metadata = try await CKContainer(identifier: Self.cloudKitContainerID).shareMetadata(for: url)
            log.log("probeShare OK: \(String(describing: metadata), privacy: .public)")
        } catch {
            log.error("probeShare failed: \(error, privacy: .public)")
        }
    }

    /// Programmatic share acceptance from a raw invite URL — the path UI tests
    /// use, since tapping an icloud.com share link doesn't work on simulators.
    func acceptShare(from url: URL) async {
        let log = Logger(subsystem: "com.sank.splitfree", category: "sharing")
        guard isCloudBacked else {
            log.log("acceptShare skipped: not cloud-backed")
            return
        }
        log.log("acceptShare: fetching metadata for \(url.absoluteString, privacy: .public)")
        do {
            let metadata = try await Self.fetchShareMetadata(for: url)
            accept(metadata)
        } catch {
            log.error("acceptShare failed: \(error, privacy: .public)")
        }
    }

    /// The async `shareMetadata(for:)` convenience runs at background QoS and
    /// starves indefinitely behind a sync backlog (a launch-time import of many
    /// zones queues ahead of it in cloudd). An explicit user-initiated
    /// operation jumps that queue — acceptance is the thing the user is
    /// actively waiting on.
    private static func fetchShareMetadata(for url: URL) async throws -> CKShare.Metadata {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKFetchShareMetadataOperation(shareURLs: [url])
            operation.qualityOfService = .userInitiated
            var fetched: CKShare.Metadata?
            operation.perShareMetadataResultBlock = { _, result in
                if case .success(let metadata) = result { fetched = metadata }
            }
            operation.fetchShareMetadataResultBlock = { result in
                switch (result, fetched) {
                case (.failure(let error), _):
                    continuation.resume(throwing: error)
                case (.success, .some(let metadata)):
                    continuation.resume(returning: metadata)
                case (.success, .none):
                    continuation.resume(throwing: CKError(.unknownItem))
                }
            }
            CKContainer(identifier: cloudKitContainerID).add(operation)
        }
    }

    func accept(_ metadata: CKShare.Metadata) {
        guard let sharedStore else { return }
        container.acceptShareInvitations(from: [metadata], into: sharedStore) { _, error in
            if let error {
                // A silent failure here strands the recipient on an empty app
                // with no idea the invite didn't take — surface it.
                print("Share acceptance failed: \(error)")
                Task { @MainActor in Self.presentShareError(error) }
            }
        }
    }

    /// Alerts from the top presented view controller — the same top-VC walk
    /// CloudSharePresenter uses, since acceptance runs outside any SwiftUI view.
    @MainActor
    private static func presentShareError(_ error: Error) {
        let alert = UIAlertController(title: "Couldn't open the shared group",
                                     message: error.localizedDescription,
                                     preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.keyWindow?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        top.present(alert, animated: true)
    }
}
