import Foundation
import Testing
import BuddyCore

struct ApprovalPolicyTests {
    private static let runFolder = "/Users/owner/Library/Application Support/Buddy/Runs/2026-11-01-070412-1"

    private static let existing: Set<String> = [
        "/Users/owner/Desktop",
        "/Users/owner/Desktop/notes.txt",
        "/Users/owner/Documents/journal.md"
    ]

    private static func engineWithRun() -> BuddyEngine {
        var engine = BuddyEngine(providerConnected: true, home: "/Users/owner", fileExists: { existing.contains($0) })
        let events: [BuddyEngine.Event] = [
            .pushToTalkPressed,
            .pushToTalkReleased,
            .transcriptFinished("agent, make a folder on my Desktop"),
            .screensCaptured([]),
            .run(RunID(1), .started(folder: runFolder))
        ]
        for event in events { _ = engine.handle(event) }
        return engine
    }

    private static func answer(_ request: ApprovalRequest) -> [BuddyEngine.Effect] {
        var engine = engineWithRun()
        return engine.handle(.run(RunID(1), .approvalRequested(id: "r1", request)))
    }

    private static let allowed: BuddyEngine.Effect = .answerApproval(RunID(1), id: "r1", .allow)

    private static func denied(_ reason: String) -> BuddyEngine.Effect {
        .answerApproval(RunID(1), id: "r1", .deny(reason))
    }

    /// What the run waits for the owner to answer after the request, with the cue played once.
    private static func asks(_ request: ApprovalRequest) -> [OwnerAsk]? {
        var engine = engineWithRun()
        guard engine.handle(.run(RunID(1), .approvalRequested(id: "r1", request))) == [.playCue(.needsOwner)],
              engine.state.runs.first?.status == .needsOwner
        else { return nil }
        return engine.state.runs.first?.asks
    }

    private static let openAppsScript = #"tell application "System Events" to get name of every application process whose background only is false"#

    private static let allowedCommands = [
        "ls -la ~/Desktop",
        "osascript -e '\(openAppsScript)'",
        #"osascript -e "set AppleScript's text item delimiters to linefeed" -e 'return {"one", "two"} as text'"#,
        #"osascript -e 'repeat with i from 1 to 3' -e 'set total to i' -e 'end repeat' -e 'return total -- the last one'"#,
        #"osascript -s s -e 'tell application "Finder" to get name of every window (* front first *)'"#,
        #"mkdir -p ~/Desktop/Open\ Apps"#,
        #"mkdir -p "$HOME/Desktop/Open Apps""#,
        #"mkdir -pv "${HOME}/Desktop/Reports" output"#,
        "mkdir -p ~/Desktop/OpenApps && osascript -e '\(openAppsScript)' > ~/Desktop/OpenApps/apps.txt",
        "rm -rf output/tmp",
        #"rm -f "\#(runFolder)/scratch.txt""#,
        "touch -c out.txt && rmdir empty",
        "find ~/Documents -maxdepth 2 -name '*.pdf'",
        "ls ~/Desktop/*.png | wc -l",
        "grep -ri invoice ~/Documents 2>/dev/null | head -5",
        "ps aux | grep -v grep | sort -k 11 -t ' ' | uniq -c",
        "sort -to names.txt",
        "defaults read com.apple.dock persistent-apps",
        "plutil -p ~/Library/Preferences/com.apple.finder.plist",
        "sysctl -n hw.memsize",
        "date -v-1d +%Y-%m-%d",
        "echo done > /dev/null; echo hi >> log.txt",
        #"/usr/bin/printf '%s\n' a b > ~/Desktop/new-list.txt"#,
        "cat < /etc/hosts",
        "ls # list the run folder; rm -rf ~",
        "system_profiler SPSoftwareDataType 2>&1 | head",
        "/bin/ls -l /usr/bin/osascript",
        "[ -d output ] && ls output || mkdir output",
        "mkdir output\nls output",
        "hostname -s && uname -a && sw_vers",
        "mdls -name kMDItemContentType ~/Desktop/notes.txt"
    ]

