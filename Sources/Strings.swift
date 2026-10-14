import Foundation

// Interface strings. The key is the English text, translations live in Localization/<language>.lproj/Localizable.strings.
// New language: copy ar.lproj, translate the strings and add the language code to CFBundleLocalizations in Info.plist.
@inline(__always) func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

// A string with arguments: L("Save changes to “%@”?", title)
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: args)
}
