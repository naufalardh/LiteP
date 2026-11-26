import UIKit

@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let tabs = UITabBarController()
        let roots: [(UIViewController, String)] = [
            (SearchViewController(style: .plain), "Search"),
            (DownloadsViewController(style: .plain), "Downloads"),
            (LibraryViewController(style: .plain), "Library"),
            (ExtensionsViewController(style: .grouped), "Extensions"),
        ]
        tabs.viewControllers = roots.map { vc, title in
            let nav = UINavigationController(rootViewController: vc)
            nav.tabBarItem = UITabBarItem(title: title, image: nil, tag: 0)
            nav.tabBarItem.titlePositionAdjustment = UIOffset(horizontal: 0, vertical: -12)
            return nav
        }
        tabs.tabBar.isTranslucent = false
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.backgroundColor = .white
        window?.rootViewController = tabs
        window?.makeKeyAndVisible()
        _ = Player.shared
        Lite.shared.start {
            if let error = Lite.shared.startError {
                tabs.selectedViewController?.alert("Backend failed to start", error)
            }
        }
        return true
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        try? Lite.shared.backend.releaseMemoryUnderPressure()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        if DownloadManager.shared.jobs.allSatisfy({ $0.done }) { try? Lite.shared.backend.releaseIdleResources() }
    }
}
