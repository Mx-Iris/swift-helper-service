import Foundation
import HelperService
import MachInjector

public actor InjectionService: HelperService {
    public init() {}
    public func setupHandler(_ handler: some HelperHandler) async {
        handler.setMessageHandler { (request: InjectApplicationRequest) -> InjectApplicationRequest.Response in
            try MachInjector.inject(pid: request.pid, dylibPath: request.dylibURL.path)
            return .empty
        }
    }

    public func run() async throws {}
}
