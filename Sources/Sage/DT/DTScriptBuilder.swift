import Foundation

/// 全部 DT AppleScript 源码构造。纯函数、可注入字符串一律转义（spec §5）。
/// `tell application id "DNtp"` 对 DEVONthink 3 与 4 通用。
public enum DTScriptBuilder {
    private static func q(_ s: String) -> String { "\"\(appleScriptEscape(s))\"" }
    private static func list(_ items: [String]) -> String {
        "{" + items.map(q).joined(separator: ", ") + "}"
    }

    public static func importScript(filePath: String, database: String, groupPath: String,
                                    tags: [String], note: String?) -> String {
        var body = """
        set theGroup to get record at \(q(groupPath)) in database \(q(database))
        set theRecord to import \(q(filePath)) to theGroup
        """
        if !tags.isEmpty { body += "\nset tags of theRecord to \(list(tags))" }
        if let note, !note.isEmpty { body += "\nset comment of theRecord to \(q(note))" }
        body += "\nreturn uuid of theRecord"
        return wrap(body)
    }

    public static func renameScript(uuid: String, newName: String) -> String {
        wrap("""
        set theRecord to get record with uuid \(q(uuid))
        set oldName to name of theRecord
        set name of theRecord to \(q(newName))
        return oldName
        """)
    }

    public static func addTagsScript(uuid: String, tags: [String]) -> String {
        wrap("""
        set theRecord to get record with uuid \(q(uuid))
        set prev to tags of theRecord
        set tags of theRecord to prev & \(list(tags))
        set AppleScript's text item delimiters to linefeed
        return prev as string
        """)
    }

    public static func moveScript(uuid: String, toDatabase: String, toGroupPath: String) -> String {
        wrap("""
        set theRecord to get record with uuid \(q(uuid))
        set prevDB to name of database of theRecord
        set prevLoc to location of theRecord
        set destGroup to get record at \(q(toGroupPath)) in database \(q(toDatabase))
        move record theRecord to destGroup
        return prevDB & tab & prevLoc
        """)
    }

    public static func deleteScript(uuid: String) -> String {
        wrap("delete record (get record with uuid \(q(uuid)))")
    }

    public static func setNameScript(uuid: String, name: String) -> String {
        wrap("set name of (get record with uuid \(q(uuid))) to \(q(name))")
    }

    public static func setTagsScript(uuid: String, tags: [String]) -> String {
        wrap("set tags of (get record with uuid \(q(uuid))) to \(list(tags))")
    }

    public static func listGroupScript(database: String, groupPath: String) -> String {
        wrap("""
        set theGroup to get record at \(q(groupPath)) in database \(q(database))
        set out to ""
        repeat with r in (children of theGroup)
            set out to out & (uuid of r) & tab & (((modification date of r) as «class isot») as string) & linefeed
        end repeat
        return out
        """)
    }

    public static func factsScript(uuid: String) -> String {
        wrap("""
        set r to get record with uuid \(q(uuid))
        return (name of r) & tab & (kind of r) & tab & (size of r) & tab & (((creation date of r) as «class isot») as string) & tab & (((modification date of r) as «class isot») as string)
        """)
    }

    public static func plainTextScript(uuid: String) -> String {
        wrap("return plain text of (get record with uuid \(q(uuid)))")
    }

    private static func wrap(_ body: String) -> String {
        "tell application id \"DNtp\"\n\(body)\nend tell"
    }
}
