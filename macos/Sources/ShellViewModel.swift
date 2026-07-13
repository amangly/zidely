// View-model for the cmux-look shell chrome.
// Demo fixtures now; socket mapping fills the same shapes later.

import Foundation
import CoreGraphics

enum ShellPanelKind: Equatable {
    case terminal
    case browser
    case placeholder
}

struct ShellSurface: Equatable, Identifiable {
    var id: String
    var title: String
    var kind: ShellPanelKind
    /// Daemon pane id when live-wired; nil in pure demo panels.
    var paneId: UInt64?
}

struct ShellPaneNode: Equatable, Identifiable {
    var id: String
    var surfaces: [ShellSurface]
    var selectedSurfaceId: String
}

enum ShellLayout: Equatable {
    case single(ShellPaneNode)
    case split(orientation: Orientation, first: ShellPaneNode, second: ShellPaneNode, ratio: CGFloat)

    enum Orientation: Equatable {
        case horizontal
        case vertical
    }
}

enum ShellAttention: Equatable {
    case none
    case working
    case needsAttention
    case finished
}

struct ShellWorkspace: Equatable, Identifiable {
    var id: String
    var title: String
    var cwd: String?
    var branch: String?
    var branchDirty: Bool
    var ports: [Int]
    var attention: ShellAttention
    var notificationSnippet: String?
    var unreadCount: Int
    var isPinned: Bool
    var layout: ShellLayout
}

enum ShellSidebarItem: Equatable, Identifiable {
    case group(id: String, title: String)
    case workspace(ShellWorkspace)

    var id: String {
        switch self {
        case let .group(id, _): return "g:\(id)"
        case let .workspace(w): return "w:\(w.id)"
        }
    }
}

struct ShellNotification: Equatable, Identifiable {
    var id: String
    var workspaceId: String
    var title: String
    var subtitle: String
    var body: String
    var isRead: Bool
}

struct ClosedSurfaceRecord: Equatable {
    var workspaceId: String
    var paneId: String
    var surface: ShellSurface
}

final class ShellViewModel {
    var items: [ShellSidebarItem] = []
    var selectedWorkspaceId: String?
    var collapsedGroups: Set<String> = []
    var notifications: [ShellNotification] = []
    var sidebarVisible = true
    var rightSidebarVisible = false
    /// Which pane host has the cmux focus ring inside the selected workspace.
    var focusedPaneId: String?
    /// Recently closed surfaces for ⌘⇧T reopen (local chrome only).
    var closedSurfaces: [ClosedSurfaceRecord] = []

    var selectedWorkspace: ShellWorkspace? {
        guard let selectedWorkspaceId else { return nil }
        return workspace(id: selectedWorkspaceId)
    }

    var workspaceIds: [String] {
        items.compactMap {
            if case let .workspace(w) = $0 { return w.id }
            return nil
        }
    }

    /// Visible workspace ids respecting collapsed groups.
    var visibleWorkspaceIds: [String] {
        var out: [String] = []
        var currentGroup: String?
        var collapsed = false
        for item in items {
            switch item {
            case let .group(id, _):
                currentGroup = id
                collapsed = collapsedGroups.contains(id)
            case let .workspace(w):
                if !collapsed { out.append(w.id) }
                _ = currentGroup
            }
        }
        return out
    }

    var unreadNotifications: [ShellNotification] {
        notifications.filter { !$0.isRead }
    }

    /// cmux-style row context: the newest notification text for a
    /// workspace, shown as the row's snippet line.
    func latestNotificationSnippet(for id: String) -> String? {
        guard let n = notifications.last(where: { $0.workspaceId == id }) else { return nil }
        return "\(n.subtitle) — \(n.body)"
    }

    func workspace(id: String) -> ShellWorkspace? {
        for item in items {
            if case let .workspace(w) = item, w.id == id { return w }
        }
        return nil
    }

    func selectWorkspace(_ id: String) {
        selectedWorkspaceId = id
        markWorkspaceRead(id)
        // Default focus to the first pane of the workspace.
        if let ws = workspace(id: id) {
            focusedPaneId = firstPaneId(of: ws.layout)
        }
    }

    func focusPane(_ paneId: String) {
        focusedPaneId = paneId
    }

