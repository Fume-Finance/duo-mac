import UIKit

// Duo Mac for iPhone: the same page as the Home Screen web app (web/), shown full screen in a web
// view, with what Safari can't give it: real haptics, Face ID through the Secure Enclave, the screen
// kept awake, edge swipes left to the trackpad, and finding the Mac on this iPhone's hotspot.
// Built and kept installed by tools/ios-app.sh (free Apple ID signing lasts 7 days).

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let c = UISceneConfiguration(name: "Default", sessionRole: session.role)
        c.delegateClass = SceneDelegate.self
        return c
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: ws)
        w.backgroundColor = .black
        w.rootViewController = WebViewController()
        w.makeKeyAndVisible()
        window = w
        if UserDefaults.standard.string(forKey: "dictationEngine") != "apple" { WhisperEngine.shared.loadIfDownloaded() }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        (window?.rootViewController as? WebViewController)?.becameActive()
        Tailnet.shared.resumed()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        UIApplication.shared.isIdleTimerDisabled = false
    }
}
