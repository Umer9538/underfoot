// driftwatch — Apple Foundation Models capture harness.
//
// Runs a driftwatch prompt suite against the OS-bundled system language model
// and writes a versioned capture JSON. Captures are the raw material of the
// drift time series: once this OS build is superseded, this data can never be
// re-measured, so the harness records everything needed to trust a capture
// years later (OS build, hardware, options, suite hash, per-run outcomes).
//
// Usage:
//   swift harness/apple/afm_capture.swift <suite.json> <output-dir>
//
// Determinism policy: greedy sampling, fresh session per run, sequential
// execution, one unrecorded warmup generation. Durations are informational
// only (thermal state is recorded, not controlled).

import CryptoKit
import Foundation
import FoundationModels

// MARK: - Suite model

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

// MARK: - Capture model

struct Capture: Codable {
    let formatVersion: Int
    let tool: String
    let suite: String
    let suiteVersion: Int
    let suiteSha256: String
    let platform: Platform
    let model: ModelMeta
    let options: Options
    let capturedAt: String
    let results: [PromptResult]
}

struct Platform: Codable {
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

struct Options: Codable {
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
    let status: String // ok | refusal | unsupported-language | context-exceeded | error
    let output: String?
    let errorDescription: String?
    let durationMs: Int
}

// MARK: - Helpers

func sysctlString(_ name: String) -> String {
    var size = 0
    sysctlbyname(name, nil, &size, nil, 0)
    guard size > 0 else { return "unknown" }
    var buffer = [CChar](repeating: 0, count: size)
    sysctlbyname(name, &buffer, &size, nil, 0)
    return String(cString: buffer)
}

func thermalStateName(_ s: ProcessInfo.ThermalState) -> String {
    switch s {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
}

func classify(_ error: Error) -> (status: String, description: String) {
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

// MARK: - Main

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: swift afm_capture.swift <suite.json> <output-dir>\n".utf8))
    exit(64)
}
let suitePath = arguments[1]
let outputDir = arguments[2]

guard let suiteData = FileManager.default.contents(atPath: suitePath) else {
    FileHandle.standardError.write(Data("cannot read suite: \(suitePath)\n".utf8))
    exit(66)
}
let suite: Suite
do {
    suite = try JSONDecoder().decode(Suite.self, from: suiteData)
} catch {
    FileHandle.standardError.write(Data("invalid suite JSON: \(error)\n".utf8))
    exit(65)
}
let suiteSha = SHA256.hash(data: suiteData).map { String(format: "%02x", $0) }.joined()

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

guard #available(macOS 26.0, *) else {
    log("FoundationModels requires macOS 26+")
    exit(69)
}

let systemModel = SystemLanguageModel.default
guard case .available = systemModel.availability else {
    log("system model unavailable: \(systemModel.availability) — enable Apple Intelligence and retry")
    exit(69)
}

let osVersion = ProcessInfo.processInfo.operatingSystemVersion
let osVersionString = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
let osBuild = sysctlString("kern.osversion")
let frameworkBuild = Bundle(identifier: "com.apple.FoundationModels")?
    .infoDictionary?["CFBundleVersion"] as? String

let platform = Platform(
    os: "macOS",
    osVersion: osVersionString,
    osBuild: osBuild,
    hardwareModel: sysctlString("hw.model"),
    chip: sysctlString("machdep.cpu.brand_string"),
    locale: Locale.current.identifier,
    lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
    thermalStateAtStart: thermalStateName(ProcessInfo.processInfo.thermalState)
)

log("driftwatch capture: \(suite.suite) v\(suite.version) on \(platform.os) \(osVersionString) (\(osBuild))")
log("prompts: \(suite.prompts.count) x \(suite.runsPerPrompt) runs, greedy sampling, fresh session per run")

let semaphore = DispatchSemaphore(value: 0)
var results: [PromptResult] = []
var exitCode: Int32 = 0

Task {
    let options = GenerationOptions(sampling: .greedy)

    // Unrecorded warmup so the first recorded run doesn't pay model-load cost.
    do {
        _ = try await LanguageModelSession().respond(to: "Say hello.", options: options)
        log("warmup done")
    } catch {
        log("warmup failed (continuing): \(error)")
    }

    for (index, prompt) in suite.prompts.enumerated() {
        var runs: [RunResult] = []
        for runIndex in 0..<suite.runsPerPrompt {
            let session = LanguageModelSession()
            let started = DispatchTime.now()
            do {
                let response = try await session.respond(to: prompt.prompt, options: options)
                let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
                runs.append(RunResult(status: "ok", output: response.content, errorDescription: nil, durationMs: elapsed))
            } catch {
                let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
                let (status, description) = classify(error)
                runs.append(RunResult(status: status, output: nil, errorDescription: description, durationMs: elapsed))
            }
            log("[\(index + 1)/\(suite.prompts.count)] \(prompt.id) run \(runIndex + 1)/\(suite.runsPerPrompt): \(runs.last!.status) (\(runs.last!.durationMs)ms)")
        }
        results.append(PromptResult(promptId: prompt.id, category: prompt.category, runs: runs))
    }

    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.timeZone = TimeZone(identifier: "UTC")
    let capture = Capture(
        formatVersion: 1,
        tool: "driftwatch",
        suite: suite.suite,
        suiteVersion: suite.version,
        suiteSha256: suiteSha,
        platform: platform,
        model: ModelMeta(family: "apple-foundation-models", availability: "available", frameworkBuild: frameworkBuild),
        options: Options(sampling: "greedy", runsPerPrompt: suite.runsPerPrompt, freshSessionPerRun: true, warmupBeforeSuite: true),
        capturedAt: isoFormatter.string(from: Date()),
        results: results
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    do {
        let data = try encoder.encode(capture)
        let dir = "\(outputDir)/apple/\(osBuild)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = "\(dir)/\(suite.suite)-v\(suite.version).capture.json"
        try (String(data: data, encoding: .utf8)! + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        log("capture written: \(path)")
    } catch {
        log("failed to write capture: \(error)")
        exitCode = 74
    }
    semaphore.signal()
}

semaphore.wait()
exit(exitCode)