    func focusAdjacentPane(delta: Int) {
        guard let ws = selectedWorkspace else { return }
        let ids = paneIds(of: ws.layout)
        guard !ids.isEmpty else { return }
        let cur = focusedPaneId.flatMap { ids.firstIndex(of: $0) } ?? 0
        focusedPaneId = ids[(cur + delta + ids.count) % ids.count]
    }

    @discardableResult
    func closeSelectedWorkspace() -> Bool {
        guard let id = selectedWorkspaceId else { return false }
        items.removeAll {
            if case let .workspace(w) = $0 { return w.id == id }
            return false
        }
        // Drop empty trailing groups.
        compactEmptyGroups()
        selectedWorkspaceId = visibleWorkspaceIds.first
        if let sid = selectedWorkspaceId, let ws = workspace(id: sid) {
            focusedPaneId = firstPaneId(of: ws.layout)
        } else {
            focusedPaneId = nil
        }
        return true
    }

    @discardableResult
    func closeSelectedSurface() -> Bool {
        guard let wsId = selectedWorkspaceId else { return false }
        let paneFocus = focusedPaneId
        var closed = false
        var record: ClosedSurfaceRecord?
        mutateWorkspace(id: wsId) { ws in
            func close(from pane: inout ShellPaneNode) {
                if let surf = pane.surfaces.first(where: { $0.id == pane.selectedSurfaceId })
                    ?? pane.surfaces.first {
                    record = ClosedSurfaceRecord(workspaceId: wsId, paneId: pane.id, surface: surf)
                }
                closed = removeSelectedSurface(from: &pane)
            }

            switch ws.layout {
            case .single(var pane):
                close(from: &pane)
                ws.layout = .single(pane)
            case .split(let o, var first, var second, let r):
                if paneFocus == second.id {
                    close(from: &second)
                    if second.surfaces.isEmpty {
                        ws.layout = .single(first)
                        focusedPaneId = first.id
                    } else {
                        ws.layout = .split(orientation: o, first: first, second: second, ratio: r)
                    }
                } else {
                    close(from: &first)
                    if first.surfaces.isEmpty {
                        ws.layout = .single(second)
                        focusedPaneId = second.id
                    } else {
                        ws.layout = .split(orientation: o, first: first, second: second, ratio: r)
                    }
                }
            }
        }
        if closed, let record {
            closedSurfaces.append(record)
            if closedSurfaces.count > 20 { closedSurfaces.removeFirst(closedSurfaces.count - 20) }
        }
        if let ws = workspace(id: wsId), surfaceCount(of: ws.layout) == 0 {
            _ = closeSelectedWorkspace()
        }
        return closed
    }

    @discardableResult
    func reopenLastClosedSurface() -> Bool {
        guard let record = closedSurfaces.popLast() else { return false }
        // Prefer original workspace if it still exists; else selected / first.
        let wsId = workspace(id: record.workspaceId)?.id
            ?? selectedWorkspaceId
            ?? workspaceIds.first
        guard let wsId else {
            closedSurfaces.append(record)
            return false
        }
        selectWorkspace(wsId)
        var surface = record.surface
        surface.id = "s-\(UUID().uuidString.prefix(6))" // fresh id so tabs don't collide
        mutateWorkspace(id: wsId) { ws in
            let targetPane = record.paneId
            switch ws.layout {
            case .single(var pane):
                pane.surfaces.append(surface)
                pane.selectedSurfaceId = surface.id
                focusedPaneId = pane.id
                ws.layout = .single(pane)
            case .split(let o, var first, var second, let r):
                if second.id == targetPane {
                    second.surfaces.append(surface)
                    second.selectedSurfaceId = surface.id
                    focusedPaneId = second.id
                } else {
                    first.surfaces.append(surface)
                    first.selectedSurfaceId = surface.id
                    focusedPaneId = first.id
                }
                ws.layout = .split(orientation: o, first: first, second: second, ratio: r)
            }
        }
        return true
    }

