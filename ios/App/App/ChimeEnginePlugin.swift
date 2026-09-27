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
        let cordLength = number(call, "cordLength")
        let damping = number(call, "damping")
        let gap = number(call, "gap")
        let tubeCount = number(call, "tubeCount").map { Int($0.rounded()) }
        let windStrength = number(call, "windStrength")
        let windSusc = number(call, "windSusc")
        let windSteady = number(call, "windSteady")
        let windTurb = number(call, "windTurb")
        let register = number(call, "register")
        let scale = call.getString("scale")
        let material = call.getString("material")

        engine.updateParams { p in
            if let cordLength { p.cordLength = cordLength }
            if let damping { p.dampingSlider = damping }
            if let gap { p.gap = gap }
            if let tubeCount { p.tubeCount = max(1, tubeCount) }
            if let windStrength { p.windStrength = windStrength }
            if let windSusc { p.windSusc = windSusc }
            if let windSteady { p.windSteady = windSteady }
            if let windTurb { p.windTurb = windTurb }
            if let register { p.register = register }
            if let scale { p.scale = scale }
            if let material { p.material = material }
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
