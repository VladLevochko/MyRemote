import AppKit
import Foundation
import MyRemoteCore

public enum AgentMain {
    /// sysexits.h
    private static let exitUsage: Int32 = 64
    private static let exitSoftware: Int32 = 70

    private static var signalSources: [DispatchSourceSignal] = []

    /// Entry point of the executable.
    public static func main(arguments: [String] = Array(CommandLine.arguments.dropFirst())) -> Never {
        // A consumer that stops reading stdout must not kill the agent.
        signal(SIGPIPE, SIG_IGN)

        let options: AgentOptions
        do {
            switch try CLI.parse(arguments) {
            case .help:
                print(CLI.usage)
                exit(0)
            case let .run(parsed):
                options = parsed
            }
        } catch {
            FileHandle.standardError.write(Data("MyRemoteAgent: \(error)\n\n\(CLI.usage)\n".utf8))
            exit(exitUsage)
        }

        if options.headless {
            runHeadless(options)
        } else {
            runMenuBar(options)
        }
    }

    // MARK: Headless (PROTOCOL.md section 6)

    private static func runHeadless(_ options: AgentOptions) -> Never {
        let controller: AgentController
        do {
            controller = try AgentController(options: options)
            try controller.start()
            // The one line integration tests wait for; flushed by LineOutput.
            LineOutput.standardOutput.writeLine("PAIRING " + (try controller.pairingURI()))
        } catch {
            Log.error("cannot start: \(error)")
            exit(exitSoftware)
        }
        Log.info(
            "listening on port \(controller.port), agent id \(controller.agent.id)"
                + (options.dryRun ? ", dry run" : ""))

        controller.startTracking()
        installTerminationHandlers {
            controller.stop()
            exit(0)
        }

        // A plain run loop: the front-app tracker needs the main run loop, and a
        // headless agent must not require a window server connection.
        let keepAlive = Timer(timeInterval: 3600, repeats: true) { _ in }
        RunLoop.main.add(keepAlive, forMode: .common)
        while true {
            RunLoop.main.run(mode: .default, before: .distantFuture)
        }
    }

    private static func installTerminationHandlers(_ handler: @escaping () -> Void) {
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler(handler: handler)
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Menu bar

    private static func runMenuBar(_ options: AgentOptions) -> Never {
        let application = NSApplication.shared
        let delegate = MenuBarAppDelegate(options: options)
        application.delegate = delegate
        // Accessory: no Dock icon, no main menu (LSUIElement does the same for the bundle).
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            application.run()
        }
        exit(0)
    }
}
