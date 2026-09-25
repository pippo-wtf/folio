import Foundation

public enum TaskListEdit {
    /// Browser source positions use UTF-16. Replace only the task state character.
    public static func setChecked(_ checked: Bool, atUTF16 offset: Int, in source: String) -> String? {
        let text = source as NSString
        guard offset > 0, offset < text.length - 1,
              text.character(at: offset - 1) == 91, text.character(at: offset + 1) == 93,
              [32, 88, 120].contains(Int(text.character(at: offset))) else { return nil }
        return text.replacingCharacters(in: NSRange(location: offset, length: 1), with: checked ? "x" : " ")
    }
}
