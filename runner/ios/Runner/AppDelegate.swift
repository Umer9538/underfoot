import CryptoKit
import Flutter
import FoundationModels
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let progressHandler = ProgressStreamHandler()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let messenger = engineBridge.applicationRegistrar.messenger()
    FlutterEventChannel(name: "underfoot/progress", binaryMessenger: messenger)
      .setStreamHandler(progressHandler)

    let captureChannel = FlutterMethodChannel(
      name: "underfoot/capture", binaryMessenger: messenger)
    captureChannel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "run", let suiteText = call.arguments as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard #available(iOS 26.0, *) else {
        result(FlutterError(code: "os", message: "FoundationModels requires iOS 26+", details: nil))
        return
      }
      // The suite takes minutes; keep the screen awake so iOS doesn't
      // suspend the app mid-capture.
      UIApplication.shared.isIdleTimerDisabled = true
      Task {
        let engine = CaptureEngine { line in
          DispatchQueue.main.async { self?.progressHandler.send(line) }
        }
        do {
          let json = try await engine.run(suiteText: suiteText)
          DispatchQueue.main.async { result(json) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "capture", message: "\(error)", details: nil))
          }
        }
      }
    }
  }
}

class ProgressStreamHandler: NSObject, FlutterStreamHandler {
  private var sink: FlutterEventSink?
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    sink = events
    return nil
  }
  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }
  func send(_ line: String) { sink?(line) }
}

// MARK: - Capture engine (iOS port of harness/apple/afm_capture.swift)

struct Suite: Codable {
  let formatVersion: Int
  let suite: String
  let version: Int
  let runsPerPrompt: Int
  let prompts: [SuitePrompt]
}

struct SuitePrompt: Codable {
  let id: String
  let category: String
  let prompt: String
}

struct CaptureDocument: Codable {
  let formatVersion: Int
  let tool: String
  let suite: String
  let suiteVersion: Int
  let suiteSha256: String
  let platform: PlatformMeta
  let model: ModelMeta
  let options: OptionsMeta
  let capturedAt: String
  let results: [PromptResult]
}

struct PlatformMeta: Codable {
  let os: String
  let osVersion: String
  let osBuild: String
  let hardwareModel: String
  let chip: String
  let locale: String
  let lowPowerMode: Bool
  let thermalStateAtStart: String
}

struct ModelMeta: Codable {
  let family: String
  let availability: String
  let frameworkBuild: String?
}

struct OptionsMeta: Codable {
  let sampling: String
  let runsPerPrompt: Int
  let freshSessionPerRun: Bool
  let warmupBeforeSuite: Bool
}

struct PromptResult: Codable {
  let promptId: String
  let category: String
  let runs: [RunResult]
}

struct RunResult: Codable {
  let status: String
  let output: String?
  let errorDescription: String?
  let durationMs: Int
}

enum CaptureError: Error {
  case suiteInvalid(String)
  case modelUnavailable(String)
}

@available(iOS 26.0, *)
final class CaptureEngine {
  private let progress: (String) -> Void

  init(progress: @escaping (String) -> Void) {
    self.progress = progress
  }

  private func sysctlString(_ name: String) -> String {
    var size = 0
    sysctlbyname(name, nil, &size, nil, 0)
    guard size > 0 else { return "unknown" }
    var buffer = [CChar](repeating: 0, count: size)
    sysctlbyname(name, &buffer, &size, nil, 0)
    return String(cString: buffer)
  }

  private func hardwareModel() -> String {
    var systemInfo = utsname()
    uname(&systemInfo)
    return withUnsafePointer(to: &systemInfo.machine) {
      $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
    }
  }

