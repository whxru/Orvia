import Foundation
import Combine

struct SystemShortcut: Codable, Equatable, Identifiable {
    let identifier: String
    let name: String
    var id: String { identifier }
    static let prefix = "mac-shortcut:"
    init?(identifier: String, name: String) {
        guard let uuid = UUID(uuidString: identifier), !name.isEmpty else { return nil }
        self.identifier = uuid.uuidString; self.name = name
    }
    var storedValue: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Self.prefix + (try! encoder.encode(self)).base64EncodedString()
    }
    static func decode(_ value: String) -> SystemShortcut? {
        guard value.hasPrefix(prefix), let data = Data(base64Encoded: String(value.dropFirst(prefix.count))),
              let saved = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        return Self(identifier: saved.identifier, name: saved.name)
    }
    static func parseList(_ output: String) -> [SystemShortcut] {
        // The system CLI appends the identifier in parentheses. Names themselves
        // may include parentheses, so match only the trailing UUID.
        let pattern = #"^(.*) \(([0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12})\)$"#
        let regex = try! NSRegularExpression(pattern: pattern)
        var seen = Set<String>()
        return output.components(separatedBy: .newlines).compactMap { line in
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let nameRange = Range(match.range(at: 1), in: line), let idRange = Range(match.range(at: 2), in: line),
                  let shortcut = Self(identifier: String(line[idRange]), name: String(line[nameRange])),
                  seen.insert(shortcut.id).inserted else { return nil }
            return shortcut
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var runArguments: [String] { ["run", identifier] }
}

enum ShortcutsError: LocalizedError {
    case unavailable, listFailed, runFailed
    var errorDescription: String? {
        switch self {
        case .unavailable: return "无法打开系统快捷指令服务。"
        case .listFailed: return "无法读取快捷指令。请打开“快捷指令”App 后刷新。"
        case .runFailed: return "快捷指令未能完成。请在“快捷指令”App 中确认它仍存在，并完成所需的权限或输入提示。"
        }
    }
}

final class ShortcutsClient {
    // Injectable only for isolated integration checks; production uses the
    // system executable directly with an argument array, never a shell.
    var execute: ([String], @escaping (Result<String, ShortcutsError>) -> Void) -> Void = { arguments, completion in
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = arguments.first == "list" ? output : FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                if arguments.first == "list" { DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout) }
                let data = arguments.first == "list" ? output.fileHandleForReading.readDataToEndOfFile() : Data()
                process.waitUntilExit(); timeout.cancel()
                completion(process.terminationStatus == 0 ? .success(String(data: data, encoding: .utf8) ?? "") : .failure(arguments.first == "list" ? .listFailed : .runFailed))
            } catch { completion(.failure(.unavailable)) }
        }
    }
    func list(_ completion: @escaping (Result<[SystemShortcut], ShortcutsError>) -> Void) {
        execute(["list", "--show-identifiers"]) { result in
            switch result {
            case .success(let output):
                let choices = SystemShortcut.parseList(output)
                if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && choices.isEmpty { completion(.failure(.listFailed)) }
                else { completion(.success(choices)) }
            case .failure(let error): completion(.failure(error))
            }
        }
    }
    func run(_ shortcut: SystemShortcut, completion: @escaping (Result<String, ShortcutsError>) -> Void) {
        execute(shortcut.runArguments, completion)
    }
}

final class ShortcutCatalog: ObservableObject {
    @Published private(set) var shortcuts: [SystemShortcut] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    let client = ShortcutsClient()
    func refresh() {
        guard !loading else { return }
        loading = true; error = nil
        client.list { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                switch result {
                case .success(let shortcuts): self.shortcuts = shortcuts
                case .failure(let error): self.shortcuts = []; self.error = error.localizedDescription
                }
            }
        }
    }
}
