import Foundation

@main struct SourceFailureTest {
    static func main() throws {
        let service=LineService()
        let files=[service.file, service.base.appendingPathComponent("providers/relay-lxy.yaml"),
                   service.base.appendingPathComponent("providers/wired-relay.yaml")]
        let old=try files.map{try Data(contentsOf:$0)}
        let before=service.snapshot()
        guard before.online && before.adaptive else { throw LineError("Active adaptive service is required for this test") }
        do {
            try service.updateSubscriptions(relay:"https://example.invalid/sub",destination:"")
            throw LineError("An unreachable subscription was accepted")
        } catch let failure as LineError {
            if failure.localizedDescription == "An unreachable subscription was accepted" { throw failure }
        }
        let after=service.snapshot()
        guard try files.map({try Data(contentsOf:$0)}) == old,
              after.relayChoice == before.relayChoice,
              after.destinationChoice == before.destinationChoice,
              after.tun == before.tun else { throw LineError("Failed subscription changed the active route") }
        print("PASS unreachable HTTPS subscription leaves configuration, cached nodes, and selections unchanged")
    }
}
