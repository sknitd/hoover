import Foundation
import HooverCore

struct TreeColumn: Identifiable {
    var id: String { "\(level):\(parentURL.path)" }
    let parentURL: URL
    let level: Int
    var items: [FileNode]
    var error: String? = nil
    var isLoading: Bool = false
}
