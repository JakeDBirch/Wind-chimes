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
        CAPPluginMethod(name: "gust", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setSound", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startStandby", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setTriggerLevel", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "arm", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "disarm", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopRecording", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cancelRecording", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "listSamples", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "saveSample", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "selectSample", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "deleteSample", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getState", returnType: CAPPluginReturnPromise),
    ]

    private let engine = ChimeEngine.shared

    @objc func setParams(_ call: CAPPluginCall) {
        let windStrength = number(call, "windStrength")
        let windConsistency = number(call, "windConsistency")
        let sensitivity = number(call, "sensitivity")
        let tubeCount = number(call, "tubeCount").map { Int($0.rounded()) }
        let register = number(call, "register")
        let scale = call.getString("scale")
        let windSound = call.getBool("windSound")
        let customScale = (call.options["customScale"] as? [NSNumber])?.map { $0.intValue }

        engine.updateParams { p in
            if let windStrength { p.windStrength = windStrength }
            if let windConsistency { p.windConsistency = min(1, max(0, windConsistency)) }
            if let sensitivity { p.sensitivity = sensitivity }
            if let tubeCount { p.tubeCount = min(12, max(1, tubeCount)) }
            if let register { p.register = register }
            if let scale { p.scale = scale }
            if let windSound { p.windSound = windSound }
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

    @objc func gust(_ call: CAPPluginCall) {
        engine.gust()
        call.resolve()
    }

    @objc func setSound(_ call: CAPPluginCall) {
        engine.setSound(call.getString("mode") ?? "metal")
        call.resolve()
    }

    public override func load() {
        engine.onRecordingEvent = { [weak self] name, data in
            self?.notifyListeners(name, data: data)
        }
    }

    @objc func startStandby(_ call: CAPPluginCall) {
        engine.startStandby { error in
            if let error {
                call.reject("Microphone unavailable", Self.code(for: error))
            } else {
                call.resolve()
            }
        }
    }

    @objc func setTriggerLevel(_ call: CAPPluginCall) {
        engine.setTriggerLevel(number(call, "dB") ?? -30)
        call.resolve()
    }

    @objc func arm(_ call: CAPPluginCall) {
        engine.arm()
        call.resolve()
    }

    @objc func disarm(_ call: CAPPluginCall) {
        engine.disarm()
        call.resolve()
    }

    @objc func stopRecording(_ call: CAPPluginCall) {
        engine.stopRecording { result in
            switch result {
            case .success(let sample):
                call.resolve(sample.info)
            case .failure(let error):
                call.reject("Recording failed", Self.code(for: error))
            }
        }
    }

    @objc func cancelRecording(_ call: CAPPluginCall) {
        engine.cancelRecording()
        call.resolve()
    }

    @objc func listSamples(_ call: CAPPluginCall) {
        call.resolve(["samples": engine.listSamples()])
    }

    @objc func saveSample(_ call: CAPPluginCall) {
        let name = call.getString("name") ?? ""
        engine.saveSample(name: name) { info in
            if let info { call.resolve(info) } else { call.reject("Nothing to save", "noSample") }
        }
    }

    @objc func selectSample(_ call: CAPPluginCall) {
        guard let id = call.getString("id") else { return call.reject("Missing id", "badArgs") }
        engine.selectSample(id: id) { ok in
            if ok { call.resolve() } else { call.reject("Sample not found", "notFound") }
        }
    }

    @objc func deleteSample(_ call: CAPPluginCall) {
        guard let id = call.getString("id") else { return call.reject("Missing id", "badArgs") }
        engine.deleteSample(id: id)
        call.resolve()
    }

    private static func code(for error: Error) -> String {
        switch error as? ChimeEngine.RecordError {
        case .permissionDenied: return "permission"
        case .noInput: return "noInput"
        case .busy: return "busy"
        case .tooQuiet: return "tooQuiet"
        case .notRecording: return "notRecording"
        case nil: return "failed"
        }
    }

    @objc func getState(_ call: CAPPluginCall) {
        call.resolve(engine.snapshot())
    }
}
