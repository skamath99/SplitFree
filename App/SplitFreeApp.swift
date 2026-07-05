import SwiftUI
import CoreData
import CloudKit
import OSLog

@main
struct SplitFreeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let persistence = PersistenceController.shared

    init() {
        CurrentUser.handleLaunchArguments()
        RecurrenceService.materializeDueExpenses(context: persistence.container.viewContext)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistence.container.viewContext)
        }
    }
}

// UIKit delegates exist only to catch CloudKit share acceptance — the hook
// SwiftUI doesn't expose. Tapping an iCloud invite routes through here.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        Logger(subsystem: "com.sank.splitfree", category: "sharing")
            .log("configurationForConnecting called")
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    func application(_ application: UIApplication,
                     userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        Logger(subsystem: "com.sank.splitfree", category: "sharing")
            .log("AppDelegate userDidAcceptCloudKitShareWith")
        PersistenceController.shared.accept(cloudKitShareMetadata)
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    /// Invite tapped while the app wasn't running: the metadata arrives in the
    /// connection options at launch, not via userDidAcceptCloudKitShareWith.
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        Logger(subsystem: "com.sank.splitfree", category: "sharing")
            .log("SceneDelegate willConnectTo, metadata: \(connectionOptions.cloudKitShareMetadata != nil)")
        if let metadata = connectionOptions.cloudKitShareMetadata {
            PersistenceController.shared.accept(metadata)
        }
    }

    func windowScene(_ windowScene: UIWindowScene,
                     userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        Logger(subsystem: "com.sank.splitfree", category: "sharing")
            .log("SceneDelegate userDidAcceptCloudKitShareWith")
        PersistenceController.shared.accept(cloudKitShareMetadata)
    }
}