    func selectAdjacentSurface(delta: Int) {
        guard let wsId = selectedWorkspaceId else { return }
        mutateWorkspace(id: wsId) { ws in
            let paneId = focusedPaneId ?? firstPaneId(of: ws.layout)
            ws.layout = mapLayout(ws.layout) { pane in
                guard pane.id == paneId, !pane.surfaces.isEmpty else { return pane }
                var p = pane
                let idx = p.surfaces.firstIndex { $0.id == p.selectedSurfaceId } ?? 0
                let next = (idx + delta + p.surfaces.count) % p.surfaces.count
                p.selectedSurfaceId = p.surfaces[next].id
                return p
            }
        }
    }

    private func removeSelectedSurface(from pane: inout ShellPaneNode) -> Bool {
        guard let idx = pane.surfaces.firstIndex(where: { $0.id == pane.selectedSurfaceId })
                ?? pane.surfaces.indices.first else { return false }
        pane.surfaces.remove(at: idx)
        if let first = pane.surfaces.first {
            pane.selectedSurfaceId = first.id
        }
        return true
    }

    private func firstPaneId(of layout: ShellLayout) -> String {
        switch layout {
        case let .single(p): return p.id
        case let .split(_, first, _, _): return first.id
        }
    }

    private func paneIds(of layout: ShellLayout) -> [String] {
        switch layout {
        case let .single(p): return [p.id]
        case let .split(_, a, b, _): return [a.id, b.id]
        }
    }

    private func surfaceCount(of layout: ShellLayout) -> Int {
        switch layout {
        case let .single(p): return p.surfaces.count
        case let .split(_, a, b, _): return a.surfaces.count + b.surfaces.count
        }
    }

    private func compactEmptyGroups() {
        var next: [ShellSidebarItem] = []
        var i = 0
        while i < items.count {
            if case let .group(gid, title) = items[i] {
                let hasMember = (i + 1 < items.count) && {
                    if case .workspace = items[i + 1] { return true }
                    return false
                }()
                if hasMember {
                    next.append(.group(id: gid, title: title))
                }
                // skip empty group header
            } else {
                next.append(items[i])
            }
            i += 1
        }
        items = next
    }

    func toggleGroup(_ id: String) {
        if collapsedGroups.contains(id) {
            collapsedGroups.remove(id)
        } else {
            collapsedGroups.insert(id)
        }
    }

    func isGroupCollapsed(_ id: String) -> Bool {
        collapsedGroups.contains(id)
    }

    func selectSurface(workspaceId: String, paneId: String, surfaceId: String) {
        mutateWorkspace(id: workspaceId) { ws in
            ws.layout = mapLayout(ws.layout) { pane in
                guard pane.id == paneId else { return pane }
                var p = pane
                p.selectedSurfaceId = surfaceId
                return p
            }
        }
    }

    func setSplitRatio(workspaceId: String, ratio: CGFloat) {
        let r = min(0.85, max(0.15, ratio))
        mutateWorkspace(id: workspaceId) { ws in
            if case let .split(o, a, b, _) = ws.layout {
                ws.layout = .split(orientation: o, first: a, second: b, ratio: r)
            }
        }
    }

    func markWorkspaceRead(_ id: String) {
        for i in notifications.indices where notifications[i].workspaceId == id {
            notifications[i].isRead = true
        }
        mutateWorkspace(id: id) { ws in
            ws.unreadCount = 0
            if ws.attention == .needsAttention {
                ws.notificationSnippet = nil
            }
        }
    }

    func markNotificationRead(_ id: String) {
        guard let idx = notifications.firstIndex(where: { $0.id == id }) else { return }
        notifications[idx].isRead = true
        let wsId = notifications[idx].workspaceId
        let remaining = notifications.filter { $0.workspaceId == wsId && !$0.isRead }.count
        mutateWorkspace(id: wsId) { $0.unreadCount = remaining }
    }

    /// Jump to the workspace of the newest unread notification.
    @discardableResult
    func jumpToLatestUnread() -> String? {
        guard let n = unreadNotifications.last else { return nil }
        selectWorkspace(n.workspaceId)
        return n.workspaceId
    }

    func selectWorkspaceIndex(_ index: Int) {
        let ids = visibleWorkspaceIds
        guard index >= 0, index < ids.count else { return }
        selectWorkspace(ids[index])
    }

    func selectAdjacentWorkspace(delta: Int) {
        let ids = visibleWorkspaceIds
        guard !ids.isEmpty else { return }
        let current = selectedWorkspaceId.flatMap { ids.firstIndex(of: $0) } ?? 0
        let next = (current + delta + ids.count) % ids.count
        selectWorkspace(ids[next])
    }

