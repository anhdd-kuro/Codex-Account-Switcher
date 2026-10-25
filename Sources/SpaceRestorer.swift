import Cocoa

@_silgen_name("CGSMainConnectionID") private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopySpacesForWindows") private func CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ wids: CFArray) -> CFArray?
@_silgen_name("CGSCopyManagedDisplaySpaces") private func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray?
@_silgen_name("CGSManagedDisplaySetCurrentSpace") private func CGSManagedDisplaySetCurrentSpace(_ cid: Int32, _ display: CFString, _ space: Int)

/// Reopens an app on the desktop (Space) it was on before it was quit.
///
/// macOS refuses to move another process's windows between Spaces, so instead the display that owns
/// the remembered Space is switched to it while the app launches (its first window opens on the
/// visible Space), then switched back to what the user was looking at.
struct SpaceRestorer {
    static let defaultsKey = "reopenOnSameDesktop"

    /// On (default): relaunch on the desktop the app was on. Off: it opens on the desktop in front.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    private let connection = CGSMainConnectionID()
    private let spaceID: Int
    private let displayID: String
    private let returnSpaceID: Int

    /// Remembers the Space of the largest window owned by `pids`; nil if none is found.
    init?(windowsOf pids: Set<Int32>) {
        guard Self.isEnabled else { return nil }
        let connection = self.connection
        let windows = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
        let remembered: (area: Double, space: Int)? = windows.compactMap { window -> (Double, Int)? in
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid),
                  window[kCGWindowLayer as String] as? Int == 0,
                  let number = window[kCGWindowNumber as String] as? Int,
                  let bounds = window[kCGWindowBounds as String] as? [String: Double],
                  let width = bounds["Width"], let height = bounds["Height"], width >= 300, height >= 200,
                  let spaces = CGSCopySpacesForWindows(connection, 7, [number] as CFArray) as? [Int],
                  let space = spaces.first else { return nil }
            return (width * height, space)
        }.max { $0.0 < $1.0 }
        guard let remembered, let display = Self.display(owning: remembered.space, connection: connection) else { return nil }
        spaceID = remembered.space
        displayID = display.id
        returnSpaceID = display.currentSpace
    }

    /// True when the remembered Space is already the one on screen.
    var isVisible: Bool { returnSpaceID == spaceID }

    /// Shows the remembered Space on its display so a launching app opens there.
    func showRememberedSpace() {
        guard !isVisible else { return }
        CGSManagedDisplaySetCurrentSpace(connection, displayID as CFString, spaceID)
    }

    /// Puts the display back on the Space the user was looking at.
    func returnToPreviousSpace() {
        guard !isVisible else { return }
        CGSManagedDisplaySetCurrentSpace(connection, displayID as CFString, returnSpaceID)
    }

    private static func display(owning space: Int, connection: Int32) -> (id: String, currentSpace: Int)? {
        let displays = (CGSCopyManagedDisplaySpaces(connection) as? [[String: Any]]) ?? []
        for display in displays {
            let spaces = (display["Spaces"] as? [[String: Any]]) ?? []
            guard spaces.contains(where: { $0["ManagedSpaceID"] as? Int == space }),
                  let id = display["Display Identifier"] as? String,
                  let current = (display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int else { continue }
            return (id, current)
        }
        return nil
    }
}