    /// Requests that send, post, buy or delete, as a run would write them.
    private static let irreversibleCommands: [(String, String)] = [
        (
            #"osascript -e 'tell application "Mail" to send (make new outgoing message with properties {subject:"Lunch", content:"Noon?", visible:false})'"#,
            "AppleScript `send` isn't on Buddy's read-only list."
        ),
        (
            """
            osascript -e 'tell application "Mail"
            set m to make new outgoing message with properties {subject:"Lunch on Friday?", content:"Would noon work?", visible:false}
            tell m to make new to recipient at end of to recipients with properties {address:"sam@example.com"}
            send m
            end tell'
            """,
            "AppleScript `send` isn't on Buddy's read-only list."
        ),
        ("curl -X POST https://api.example.com/posts -d 'text=Hello'", "`curl` isn't on Buddy's list of allowed commands."),
        ("open 'https://shop.example.com/checkout?item=42'", "`open` isn't on Buddy's list of allowed commands."),
        ("rm ~/Desktop/old.txt", "`rm` may only remove files inside the run folder."),
        (#"osascript -e 'tell application "Finder" to delete file "notes.txt" of desktop'"#, "AppleScript `delete` isn't on Buddy's read-only list.")
    ]

    private static let deniedCommands: [(String, String)] = [
        ("cd ~/Desktop && rm x", "Buddy keeps commands in the run folder; use paths instead of `cd`."),
        ("cd output && rm x", "Buddy keeps commands in the run folder; use paths instead of `cd`."),
        ("cd", "Buddy keeps commands in the run folder; use paths instead of `cd`."),
        ("curl -s https://example.com; cd output", "Buddy keeps commands in the run folder; use paths instead of `cd`."),
        ("printf '%s' x | osascript", "Use `/usr/bin/printf` so the shell cannot change variables.")
    ]

    private static let ownerCommands: [(String, String)] = [
        ("rm -rf ~/Desktop/old", "`rm` may only remove files inside the run folder."),
        (#"rm -rf "\#(runFolder)""#, "`rm` may only remove files inside the run folder."),
        ("rm -rf .", "`rm` may only remove files inside the run folder."),
        ("rm ../x", "`rm` may only remove files inside the run folder."),
        ("rm *.txt", "Buddy can't check a pattern like `*.txt`."),
        ("rm -P x", "`rm -P` isn't on Buddy's list of allowed commands."),
        ("touch ~/Desktop/new.txt", "`touch` may only change files inside the run folder."),
        ("/opt/homebrew/bin/rg TODO", "`/opt/homebrew/bin/rg` isn't on Buddy's list of allowed commands."),
        ("curl -s https://example.com", "`curl` isn't on Buddy's list of allowed commands."),
        ("mv ~/Desktop/notes.txt output", "`mv` isn't on Buddy's list of allowed commands."),
        ("echo $(whoami)", "Buddy can't check commands that use `$(...)`."),
        ("echo `whoami`", "Buddy can't check commands that use backticks."),
        ("echo $PATH", "Buddy can't check commands that use `$` other than in `$HOME`."),
        (#"echo "$HOME_DIR""#, "Buddy can't check commands that use `$` other than in `$HOME`."),
        ("cat <<EOF > notes.txt\nhi\nEOF", "Buddy can't check commands that use here-documents."),
        ("cat <<< hi", "Buddy can't check commands that use here-strings."),
        ("cat < <(ls)", "Buddy can't check commands that use process substitution."),
        ("sleep 100 &", "Buddy can't check commands that use `&` to run in the background."),
        ("ls |& cat", "Buddy can't check commands that use `|&`."),
        ("FOO=1 ls", "Buddy can't check commands that use variable assignments."),
        ("ls | (cd / && rm -rf x)", "Buddy can't check commands that use parentheses."),
        ("{ rm x; }", "Buddy can't check commands that use `{ }` groups."),
        ("ls ~root", "Buddy can't check commands that use `~` other than for the home folder."),
        ("echo 'unclosed", "Buddy can't check commands that use unclosed quotes."),
        ("ls >", "Buddy can't check commands that use a redirect with no file."),
        ("osascript -e 'return «class utf8»'", "Buddy can't check commands that use `«`."),
        ("echo hi > ~/Desktop/notes.txt", "`/Users/owner/Desktop/notes.txt` already exists, and runs may only add new files outside their folder."),
        ("echo hi >! ~/Desktop/notes.txt", "`/Users/owner/Desktop/notes.txt` already exists, and runs may only add new files outside their folder."),
        ("echo more >> ~/Documents/journal.md", "`>` may only write inside the run folder or add new files to the Desktop."),
        ("echo hi > ~/Library/LaunchAgents/x.plist", "`>` may only write inside the run folder or add new files to the Desktop."),
        ("cat x > ../out.txt", "`>` may only write inside the run folder or add new files to the Desktop."),
        ("ls > *.out", "Buddy can't check a pattern like `*.out`."),
        ("mkdir ~/Library/x", "`mkdir` may only make folders inside the run folder or in the Desktop."),
        ("mkdir -p ~/Desktop/.config", "`mkdir` may only make folders inside the run folder or in the Desktop."),
        ("mkdir -m 777 x", "`mkdir -m` isn't on Buddy's list of allowed commands."),
        ("find . -delete", "`find -delete` isn't on Buddy's list of allowed commands."),
        (#"find ~ -name x -exec rm '{}' \;"#, "`find -exec` isn't on Buddy's list of allowed commands."),
        ("find ~ -print *", "Buddy can't check a pattern like `*`."),
        ("sort -o out in", "`sort -o` isn't on Buddy's list of allowed commands."),
        ("sort -ruo out.txt in.txt", "`sort -o` isn't on Buddy's list of allowed commands."),
        ("sort --outp=out.txt in.txt", "`sort --outp` isn't on Buddy's list of allowed commands."),
        ("uniq in.txt ~/Desktop/notes.txt", "`uniq` may only take one file, since a second one is where it writes."),
        ("uniq ~/Desktop/*.txt", "Buddy can't check a pattern like `/Users/owner/Desktop/*.txt`."),
        ("mdls -plist out.plist ~/Desktop/notes.txt", "`mdls -plist` isn't on Buddy's list of allowed commands."),
        ("date 010112002026", "`date` may only show the date, so each operand must start with `+`."),
        ("hostname buddy", "`hostname` may only show its setting, not change it."),
        ("defaults write com.apple.dock autohide -bool true", "`defaults write` isn't on Buddy's list of allowed commands."),
        ("plutil -convert xml1 ~/Desktop/x.plist", "`plutil -convert` isn't on Buddy's list of allowed commands."),
        ("sysctl -w kern.x=1", "`sysctl -w` isn't on Buddy's list of allowed commands."),
        ("sysctl kern.x=1", "`sysctl` may only read settings, not change them."),
        (#"osascript -e 'do shell script "rm -rf ~"'"#, "AppleScript `do` isn't on Buddy's read-only list."),
        (#"osascript -e 'tell application "Finder" to delete file "notes.txt" of desktop'"#, "AppleScript `delete` isn't on Buddy's read-only list."),
        (#"osascript -e 'tell application "System Events" to keystroke "q"'"#, "AppleScript `keystroke` isn't on Buddy's read-only list."),
        (#"osascript -e 'tell application "Finder" to make new folder at desktop with properties {name:"Open Apps"}'"#, "AppleScript `make` isn't on Buddy's read-only list."),
        ("osascript -e 'set volume output volume 0'", "AppleScript `set` may only change the script's own variables."),
        (#"osascript -e 'tell application "Finder" to set name of file "a" to "b"'"#, "AppleScript `set` isn't allowed inside tell blocks."),
        (#"osascript -e 'tell application "System Events"' -e 'set appNames to name of every process whose background only is false' -e 'end tell'"#, "AppleScript `set` isn't allowed inside tell blocks."),
        (#"osascript -e 'tell application "Finder" to set comment to "changed"'"#, "AppleScript `set` isn't allowed inside tell blocks."),
        ("osascript -e 'set beep to 1' -e 'beep'", "AppleScript `set` may only change the script's own variables."),
        (#"osascript -e 'set reveal to 1' -e 'tell application "Finder" to reveal reveal'"#, "Buddy can't check AppleScript that uses the variable `reveal` inside a tell block."),
        ("osascript -e 'tell application \"Finder\"' -e 'end tell' -e 'end tell'", "Buddy can't check this AppleScript's tell blocks."),
        ("osascript -e 'return |do shell script|'", "AppleScript `|` isn't on Buddy's read-only list."),
        ("osascript -e do*", "Buddy can't check a pattern like `do*`."),
        (#"osascript -l JavaScript -e 'Application("Finder").delete()'"#, "`osascript` may only run AppleScript given with -e."),
        ("osascript script.scpt", "`osascript` may only run AppleScript given with -e."),
        ("echo 'do shell script \"rm -rf ~\"' | osascript", "`osascript` may only run AppleScript given with -e."),
        ("ls; curl -s https://example.com && open https://example.com", "`curl` isn't on Buddy's list of allowed commands.")
    ]

    private static let allowedFileRequests: [ApprovalRequest] = [
        .buddyTool("mcp__buddy__update_run_note"),
        .read(path: "/etc/hosts"),
        .read(path: "/Users/owner/Library/Preferences/com.apple.dock.plist"),
        .write(path: "\(runFolder)/output/open-apps.txt"),
        .write(path: "notes/plan.md"),
        .write(path: "/Users/owner/Desktop/Open Apps/open-apps.txt"),
        .write(path: "~/Desktop/report.txt"),
        .edit(path: "\(runFolder)/note.md"),
        .edit(path: "output/./open-apps.txt"),
        .delete(path: "\(runFolder)/scratch/draft.txt"),
        .changes([.write(path: "\(runFolder)/output/apps.txt"), .edit(path: "note.md"), .delete(path: "scratch/old.txt")]),
        .changes([.delete(path: "\(runFolder)/output/a.txt"), .write(path: "/Users/owner/Desktop/Apps/a.txt")])
    ]

    private static let ownerFileRequests: [(ApprovalRequest, String, String)] = [
        (.write(path: "/Users/owner/Desktop/notes.txt"), "write /Users/owner/Desktop/notes.txt", "`/Users/owner/Desktop/notes.txt` already exists, and runs may only add new files outside their folder."),
        (.write(path: "/Users/owner/Desktop/../Desktop/notes.txt"), "write /Users/owner/Desktop/../Desktop/notes.txt", "`/Users/owner/Desktop/notes.txt` already exists, and runs may only add new files outside their folder."),
        (.write(path: "/Users/owner/Library/LaunchAgents/com.example.plist"), "write /Users/owner/Library/LaunchAgents/com.example.plist", "Runs may only write inside the run folder or add new files to the Desktop."),
        (.write(path: "/Users/owner/Desktop/.hidden"), "write /Users/owner/Desktop/.hidden", "Runs may only write inside the run folder or add new files to the Desktop."),
        (.write(path: "/Users/owner/.zshrc"), "write /Users/owner/.zshrc", "Runs may only write inside the run folder or add new files to the Desktop."),
        (.write(path: "/Applications/Notes.txt"), "write /Applications/Notes.txt", "Runs may only write inside the run folder or add new files to the Desktop."),
        (.write(path: "../escape.txt"), "write ../escape.txt", "Runs may only write inside the run folder or add new files to the Desktop."),
        (.write(path: runFolder), "write \(runFolder)", "Runs may only write inside the run folder or add new files to the Desktop."),
        (.edit(path: "/Users/owner/Documents/journal.md"), "edit /Users/owner/Documents/journal.md", "Runs may only edit files inside the run folder."),
        (.edit(path: "\(runFolder)/../other-run/note.md"), "edit \(runFolder)/../other-run/note.md", "Runs may only edit files inside the run folder."),
        (.delete(path: "/Users/owner/Desktop/notes.txt"), "delete /Users/owner/Desktop/notes.txt", "Runs may only delete files inside the run folder."),
        (.delete(path: "~/Documents/journal.md"), "delete ~/Documents/journal.md", "Runs may only delete files inside the run folder."),
        (
            .changes([.write(path: "output/apps.txt"), .edit(path: "/Users/owner/Documents/journal.md"), .delete(path: "/Users/owner/Desktop/notes.txt")]),
            "write output/apps.txt, edit /Users/owner/Documents/journal.md, delete /Users/owner/Desktop/notes.txt",
            "Runs may only edit files inside the run folder."
        ),
        (
            .changes([.delete(path: "/Users/owner/Desktop/notes.txt"), .write(path: "output/notes.txt")]),
            "delete /Users/owner/Desktop/notes.txt, write output/notes.txt",
            "Runs may only delete files inside the run folder."
        )
    ]

    @Test(arguments: allowedFileRequests)
    func allowsReadingAnythingAndWritingInsideTheRunFolderOrNewOwnerFiles(request: ApprovalRequest) {
        #expect(Self.answer(request) == [Self.allowed])
    }

    @Test(arguments: ownerFileRequests)
    func asksTheOwnerBeforeReplacingOrWritingElsewhere(request: ApprovalRequest, action: String, reason: String) {
        #expect(Self.asks(request) == [.approval(id: "r1", action: action, reason: reason)])
    }

    @Test func deniesToolsBuddyDoesNotOffer() {
        #expect(Self.answer(.other(tool: "WebFetch")).last == Self.denied("Buddy doesn't allow the WebFetch tool."))
    }

    @Test func aPatchWithAToolBuddyDoesNotOfferIsDeniedEvenBesideAChangeForTheOwner() {
        #expect(Self.answer(.changes([.edit(path: "/Users/owner/Documents/journal.md"), .other(tool: "apply_patch")])).last
            == Self.denied("Buddy doesn't allow the apply_patch tool."))
    }

    @Test(arguments: allowedCommands)
    func allowsReadOnlyCommandsAndChangesItCanCheck(command: String) {
        #expect(Self.answer(.command(command)) == [Self.allowed])
    }

    @Test(arguments: irreversibleCommands)
    func asksTheOwnerBeforeSendingPostingBuyingOrDeleting(command: String, reason: String) {
        #expect(Self.asks(.command(command)) == [.approval(id: "r1", action: command, reason: reason)])
    }

    @Test(arguments: ownerCommands)
    func asksTheOwnerAboutCommandsOutsideTheAllowedSetNamingTheFirstProblem(command: String, reason: String) {
        #expect(Self.asks(.command(command)) == [.approval(id: "r1", action: command, reason: reason)])
    }

    @Test(arguments: deniedCommands)
    func deniesCommandsThatMustBeWrittenAnotherWayEvenBesideOnesForTheOwner(command: String, reason: String) {
        #expect(Self.answer(.command(command)).last == Self.denied(reason))
    }

    @Test func aDenialSavesTheRunNoteBeforeAnswering() {
        #expect(Self.answer(.command("cd output")) == [
            .saveRunNote(RunID(1), "## Denied\n- `cd output`: Buddy keeps commands in the run folder; use paths instead of `cd`.\n"),
            Self.denied("Buddy keeps commands in the run folder; use paths instead of `cd`.")
        ])
    }

    @Test func denialsAccumulateInTheRunNoteInOrder() {
        var engine = Self.engineWithRun()
        _ = engine.handle(.run(RunID(1), .approvalRequested(id: "r1", .other(tool: "WebFetch"))))
        #expect(engine.handle(.run(RunID(1), .approvalRequested(id: "r2", .read(path: "/etc/hosts")))) == [
            .answerApproval(RunID(1), id: "r2", .allow)
        ])
        #expect(engine.handle(.run(RunID(1), .approvalRequested(id: "r3", .command("cd ~/Desktop")))) == [
            .saveRunNote(RunID(1), """
            ## Denied
            - `WebFetch`: Buddy doesn't allow the WebFetch tool.
            - `cd ~/Desktop`: Buddy keeps commands in the run folder; use paths instead of `cd`.

            """),
            .answerApproval(RunID(1), id: "r3", .deny("Buddy keeps commands in the run folder; use paths instead of `cd`."))
        ])
    }

    @Test func writingThroughASymlinkCannotEscapeTheRunFolder() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "buddy-policy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "run")
        let outside = root.appending(path: "outside")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "link"), withDestinationURL: outside)
        var engine = BuddyEngine(providerConnected: true, home: "/Users/owner")
        for event: BuddyEngine.Event in [
            .pushToTalkPressed, .pushToTalkReleased, .transcriptFinished("agent, make a report"),
            .screensCaptured([]), .run(RunID(1), .started(folder: folder.path))
        ] { _ = engine.handle(event) }
        #expect(engine.handle(.run(RunID(1), .approvalRequested(id: "r1", .write(path: "link/report.txt")))) == [.playCue(.needsOwner)])
        #expect(engine.state.runs.first?.asks == [.approval(
            id: "r1", action: "write link/report.txt", reason: "Runs may only write inside the run folder or add new files to the Desktop."
        )])
    }

    @Test func commandsCannotChangeTheFolderOrOverrideProgramLookup() {
        #expect(Self.answer(.command("cd ./output; rm notes.txt")).last ==
            Self.denied("Buddy keeps commands in the run folder; use paths instead of `cd`."))
        #expect(Self.answer(.command("printf -v PATH /tmp; ls")).last ==
            Self.denied("Use `/usr/bin/printf` so the shell cannot change variables."))
    }

    @Test func shellPrintfMustUseTheExternalProgram() {
        #expect(Self.answer(.command("printf '%n' value")).last ==
            Self.denied("Use `/usr/bin/printf` so the shell cannot change variables."))
    }

    @Test func appleScriptThatSetsAnAppPropertyInsideATellBlockWaitsForTheOwner() {
        let command = #"osascript -e 'tell application "Finder"' -e 'tell file "Example.txt" of desktop' -e 'set comment to "changed"' -e 'end tell' -e 'end tell'"#
        #expect(Self.asks(.command(command)) == [
            .approval(id: "r1", action: command, reason: "AppleScript `set` isn't allowed inside tell blocks.")
        ])
    }
}