    func togglePin(_ id: String) {
        mutateWorkspace(id: id) { $0.isPinned.toggle() }
        // Pinned workspaces float above unpinned within their group.
        resortItems()
    }

    /// Wire a freshly spawned daemon pane into a workspace as the
    /// second half of a split (cmux ⌘D / ⌘⇧D — the live path).
    func graftSplit(workspaceId: String, orientation: ShellLayout.Orientation, paneId: UInt64) {
        let surface = ShellSurface(
            id: "pane-\(paneId)", title: "pane \(paneId)", kind: .terminal, paneId: paneId)
        let node = ShellPaneNode(id: "p-\(paneId)", surfaces: [surface], selectedSurfaceId: surface.id)
        mutateWorkspace(id: workspaceId) { ws in
            switch ws.layout {
            case let .single(existing):
                ws.layout = .split(orientation: orientation, first: existing, second: node, ratio: 0.5)
            case let .split(_, first, _, _):
                ws.layout = .split(orientation: orientation, first: first, second: node, ratio: 0.5)
            }
        }
        focusedPaneId = node.id
    }

    /// A daemon pane is gone (child exited, pane removed): drop its
    /// surfaces from every workspace and collapse half-empty splits to
    /// the surviving side. Workspaces left with no surfaces disappear
    /// on the next applyLive (the daemon no longer lists their pane).
    func removePaneEverywhere(_ pane: UInt64) {
        for id in workspaceIds {
            mutateWorkspace(id: id) { ws in
                func prune(_ node: inout ShellPaneNode) {
                    node.surfaces.removeAll { $0.paneId == pane }
                    if !node.surfaces.contains(where: { $0.id == node.selectedSurfaceId }) {
                        node.selectedSurfaceId = node.surfaces.first?.id ?? ""
                    }
                }
                switch ws.layout {
                case .single(var p):
                    prune(&p)
                    ws.layout = .single(p)
                case .split(let o, var first, var second, let r):
                    prune(&first)
                    prune(&second)
                    if first.surfaces.isEmpty {
                        ws.layout = .single(second)
                        if focusedPaneId == first.id { focusedPaneId = second.id }
                    } else if second.surfaces.isEmpty {
                        ws.layout = .single(first)
                        if focusedPaneId == second.id { focusedPaneId = first.id }
                    } else {
                        ws.layout = .split(orientation: o, first: first, second: second, ratio: r)
                    }
                }
            }
        }
    }

    /// Rename every surface bound to a daemon pane (live OSC titles).
    func setSurfaceTitle(paneId: UInt64, title: String) {
        for id in workspaceIds {
            mutateWorkspace(id: id) { ws in
                func apply(_ node: inout ShellPaneNode) {
                    for i in node.surfaces.indices where node.surfaces[i].paneId == paneId {
                        node.surfaces[i].title = title
                    }
                }
                switch ws.layout {
                case .single(var p):
                    apply(&p)
                    ws.layout = .single(p)
                case .split(let o, var first, var second, let r):
                    apply(&first)
                    apply(&second)
                    ws.layout = .split(orientation: o, first: first, second: second, ratio: r)
                }
            }
        }
    }

    /// Daemon pane ids referenced by a layout's surfaces.
    func daemonPaneIds(of layout: ShellLayout) -> [UInt64] {
        let nodes: [ShellPaneNode]
        switch layout {
        case let .single(p): nodes = [p]
        case let .split(_, a, b, _): nodes = [a, b]
        }
        return nodes.flatMap { $0.surfaces.compactMap(\.paneId) }
    }

    /// cmux ⌘D / ⌘⇧D — visual split only (demo / local layout).
    func splitSelected(orientation: ShellLayout.Orientation) {
        guard let id = selectedWorkspaceId else { return }
        mutateWorkspace(id: id) { ws in
            let newPane = ShellPaneNode(
                id: "split-\(UUID().uuidString.prefix(6))",
                surfaces: [ShellSurface(id: "s-\(UUID().uuidString.prefix(6))", title: "zsh", kind: .terminal, paneId: nil)],
                selectedSurfaceId: "")
            var pane = newPane
            pane.selectedSurfaceId = pane.surfaces[0].id
            switch ws.layout {
            case let .single(existing):
                ws.layout = .split(orientation: orientation, first: existing, second: pane, ratio: 0.5)
            case let .split(_, first, _, _):
                // Nest: keep first, replace second with a split containing old second... keep it simple — replace whole layout.
                ws.layout = .split(orientation: orientation, first: first, second: pane, ratio: 0.5)
            }
        }
    }

