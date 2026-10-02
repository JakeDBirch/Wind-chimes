import Capacitor
import Foundation

/// Bridge between the web controls in index.html and the native ChimeEngine.
@objc(ChimeEnginePlugin)
public class ChimeEnginePlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "ChimeEnginePlugin"
    public let jsName = "ChimeEngine"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "setParams", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setPhysics", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setSource", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "gust", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getState", returnType: CAPPluginReturnPromise),
    ]

    private let engine = ChimeEngine.shared

    @objc func setParams(_ call: CAPPluginCall) {
        let windStrength = number(call, "windStrength")
        let windConsistency = number(call, "windConsistency")
        let sensitivity = number(call, "sensitivity")
        let swing = number(call, "swing")
        let tubeCount = number(call, "tubeCount").map { Int($0.rounded()) }
        let register = number(call, "register")
        let scale = call.getString("scale")
        let customScale = (call.options["customScale"] as? [NSNumber])?.map { $0.intValue }

        engine.updateParams { p in
            if let windStrength { p.windStrength = windStrength }
            if let windConsistency { p.windConsistency = min(1, max(0, windConsistency)) }
            if let sensitivity { p.sensitivity = sensitivity }
            if let swing { p.swing = min(1, max(0, swing)) }
            if let tubeCount { p.tubeCount = min(12, max(1, tubeCount)) }
            if let register { p.register = register }
            if let scale { p.scale = scale }
            if let customScale { p.customScale = customScale }
        }
        call.resolve()
    }

    /// JS numbers arrive as NSNumber; accept integers and fractions alike.
    private func number(_ call: CAPPluginCall, _ key: String) -> Double? {
        (call.options[key] as? NSNumber)?.doubleValue
    }

    @objc func setPhysics(_ call: CAPPluginCall) {
        engine.setPhysics(call.getBool("on") ?? false)
        call.resolve()
    }

    @objc func setSource(_ call: CAPPluginCall) {
        engine.setSource(call.getString("source") ?? "wind")
        call.resolve()
    }

    @objc func gust(_ call: CAPPluginCall) {
        engine.gust()
        call.resolve()
    }

    @objc func getState(_ call: CAPPluginCall) {
        call.resolve(engine.snapshot())
    }
}
