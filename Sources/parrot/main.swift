import Foundation

/// Single entry point. A double-clicked `.app` (or a bare `parrot` with no
/// arguments) launches the GUI. Any recognized subcommand or help flag routes
/// to the ArgumentParser CLI instead, so terminal users keep
/// `parrot doctor/setup/models/install/run`.
let cliCommands: Set<String> = ["run", "setup", "doctor", "models", "install", "help"]
let args = Array(CommandLine.arguments.dropFirst())
let wantsCLI = args.contains { cliCommands.contains($0) }
    || args.contains("-h")
    || args.contains("--help")
    || args.contains("--version")

if wantsCLI {
    Parrot.main()
} else {
    launchGUI()
}