    func addSurfaceToSelected(kind: ShellPanelKind = .terminal) {
        guard let id = selectedWorkspaceId else { return }
        let title = kind == .browser ? "web" : "term"
        let surface = ShellSurface(
            id: "s-\(UUID().uuidString.prefix(6))", title: title, kind: kind, paneId: nil)
        mutateWorkspace(id: id) { ws in
            switch ws.layout {
            case .single(var pane):
                pane.surfaces.append(surface)
                pane.selectedSurfaceId = surface.id
                ws.layout = .single(pane)
            case .split(let o, var first, let second, let r):
                first.surfaces.append(surface)
                first.selectedSurfaceId = surface.id
                ws.layout = .split(orientation: o, first: first, second: second, ratio: r)
            }
        }
    }

    /// Demo/local: spawn a workspace under a group (UI only).
    func addWorkspace(inGroup groupId: String) {
        let id = "ws-\(UUID().uuidString.prefix(6))"
        let surface = ShellSurface(id: "s1", title: "zsh", kind: .terminal, paneId: nil)
        let ws = ShellWorkspace(
            id: id,
            title: "New workspace",
            cwd: "~",
            branch: nil,
            branchDirty: false,
            ports: [],
            attention: .none,
            notificationSnippet: nil,
            unreadCount: 0,
            isPinned: false,
            layout: .single(ShellPaneNode(id: "p1", surfaces: [surface], selectedSurfaceId: surface.id)))

        var next: [ShellSidebarItem] = []
        var insertAt: Int?
        for (i, item) in items.enumerated() {
            if case let .group(gid, _) = item, gid == groupId {
                insertAt = i + 1
                // Walk forward past existing members.
                var j = i + 1
                while j < items.count {
                    if case .group = items[j] { break }
                    j += 1
                }
                insertAt = j
            }
            _ = i
        }
        next = items
        if let insertAt {
            next.insert(.workspace(ws), at: insertAt)
        } else {
            next.append(.group(id: groupId, title: groupId.uppercased()))
            next.append(.workspace(ws))
        }
        items = next
        selectWorkspace(id)
    }

    func renameWorkspace(_ id: String, title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        mutateWorkspace(id: id) { $0.title = t }
    }

    func renameSelectedWorkspace(title: String) {
        guard let id = selectedWorkspaceId else { return }
        renameWorkspace(id, title: title)
    }

