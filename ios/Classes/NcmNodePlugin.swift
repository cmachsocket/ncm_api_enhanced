// NcmNodePlugin.swift — Flutter plugin that drives NodeMobile.xcframework
// (nodejs-mobile v18.20.4) on iOS.
//
// Contract with Dart `MobileNcmBridge`:
//   Method channel: "ncm_api_enhanced/bridge"
//     start(Map)    → Map {ready: true}
//     call(Map)     → null
//     shutdown()    → null
//   Event channel:  "ncm_api_enhanced/events"
//     emits one event per NDJSON line emitted by bridge.js.

import Flutter
import UIKit

public class NcmNodePlugin: NSObject, FlutterPlugin, FlutterStreamHandler, NodeRunnerDelegate {

    private static let METHOD_CHANNEL = "ncm_api_enhanced/bridge"
    private static let EVENT_CHANNEL = "ncm_api_enhanced/events"

    private var eventSink: FlutterEventSink?
    private var started = false
    private let ioQueue = DispatchQueue(label: "ncm-node-io", qos: .userInitiated)

    public static func register(with registrar: FlutterPluginRegistrar) {
        let methodChannel = FlutterMethodChannel(
            name: METHOD_CHANNEL, binaryMessenger: registrar.messenger())
        let eventChannel = FlutterEventChannel(
            name: EVENT_CHANNEL, binaryMessenger: registrar.messenger())
        let plugin = NcmNodePlugin()
        registrar.addMethodCallDelegate(plugin, channel: methodChannel)
        eventChannel.setStreamHandler(plugin)
    }

    // MARK: - FlutterPlugin

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "start":
            handleStart(result: result)
        case "call":
            handleCall(call: call, result: result)
        case "shutdown":
            handleShutdown(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - FlutterStreamHandler

    public func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    public func onCancel(withArguments _: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    // MARK: - NodeRunnerDelegate (called on background threads)

    public func nodeRunner(_ runner: NodeRunner, didProduceStdout data: Data) {
        // EventChannel expects the payload to be one of the standard
        // types. Pass bytes as FlutterStandardTypedData; Dart splits.
        let typed = FlutterStandardTypedData(bytes: data)
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(typed)
        }
    }

    public func nodeRunner(_ runner: NodeRunner, didProduceStderr data: Data) {
        let text = String(data: data, encoding: .utf8) ?? "<non-utf8 stderr>"
        let trimmed = text.trimmingCharacters(in: .newlines)
        let escaped = jsonString(trimmed)
        let payload = "{\"event\":\"log\",\"data\":{\"level\":\"stderr\",\"line\":\(escaped)}}"
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(payload)
        }
    }

    // MARK: - Handlers

    private func handleStart(result: @escaping FlutterResult) {
        if started {
            result(FlutterError(code: "ALREADY_STARTED",
                                message: "node bridge already started",
                                details: nil))
            return
        }
        started = true

        // Install ourselves as the stdout/stderr delegate BEFORE node starts.
        NodeRunner.setDelegate(self)

        ioQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                // 1. Copy assets/ncm_bridge → Documents/ncm_bridge.
                guard let dest = self.copyBridgeToDocuments() else {
                    self.failStart(result: result,
                                   code: "COPY_FAILED",
                                   message: "could not prepare bridge dir")
                    return
                }

                // 2. Run node_start on a dedicated NSThread with 2 MB stack.
                //    node_start blocks until node exits.
                let bridgeJs = (dest as NSString).appendingPathComponent("bridge.js")
                let args = ["node", bridgeJs]
                let thread = Thread {
                    NodeRunner.startEngine(withArguments: args)
                }
                thread.stackSize = 2 * 1024 * 1024
                thread.start()

                // 3. Confirm we launched. Dart's MobileNcmBridge waits for
                //    {"event":"ready"} on the event channel before its
                //    start() future resolves.
                DispatchQueue.main.async {
                    result(["ready": true])
                }
            }
        }
    }

    private func failStart(result: @escaping FlutterResult, code: String, message: String) {
        started = false
        DispatchQueue.main.async {
            result(FlutterError(code: code, message: message, details: nil))
        }
    }

    private func handleCall(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let id = args["id"] as? Int,
              let method = args["method"] as? String else {
            result(FlutterError(code: "BAD_ARGS",
                                message: "id and method required",
                                details: nil))
            return
        }
        let params = args["params"] as? [String: Any] ?? [:]
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            let line = "{\"id\":\(id),\"method\":\(self.jsonString(method)),\"params\":\(self.jsonEncode(params))}\n"
            NodeRunner.writeToStdin(line)
            DispatchQueue.main.async { result(nil) }
        }
    }

    private func handleShutdown(result: @escaping FlutterResult) {
        // Embedded node has no clean shutdown. Treat as advisory.
        started = false
        result(nil)
    }

    // MARK: - Asset copy

    private func copyBridgeToDocuments() -> String? {
        // Flutter writes asset bundle entries (declared via the package's
        // `flutter.assets:` pubspec entry) into Frameworks/App.framework/
        // flutter_assets/. We copy the bridge tree out to Documents so
        // node can require it (the bundle is read-only).
        guard let bundleRoot = Bundle.main.path(
            forResource: "Frameworks/App.framework/flutter_assets/bridge",
            ofType: nil
        ) ?? Bundle.main.path(
            forResource: "flutter_assets/bridge",
            ofType: nil
        ) else {
            NSLog("[NcmNodeBridge] flutter_assets/bridge not found in bundle")
            return nil
        }
        guard let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first else {
            return nil
        }
        let dest = (docs as NSString).appendingPathComponent("ncm_bridge")
        let fm = FileManager.default

        // Recursive delete + copy so updates take effect.
        try? fm.removeItem(atPath: dest)
        do {
            try fm.copyItem(atPath: bundleRoot, toPath: dest)
        } catch {
            NSLog("[NcmNodeBridge] copy failed: \(error)")
            return nil
        }
        return dest
    }

    // MARK: - JSON helpers (hand-rolled to avoid Foundation overhead)

    private func jsonString(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if c.value < 0x20 {
                    out += String(format: "\\u%04x", c.value)
                } else {
                    out += String(c)
                }
            }
        }
        out += "\""
        return out
    }

    private func jsonEncode(_ v: Any?) -> String {
        switch v {
        case nil: return "null"
        case let b as Bool: return b ? "true" : "false"
        case let n as NSNumber: return n.stringValue
        case let s as String: return jsonString(s)
        case let m as [String: Any]:
            var parts: [String] = []
            for (k, vv) in m {
                parts.append("\(jsonString(k)):\(jsonEncode(vv))")
            }
            return "{" + parts.joined(separator: ",") + "}"
        case let arr as [Any?]:
            return "[" + arr.map { jsonEncode($0) }.joined(separator: ",") + "]"
        default:
            return jsonString("\(v)")
        }
    }
}