import Foundation

@main struct RouteRollbackTest {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw LineError("Missing isolated test directory") }
        let service=LineService(base:URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true))
        let before=service.snapshot()
        guard before.online && before.adaptive && before.relayOptions.contains("Unreachable-Relay") else { throw LineError("Isolated test core is not ready") }
        do {
            try service.selectRoutes(relay:"Unreachable-Relay",destination:before.destinationChoice)
            throw LineError("An unreachable relay was accepted")
        } catch let failure as LineError {
            if failure.localizedDescription == "An unreachable relay was accepted" { throw failure }
        }
        let after=service.snapshot()
        guard after.relayChoice == before.relayChoice && after.destinationChoice == before.destinationChoice && service.lineCheck().state == "good" else { throw LineError("Previous working route was not restored") }
        print("PASS unreachable relay rejected and the working route restored")
    }
}