    /// Filter workspaces for the ⌘P switcher.
    func workspaces(matching query: String) -> [ShellWorkspace] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let all = items.compactMap { item -> ShellWorkspace? in
            if case let .workspace(w) = item { return w }
            return nil
        }
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.title.lowercased().contains(q)
                || ($0.cwd?.lowercased().contains(q) ?? false)
                || ($0.branch?.lowercased().contains(q) ?? false)
        }
    }

    /// Group containing the selected workspace, if any.
    func groupId(containingWorkspace id: String) -> String? {
        var current: String?
        for item in items {
            switch item {
            case let .group(gid, _): current = gid
            case let .workspace(w) where w.id == id: return current
            default: break
            }
        }
        return nil
    }

    func collapseFocusedGroup() {
        guard let wsId = selectedWorkspaceId,
              let gid = groupId(containingWorkspace: wsId) else { return }
        toggleGroup(gid)
    }

    /// cmux ⌃⌘G — empty group with an anchor workspace.
    func createEmptyGroup(named name: String? = nil) {
        let n = items.reduce(0) { acc, item in
            if case .group = item { return acc + 1 }
            return acc
        } + 1
        let gid = "group-\(n)"
        let title = name ?? "GROUP \(n)"
        let surface = ShellSurface(id: "s1", title: "zsh", kind: .terminal, paneId: nil)
        let anchor = ShellWorkspace(
            id: "anchor-\(gid)",
            title: title.capitalized,
            cwd: "~",
            branch: nil,
            branchDirty: false,
            ports: [],
            attention: .none,
            notificationSnippet: nil,
            unreadCount: 0,
            isPinned: false,
            layout: .single(ShellPaneNode(id: "p1", surfaces: [surface], selectedSurfaceId: surface.id)))
        items.append(.group(id: gid, title: title))
        items.append(.workspace(anchor))
        selectWorkspace(anchor.id)
    }

    private func resortItems() {
        // Keep group headers; within each group, pinned first.
        var result: [ShellSidebarItem] = []
        var bucket: [ShellWorkspace] = []
        var currentGroup: ShellSidebarItem?

        func flush() {
            if let g = currentGroup { result.append(g) }
            let pinned = bucket.filter(\.isPinned)
            let rest = bucket.filter { !$0.isPinned }
            for w in pinned + rest { result.append(.workspace(w)) }
            bucket.removeAll()
            currentGroup = nil
        }

        for item in items {
            switch item {
            case .group:
                flush()
                currentGroup = item
            case let .workspace(w):
                bucket.append(w)
            }
        }
        flush()
        items = result
    }

    private func mutateWorkspace(id: String, _ body: (inout ShellWorkspace) -> Void) {
        for i in items.indices {
            if case var .workspace(w) = items[i], w.id == id {
                body(&w)
                items[i] = .workspace(w)
                return
            }
        }
    }

    private func mapLayout(_ layout: ShellLayout, _ body: (ShellPaneNode) -> ShellPaneNode) -> ShellLayout {
        switch layout {
        case let .single(p):
            return .single(body(p))
        case let .split(o, a, b, r):
            return .split(orientation: o, first: body(a), second: body(b), ratio: r)
        }
    }

    /// Full cmux-like fixture for `ZIDE_UI_DEMO=1`.
    static func demo() -> ShellViewModel {
        let vm = ShellViewModel()

        let agentSurfaces = [
            ShellSurface(id: "a1", title: "claude", kind: .terminal, paneId: nil),
            ShellSurface(id: "a2", title: "diff", kind: .placeholder, paneId: nil),
        ]
        let agentPane = ShellPaneNode(id: "ap", surfaces: agentSurfaces, selectedSurfaceId: "a1")
        let browserPane = ShellPaneNode(
            id: "bp",
            surfaces: [ShellSurface(id: "b1", title: "PR", kind: .browser, paneId: nil)],
            selectedSurfaceId: "b1")

        let agent = ShellWorkspace(
            id: "task-1",
            title: "Start phase 1 PTY layer",
            cwd: "~/zide",
            branch: "zide/pty-layer",
            branchDirty: true,
            ports: [],
            attention: .needsAttention,
            notificationSnippet: "Claude Code needs input",
            unreadCount: 1,
            isPinned: true,
            layout: .split(orientation: .horizontal, first: agentPane, second: browserPane, ratio: 0.55))

        let idleAgent = ShellWorkspace(
            id: "task-2",
            title: "Review merge flow",
            cwd: "~/zide",
            branch: "zide/review-merge",
            branchDirty: false,
            ports: [],
            attention: .finished,
            notificationSnippet: nil,
            unreadCount: 0,
            isPinned: false,
            layout: .single(ShellPaneNode(
                id: "ip",
                surfaces: [ShellSurface(id: "i1", title: "claude", kind: .terminal, paneId: nil)],
                selectedSurfaceId: "i1")))

        let devLeft = ShellPaneNode(
            id: "dl",
            surfaces: [
                ShellSurface(id: "d1", title: "zsh", kind: .terminal, paneId: nil),
                ShellSurface(id: "d2", title: "logs", kind: .terminal, paneId: nil),
            ],
            selectedSurfaceId: "d1")
        let devRight = ShellPaneNode(
            id: "dr",
            surfaces: [ShellSurface(id: "d3", title: "~/zide", kind: .terminal, paneId: nil)],
            selectedSurfaceId: "d3")

        let dev = ShellWorkspace(
            id: "ws-dev",
            title: "~/zide",
            cwd: "~/zide",
            branch: "main",
            branchDirty: false,
            ports: [],
            attention: .none,
            notificationSnippet: nil,
            unreadCount: 0,
            isPinned: false,
            layout: .split(orientation: .horizontal, first: devLeft, second: devRight, ratio: 0.5))

        let qemu = ShellWorkspace(
            id: "ws-qemu",
            title: "QEMU Valorant Research",
            cwd: "~",
            branch: nil,
            branchDirty: false,
            ports: [3389],
            attention: .working,
            notificationSnippet: nil,
            unreadCount: 2,
            isPinned: false,
            layout: .single(ShellPaneNode(
                id: "qp",
                surfaces: [ShellSurface(id: "q1", title: "qemu", kind: .terminal, paneId: nil)],
                selectedSurfaceId: "q1")))

        vm.items = [
            .group(id: "sessions", title: "WORKSPACES"),
            .workspace(agent),
            .workspace(idleAgent),
            .workspace(dev),
            .workspace(qemu),
        ]
        vm.selectedWorkspaceId = agent.id
        vm.focusedPaneId = "ap"
        vm.notifications = [
            ShellNotification(
                id: "n1", workspaceId: "task-1", title: "Claude Code",
                subtitle: "Needs attention", body: "Waiting for permission to edit Pty.zig",
                isRead: false),
            ShellNotification(
                id: "n2", workspaceId: "ws-qemu", title: "Build",
                subtitle: "Completed", body: "QEMU guest booted on :3389",
                isRead: false),
            ShellNotification(
                id: "n3", workspaceId: "ws-qemu", title: "Ports",
                subtitle: "Listening", body: "RDP ready on 3389",
                isRead: false),
            ShellNotification(
                id: "n4", workspaceId: "task-2", title: "Claude Code",
                subtitle: "Idle", body: "Review merge flow finished",
                isRead: true),
        ]
        return vm
    }

    /// Live map: sessions/panes into workspace rows.
    /// Call `applyPaneMeta` after for cwd/branch/ports from `panes-meta`.
    func applyLive(
        sessions: [(id: UInt64, title: String, panes: [UInt64], browsers: [UInt64], exited: [UInt64])],
        bells: Set<UInt64>,
        exited: Set<UInt64>,
        browserTitles: [UInt64: String] = [:],
        paneTitles: [UInt64: String] = [:],
        agentActivity: [UInt64: String?] = [:]
    ) {
        // Panes grafted into another workspace's layout (splits, extra
        // tabs) must not also surface as standalone rows.
        var embedded: Set<UInt64> = []
        for item in items {
            guard case let .workspace(w) = item else { continue }
            for pid in daemonPaneIds(of: w.layout)
            where "term-\(pid)" != w.id && "web-\(pid)" != w.id {
                embedded.insert(pid)
            }
        }
        var next: [ShellSidebarItem] = []

        var anySession = false
        for s in sessions {
            let visible = s.panes.filter { !embedded.contains($0) }
            let visibleBrowsers = s.browsers.filter { !embedded.contains($0) }
            if visible.isEmpty && visibleBrowsers.isEmpty { continue }
            if !anySession {
                next.append(.group(id: "sessions", title: "WORKSPACES"))
                anySession = true
            }
            for pane in visible {
                // A pane whose foreground process is an AI agent is
                // "working" until it rings for attention — the cmux
                // row treatment, driven by panes-meta.
                let isAgent = agentActivity.keys.contains(pane)
                let attention: ShellAttention =
                    exited.contains(pane) ? .finished :
                    bells.contains(pane) ? .needsAttention :
                    isAgent ? .working : .none
                let surface = ShellSurface(
                    id: "pane-\(pane)",
                    title: paneTitles[pane] ?? "pane \(pane)",
                    kind: .terminal, paneId: pane)
                let id = "term-\(pane)"
                let prev = workspace(id: id)
                next.append(.workspace(ShellWorkspace(
                    id: id,
                    title: s.title.isEmpty ? "pane \(pane)" : s.title,
                    cwd: prev?.cwd,
                    branch: prev?.branch,
                    branchDirty: prev?.branchDirty ?? false,
                    ports: prev?.ports ?? [],
                    attention: attention,
                    notificationSnippet: (agentActivity[pane] ?? nil)
                        ?? latestNotificationSnippet(for: id),
                    unreadCount: bells.contains(pane) ? max(1, prev?.unreadCount ?? 1) : (prev?.unreadCount ?? 0),
                    isPinned: prev?.isPinned ?? false,
                    layout: prev?.layout ?? .single(ShellPaneNode(
                        id: "p-\(pane)", surfaces: [surface], selectedSurfaceId: surface.id)))))
            }
            for pane in visibleBrowsers {
                let id = "web-\(pane)"
                let webTitle = browserTitles[pane] ?? prevTitle(id: id) ?? "web \(pane)"
                let surface = ShellSurface(
                    id: "web-\(pane)", title: webTitle, kind: .browser, paneId: pane)
                let prev = workspace(id: id)
                next.append(.workspace(ShellWorkspace(
                    id: id,
                    title: webTitle,
                    cwd: prev?.cwd,
                    branch: prev?.branch,
                    branchDirty: prev?.branchDirty ?? false,
                    ports: prev?.ports ?? [],
                    attention: .none,
                    notificationSnippet: nil,
                    unreadCount: prev?.unreadCount ?? 0,
                    isPinned: prev?.isPinned ?? false,
                    layout: prev?.layout ?? .single(ShellPaneNode(
                        id: "p-\(pane)", surfaces: [surface], selectedSurfaceId: surface.id)))))
            }
        }

        let previous = selectedWorkspaceId
        items = next
        if let previous, items.contains(where: {
            if case let .workspace(w) = $0 { return w.id == previous }
            return false
        }) {
            selectedWorkspaceId = previous
        } else {
            selectedWorkspaceId = items.compactMap {
                if case let .workspace(w) = $0 { return w.id }
                return nil
            }.first
        }
    }

    /// Overlay cwd / branch / dirty / ports from `panes-meta` onto workspaces
    /// that own those daemon pane ids.
    func applyPaneMeta(
        _ metas: [UInt64: (cwd: String?, branch: String?, dirty: Bool, ports: [Int],
                           agent: String?, activity: String?)]
    ) {
        guard !metas.isEmpty else { return }
        items = items.map { item in
            guard case var .workspace(w) = item else { return item }
            guard let pane = primaryTerminalPaneId(of: w), let m = metas[pane] else {
                return item
            }
            w.cwd = m.cwd ?? w.cwd
            w.branch = m.branch ?? w.branch
            w.branchDirty = m.dirty
            w.ports = m.ports.isEmpty ? w.ports : m.ports
            // An AI agent running in a pane (user typed `claude`)
            // lights the row up like cmux: working dot, and the pane's
            // live status line as the snippet — the sidebar knows what
            // is going on in there. Bell attention wins.
            if m.agent != nil {
                if w.attention == ShellAttention.none { w.attention = .working }
                if let activity = m.activity, !activity.isEmpty {
                    w.notificationSnippet = activity
                }
            }
            return .workspace(w)
        }
    }

    func setBrowserTitle(pane: UInt64, title: String) {
        let id = "web-\(pane)"
        items = items.map { item in
            guard case var .workspace(w) = item, w.id == id else { return item }
            w.title = title
            w.layout = renameSurface(in: w.layout, surfaceId: "web-\(pane)", title: title)
            return .workspace(w)
        }
    }

    private func renameSurface(in layout: ShellLayout, surfaceId: String, title: String) -> ShellLayout {
        func rename(_ node: ShellPaneNode) -> ShellPaneNode {
            var n = node
            n.surfaces = n.surfaces.map { s in
                var s = s
                if s.id == surfaceId { s.title = title }
                return s
            }
            return n
        }
        switch layout {
        case let .single(p): return .single(rename(p))
        case let .split(o, a, b, r): return .split(orientation: o, first: rename(a), second: rename(b), ratio: r)
        }
    }

    private func prevTitle(id: String) -> String? {
        workspace(id: id)?.title
    }

    private func primaryTerminalPaneId(of w: ShellWorkspace) -> UInt64? {
        func from(_ node: ShellPaneNode) -> UInt64? {
            let surfaces = node.surfaces.filter { $0.kind == .terminal }
            return (surfaces.first { $0.id == node.selectedSurfaceId } ?? surfaces.first)?.paneId
        }
        switch w.layout {
        case let .single(p): return from(p)
        case let .split(_, a, b, _): return from(a) ?? from(b)
        }
    }
}
