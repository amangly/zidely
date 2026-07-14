// View-model for the cmux-look shell chrome.
//
// The cmux system, mapped onto zide's daemon: a sidebar row is a
// WORKSPACE (one daemon session), and a workspace contains a recursive
// split tree of panels — terminal panes on the left, browser panels
// docked as a right-hand column (cmux's _dockSplit). Browsers never
// become sidebar rows of their own.

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

/// cmux-style surface tree: leaves are panels, splits nest arbitrarily.
indirect enum ShellLayout: Equatable {
    case leaf(ShellPaneNode)
    case split(orientation: Orientation, first: ShellLayout, second: ShellLayout, ratio: CGFloat)

    enum Orientation: Equatable {
        case horizontal
        case vertical
    }

    var leaves: [ShellPaneNode] {
        switch self {
        case let .leaf(node): return [node]
        case let .split(_, a, b, _): return a.leaves + b.leaves
        }
    }

    var daemonPaneIds: [UInt64] {
        leaves.flatMap { $0.surfaces.compactMap(\.paneId) }
    }

    /// A placeholder tree for a workspace with no panels yet.
    static func empty(_ tag: String) -> ShellLayout {
        .leaf(ShellPaneNode(id: "empty-\(tag)", surfaces: [], selectedSurfaceId: ""))
    }

    var isEmpty: Bool {
        leaves.allSatisfy(\.surfaces.isEmpty)
    }

    func mapLeaves(_ body: (ShellPaneNode) -> ShellPaneNode) -> ShellLayout {
        switch self {
        case let .leaf(node):
            return .leaf(body(node))
        case let .split(o, a, b, r):
            return .split(orientation: o, first: a.mapLeaves(body), second: b.mapLeaves(body), ratio: r)
        }
    }

    /// Drop leaves the predicate rejects, collapsing half-empty splits
    /// to the surviving side. nil when nothing survives.
    func pruned(keep: (ShellPaneNode) -> Bool) -> ShellLayout? {
        switch self {
        case let .leaf(node):
            return keep(node) ? self : nil
        case let .split(o, a, b, r):
            switch (a.pruned(keep: keep), b.pruned(keep: keep)) {
            case let (first?, second?):
                return .split(orientation: o, first: first, second: second, ratio: r)
            case let (first?, nil): return first
            case let (nil, second?): return second
            case (nil, nil): return nil
            }
        }
    }

    /// Split the leaf with `id` in place: it keeps the first half, the
    /// new node takes the second.
    func splittingLeaf(
        id: String, orientation: Orientation, with node: ShellPaneNode, ratio: CGFloat = 0.5
    ) -> ShellLayout {
        switch self {
        case let .leaf(existing):
            guard existing.id == id else { return self }
            return .split(orientation: orientation, first: self, second: .leaf(node), ratio: ratio)
        case let .split(o, a, b, r):
            return .split(
                orientation: o,
                first: a.splittingLeaf(id: id, orientation: orientation, with: node, ratio: ratio),
                second: b.splittingLeaf(id: id, orientation: orientation, with: node, ratio: ratio),
                ratio: r)
        }
    }

    /// Splits are addressed by path from the root: "" is the root
    /// split, then "0"/"1" per side, "0.1", ... — divider drags name
    /// the split they belong to.
    func settingRatio(path: String, ratio: CGFloat) -> ShellLayout {
        let clamped = min(0.85, max(0.15, ratio))
        func walk(_ layout: ShellLayout, _ remaining: Substring) -> ShellLayout {
            guard case let .split(o, a, b, r) = layout else { return layout }
            if remaining.isEmpty {
                return .split(orientation: o, first: a, second: b, ratio: clamped)
            }
            let head = remaining.prefix(1)
            let rest = remaining.dropFirst(head == remaining ? 1 : 2)
            if head == "0" {
                return .split(orientation: o, first: walk(a, rest), second: b, ratio: r)
            }
            return .split(orientation: o, first: a, second: walk(b, rest), ratio: r)
        }
        return walk(self, Substring(path))
    }

    /// The dock: the right side of the root horizontal split when it
    /// holds only browser panels (cmux's _dockSplit shape).
    var dock: ShellLayout? {
        guard case let .split(o, _, second, _) = self, o == .horizontal,
              !second.isEmpty,
              second.leaves.allSatisfy({ node in
                  node.surfaces.allSatisfy { $0.kind == .browser }
              })
        else { return nil }
        return second
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
    /// Daemon session backing this workspace; nil in demo fixtures.
    var sessionId: UInt64?
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

final class ShellViewModel {
    var items: [ShellSidebarItem] = []
    var selectedWorkspaceId: String?
    var collapsedGroups: Set<String> = []
    var notifications: [ShellNotification] = []
    var sidebarVisible = true
    var rightSidebarVisible = false
    /// Which leaf has the cmux focus ring inside the selected workspace.
    var focusedPaneId: String?

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
        var collapsed = false
        for item in items {
            switch item {
            case let .group(id, _):
                collapsed = collapsedGroups.contains(id)
            case let .workspace(w):
                if !collapsed { out.append(w.id) }
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
        if let ws = workspace(id: id) {
            focusedPaneId = ws.layout.leaves.first?.id
        }
    }

    func focusPane(_ paneId: String) {
        focusedPaneId = paneId
    }

    func focusAdjacentPane(delta: Int) {
        guard let ws = selectedWorkspace else { return }
        let ids = ws.layout.leaves.map(\.id)
        guard !ids.isEmpty else { return }
        let cur = focusedPaneId.flatMap { ids.firstIndex(of: $0) } ?? 0
        focusedPaneId = ids[(cur + delta + ids.count) % ids.count]
    }

    /// The focused leaf's visible surface in the selected workspace.
    var focusedSurface: ShellSurface? {
        guard let ws = selectedWorkspace else { return nil }
        let leaves = ws.layout.leaves
        let node = leaves.first { $0.id == focusedPaneId } ?? leaves.first
        guard let node else { return nil }
        return node.surfaces.first { $0.id == node.selectedSurfaceId } ?? node.surfaces.first
    }

    @discardableResult
    func closeSelectedWorkspace() -> Bool {
        guard let id = selectedWorkspaceId else { return false }
        items.removeAll {
            if case let .workspace(w) = $0 { return w.id == id }
            return false
        }
        compactEmptyGroups()
        selectedWorkspaceId = visibleWorkspaceIds.first
        if let sid = selectedWorkspaceId, let ws = workspace(id: sid) {
            focusedPaneId = ws.layout.leaves.first?.id
        } else {
            focusedPaneId = nil
        }
        return true
    }

    /// Drop the focused leaf from the selected workspace (local chrome;
    /// the daemon-side close happens in the controller). The workspace
    /// row stays — its daemon session decides its lifetime.
    @discardableResult
    func closeFocusedPanel() -> Bool {
        guard let wsId = selectedWorkspaceId, let ws = workspace(id: wsId) else { return false }
        let target = focusedPaneId ?? ws.layout.leaves.first?.id
        guard let target else { return false }
        var closed = false
        mutateWorkspace(id: wsId) { ws in
            if let pruned = ws.layout.pruned(keep: { $0.id != target }) {
                ws.layout = pruned
                closed = true
                focusedPaneId = pruned.leaves.first?.id
            } else {
                ws.layout = .empty(ws.id)
                closed = true
                focusedPaneId = nil
            }
        }
        return closed
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

    func setSplitRatio(workspaceId: String, path: String, ratio: CGFloat) {
        mutateWorkspace(id: workspaceId) { ws in
            ws.layout = ws.layout.settingRatio(path: path, ratio: ratio)
        }
    }

    /// Replace a workspace's whole tree (shell-state restore).
    func setLayout(workspaceId: String, layout: ShellLayout) {
        mutateWorkspace(id: workspaceId) { ws in
            ws.layout = layout
        }
        if selectedWorkspaceId == workspaceId {
            focusedPaneId = layout.leaves.first?.id
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
        resortItems()
    }

    /// Wire a freshly spawned daemon pane into the selected workspace by
    /// splitting its focused leaf (cmux ⌘D / ⌘⇧D).
    func graftSplit(workspaceId: String, orientation: ShellLayout.Orientation, paneId: UInt64) {
        let surface = ShellSurface(
            id: "pane-\(paneId)", title: "pane \(paneId)", kind: .terminal, paneId: paneId)
        let node = ShellPaneNode(id: "p-\(paneId)", surfaces: [surface], selectedSurfaceId: surface.id)
        mutateWorkspace(id: workspaceId) { ws in
            if ws.layout.isEmpty {
                ws.layout = .leaf(node)
            } else if let target = focusedPaneId ?? ws.layout.leaves.first?.id {
                ws.layout = ws.layout.splittingLeaf(id: target, orientation: orientation, with: node)
            }
        }
        focusedPaneId = node.id
    }

    /// A daemon pane is gone (child exited, pane removed): drop its
    /// leaves from every workspace, collapsing splits to the survivor.
    func removePaneEverywhere(_ pane: UInt64) {
        for id in workspaceIds {
            mutateWorkspace(id: id) { ws in
                let keep: (ShellPaneNode) -> Bool = { node in
                    !node.surfaces.contains { $0.paneId == pane } || node.surfaces.count > 1
                }
                var layout = ws.layout.pruned(keep: keep) ?? .empty(ws.id)
                layout = layout.mapLeaves { node in
                    var n = node
                    n.surfaces.removeAll { $0.paneId == pane }
                    if !n.surfaces.contains(where: { $0.id == n.selectedSurfaceId }) {
                        n.selectedSurfaceId = n.surfaces.first?.id ?? ""
                    }
                    return n
                }
                ws.layout = layout
                if let focusedPaneId, !layout.leaves.contains(where: { $0.id == focusedPaneId }) {
                    self.focusedPaneId = layout.leaves.first?.id
                }
            }
        }
    }

    /// Rename every surface bound to a daemon pane (live OSC titles).
    func setSurfaceTitle(paneId: UInt64, title: String) {
        for id in workspaceIds {
            mutateWorkspace(id: id) { ws in
                ws.layout = ws.layout.mapLeaves { node in
                    var n = node
                    for i in n.surfaces.indices where n.surfaces[i].paneId == paneId {
                        n.surfaces[i].title = title
                    }
                    return n
                }
            }
        }
    }

    /// Browser page titles live on the dock panel's surface (the
    /// workspace title belongs to the session).
    func setBrowserTitle(pane: UInt64, title: String) {
        setSurfaceTitle(paneId: pane, title: title)
    }

    /// The workspace's leading terminal pane — its process/agent title
    /// drives the row label (cmux follows the active pane).
    func leadPaneId(ofSession sessionId: UInt64) -> UInt64? {
        guard let ws = workspace(id: "sess-\(sessionId)") else { return nil }
        for node in ws.layout.leaves {
            if let pane = node.surfaces.first(where: { $0.kind == .terminal })?.paneId {
                return pane
            }
        }
        return nil
    }

    /// Retitle a workspace row live (dynamic pane title between full
    /// refreshes). No-op if the workspace is gone.
    func setWorkspaceTitle(sessionId: UInt64, title: String) {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        mutateWorkspace(id: "sess-\(sessionId)") { $0.title = t }
    }

    /// Daemon pane ids referenced by a layout's surfaces.
    func daemonPaneIds(of layout: ShellLayout) -> [UInt64] {
        layout.daemonPaneIds
    }

    /// cmux ⌘D / ⌘⇧D — visual split only (demo / local layout).
    func splitSelected(orientation: ShellLayout.Orientation) {
        guard let id = selectedWorkspaceId else { return }
        let surface = ShellSurface(
            id: "s-\(UUID().uuidString.prefix(6))", title: "zsh", kind: .terminal, paneId: nil)
        let node = ShellPaneNode(
            id: "split-\(UUID().uuidString.prefix(6))",
            surfaces: [surface], selectedSurfaceId: surface.id)
        mutateWorkspace(id: id) { ws in
            if ws.layout.isEmpty {
                ws.layout = .leaf(node)
            } else if let target = focusedPaneId ?? ws.layout.leaves.first?.id {
                ws.layout = ws.layout.splittingLeaf(id: target, orientation: orientation, with: node)
            }
        }
        focusedPaneId = node.id
    }

    /// Demo/local: spawn a workspace under a group (UI only).
    func addWorkspace(inGroup groupId: String) {
        let id = "ws-\(UUID().uuidString.prefix(6))"
        let surface = ShellSurface(id: "s1", title: "zsh", kind: .terminal, paneId: nil)
        let ws = ShellWorkspace(
            id: id,
            title: "New workspace",
            sessionId: nil,
            cwd: "~",
            branch: nil,
            branchDirty: false,
            ports: [],
            attention: .none,
            notificationSnippet: nil,
            unreadCount: 0,
            isPinned: false,
            layout: .leaf(ShellPaneNode(id: "p1", surfaces: [surface], selectedSurfaceId: surface.id)))

        var insertAt: Int?
        for (i, item) in items.enumerated() {
            if case let .group(gid, _) = item, gid == groupId {
                var j = i + 1
                while j < items.count {
                    if case .group = items[j] { break }
                    j += 1
                }
                insertAt = j
            }
        }
        if let insertAt {
            items.insert(.workspace(ws), at: insertAt)
        } else {
            items.append(.group(id: groupId, title: groupId.uppercased()))
            items.append(.workspace(ws))
        }
        selectWorkspace(id)
    }

    func renameWorkspace(_ id: String, title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        mutateWorkspace(id: id) { $0.title = t }
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
            sessionId: nil,
            cwd: "~",
            branch: nil,
            branchDirty: false,
            ports: [],
            attention: .none,
            notificationSnippet: nil,
            unreadCount: 0,
            isPinned: false,
            layout: .leaf(ShellPaneNode(id: "p1", surfaces: [surface], selectedSurfaceId: surface.id)))
        items.append(.group(id: gid, title: title))
        items.append(.workspace(anchor))
        selectWorkspace(anchor.id)
    }

    private func resortItems() {
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

    // MARK: Live mapping (sessions → workspaces)

    /// One workspace per daemon session, cmux-style. The layout is the
    /// previous tree pruned to still-live panes, with new panes grafted
    /// in: terminals split the terminal side, browsers stack in the
    /// dock column on the right.
    func applyLive(
        sessions: [(id: UInt64, title: String, panes: [UInt64], browsers: [UInt64], exited: [UInt64])],
        bells: Set<UInt64>,
        exited: Set<UInt64>,
        browserTitles: [UInt64: String] = [:],
        paneTitles: [UInt64: String] = [:],
        agentActivity: [UInt64: String?] = [:]
    ) {
        // A session with no panes and no browsers is an empty husk
        // (all its panes exited) — not a workspace worth a row.
        let live = sessions.filter { !($0.panes.isEmpty && $0.browsers.isEmpty) }
        var next: [ShellSidebarItem] = []
        if !live.isEmpty {
            next.append(.group(id: "sessions", title: "WORKSPACES"))
        }
        for s in live {
            let id = "sess-\(s.id)"
            let prev = workspace(id: id)
            let live = Set(s.panes + s.browsers)

            var layout = prev?.layout.pruned { node in
                node.surfaces.contains { surf in
                    surf.paneId.map(live.contains) ?? false
                }
            }
            let present = Set(layout?.daemonPaneIds ?? [])
            for pane in s.panes where !present.contains(pane) {
                layout = Self.graftTerminal(layout, pane: pane, title: paneTitles[pane])
            }
            for pane in s.browsers where !present.contains(pane) {
                layout = Self.graftBrowser(layout, pane: pane, title: browserTitles[pane])
            }
            var tree = layout ?? .empty("\(s.id)")
            tree = tree.mapLeaves { node in
                var n = node
                for i in n.surfaces.indices {
                    guard let pid = n.surfaces[i].paneId else { continue }
                    switch n.surfaces[i].kind {
                    case .terminal:
                        if let t = paneTitles[pid] { n.surfaces[i].title = t }
                    case .browser:
                        if let t = browserTitles[pid], !t.isEmpty { n.surfaces[i].title = t }
                    case .placeholder:
                        break
                    }
                }
                return n
            }

            // Workspace status aggregates its panes, cmux-row style:
            // any bell → needs attention; any agent → working.
            let hasBell = s.panes.contains(where: bells.contains)
            let agents = s.panes.filter { agentActivity.keys.contains($0) }
            let attention: ShellAttention =
                hasBell ? .needsAttention : (!agents.isEmpty ? .working : .none)
            let activity = agents.compactMap { agentActivity[$0] ?? nil }.first

            // The row title follows the pane live (cmux): the leading
            // terminal's process/agent (paneTitles = OSC title → agent
            // name → command → cwd), then a browser-only workspace's
            // page title, then the session name as the last resort.
            func nonEmpty(_ value: String?) -> String? {
                let trimmed = value?.trimmingCharacters(in: .whitespaces)
                return (trimmed?.isEmpty == false) ? trimmed : nil
            }
            let leadTitle = nonEmpty(s.panes.first.flatMap { paneTitles[$0] })
            let browserTitle = nonEmpty(s.browsers.first.flatMap { browserTitles[$0] })
            let sessionTitle = s.title.isEmpty ? "workspace \(s.id)" : s.title
            let wsTitle = leadTitle ?? prev?.title ?? browserTitle ?? sessionTitle

            next.append(.workspace(ShellWorkspace(
                id: id,
                title: wsTitle,
                sessionId: s.id,
                cwd: prev?.cwd,
                branch: prev?.branch,
                branchDirty: prev?.branchDirty ?? false,
                ports: prev?.ports ?? [],
                attention: attention,
                notificationSnippet: activity ?? latestNotificationSnippet(for: id),
                unreadCount: hasBell ? max(1, prev?.unreadCount ?? 1) : (prev?.unreadCount ?? 0),
                isPinned: prev?.isPinned ?? false,
                layout: tree)))
        }

        let previous = selectedWorkspaceId
        items = next
        if let previous, workspace(id: previous) != nil {
            selectedWorkspaceId = previous
        } else {
            selectedWorkspaceId = workspaceIds.first
        }
        if let sid = selectedWorkspaceId, let ws = workspace(id: sid),
           !ws.layout.leaves.contains(where: { $0.id == focusedPaneId }) {
            focusedPaneId = ws.layout.leaves.first?.id
        }
    }

    static func graftTerminal(_ layout: ShellLayout?, pane: UInt64, title: String?) -> ShellLayout {
        let surface = ShellSurface(
            id: "pane-\(pane)", title: title ?? "pane \(pane)", kind: .terminal, paneId: pane)
        let node = ShellPaneNode(id: "p-\(pane)", surfaces: [surface], selectedSurfaceId: surface.id)
        guard let layout, !layout.isEmpty else { return .leaf(node) }
        // Terminals join the terminal side, leaving the dock column
        // alone (cmux keeps the dock pinned right).
        if case let .split(o, first, second, r) = layout, layout.dock != nil {
            return .split(
                orientation: o,
                first: graftTerminal(first, pane: pane, title: title),
                second: second, ratio: r)
        }
        if layout.leaves.allSatisfy({ $0.surfaces.allSatisfy { $0.kind == .browser } }) {
            // Browser-only workspace: the terminal takes the left.
            return .split(orientation: .horizontal, first: .leaf(node), second: layout, ratio: 0.55)
        }
        return .split(orientation: .horizontal, first: layout, second: .leaf(node), ratio: 0.5)
    }

    static func graftBrowser(_ layout: ShellLayout?, pane: UInt64, title: String?) -> ShellLayout {
        let surface = ShellSurface(
            id: "web-\(pane)", title: title ?? "browser", kind: .browser, paneId: pane)
        let node = ShellPaneNode(id: "w-\(pane)", surfaces: [surface], selectedSurfaceId: surface.id)
        guard let layout, !layout.isEmpty else { return .leaf(node) }
        // A dock already exists → stack the new browser under it;
        // otherwise the browser docks as the right column (cmux).
        if case let .split(o, first, second, r) = layout, layout.dock != nil {
            return .split(
                orientation: o,
                first: first,
                second: .split(orientation: .vertical, first: second, second: .leaf(node), ratio: 0.5),
                ratio: r)
        }
        return .split(orientation: .horizontal, first: layout, second: .leaf(node), ratio: 0.55)
    }

    /// Overlay cwd / branch / dirty / ports from `panes-meta` onto
    /// workspaces that own those daemon pane ids.
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
            if m.agent != nil {
                if w.attention == ShellAttention.none { w.attention = .working }
                if let activity = m.activity, !activity.isEmpty {
                    w.notificationSnippet = activity
                }
            }
            return .workspace(w)
        }
    }

    private func primaryTerminalPaneId(of w: ShellWorkspace) -> UInt64? {
        for node in w.layout.leaves {
            let terminals = node.surfaces.filter { $0.kind == .terminal }
            if let pane = (terminals.first { $0.id == node.selectedSurfaceId } ?? terminals.first)?.paneId {
                return pane
            }
        }
        return nil
    }

    /// Full cmux-like fixture for `ZIDE_UI_DEMO=1`.
    static func demo() -> ShellViewModel {
        let vm = ShellViewModel()

        let agentPane = ShellPaneNode(
            id: "ap",
            surfaces: [ShellSurface(id: "a1", title: "claude", kind: .terminal, paneId: nil)],
            selectedSurfaceId: "a1")
        let browserPane = ShellPaneNode(
            id: "bp",
            surfaces: [ShellSurface(id: "b1", title: "PR", kind: .browser, paneId: nil)],
            selectedSurfaceId: "b1")

        let agent = ShellWorkspace(
            id: "task-1",
            title: "Start phase 1 PTY layer",
            sessionId: nil,
            cwd: "~/zide",
            branch: "zide/pty-layer",
            branchDirty: true,
            ports: [],
            attention: .needsAttention,
            notificationSnippet: "Claude Code needs input",
            unreadCount: 1,
            isPinned: true,
            layout: .split(
                orientation: .horizontal, first: .leaf(agentPane), second: .leaf(browserPane),
                ratio: 0.55))

        let dev = ShellWorkspace(
            id: "ws-dev",
            title: "~/zide",
            sessionId: nil,
            cwd: "~/zide",
            branch: "main",
            branchDirty: false,
            ports: [],
            attention: .none,
            notificationSnippet: nil,
            unreadCount: 0,
            isPinned: false,
            layout: .split(
                orientation: .horizontal,
                first: .leaf(ShellPaneNode(
                    id: "dl",
                    surfaces: [ShellSurface(id: "d1", title: "zsh", kind: .terminal, paneId: nil)],
                    selectedSurfaceId: "d1")),
                second: .leaf(ShellPaneNode(
                    id: "dr",
                    surfaces: [ShellSurface(id: "d3", title: "~/zide", kind: .terminal, paneId: nil)],
                    selectedSurfaceId: "d3")),
                ratio: 0.5))

        let qemu = ShellWorkspace(
            id: "ws-qemu",
            title: "QEMU Valorant Research",
            sessionId: nil,
            cwd: "~",
            branch: nil,
            branchDirty: false,
            ports: [3389],
            attention: .working,
            notificationSnippet: nil,
            unreadCount: 2,
            isPinned: false,
            layout: .leaf(ShellPaneNode(
                id: "qp",
                surfaces: [ShellSurface(id: "q1", title: "qemu", kind: .terminal, paneId: nil)],
                selectedSurfaceId: "q1")))

        vm.items = [
            .group(id: "sessions", title: "WORKSPACES"),
            .workspace(agent),
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
        ]
        return vm
    }
}
