import CoreData
import CloudKit

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
        if let existing = existingShare(for: group) { return existing }
        let (_, share, _) = try await container.share([group], to: nil)
        share[CKShare.SystemFieldKey.title] = group.name as CKRecordValue
        persistUpdatedShare(share)
        return share
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

    func accept(_ metadata: CKShare.Metadata) {
        guard let sharedStore else { return }
        container.acceptShareInvitations(from: [metadata], into: sharedStore) { _, error in
            if let error {
                print("Share acceptance failed: \(error)")
            }
        }
    }
}
