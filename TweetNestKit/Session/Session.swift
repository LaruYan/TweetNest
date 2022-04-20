//
//  Session.swift
//  TweetNestKit
//
//  Created by Jaehong Kang on 2021/02/23.
//

import Foundation
import UserNotifications
import CoreData
import OrderedCollections
import UnifiedLogging
import BackgroundTask
import Twitter

public class Session {
    public static let shared = Session()

    private let _twitterAPIConfiguration: AsyncLazy<TwitterAPIConfiguration>
    public var twitterAPIConfiguration: TwitterAPIConfiguration {
        get async throws {
            try await _twitterAPIConfiguration.wrappedValue
        }
    }

    private let inMemory: Bool
    private(set) lazy var sessionActor = SessionActor(session: self)

    public private(set) lazy var persistentContainer = PersistentContainer(inMemory: inMemory)
    private(set) lazy var dataAssetsURLSessionManager = DataAssetsURLSessionManager(session: self)

    private lazy var persistentStoreRemoteChangeNotification = NotificationCenter.default
        .publisher(for: .NSPersistentStoreRemoteChange, object: persistentContainer.persistentStoreCoordinator)
        .sink { [weak self] _ in
            self?.handlePersistentStoreRemoteChanges()
        }

    @Published
    public private(set) var persistentContainerLoadingResult: Result<Void, Swift.Error>?

    @Published
    public private(set) var persistentCloudKitContainerEvents: OrderedDictionary<UUID, PersistentContainer.CloudKitEvent> = [:]
    private lazy var persistentCloudKitContainerEventDidChanges = NotificationCenter.default
        .publisher(for: NSPersistentCloudKitContainer.eventChangedNotification, object: persistentContainer)
        .compactMap { $0.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event }
        .receive(on: DispatchQueue.main)
        .sink { [weak self] event in
            self?.persistentCloudKitContainerEvents[event.identifier] = PersistentContainer.CloudKitEvent(event)
        }

    private lazy var fetchNewDataIntervalObserver = TweetNestKitUserDefaults.standard
        .observe(\.fetchNewDataInterval, options: [.new]) { [weak self] userDefaults, changes in
            self?.fetchNewDataIntervalDidChange(changes.newValue ?? userDefaults.fetchNewDataInterval)
        }

    private init(twitterAPIConfiguration: @escaping () async throws -> TwitterAPIConfiguration, inMemory: Bool) {
        _twitterAPIConfiguration = .init(twitterAPIConfiguration)
        self.inMemory = inMemory

        Task.detached {
            if inMemory == false {
                _ = self.persistentStoreRemoteChangeNotification
                _ = self.persistentCloudKitContainerEventDidChanges
            }

            Task(priority: .utility) {
                do {
                    try await self.persistentContainer.loadPersistentStores()

                    await MainActor.run {
                        self.persistentContainerLoadingResult = .success(())
                    }
                } catch {
                    Logger(label: Bundle.tweetNestKit.bundleIdentifier!, category: String(reflecting: Self.self))
                        .error("Error occurred while load persistent stores: \(error as NSError, privacy: .public)")

                    await MainActor.run {
                        self.persistentContainerLoadingResult = .failure(error)
                    }
                }
            }

            Task(priority: .utility) {
                _ = try? await self.twitterAPIConfiguration
            }

            Task(priority: .utility) {
                _ = self.fetchNewDataIntervalObserver
            }
        }
    }
}

extension Session {
    public convenience init(twitterAPIConfiguration: @autoclosure @escaping () throws -> TwitterAPIConfiguration? = nil, inMemory: Bool = false) {
        self.init(
            twitterAPIConfiguration: {
                if let twitterAPIConfiguration = try twitterAPIConfiguration() {
                    return twitterAPIConfiguration
                } else {
                    return try await .iCloud
                }
            },
            inMemory: inMemory
        )
    }

    public convenience init(twitterAPIConfiguration: @autoclosure @escaping () async throws -> TwitterAPIConfiguration, inMemory: Bool = false) async {
        self.init(twitterAPIConfiguration: { try await twitterAPIConfiguration() }, inMemory: inMemory)
    }
}

extension Session {
    public func twitterSession(for accountObjectID: NSManagedObjectID? = nil) async throws -> Twitter.Session {
        try await sessionActor.twitterSession(for: accountObjectID)
    }
}

extension Session {
    @discardableResult
    public static func handleEventsForBackgroundURLSession(_ identifier: String, completionHandler: @escaping () -> Void) -> Bool {
        switch identifier {
        case DataAssetsURLSessionManager.backgroundURLSessionIdentifier:
            Task {
                await Session.shared.dataAssetsURLSessionManager.handleBackgroundURLSessionEvents(completionHandler: completionHandler)
            }
            return true
        default:
            return false
        }
    }
}

extension Session {
    private func fetchNewDataIntervalDidChange(_ newValue: TimeInterval) {
        Task {
            await sessionActor.updateFetchNewDataTimer(interval: newValue)
        }
    }

    public func pauseAutomaticallyFetchNewData() {
        Task {
            await sessionActor.destroyFetchNewDataTimer()
        }
    }

    public func resumeAutomaticallyFetchNewData() {
        Task {
            await sessionActor.initializeFetchNewDataTimer(interval: TweetNestKitUserDefaults.standard.fetchNewDataInterval)
        }
    }
}

extension Session {
    @discardableResult
    public func fetchNewData(cleansingData: Bool = true, force: Bool = false) async throws -> Bool {
        try await withExtendedBackgroundExecution { [self] in
            let logger = Logger(subsystem: Bundle.tweetNestKit.bundleIdentifier!, category: "fetch-new-data")

            guard force || TweetNestKitUserDefaults.standard.lastFetchNewDataDate.addingTimeInterval(TweetNestKitUserDefaults.standard.fetchNewDataInterval) < Date() else {
                return false
            }

            TweetNestKitUserDefaults.standard.lastFetchNewDataDate = Date()

            do {
                defer {
                    if cleansingData {
                        Task.detached(priority: .utility) {
                            do {
                                try await self.cleansingAllData(force: force)
                            } catch {
                                Logger(label: Bundle.tweetNestKit.bundleIdentifier!, category: String(reflecting: Self.self))
                                    .error("Error occurred while cleansing data: \(error as NSError, privacy: .public)")
                            }
                        }
                    }
                }

                let hasChanges = try await updateAllAccounts()

                for hasChanges in hasChanges {
                    _ = try hasChanges.1.get()
                }

                return try await updateAllAccounts().reduce(false, { try $1.1.get() || $0 })
            } catch {
                logger.error("Error occurred while update accounts: \(String(describing: error))")

                switch error {
                case is CancellationError, URLError.cancelled:
                    break
                default:
                    let notificationContent = UNMutableNotificationContent()
                    notificationContent.title = String(localized: "Background Refresh", bundle: .tweetNestKit, comment: "background-refresh notification title.")
                    notificationContent.subtitle = String(localized: "Error", bundle: .tweetNestKit, comment: "background-refresh notification subtitle.")
                    notificationContent.body = error.localizedDescription
                    notificationContent.sound = .default

                    let notificationRequest = UNNotificationRequest(identifier: UUID().uuidString, content: notificationContent, trigger: nil)

                    do {
                        try await UNUserNotificationCenter.current().add(notificationRequest)
                    } catch {
                        logger.error("Error occurred while request notification: \(String(reflecting: error), privacy: .public)")

                        throw error
                    }
                }

                return false
            }
        }
    }
}
