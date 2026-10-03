import Foundation

let url = URL(fileURLWithPath: "Sources/Hoover/Resources/Info.plist")
let data = try Data(contentsOf: url)
guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
      info["LSUIElement"] as? Bool == true,
      info["CFBundleExecutable"] as? String == "Hoover",
      info["LSMinimumSystemVersion"] as? String == "13.0" else {
    fatalError("Hoover bundle metadata invariants are invalid")
}
print("Bundle metadata validated.")
