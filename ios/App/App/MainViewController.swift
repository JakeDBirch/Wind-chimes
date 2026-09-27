import Capacitor
import UIKit

/// Capacitor's web view controller, with the app's own native plugin registered.
class MainViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        bridge?.registerPluginInstance(ChimeEnginePlugin())
    }
}
