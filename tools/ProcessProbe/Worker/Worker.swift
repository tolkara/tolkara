// A ProcessProbe worker: an app extension the probe app starts in its own process,
// answering one XPC request with its own report.
import ExtensionFoundation
import Foundation

final class Service: NSObject, ProbeService {
    func report(_ reply: @escaping (String) -> Void) {
        reply(ProbeReport.make(role: "worker"))
    }
}

@main
struct Worker: AppExtension {
    var configuration: ConnectionHandler {
        ConnectionHandler(onConnection: { connection in
            connection.exportedInterface = NSXPCInterface(with: ProbeService.self)
            connection.exportedObject = Service()
            connection.resume()
            return true
        })
    }
}
