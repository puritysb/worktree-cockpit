import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct HelperRequest: Decodable {
    let id: Int
    let type: String?
    let prompt: String?
    let instructions: String?
    let temperature: Double?
}

@main
struct AgentDeckFMHelper {
    static func main() async {
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                await handle(line)
            }
        } catch {
            write(["id": -1, "error": "stdin_error", "reason": String(describing: error)])
        }
    }

    private static func handle(_ line: String) async {
        guard let data = line.data(using: .utf8),
              let request = try? JSONDecoder().decode(HelperRequest.self, from: data) else {
            write(["id": -1, "error": "bad_request", "reason": "invalid JSON line"])
            return
        }

        if request.type == "health" {
            write(healthResponse(id: request.id))
            return
        }

        guard let prompt = request.prompt, !prompt.isEmpty else {
            write(["id": request.id, "error": "bad_request", "reason": "missing prompt"])
            return
        }

#if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else {
                write([
                    "id": request.id,
                    "error": "unavailable",
                    "reason": unavailableReason(),
                ])
                return
            }

            do {
                let session = LanguageModelSession(
                    instructions: request.instructions ?? "You are an exacting code evaluator. Reply with strict JSON only."
                )
                let options = GenerationOptions(temperature: request.temperature ?? 0)
                let response = try await session.respond(to: prompt, options: options)
                write(["id": request.id, "text": response.content])
            } catch {
                write(["id": request.id, "error": "session_error", "reason": String(describing: error)])
            }
        } else {
            write(["id": request.id, "error": "unavailable", "reason": "macOS 26 or later required"])
        }
#else
        write(["id": request.id, "error": "unavailable", "reason": "FoundationModels framework not present"])
#endif
    }

    private static func healthResponse(id: Int) -> [String: Any] {
#if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability {
                return ["id": id, "status": "ready"]
            }
            return ["id": id, "status": "unavailable", "reason": unavailableReason()]
        }
        return ["id": id, "status": "unavailable", "reason": "macOS 26 or later required"]
#else
        return ["id": id, "status": "unavailable", "reason": "FoundationModels framework not present"]
#endif
    }

    private static func unavailableReason() -> String {
#if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return "available"
            case .unavailable(let reason):
                return "unavailable: \(reason)"
            @unknown default:
                return "unavailable: unknown state"
            }
        }
        return "macOS 26 or later required"
#else
        return "FoundationModels framework not present"
#endif
    }

    private static func write(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }
}
