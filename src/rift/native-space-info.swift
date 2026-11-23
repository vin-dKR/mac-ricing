import Darwin
import Foundation

typealias Connection = @convention(c) () -> UInt32
typealias DisplaySpaces = @convention(c) (UInt32) -> Unmanaged<CFArray>?
typealias ActiveDisplay = @convention(c) (UInt32) -> Unmanaged<CFString>?

struct Snapshot: Encodable {
    struct Space: Encodable {
        let id: UInt64
        let type: Int

        init?(_ row: [String: Any]) {
            guard let id = row["ManagedSpaceID"] as? UInt64,
                  let type = row["type"] as? Int else { return nil }
            self.id = id
            self.type = type
        }
    }

    let display: String
    let current: Space
    let spaces: [Space]
}

func snapshot() -> Snapshot? {
    guard let framework = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
          let connection = dlsym(framework, "CGSMainConnectionID"),
          let displays = dlsym(framework, "CGSCopyManagedDisplaySpaces"),
          let selected = dlsym(framework, "SLSCopyActiveMenuBarDisplayIdentifier") else { return nil }

    let cid = unsafeBitCast(connection, to: Connection.self)()
    let active = unsafeBitCast(selected, to: ActiveDisplay.self)(cid)?.takeRetainedValue() as String?
    guard let rows = unsafeBitCast(displays, to: DisplaySpaces.self)(cid)?
              .takeRetainedValue() as? [[String: Any]],
          let row = rows.first(where: { ($0["Display Identifier"] as? String) == active })
              ?? (rows.count == 1 ? rows.first : nil),
          let display = row["Display Identifier"] as? String,
          let currentRow = row["Current Space"] as? [String: Any],
          let current = Snapshot.Space(currentRow),
          let spaces = row["Spaces"] as? [[String: Any]] else { return nil }

    return Snapshot(display: display, current: current, spaces: spaces.compactMap(Snapshot.Space.init))
}

guard let snapshot = snapshot(), let data = try? JSONEncoder().encode(snapshot) else { exit(1) }
FileHandle.standardOutput.write(data)
