//
//  TweetNestApp.swift
//  TweetNest
//
//  Created by Jaehong Kang on 2021/02/23.
//

import SwiftUI
import TweetNestKit
import UnifiedLogging

#if os(iOS)
typealias ApplicationDelegateAdaptor = UIApplicationDelegateAdaptor
#elseif os(macOS)
typealias ApplicationDelegateAdaptor = NSApplicationDelegateAdaptor
#elseif os(watchOS)
typealias ApplicationDelegateAdaptor = WKExtensionDelegateAdaptor
#endif

@main
struct TweetNestApp: App {
    #if DEBUG
    static nonisolated var isPreview: Bool {
        CommandLine.arguments.contains("-com.tweetnest.TweetNest.Preview") || ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }
    #endif

    static nonisolated var session: Session {
        #if DEBUG
        if isPreview {
            return Session.preview
        } else {
            return Session.shared
        }
        #else
        return Session.shared
        #endif
    }

    @ApplicationDelegateAdaptor(TweetNestAppDelegate.self) var delegate
    @Environment(\.scenePhase) private var scenePhase

    var session: Session {
        delegate.session
    }

    var body: some Scene {
        Group {
            WindowGroup {
                MainView()
                    .environmentObject(delegate)
                    .environment(\.managedObjectContext, session.persistentContainer.viewContext)
                    #if os(macOS) && DEBUG
                    .frame(width: Self.isPreview ? 1440 : nil, height: Self.isPreview ? (900 - 52) : nil)
                    #endif
            }
            #if os(iOS) || os(macOS)
            .commands {
                SidebarCommands()
            }
            #endif

            #if os(macOS)
            Settings {
                SettingsMainView()
                    .environment(\.managedObjectContext, session.persistentContainer.viewContext)
            }
            #elseif os(watchOS)
            WKNotificationScene(controller: NotificationController.self, category: "NewAccountData")
            #endif
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active, .inactive:
                session.resumeAutomaticallyFetchNewData()
            case .background:
                session.pauseAutomaticallyFetchNewData()
                #if (canImport(BackgroundTasks) && !os(macOS)) || canImport(WatchKit)
                Task {
                    do {
                        try await BackgroundTaskScheduler.shared.scheduleBackgroundTasks()
                    } catch {
                        Logger().error("Error occurred while schedule refresh: \(String(reflecting: error), privacy: .public)")
                    }
                }
                #endif
            @unknown default:
                break
            }
        }
    }
}
