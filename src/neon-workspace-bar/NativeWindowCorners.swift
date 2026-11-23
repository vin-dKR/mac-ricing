import CoreGraphics
import Darwin
import Foundation

/// Reads the compositor's radii. A missing private API leaves the desktop matte usable.
enum NativeWindowCorners {
    struct Tile {
        let id: UInt32
        let frame: CGRect
    }

    private struct Lookup {
        typealias Connection = @convention(c) () -> Int32
        typealias Query = @convention(c) (Int32, CFArray, UInt32) -> Unmanaged<CFTypeRef>?
        typealias Iterator = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
        typealias Advance = @convention(c) (CFTypeRef) -> Bool
        typealias WindowID = @convention(c) (CFTypeRef) -> UInt32
        typealias Radii = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?

        let connection: Connection
        let query: Query
        let iterator: Iterator
        let advance: Advance
        let windowID: WindowID
        let radii: Radii

        init?() {
            guard let framework = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
                  let connection = dlsym(framework, "SLSMainConnectionID"),
                  let query = dlsym(framework, "SLSWindowQueryWindows"),
                  let iterator = dlsym(framework, "SLSWindowQueryResultCopyWindows"),
                  let advance = dlsym(framework, "SLSWindowIteratorAdvance"),
                  let windowID = dlsym(framework, "SLSWindowIteratorGetWindowID"),
                  let radii = dlsym(framework, "SLSWindowIteratorGetCornerRadii") else { return nil }
            self.connection = unsafeBitCast(connection, to: Connection.self)
            self.query = unsafeBitCast(query, to: Query.self)
            self.iterator = unsafeBitCast(iterator, to: Iterator.self)
            self.advance = unsafeBitCast(advance, to: Advance.self)
            self.windowID = unsafeBitCast(windowID, to: WindowID.self)
            self.radii = unsafeBitCast(radii, to: Radii.self)
        }

        func read(_ ids: Set<UInt32>) -> [UInt32: WorkspaceCornerRadii] {
            let keys = ids.map { NSNumber(value: $0) } as CFArray
            guard let query = query(connection(), keys, 0)?.takeRetainedValue(),
                  let iterator = iterator(query)?.takeRetainedValue() else { return [:] }
            return withExtendedLifetime(query) {
                var matches: [UInt32: WorkspaceCornerRadii] = [:]
                while advance(iterator) {
                    guard let numbers = radii(iterator)?.takeRetainedValue() as? [NSNumber],
                          numbers.count >= 4 else { continue }
                    let values = numbers.prefix(4).map { CGFloat($0.doubleValue) }
                    guard values.allSatisfy({ $0.isFinite && (0...128).contains($0) }) else { continue }
                    let id = windowID(iterator)
                    matches[id] = WorkspaceCornerRadii(topLeft: values[0], topRight: values[1],
                                                       bottomLeft: values[2], bottomRight: values[3])
                }
                return matches
            }
        }
    }

    private static let lookup = Lookup()

    static func opening(for tiles: [Tile], display: CGRect) -> WorkspaceCornerRadii {
        let desired = CGRect(x: display.minX + WorkspaceChrome.edgeInset,
                             y: display.minY + WorkspaceChrome.edgeInset,
                             width: display.width - WorkspaceChrome.edgeInset * 2,
                             height: display.height - WorkspaceChrome.edgeInset - WorkspaceChrome.footerHeight)
        let horizontal: [(Tile) -> Bool] = [
            { abs($0.frame.minX - desired.minX) <= 2 },
            { abs($0.frame.maxX - desired.maxX) <= 2 }
        ]
        let vertical: [(Tile) -> Bool] = [
            { abs($0.frame.minY - desired.minY) <= 2 },
            { abs($0.frame.maxY - desired.maxY) <= 2 }
        ]
        let corners = vertical.flatMap { crossesY in
            horizontal.map { crossesX in tiles.first { crossesX($0) && crossesY($0) }?.id }
        }
        let ids = Set(corners.compactMap { $0 })
        guard !ids.isEmpty, let lookup else { return WorkspaceCornerRadii() }

        let values = lookup.read(ids)
        let fallback = WorkspaceCornerRadii()
        let match = corners.map { $0.flatMap { values[$0] } }
        return WorkspaceCornerRadii(topLeft: match[0]?.topLeft ?? fallback.topLeft,
                                   topRight: match[1]?.topRight ?? fallback.topRight,
                                   bottomLeft: match[2]?.bottomLeft ?? fallback.bottomLeft,
                                   bottomRight: match[3]?.bottomRight ?? fallback.bottomRight)
    }
}