  private func thermalStateName(_ s: ProcessInfo.ThermalState) -> String {
    switch s {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
  }

  private func classify(_ error: Error) -> (status: String, description: String) {
    if let generationError = error as? LanguageModelSession.GenerationError {
      switch generationError {
      case .guardrailViolation:
        return ("refusal", String(describing: generationError))
      case .unsupportedLanguageOrLocale:
        return ("unsupported-language", String(describing: generationError))
      case .exceededContextWindowSize:
        return ("context-exceeded", String(describing: generationError))
      default:
        return ("error", String(describing: generationError))
      }
    }
    return ("error", String(describing: error))
  }

  func run(suiteText: String) async throws -> String {
    let suiteData = Data(suiteText.utf8)
    let suite: Suite
    do {
      suite = try JSONDecoder().decode(Suite.self, from: suiteData)
    } catch {
      throw CaptureError.suiteInvalid("\(error)")
    }
    let suiteSha = SHA256.hash(data: suiteData).map { String(format: "%02x", $0) }.joined()

    let systemModel = SystemLanguageModel.default
    guard case .available = systemModel.availability else {
      throw CaptureError.modelUnavailable("\(systemModel.availability)")
    }

    let osBuild = sysctlString("kern.osversion")
    progress(
      "underfoot capture: \(suite.suite) v\(suite.version) on iOS "
        + "\(UIDevice.current.systemVersion) (\(osBuild))")

    // A simulator capture must be labeled as one: the model executes via the
    // host Mac's Apple Intelligence, not phone silicon.
    let simulatorModel = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
    let platform = PlatformMeta(
      os: simulatorModel == nil ? "iOS" : "iOS-simulator",
      osVersion: UIDevice.current.systemVersion,
      osBuild: osBuild,
      hardwareModel: simulatorModel ?? hardwareModel(),
      chip: sysctlString("hw.machine"),
      locale: Locale.current.identifier,
      lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
      thermalStateAtStart: thermalStateName(ProcessInfo.processInfo.thermalState)
    )
    let frameworkBuild =
      Bundle(identifier: "com.apple.FoundationModels")?
      .infoDictionary?["CFBundleVersion"] as? String

    let options = GenerationOptions(sampling: .greedy)

    do {
      _ = try await LanguageModelSession().respond(to: "Say hello.", options: options)
      progress("warmup done")
    } catch {
      progress("warmup failed (continuing): \(error)")
    }

    var results: [PromptResult] = []
    for (index, prompt) in suite.prompts.enumerated() {
      var runs: [RunResult] = []
      for runIndex in 0..<suite.runsPerPrompt {
        let session = LanguageModelSession()
        let started = DispatchTime.now()
        do {
          let response = try await session.respond(to: prompt.prompt, options: options)
          let elapsed = Int(
            (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
          runs.append(
            RunResult(
              status: "ok", output: response.content, errorDescription: nil, durationMs: elapsed))
        } catch {
          let elapsed = Int(
            (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
          let (status, description) = classify(error)
          runs.append(
            RunResult(
              status: status, output: nil, errorDescription: description, durationMs: elapsed))
        }
        progress(
          "[\(index + 1)/\(suite.prompts.count)] \(prompt.id) "
            + "run \(runIndex + 1)/\(suite.runsPerPrompt): \(runs.last!.status) "
            + "(\(runs.last!.durationMs)ms)")
      }
      results.append(PromptResult(promptId: prompt.id, category: prompt.category, runs: runs))
    }

    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.timeZone = TimeZone(identifier: "UTC")
    let capture = CaptureDocument(
      formatVersion: 1,
      tool: "underfoot",
      suite: suite.suite,
      suiteVersion: suite.version,
      suiteSha256: suiteSha,
      platform: platform,
      model: ModelMeta(
        family: "apple-foundation-models", availability: "available",
        frameworkBuild: frameworkBuild),
      options: OptionsMeta(
        sampling: "greedy", runsPerPrompt: suite.runsPerPrompt, freshSessionPerRun: true,
        warmupBeforeSuite: true),
      capturedAt: isoFormatter.string(from: Date()),
      results: results
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(capture)
    let json = String(data: data, encoding: .utf8)! + "\n"

    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let fileURL = documents.appendingPathComponent(
      "\(suite.suite)-v\(suite.version)-\(osBuild).capture.json")
    try json.write(to: fileURL, atomically: true, encoding: .utf8)
    progress("capture written: \(fileURL.lastPathComponent)")

    return json
  }
}
