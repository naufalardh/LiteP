import UIKit

@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        Theme.apply(window)
        let tabs = MainTabController()
        let roots: [(UIViewController, String, Icon)] = [
            (HomeViewController(), "Home", .home),
            (SearchViewController(style: .plain), "Search", .search),
            (LibraryViewController(style: .plain), "Your Library", .library),
            (DownloadsViewController(style: .plain), "Downloads", .download),
            (SettingsViewController(style: .grouped), "Settings", .settings),
        ]
        tabs.viewControllers = roots.enumerated().map { i, root in
            let (vc, title, icon) = root
            let nav = UINavigationController(rootViewController: vc)
            nav.navigationBar.prefersLargeTitles = true
            nav.tabBarItem = UITabBarItem(title: title, image: icon.image(24), tag: i)
            nav.tabBarItem.badgeColor = Theme.green
            return nav
        }
        window?.rootViewController = tabs
        window?.makeKeyAndVisible()
        _ = Player.shared
        Lite.shared.start {
            LibraryStore.shared.scan {}
            if let error = Lite.shared.startError {
                tabs.selectedViewController?.alert("Backend failed to start", error)
            }
        }
        return true
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        Verification.shared.handle(url)
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        try? Lite.shared.backend.releaseMemoryUnderPressure()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        if DownloadManager.shared.jobs.allSatisfy({ $0.done }) { try? Lite.shared.backend.releaseIdleResources() }
    }
}
