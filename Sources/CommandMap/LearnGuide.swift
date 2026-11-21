/// Step-by-step instructions (with Logic's English menu names) for teaching Logic a command with
/// Key Commands > Learn New Assignment. Shown by `list_commands`, `learn_command` and the
/// console; docs/setup/03-phase3-commands.md has the same steps with more context. The steps
/// were tested on Logic 13 with the Japanese UI; a command's Japanese name, when it was seen
/// there, is given as well.
public enum LearnGuide {
    /// The window where key commands are learned.
    public static let keyCommandsMenu = "Logic Pro > Key Commands > Edit Assignments…"
    /// The learn button under "Control Surface" in that window.
    public static let learnButton = "Learn New Assignment"
    /// The window that lists every learned assignment.
    public static let controllerAssignmentsMenu = "Logic Pro > Control Surfaces > Controller Assignments…"
    /// The button at the bottom right of that window that arms learning there.
    public static let controllerLearnButton = "Learn Mode"

    /// How to find the command's row in the Key Commands window.
    public static func findRow(_ command: LogicCommand) -> String {
        let row = "Type “\(command.englishName)” into the search field at the top right and find that row."
        if let name = command.verifiedJapaneseName {
            return row + " With Logic's Japanese UI the row is “\(name)”."
        }
        let keywords = command.japaneseKeywords.map { "“\($0)”" }.joined(separator: ", ")
        let hint = keywords.isEmpty ? "" : " try searching for \(keywords) (guesses, unverified), then"
        return row + " With Logic's Japanese UI the row's name has not been seen yet:\(hint) find the row whose English name is “\(command.englishName)” and tell Claude its Japanese name so it can go into the catalog."
    }

    /// Everything to do before the message is sent.
    public static func beforeSending(_ command: LogicCommand) -> [String] {
        [
            "In Logic, open **\(keyCommandsMenu)**.",
            findRow(command),
            "**Click the row first to select it**, then click **\(learnButton)** under “Control Surface” on the right. The button looks the same armed and unarmed, so always select the row before clicking the button.",
            "After clicking the button and before the message is sent, do not let Claude call any other Logic tool: while learning, Logic takes Mackie Control messages as the input to learn (observed: a Bank Left sent while reading tracks was learned as “Note 46”).",
        ]
    }

    /// What to check after the message was sent.
    public static func afterSending(_ command: LogicCommand) -> [String] {
        var steps = [
            "Check the row's “Control Surface” column: text like `CC \(command.controller) (127)` (port LogicMCP Keys, channel 16) means it worked. If nothing appears, repeat: select the row → click \(learnButton) → send.",
            "If an alert says the control is already assigned to another parameter and asks whether to reassign it: agree only if you are sure you are relearning this command; otherwise click **Cancel**.",
        ]
        if !command.runnable {
            steps.append("If Logic opened this command's dialog (\(command.englishName)), \(learnButton) was not armed and the command, already learned, ran: first click **Cancel** in Logic to close the dialog, then let Claude use other Logic tools (the server cannot close the dialog, and while it is open Mackie Control input goes into it).")
        }
        steps.append("After learning all commands, open **\(controllerAssignmentsMenu)** and check that **\(controllerLearnButton)** at the bottom right is not lit (blue); if it is, click it to turn it off.")
        return steps
    }

    /// Before + send + after, for printed guides.
    public static func steps(_ command: LogicCommand, sendStep: String) -> [String] {
        beforeSending(command) + [sendStep] + afterSending(command)
    }
}
