import AppKit
import SwiftUI
import UniformTypeIdentifiers

private extension Sequence {
    func uniqued<HashableValue: Hashable>(by keyPath: KeyPath<Element, HashableValue>) -> [Element] {
        var seen: Set<HashableValue> = []
        return filter { seen.insert($0[keyPath: keyPath]).inserted }
    }
}

private enum RemoteDragItemCodec {
    nonisolated static let itemType = UTType(exportedAs: AppConfiguration.remoteDragItemTypeIdentifier, conformingTo: .data)
    nonisolated static let textPrefix = AppConfiguration.remoteDragTextPrefix
    nonisolated static let collectionTextPrefix = AppConfiguration.remoteDragCollectionTextPrefix

    nonisolated static func encode(id: String, name: String, pathDescription: String, isDirectory: Bool) -> Data? {
        let payload: [String: Any] = [
            "id": id,
            "name": name,
            "pathDescription": pathDescription,
            "isDirectory": isDirectory
        ]
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    nonisolated static func decode(data: Data) -> RemoteDragItem? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = object["id"] as? String,
            let name = object["name"] as? String,
            let pathDescription = object["pathDescription"] as? String,
            let isDirectory = object["isDirectory"] as? Bool
        else {
            return nil
        }

        return RemoteDragItem(
            id: id,
            name: name,
            pathDescription: pathDescription,
            isDirectory: isDirectory
        )
    }

    nonisolated static func decode(text: String) -> RemoteDragItem? {
        guard text.hasPrefix(textPrefix) else { return nil }
        let jsonString = String(text.dropFirst(textPrefix.count))
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return decode(data: data)
    }

    nonisolated static func encodeCollection(_ items: [RemoteDragItem]) -> Data? {
        let payload = items.map {
            [
                "id": $0.id,
                "name": $0.name,
                "pathDescription": $0.pathDescription,
                "isDirectory": $0.isDirectory
            ] as [String: Any]
        }
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    nonisolated static func decodeCollection(data: Data) -> [RemoteDragItem]? {
        guard
            let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return nil
        }

        return objects.compactMap { object in
            guard
                let id = object["id"] as? String,
                let name = object["name"] as? String,
                let pathDescription = object["pathDescription"] as? String,
                let isDirectory = object["isDirectory"] as? Bool
            else {
                return nil
            }

            return RemoteDragItem(
                id: id,
                name: name,
                pathDescription: pathDescription,
                isDirectory: isDirectory
            )
        }
    }

    nonisolated static func decodeCollection(text: String) -> [RemoteDragItem]? {
        guard text.hasPrefix(collectionTextPrefix) else { return nil }
        let jsonString = String(text.dropFirst(collectionTextPrefix.count))
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return decodeCollection(data: data)
    }
}

private enum LocalDragItemCodec {
    nonisolated static let itemType = UTType(exportedAs: AppConfiguration.localDragItemTypeIdentifier, conformingTo: .data)

    nonisolated static func encode(_ urls: [URL]) -> Data? {
        let payload = urls.map { $0.standardizedFileURL.path(percentEncoded: false) }
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    nonisolated static func decode(data: Data) -> [URL]? {
        guard let paths = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return nil
        }
        return paths.map { URL(fileURLWithPath: $0, isDirectory: false).standardizedFileURL }
    }
}

struct FilePierWorkspaceView: View {
    @ObservedObject var state: FilePierWorkspaceState

    var body: some View {
        NavigationSplitView {
            SidebarView(state: state)
                .navigationSplitViewColumnWidth(min: 230, ideal: 260)
        } detail: {
            VStack(spacing: 0) {
                if let feedback = state.transferFeedback {
                    TransferFeedbackBanner(feedback: feedback) {
                        state.dismissTransferFeedback()
                    }
                }

                HSplitView {
                    localBrowserPane
                    remoteBrowserPane

                    if state.showsInspector {
                        inspectorPane
                    }
                }
            }
            .toolbar {
                ToolbarContentView(state: state)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .sheet(item: $state.renameRequest) { request in
                RenameSheet(
                    request: request,
                    onCancel: {
                        state.cancelRenameRequest()
                    },
                    onCommit: { updatedName in
                        state.renameRequest?.proposedName = updatedName
                        state.submitRenameRequest()
                    }
                )
            }
            .sheet(item: $state.createFolderRequest) { request in
                CreateFolderSheet(
                    request: request,
                    onCancel: {
                        state.cancelCreateFolderRequest()
                    },
                    onCommit: { updatedName in
                        state.createFolderRequest?.proposedName = updatedName
                        state.submitCreateFolderRequest()
                    }
                )
            }
            .sheet(item: $state.favoriteRenameRequest) { request in
                FavoriteRenameSheet(
                    request: request,
                    onCancel: {
                        state.cancelFavoriteRenameRequest()
                    },
                    onCommit: { updatedName in
                        state.favoriteRenameRequest?.proposedName = updatedName
                        state.submitFavoriteRenameRequest()
                    }
                )
            }
            .sheet(isPresented: $state.showsConnectionSheet) {
                ConnectionSheet(
                    servers: state.servers,
                    selectedServer: state.selectedServer,
                    draft: $state.connectionDraft,
                    currentLocalPath: state.localPathDisplayName,
                    currentRemotePath: state.remoteLocation.remotePath,
                    hasSavedPassword: state.hasSavedPasswordForSelectedServer,
                    status: state.remoteSessionStatus,
                    onSelectServer: { server in
                        state.selectServer(server)
                    },
                    onSave: {
                        _ = state.saveConnectionDraftAsSite()
                    },
                    onClearSavedPassword: {
                        state.clearSavedPasswordFromDraft()
                    },
                    onCancel: {
                        state.showsConnectionSheet = false
                    },
                    onConnect: {
                        state.connectRemoteSession()
                    }
                )
            }
            .sheet(isPresented: $state.showsRemotePathSheet) {
                RemotePathSheet(
                    currentPath: state.remoteLocation.remotePath,
                    draft: $state.remotePathDraft,
                    homePath: state.remoteHomePath,
                    isBusy: state.isRemoteBusy,
                    onCancel: {
                        state.showsRemotePathSheet = false
                    },
                    onJumpHome: {
                        state.jumpToRemoteHomeDirectory()
                    },
                    onJumpRoot: {
                        state.jumpToRemoteRootDirectory()
                    },
                    onCommit: {
                        state.navigateToRemotePath(state.remotePathDraft)
                    }
                )
            }
            .confirmationDialog(
                "Delete Item?",
                isPresented: Binding(
                    get: { state.deleteRequest != nil },
                    set: { isPresented in
                        if !isPresented {
                            state.cancelDeleteRequest()
                        }
                    }
                ),
                presenting: state.deleteRequest
            ) { request in
                Button(String(localized: "Delete \(request.itemName)"), role: .destructive) {
                    state.confirmDeleteRequest()
                }
                Button("Cancel", role: .cancel) {
                    state.cancelDeleteRequest()
                }
            } message: { request in
                Text(String(localized: "This permanently deletes \(request.itemName) from the current pane."))
            }
            .confirmationDialog(
                "Delete Folder Contents?",
                isPresented: Binding(
                    get: { state.nonEmptyFolderDeleteRequest != nil },
                    set: { isPresented in
                        if !isPresented {
                            state.cancelNonEmptyFolderDeleteRequest()
                        }
                    }
                ),
                presenting: state.nonEmptyFolderDeleteRequest
            ) { request in
                Button(String(localized: "Delete \(request.itemName) and Contents"), role: .destructive) {
                    state.confirmNonEmptyFolderDeleteRequest()
                }
                Button("Cancel", role: .cancel) {
                    state.cancelNonEmptyFolderDeleteRequest()
                }
            } message: { request in
                Text(String(localized: "\(request.itemName) is not empty. Delete this folder and everything inside it?"))
            }
            .confirmationDialog(
                "Delete Site?",
                isPresented: Binding(
                    get: { state.deleteServerRequest != nil },
                    set: { isPresented in
                        if !isPresented {
                            state.cancelDeleteServerRequest()
                        }
                    }
                ),
                presenting: state.deleteServerRequest
            ) { request in
                Button(String(localized: "Delete \(request.server.name)"), role: .destructive) {
                    state.confirmDeleteServerRequest()
                }
                Button("Cancel", role: .cancel) {
                    state.cancelDeleteServerRequest()
                }
            } message: { request in
                Text(String(localized: "This removes \(request.server.name) from saved sites and deletes its stored password."))
            }
            .confirmationDialog(
                state.transferConflictResolutionRequest?.operationTitle ?? "Transfer Conflict",
                isPresented: Binding(
                    get: { state.transferConflictResolutionRequest != nil },
                    set: { isPresented in
                        if !isPresented {
                            state.cancelTransferConflictResolution()
                        }
                    }
                ),
                presenting: state.transferConflictResolutionRequest
            ) { request in
                Button("Keep Both") {
                    state.resolveTransferConflict(with: .rename)
                }
                Button("Replace") {
                    state.resolveTransferConflict(with: .overwrite)
                }
                Button("Cancel", role: .cancel) {
                    state.cancelTransferConflictResolution()
                }
            } message: { request in
                Text(conflictResolutionMessage(for: request))
            }
        }
    }

    private var inspectorPane: some View {
        InspectorView(
            focusedPane: state.focusedPane,
            selectedServer: state.selectedServer,
            activeRemoteServer: state.activeRemoteServer,
            showsConnectionSheet: state.showsConnectionSheet,
            connectionDraft: state.connectionDraft,
            hasSavedPasswordForSelectedServer: state.hasSavedPasswordForSelectedServer,
            remoteSessionStatus: state.remoteSessionStatus,
            localPath: state.localPathDisplayName,
            remotePath: state.remotePathDisplayName,
            remoteHomePath: state.remoteHomePath,
            favoriteCount: state.favoritePlaces.count,
            maxConcurrentTransfers: state.maxConcurrentTransfers,
            item: state.selectedItem,
            recentTransfers: state.recentTransfers,
            highlightsActivity: state.isRemoteBusy,
            canRetryTransfer: state.canRetryTransferActivity,
            canCancelTransfer: state.canCancelTransferActivity,
            canPauseTransfer: state.canPauseTransferActivity,
            canResumeTransfer: state.canResumeTransferActivity,
            hasCompletedTransfers: state.hasCompletedTransferActivities,
            retryTransfer: state.retryTransferActivity,
            cancelTransfer: state.cancelTransferActivity,
            pauseTransfer: state.pauseTransferActivity,
            resumeTransfer: state.resumeTransferActivity,
            clearCompletedTransfers: state.clearCompletedTransferActivities
        )
        .frame(minWidth: 260, idealWidth: 280, maxWidth: 320)
    }

    private var localBrowserPane: some View {
        BrowserPaneView(
            title: BrowserPane.local.title,
            path: state.localPathDisplayName,
            items: state.localItems,
            density: state.browserDensity,
            selectedItemIDs: $state.selectedLocalItemIDs,
            selectedItemID: $state.selectedLocalItemID,
            focusedPane: $state.focusedPane,
            errorMessage: state.localErrorMessage,
            canNavigateUp: state.canNavigateToLocalParent,
            remoteSessionStatus: state.remoteSessionStatus,
            isNetworkReachable: state.isNetworkReachable,
            isBusy: false,
            sortOption: state.localBrowserSort,
            pane: .local,
            showsChooseDirectoryButton: true,
            showsRemotePathButton: false
        ) {
            state.navigateToLocalParent()
        } onRefresh: {
            state.refreshLocalDirectory()
        } onOpenSelection: {
            state.openLocalSelection()
        } onTransferSelection: {
            state.copyFocusedSelectionToOtherPane()
        } onCreateFolder: {
            state.beginCreatingFolderInFocusedPane()
        } onSelectionSetChange: { ids in
            state.selectLocalItems(ids: ids)
        } onSelectionChange: { id in
            state.selectLocalItem(id: id)
        } onDropLocalItems: { items in
            state.handleDrop(of: items, into: .local)
        } onDropRemoteItems: { items in
            state.handleRemoteDrop(of: items, into: .local)
        } onDropLocalItemsIntoDirectory: { items, itemID in
            state.handleDrop(of: items, into: .local, targetItemID: itemID)
        } onDropRemoteItemsIntoDirectory: { items, itemID in
            state.handleRemoteDrop(of: items, into: .local, targetItemID: itemID)
        } onBeginDrag: { items in
            state.beginLocalDrag(items: items)
        } onBeginRename: { itemID in
            state.beginRenaming(itemID: itemID, in: .local)
        } onRequestDelete: { itemID in
            state.requestDelete(itemID: itemID, in: .local)
        } onChooseDirectory: {
            state.chooseLocalDirectory()
        } onPresentRemotePathSheet: {
        } onJumpRemoteHome: {
        } onJumpRemoteRoot: {
        } onSortChange: { sort in
            state.setBrowserSort(sort, for: .local)
        }
    }

    private var remoteBrowserPane: some View {
        BrowserPaneView(
            title: state.activeRemoteServer?.name ?? state.selectedServer?.name ?? BrowserPane.remote.title,
            path: state.remotePathDisplayName,
            items: state.remoteItems,
            density: state.browserDensity,
            selectedItemIDs: $state.selectedRemoteItemIDs,
            selectedItemID: $state.selectedRemoteItemID,
            focusedPane: $state.focusedPane,
            errorMessage: state.remoteErrorMessage,
            canNavigateUp: state.canNavigateToRemoteParent,
            remoteSessionStatus: state.remoteSessionStatus,
            isNetworkReachable: state.isNetworkReachable,
            isBusy: state.isRemoteConnectionBusy,
            sortOption: state.remoteBrowserSort,
            pane: .remote,
            showsChooseDirectoryButton: false,
            showsRemotePathButton: true
        ) {
            state.navigateToRemoteParent()
        } onRefresh: {
            state.refreshRemoteDirectory()
        } onOpenSelection: {
            state.openRemoteSelection()
        } onTransferSelection: {
            state.copyFocusedSelectionToOtherPane()
        } onCreateFolder: {
            state.beginCreatingFolderInFocusedPane()
        } onSelectionSetChange: { ids in
            state.selectRemoteItems(ids: ids)
        } onSelectionChange: { id in
            state.selectRemoteItem(id: id)
        } onDropLocalItems: { items in
            state.handleDrop(of: state.resolveLocalDragURLs(fallingBackTo: items), into: .remote)
        } onDropRemoteItems: { items in
            state.handleRemoteDrop(of: items, into: .remote)
        } onDropLocalItemsIntoDirectory: { items, itemID in
            state.handleDrop(
                of: state.resolveLocalDragURLs(fallingBackTo: items),
                into: .remote,
                targetItemID: itemID
            )
        } onDropRemoteItemsIntoDirectory: { items, itemID in
            state.handleRemoteDrop(of: items, into: .remote, targetItemID: itemID)
        } onBeginDrag: { _ in
        } onBeginRename: { itemID in
            state.beginRenaming(itemID: itemID, in: .remote)
        } onRequestDelete: { itemID in
            state.requestDelete(itemID: itemID, in: .remote)
        } onChooseDirectory: {
        } onPresentRemotePathSheet: {
            state.presentRemotePathSheet()
        } onJumpRemoteHome: {
            state.jumpToRemoteHomeDirectory()
        } onJumpRemoteRoot: {
            state.jumpToRemoteRootDirectory()
        } onSortChange: { sort in
            state.setBrowserSort(sort, for: .remote)
        }
    }

    private func conflictResolutionMessage(for request: TransferConflictResolutionRequest) -> String {
        let names = request.conflictingNames.prefix(3).joined(separator: ", ")
        let suffix = request.conflictingNames.count > 3 ? String(localized: " and \(request.conflictingNames.count - 3) more") : ""
        return String(localized: "The destination already contains \(names)\(suffix) in \(request.destinationSummary).")
    }
}
private struct TransferFeedbackBanner: View {
    let feedback: TransferFeedback
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: feedback.status.systemImage)
                .foregroundStyle(feedback.status == .failed ? .red : .green)
            Text(feedback.message)
                .font(.subheadline)
            Spacer()
            if feedback.status == .failed {
                ErrorCopyButton(message: feedback.message)
            }
            Button(String(localized: "Dismiss"), action: onDismiss)
                .buttonStyle(.link)
                .help(String(localized: "Hide this transfer result banner."))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(feedback.status == .failed ? Color.red.opacity(0.08) : Color.green.opacity(0.08))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct SidebarView: View {
    @ObservedObject var state: FilePierWorkspaceState
    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        List(selection: .constant(state.selectedServer?.id)) {
            if !state.favoritePlaces.isEmpty {
                Section("Favorites") {
                    ForEach(state.favoritePlaces) { place in
                        placeRow(place)
                            .contextMenu {
                                Button("Open in Local", systemImage: "folder") {
                                    state.openPlace(place)
                                }

                                Button("Rename Favorite", systemImage: "pencil") {
                                    state.beginRenamingFavorite(place)
                                }

                                Button("Move Up", systemImage: "arrow.up") {
                                    state.moveFavorite(place, by: -1)
                                }
                                .disabled(state.favoritePlaces.first?.id == place.id)

                                Button("Move Down", systemImage: "arrow.down") {
                                    state.moveFavorite(place, by: 1)
                                }
                                .disabled(state.favoritePlaces.last?.id == place.id)

                                Divider()

                                Button("Remove Favorite", role: .destructive) {
                                    state.removeFavorite(place)
                                }
                            }
                    }
                    .onMove(perform: state.moveFavorite)
                }
            }

            Section {
                Button {
                    state.beginCreatingSite()
                } label: {
                    Label("Quick Connect", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
                .help("Create a new site or connect to a host that is not saved yet.")

                ForEach(state.servers) { server in
                    HStack(spacing: 10) {
                        Button {
                            state.selectServer(server)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: server.systemImage)
                                    .foregroundStyle(accentColor(named: server.accentName))
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(server.name)
                                        if state.connectionState(for: server) != .idle {
                                            siteStatusBadge(for: server)
                                        }
                                    }
                                    Text(siteSubtitle(for: server))
                                        .font(.caption)
                                        .foregroundStyle(siteSubtitleColor(for: server))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                state.selectServer(server)
                                state.connectRemoteSession()
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Select \(server.name). Double-click to connect.")
                        .contextMenu {
                            Button {
                                state.selectServer(server)
                                state.connectRemoteSession()
                            } label: {
                                Label("Connect", systemImage: "bolt.horizontal.circle")
                            }

                            Button {
                                state.selectServer(server)
                                state.editSelectedSite()
                            } label: {
                                Label("Edit Site", systemImage: "slider.horizontal.3")
                            }

                            Button {
                                state.duplicateServer(server)
                            } label: {
                                Label("Copy Site", systemImage: "doc.on.doc")
                            }

                            Divider()

                            Button(role: .destructive) {
                                state.requestDeleteServer(server)
                            } label: {
                                Label("Delete Site", systemImage: "trash")
                            }
                        }

                        Button {
                            state.selectServer(server)
                            state.connectRemoteSession()
                        } label: {
                            Image(systemName: "bolt.horizontal.circle.fill")
                                .foregroundStyle(accentColor(named: server.accentName))
                        }
                        .buttonStyle(.borderless)
                        .disabled(state.isRemoteConnectionBusy)
                        .help("Connect to \(server.name).")
                    }
                }
            } header: {
                HStack {
                    Text("Sites")
                    Spacer()
                    Text("\(state.servers.count)")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Local") {
                ForEach(state.builtInPlaces) { place in
                    placeRow(place)
                }
            }

            Section("Workspace") {
                ForEach(state.workspacePlaces) { place in
                    placeRow(place)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func accentColor(named name: String) -> Color {
        switch name {
        case "Orange": .orange
        case "Blue": .blue
        case "Green": .green
        default: .accentColor
        }
    }

    private func siteSubtitle(for server: ServerProfile) -> String {
        switch state.connectionState(for: server) {
        case .idle:
            if let usage = state.siteUsage(for: server) {
                let relative = Self.relativeDateFormatter.localizedString(for: usage.lastConnectedAt, relativeTo: Date())
                return String(localized: "Last connected \(relative) · \(usage.lastConnectionSummary)")
            }
            return "\(server.connectionKind.title) · \(server.username)@\(server.endpoint)"
        case .connecting:
            return String(localized: "Connecting to \(server.endpoint)…")
        case .connected(let details):
            return details
        case .failed(let message):
            return message
        }
    }

    private func siteSubtitleColor(for server: ServerProfile) -> Color {
        switch state.connectionState(for: server) {
        case .failed:
            return .red
        default:
            return .secondary
        }
    }

    @ViewBuilder
    private func siteStatusBadge(for server: ServerProfile) -> some View {
        let status = state.connectionState(for: server)
        Text(status.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(siteStatusColor(for: status))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(siteStatusColor(for: status).opacity(0.14), in: Capsule())
    }

    private func siteStatusColor(for status: SiteConnectionState) -> Color {
        switch status {
        case .idle:
            return .secondary
        case .connecting:
            return .orange
        case .connected:
            return .green
        case .failed:
            return .red
        }
    }

    @ViewBuilder
    private func placeRow(_ place: PlaceItem) -> some View {
        Button {
            state.openPlace(place)
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.title)
                    Text(place.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } icon: {
                Image(systemName: place.systemImage)
                    .foregroundStyle(place.isFavorite ? .yellow : .secondary)
            }
        }
        .buttonStyle(.plain)
        .help(place.subtitle)
    }
}

private struct BrowserPaneView: View {
    let title: String
    let path: String
    let items: [BrowserItem]
    let density: BrowserDensityMode
    @Binding var selectedItemIDs: Set<BrowserItem.ID>
    @Binding var selectedItemID: BrowserItem.ID?
    @Binding var focusedPane: BrowserPane
    let errorMessage: String?
    let canNavigateUp: Bool
    let remoteSessionStatus: RemoteSessionStatus
    let isNetworkReachable: Bool
    let isBusy: Bool
    let sortOption: BrowserSortOption
    let pane: BrowserPane
    let showsChooseDirectoryButton: Bool
    let showsRemotePathButton: Bool
    let onNavigateUp: () -> Void
    let onRefresh: () -> Void
    let onOpenSelection: () -> Void
    let onTransferSelection: () -> Void
    let onCreateFolder: () -> Void
    let onSelectionSetChange: (Set<BrowserItem.ID>) -> Void
    let onSelectionChange: (BrowserItem.ID?) -> Void
    let onDropLocalItems: ([URL]) -> Bool
    let onDropRemoteItems: ([RemoteDragItem]) -> Bool
    let onDropLocalItemsIntoDirectory: ([URL], BrowserItem.ID) -> Bool
    let onDropRemoteItemsIntoDirectory: ([RemoteDragItem], BrowserItem.ID) -> Bool
    let onBeginDrag: ([BrowserItem]) -> Void
    let onBeginRename: (BrowserItem.ID) -> Void
    let onRequestDelete: (BrowserItem.ID) -> Void
    let onChooseDirectory: () -> Void
    let onPresentRemotePathSheet: () -> Void
    let onJumpRemoteHome: () -> Void
    let onJumpRemoteRoot: () -> Void
    let onSortChange: (BrowserSortOption) -> Void

    @State private var isDropTargeted = false
    @State private var targetedDirectoryItemID: BrowserItem.ID?
    @State private var selectionAnchorItemID: BrowserItem.ID?

    private let primaryHeaderActionWidth: CGFloat = 148
    private let sortHeaderActionWidth: CGFloat = 88

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 12) {
                    Label(title, systemImage: pane == .local ? "internaldrive" : "server.rack")
                        .font(.headline)
                        .lineLimit(1)

                    Spacer(minLength: 12)

                    HStack(spacing: 8) {
                        Group {
                            if showsChooseDirectoryButton {
                                Button {
                                    onChooseDirectory()
                                } label: {
                                    Label(String(localized: "Choose Folder"), systemImage: "folder.badge.gearshape")
                                }
                                .buttonStyle(.borderless)
                                .help(String(localized: "Pick a local folder for the left pane."))
                            } else if showsRemotePathButton {
                                Menu {
                                    Button(String(localized: "Go to Folder…"), systemImage: "folder.badge.gearshape") {
                                        onPresentRemotePathSheet()
                                    }

                                    Divider()

                                    Button(String(localized: "Home"), systemImage: "house") {
                                        onJumpRemoteHome()
                                    }

                                    Button(String(localized: "Root"), systemImage: "externaldrive") {
                                        onJumpRemoteRoot()
                                    }
                                } label: {
                                    Label(String(localized: "Go"), systemImage: "folder.badge.gearshape")
                                }
                                .menuStyle(.borderlessButton)
                                .help(String(localized: "Jump to a specific remote folder."))
                            } else {
                                Color.clear
                            }
                        }
                        .frame(width: primaryHeaderActionWidth, alignment: .trailing)

                        Menu {
                            ForEach(BrowserSortField.allCases, id: \.self) { field in
                                Button {
                                    onSortChange(.init(field: field, ascending: sortOption.ascending))
                                } label: {
                                    Label(
                                        field.title,
                                        systemImage: sortOption.field == field ? "checkmark" : "circle"
                                    )
                                }
                            }

                            Divider()

                            Button {
                                onSortChange(.init(field: sortOption.field, ascending: true))
                            } label: {
                                Label(
                                    String(localized: "Ascending"),
                                    systemImage: sortOption.ascending ? "checkmark" : "arrow.up"
                                )
                            }

                            Button {
                                onSortChange(.init(field: sortOption.field, ascending: false))
                            } label: {
                                Label(
                                    String(localized: "Descending"),
                                    systemImage: sortOption.ascending ? "arrow.down" : "checkmark"
                                )
                            }
                        } label: {
                            Label(String(localized: "Sort"), systemImage: "arrow.up.arrow.down.circle")
                        }
                        .frame(width: sortHeaderActionWidth, alignment: .trailing)
                    }
                }

                HStack(alignment: .center, spacing: 10) {
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .accessibilityIdentifier(pane == .local ? "local-browser-path" : "remote-browser-path")

                    Spacer(minLength: 0)

                    if pane == .remote {
                        RemoteSessionStatusBadge(status: remoteSessionStatus, isNetworkReachable: isNetworkReachable)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)

            if let errorMessage {
                VStack(spacing: 12) {
                    ContentUnavailableView(
                        String(localized: "Folder Unavailable"),
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                    if showsChooseDirectoryButton {
                        Button(String(localized: "Choose Folder")) {
                            onChooseDirectory()
                        }
                        .help(String(localized: "Pick another local folder with Finder access."))
                    }
                    ErrorCopyButton(message: errorMessage)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: selectionBinding) {
                    if canNavigateUp {
                        Button {
                            focusedPane = pane
                            onSelectionChange(nil)
                            onNavigateUp()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "arrow.turn.up.left")
                                    .frame(width: 20)
                                    .foregroundStyle(.secondary)

                                VStack(alignment: .leading, spacing: rowTextSpacing) {
                                    Text("..")
                                        .font(primaryRowFont)
                                    Text(String(localized: "Parent Folder"))
                                        .font(secondaryRowFont)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()
                            }
                            .padding(.vertical, rowVerticalPadding)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(String(localized: "Open Parent Folder"), systemImage: "arrow.turn.up.left") {
                                focusedPane = pane
                                onSelectionChange(nil)
                                onNavigateUp()
                            }
                        }
                    }

                    ForEach(items) { item in
                        HStack(spacing: 12) {
                            Image(systemName: item.iconName)
                                .foregroundStyle(item.kind == .folder ? Color.accentColor : Color.secondary)
                                .frame(width: 20)

                            VStack(alignment: .leading, spacing: rowTextSpacing) {
                                Text(item.name)
                                    .font(primaryRowFont)
                                Text(item.modifiedDescription)
                                    .font(secondaryRowFont)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text(item.sizeDescription)
                                .font(secondaryRowFont)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, rowVerticalPadding)
                        .listRowBackground(rowBackground(for: item))
                        .contentShape(Rectangle())
                        .tag(item.id)
                        .onDrag {
                            let payloadItems = dragItems(initiatedBy: item)
                            onBeginDrag(payloadItems)
                            return makeDragProvider(for: payloadItems)
                        }
                        .simultaneousGesture(TapGesture().onEnded {
                            handlePrimaryClick(on: item.id)
                        })
                        .onDrop(
                            of: [UTType.fileURL, LocalDragItemCodec.itemType, RemoteDragItemCodec.itemType, .plainText],
                            isTargeted: Binding(
                                get: { targetedDirectoryItemID == item.id },
                                set: { isTargeted in
                                    targetedDirectoryItemID = isTargeted ? item.id : (targetedDirectoryItemID == item.id ? nil : targetedDirectoryItemID)
                                }
                            )
                        ) { providers in
                            guard item.isDirectory else { return false }
                            focusedPane = pane
                            return handleDrop(providers: providers, targetItemID: item.id)
                        }
                        .contextMenu {
                            if item.isDirectory {
                                Button(String(localized: "Open")) {
                                    focusedPane = pane
                                    onSelectionChange(item.id)
                                    onOpenSelection()
                                }
                            }

                            Button(transferActionTitle, systemImage: transferActionSystemImage) {
                                focusSelectionForTransferAction(on: item)
                                onTransferSelection()
                            }
                            .disabled(transferActionDisabled)

                            Button(String(localized: "Refresh"), systemImage: "arrow.clockwise") {
                                focusedPane = pane
                                onSelectionChange(item.id)
                                onRefresh()
                            }
                            .disabled(isBusy)

                            Divider()

                            Button(String(localized: "New Folder"), systemImage: "folder.badge.plus") {
                                focusedPane = pane
                                onSelectionChange(item.id)
                                onCreateFolder()
                            }
                            .disabled(createFolderDisabled)

                            Button(String(localized: "Rename")) {
                                focusedPane = pane
                                onSelectionChange(item.id)
                                onBeginRename(item.id)
                            }

                            Button(String(localized: "Delete"), role: .destructive) {
                                focusedPane = pane
                                onSelectionChange(item.id)
                                onRequestDelete(item.id)
                            }
                        }
                        .highPriorityGesture(TapGesture(count: 2).onEnded {
                            focusedPane = pane
                            onSelectionChange(item.id)
                            if item.isDirectory {
                                onOpenSelection()
                            }
                        })
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .accessibilityIdentifier(pane == .local ? "local-browser-list" : "remote-browser-list")
                .onDrop(of: [UTType.fileURL, LocalDragItemCodec.itemType, RemoteDragItemCodec.itemType, .plainText], isTargeted: $isDropTargeted) { providers in
                    focusedPane = pane
                    return handleDrop(providers: providers)
                }
                .overlay {
                    if isDropTargeted {
                        dropTargetOverlay
                    } else if items.isEmpty {
                        ContentUnavailableView(
                            emptyStateTitle,
                            systemImage: emptyStateSystemImage,
                            description: Text(emptyStateDescription)
                        )
                    }
                }
            }
        }
        .frame(minWidth: 320, idealWidth: 420)
        .contentShape(Rectangle())
        .contextMenu {
            Button(String(localized: "Refresh"), systemImage: "arrow.clockwise") {
                focusedPane = pane
                onRefresh()
            }
            .disabled(isBusy)

            Button(transferActionTitle, systemImage: transferActionSystemImage) {
                focusedPane = pane
                onTransferSelection()
            }
            .disabled(transferActionDisabled)

            Button(String(localized: "New Folder"), systemImage: "folder.badge.plus") {
                focusedPane = pane
                onSelectionChange(selectedItemID)
                onCreateFolder()
            }
            .disabled(createFolderDisabled)

            if showsChooseDirectoryButton {
                Button(String(localized: "Choose Folder"), systemImage: "folder.badge.gearshape") {
                    focusedPane = pane
                    onChooseDirectory()
                }
            }
        }
        .onDrop(of: [UTType.fileURL, LocalDragItemCodec.itemType, RemoteDragItemCodec.itemType, .plainText], isTargeted: $isDropTargeted) { providers in
            focusedPane = pane
            return handleDrop(providers: providers)
        }
        .overlay(alignment: .center) {
            if isDropTargeted {
                dropTargetCallout
            }
        }
        .overlay {
            if isDropTargeted {
                dropTargetOverlay
            }
        }
    }

    private var transferActionTitle: String {
        pane == .local ? String(localized: "Upload to Remote") : String(localized: "Download to Local")
    }

    private var transferActionSystemImage: String {
        pane == .local ? "arrow.up.circle" : "arrow.down.circle"
    }

    private var transferActionDisabled: Bool {
        selectedItemIDs.isEmpty || (pane == .remote && !isRemoteSessionTransferAvailable)
    }

    private var createFolderDisabled: Bool {
        pane == .remote ? !isRemoteSessionTransferAvailable || isBusy : false
    }

    private var dropHintSystemImage: String {
        pane == .local ? "arrow.down.circle" : "arrow.up.circle"
    }

    private var dropTargetTitle: String {
        switch pane {
        case .local:
            return String(localized: "Drop to Download")
        case .remote:
            return String(localized: "Drop to Upload")
        }
    }

    private var dropTargetSubtitle: String {
        if let targetedDirectoryItemID,
           let item = items.first(where: { $0.id == targetedDirectoryItemID }) {
            return pane == .local
                ? String(localized: "Download files into \(item.name)")
                : String(localized: "Upload files into \(item.name)")
        }
        return pane == .local
            ? String(localized: "Download files into the current local folder")
            : String(localized: "Upload files into the current remote folder")
    }

    private var dropTargetOverlay: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.accentColor.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            )
            .padding(6)
    }

    private var dropTargetCallout: some View {
        VStack(spacing: 8) {
            Image(systemName: dropHintSystemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            Text(dropTargetTitle)
                .font(.headline)
            Text(dropTargetSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Folders are targets. Transfers currently focus on files.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var isRemoteSessionTransferAvailable: Bool {
        switch remoteSessionStatus {
        case .connected:
            return true
        case .idle, .connecting, .failed:
            return false
        }
    }

    @ViewBuilder
    private func directoryDropHighlight(for item: BrowserItem) -> some View {
        if item.isDirectory && targetedDirectoryItemID == item.id {
            ZStack(alignment: .trailing) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.accentColor, lineWidth: 1.5)
                    )

                Text("Drop Here")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.trailing, 10)
            }
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func rowBackground(for item: BrowserItem) -> some View {
        ZStack {
            if selectedItemIDs.contains(item.id) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selectionTint)
            }
            directoryDropHighlight(for: item)
        }
    }

    private var selectionBinding: Binding<Set<BrowserItem.ID>> {
        Binding(
            get: { selectedItemIDs },
            set: { updatedIDs in
                focusedPane = pane
                if updatedIDs.isEmpty {
                    selectionAnchorItemID = nil
                    onSelectionSetChange([])
                } else {
                    if let selectedItemID, updatedIDs.contains(selectedItemID) {
                        selectionAnchorItemID = selectedItemID
                    } else {
                        selectionAnchorItemID = items.first(where: { updatedIDs.contains($0.id) })?.id
                    }
                    onSelectionSetChange(updatedIDs)
                }
            }
        )
    }

    private var selectionTint: Color {
        focusedPane == pane ? Color.accentColor.opacity(0.32) : Color.secondary.opacity(0.18)
    }

    private func handleDrop(providers: [NSItemProvider], targetItemID: BrowserItem.ID? = nil) -> Bool {
        let localCollectionProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(LocalDragItemCodec.itemType.identifier) }
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        if !localCollectionProviders.isEmpty {
            loadLocalCollections(
                from: localCollectionProviders,
                fallbackFileProviders: fileProviders,
                targetItemID: targetItemID
            )
            return true
        }

        let remoteProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(RemoteDragItemCodec.itemType.identifier) }
        if !remoteProviders.isEmpty {
            loadRemoteCollections(from: remoteProviders, targetItemID: targetItemID)
            return true
        }

        if !fileProviders.isEmpty {
            loadFileURLs(from: fileProviders, targetItemID: targetItemID)
            return true
        }

        if pane == .remote {
            if let targetItemID {
                if onDropLocalItemsIntoDirectory([], targetItemID) {
                    return true
                }
            } else if onDropLocalItems([]) {
                return true
            }
        }

        let textProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }
        if !textProviders.isEmpty {
            loadRemoteTextPayloads(from: textProviders, targetItemID: targetItemID)
            return true
        }

        return false
    }

    private func handlePrimaryClick(on itemID: BrowserItem.ID) {
        focusedPane = pane

        let modifierFlags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        let commandPressed = modifierFlags.contains(.command)
        let shiftPressed = modifierFlags.contains(.shift)

        if shiftPressed {
            let anchorID = selectionAnchorItemID ?? selectedItemID ?? itemID
            let selectedRange = contiguousSelection(from: anchorID, to: itemID)

            if commandPressed {
                onSelectionSetChange(selectedItemIDs.union(selectedRange))
            } else {
                onSelectionSetChange(selectedRange)
            }
            return
        }

        if commandPressed {
            var updatedIDs = selectedItemIDs
            if updatedIDs.contains(itemID) {
                updatedIDs.remove(itemID)
            } else {
                updatedIDs.insert(itemID)
            }
            selectionAnchorItemID = itemID
            onSelectionSetChange(updatedIDs)
            return
        }

        selectionAnchorItemID = itemID
        onSelectionChange(itemID)
    }

    private func contiguousSelection(from anchorID: BrowserItem.ID, to itemID: BrowserItem.ID) -> Set<BrowserItem.ID> {
        guard
            let anchorIndex = items.firstIndex(where: { $0.id == anchorID }),
            let itemIndex = items.firstIndex(where: { $0.id == itemID })
        else {
            return [itemID]
        }

        let lowerBound = min(anchorIndex, itemIndex)
        let upperBound = max(anchorIndex, itemIndex)
        return Set(items[lowerBound...upperBound].map(\.id))
    }

    private func makeDragProvider(for dragItems: [BrowserItem]) -> NSItemProvider {
        if pane == .remote {
            let payloadItems = dragItems.map {
                RemoteDragItem(
                    id: $0.id,
                    name: $0.name,
                    pathDescription: $0.pathDescription,
                    isDirectory: $0.isDirectory
                )
            }
            let payloadData = RemoteDragItemCodec.encodeCollection(payloadItems)
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: RemoteDragItemCodec.itemType.identifier, visibility: .all) { completion in
                completion(payloadData, nil)
                return nil
            }
            if
                let payloadData,
                let payloadString = String(data: payloadData, encoding: .utf8)
            {
                provider.registerObject(
                    NSString(string: RemoteDragItemCodec.collectionTextPrefix + payloadString),
                    visibility: .all
                )
            }
            return provider
        }

        let urls = dragItems.compactMap { $0.url ?? URL(fileURLWithPath: $0.pathDescription) }
        if urls.count == 1, let url = urls.first {
            return NSItemProvider(object: url as NSURL)
        }

        let provider = NSItemProvider()
        let payloadData = LocalDragItemCodec.encode(urls)
        provider.registerDataRepresentation(forTypeIdentifier: LocalDragItemCodec.itemType.identifier, visibility: .all) { completion in
            completion(payloadData, nil)
            return nil
        }
        if let primaryURL = urls.first {
            provider.registerObject(primaryURL as NSURL, visibility: .all)
        }
        return provider
    }

    private func dragItems(initiatedBy item: BrowserItem) -> [BrowserItem] {
        if selectedItemIDs.contains(item.id) {
            let selectedItems = items.filter { selectedItemIDs.contains($0.id) }
            if !selectedItems.isEmpty {
                return selectedItems
            }
        }
        return [item]
    }

    private func loadLocalCollections(
        from providers: [NSItemProvider],
        fallbackFileProviders: [NSItemProvider],
        targetItemID: BrowserItem.ID?
    ) {
        let group = DispatchGroup()
        let lock = NSLock()
        var allURLs: [URL] = []

        for provider in providers {
            group.enter()
            provider.loadDataRepresentation(forTypeIdentifier: LocalDragItemCodec.itemType.identifier) { data, _ in
                defer { group.leave() }
                guard let data, let urls = LocalDragItemCodec.decode(data: data) else { return }
                lock.lock()
                allURLs.append(contentsOf: urls)
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            let urls = allURLs.uniqued(by: \.standardizedFileURL)
            guard !urls.isEmpty else {
                if !fallbackFileProviders.isEmpty {
                    loadFileURLs(from: fallbackFileProviders, targetItemID: targetItemID)
                }
                return
            }
            if let targetItemID {
                _ = onDropLocalItemsIntoDirectory(urls, targetItemID)
            } else {
                _ = onDropLocalItems(urls)
            }
        }
    }

    private func loadRemoteCollections(from providers: [NSItemProvider], targetItemID: BrowserItem.ID?) {
        let group = DispatchGroup()
        let lock = NSLock()
        var allItems: [RemoteDragItem] = []

        for provider in providers {
            group.enter()
            provider.loadDataRepresentation(forTypeIdentifier: RemoteDragItemCodec.itemType.identifier) { data, _ in
                defer { group.leave() }
                guard let data else { return }
                let items = RemoteDragItemCodec.decodeCollection(data: data)
                    ?? RemoteDragItemCodec.decode(data: data).map { [$0] }
                    ?? []
                lock.lock()
                allItems.append(contentsOf: items)
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            let items = allItems.uniqued(by: \.id)
            guard !items.isEmpty else { return }
            if let targetItemID {
                _ = onDropRemoteItemsIntoDirectory(items, targetItemID)
            } else {
                _ = onDropRemoteItems(items)
            }
        }
    }

    private func loadFileURLs(from providers: [NSItemProvider], targetItemID: BrowserItem.ID?) {
        let group = DispatchGroup()
        let lock = NSLock()
        var allURLs: [URL] = []

        for provider in providers {
            group.enter()
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                defer { group.leave() }
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                lock.lock()
                allURLs.append(url)
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            let urls = allURLs.uniqued(by: \.standardizedFileURL)
            guard !urls.isEmpty else { return }
            if let targetItemID {
                _ = onDropLocalItemsIntoDirectory(urls, targetItemID)
            } else {
                _ = onDropLocalItems(urls)
            }
        }
    }

    private func loadRemoteTextPayloads(from providers: [NSItemProvider], targetItemID: BrowserItem.ID?) {
        let group = DispatchGroup()
        let lock = NSLock()
        var allItems: [RemoteDragItem] = []

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let text: String?
                switch item {
                case let data as Data:
                    text = String(data: data, encoding: .utf8)
                case let string as String:
                    text = string
                case let nsString as NSString:
                    text = nsString as String
                default:
                    text = nil
                }

                guard let text else { return }
                let items = RemoteDragItemCodec.decodeCollection(text: text)
                    ?? RemoteDragItemCodec.decode(text: text).map { [$0] }
                    ?? []
                lock.lock()
                allItems.append(contentsOf: items)
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            let items = allItems.uniqued(by: \.id)
            guard !items.isEmpty else { return }
            if let targetItemID {
                _ = onDropRemoteItemsIntoDirectory(items, targetItemID)
            } else {
                _ = onDropRemoteItems(items)
            }
        }
    }

    private func focusSelectionForTransferAction(on item: BrowserItem) {
        focusedPane = pane
        guard !selectedItemIDs.contains(item.id) else { return }
        onSelectionChange(item.id)
    }

    private var emptyStateTitle: String {
        if pane == .remote, !isNetworkReachable {
            return String(localized: "Network Offline")
        }
        if pane == .remote, case .idle = remoteSessionStatus {
            return String(localized: "Remote Disconnected")
        }
        return String(localized: "Folder Empty")
    }

    private var emptyStateSystemImage: String {
        if pane == .remote, !isNetworkReachable {
            return "wifi.slash"
        }
        if pane == .remote, case .idle = remoteSessionStatus {
            return "bolt.slash"
        }
        return "folder"
    }

    private var emptyStateDescription: String {
        if pane == .remote, !isNetworkReachable {
            return String(localized: "Network connection lost. Check Wi-Fi or Ethernet and reconnect.")
        }
        if pane == .remote, case .idle = remoteSessionStatus {
            return String(localized: "Connect to a remote server to browse files.")
        }
        return String(localized: "This directory does not contain any visible files yet.")
    }

    private var primaryRowFont: Font {
        switch density {
        case .comfortable:
            return .body
        case .compact:
            return .subheadline
        case .ultraCompact:
            return .caption
        }
    }

    private var secondaryRowFont: Font {
        switch density {
        case .comfortable:
            return .caption
        case .compact:
            return .caption2
        case .ultraCompact:
            return .caption2
        }
    }

    private var rowVerticalPadding: CGFloat {
        switch density {
        case .comfortable:
            return 4
        case .compact:
            return 1
        case .ultraCompact:
            return 0
        }
    }

    private var rowTextSpacing: CGFloat {
        switch density {
        case .comfortable:
            return 2
        case .compact:
            return 1
        case .ultraCompact:
            return 0
        }
    }
}

private struct BusyOverlay: View {
    let title: String

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct InspectorView: View {
    let focusedPane: BrowserPane
    let selectedServer: ServerProfile?
    let activeRemoteServer: ServerProfile?
    let showsConnectionSheet: Bool
    let connectionDraft: ConnectionDraft
    let hasSavedPasswordForSelectedServer: Bool
    let remoteSessionStatus: RemoteSessionStatus
    let localPath: String
    let remotePath: String
    let remoteHomePath: String?
    let favoriteCount: Int
    let maxConcurrentTransfers: Int
    let item: BrowserItem?
    let recentTransfers: [TransferActivity]
    let highlightsActivity: Bool
    let canRetryTransfer: (UUID) -> Bool
    let canCancelTransfer: (UUID) -> Bool
    let canPauseTransfer: (UUID) -> Bool
    let canResumeTransfer: (UUID) -> Bool
    let hasCompletedTransfers: Bool
    let retryTransfer: (UUID) -> Void
    let cancelTransfer: (UUID) -> Void
    let pauseTransfer: (UUID) -> Void
    let resumeTransfer: (UUID) -> Void
    let clearCompletedTransfers: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let totalHeight = max(proxy.size.height, 320)
            let topHeight = inspectorHeight(for: totalHeight)
            let bottomHeight = max(totalHeight - topHeight - 1, 180)

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !prefersActivityLayout {
                            Text(String(localized: "Inspector"))
                                .font(.title3.weight(.semibold))

                            if highlightsActivity {
                                Label(String(localized: "Transfer activity is in progress."), systemImage: "bolt.badge.clock")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.orange)
                            }

                            inspectorSection("Workspace") {
                                inspectorValueRow(String(localized: "Focused Pane"), value: focusedPane.title)
                                inspectorValueRow(String(localized: "Favorites"), value: "\(favoriteCount)")
                                inspectorValueRow(String(localized: "Transfer Slots"), value: "\(maxConcurrentTransfers)")
                                inspectorValueRow(String(localized: "Local Folder"), value: localPath, prominent: false, monospace: true)
                                if let activeRemoteServer {
                                    inspectorValueRow(String(localized: "Active Site"), value: activeRemoteServer.name)
                                }
                                inspectorValueRow(String(localized: "Remote Folder"), value: remotePath, prominent: false, monospace: true)

                                if let remoteHomePath {
                                    inspectorValueRow(String(localized: "Remote Home"), value: remoteHomePath, prominent: false, monospace: true)
                                }

                                inspectorValueRow(String(localized: "Remote Status"), value: remoteStatusSummary)
                                siteSummarySection
                            }

                            Divider()
                        }

                        inspectorSection(prefersActivityLayout ? "Selected" : "Selection") {
                            if let item {
                                inspectorValueRow(String(localized: "Name"), value: item.name)
                                inspectorValueRow(String(localized: "Path"), value: item.pathDescription, prominent: false, monospace: true)
                            } else {
                                Text(String(localized: "Select a file or folder to inspect metadata and transfer context."))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(16)
                }
                .frame(height: topHeight)
                .opacity(highlightsActivity && !prefersActivityLayout ? 0.52 : 1)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(String(localized: "Activity"))
                                .font(.headline)
                            Spacer()
                            if hasCompletedTransfers {
                                Button(String(localized: "Clear Completed")) {
                                    clearCompletedTransfers()
                                }
                                .font(.caption)
                                .buttonStyle(.link)
                                .help(String(localized: "Remove completed transfers from the activity list."))
                            }
                            Text(activitySummary)
                                .font(.caption)
                                .foregroundStyle(highlightsActivity ? .orange : .secondary)
                        }

                        if recentTransfers.isEmpty {
                            Text(String(localized: "No transfer activity yet."))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(recentTransfers) { transfer in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(transfer.title)
                                            .font(.subheadline.weight(.medium))
                                        Spacer()
                                        if canRetryTransfer(transfer.id) {
                                            Button(String(localized: "Retry"), systemImage: "arrow.clockwise") {
                                                retryTransfer(transfer.id)
                                            }
                                            .labelStyle(.iconOnly)
                                            .buttonStyle(.plain)
                                            .help(String(localized: "Retry this transfer."))
                                        }
                                        if canPauseTransfer(transfer.id) {
                                            Button(String(localized: "Pause"), systemImage: "pause") {
                                                pauseTransfer(transfer.id)
                                            }
                                            .labelStyle(.iconOnly)
                                            .buttonStyle(.plain)
                                            .help(String(localized: "Pause this transfer."))
                                        }
                                        if canResumeTransfer(transfer.id) {
                                            Button(String(localized: "Resume"), systemImage: "play.fill") {
                                                resumeTransfer(transfer.id)
                                            }
                                            .labelStyle(.iconOnly)
                                            .buttonStyle(.plain)
                                            .help(String(localized: "Resume this transfer."))
                                        }
                                        if canCancelTransfer(transfer.id) {
                                            Button(String(localized: "Cancel"), systemImage: "xmark") {
                                                cancelTransfer(transfer.id)
                                            }
                                            .labelStyle(.iconOnly)
                                            .buttonStyle(.plain)
                                            .help(String(localized: "Cancel this transfer."))
                                        }
                                        Label(transfer.status.label, systemImage: transfer.status.systemImage)
                                            .font(.caption)
                                            .foregroundStyle(statusColor(transfer.status))
                                    }

                                    Text(transfer.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    ProgressView(value: transfer.progress)
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                    .padding(16)
                }
                .frame(height: bottomHeight)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func statusColor(_ status: TransferStatus) -> Color {
        switch status {
        case .running: .blue
        case .queued: .secondary
        case .paused: .orange
        case .completed: .green
        case .cancelled: .orange
        case .failed: .red
        }
    }

    private var remoteStatusSummary: String {
        switch remoteSessionStatus {
        case .idle:
            return String(localized: "Idle")
        case .connecting:
            return String(localized: "Connecting")
        case .connected(let details):
            return String(localized: "Connected (\(details))")
        case .failed(let message):
            return String(localized: "Failed (\(message))")
        }
    }

    private var activitySummary: String {
        let runningCount = recentTransfers.filter { $0.status == .running || $0.status == .queued || $0.status == .paused }.count
        if runningCount > 0 {
            return "\(runningCount) active"
        }
        return "\(recentTransfers.count) recent"
    }

    private var prefersActivityLayout: Bool {
        if case .connected = remoteSessionStatus {
            return true
        }
        return false
    }

    private func inspectorHeight(for totalHeight: CGFloat) -> CGFloat {
        let ratio: CGFloat = prefersActivityLayout ? 0.18 : 0.62
        let minHeight: CGFloat = prefersActivityLayout ? 92 : 220
        let maxHeight: CGFloat = prefersActivityLayout ? 140 : 560
        return min(max(totalHeight * ratio, minHeight), maxHeight)
    }

    @ViewBuilder
    private var siteSummarySection: some View {
        if let resolvedSiteSummary {
            inspectorValueRow("Site", value: resolvedSiteSummary.name)
            inspectorValueRow("Endpoint", value: resolvedSiteSummary.endpoint, prominent: false, monospace: true)
            inspectorValueRow("Protocol", value: resolvedSiteSummary.protocolTitle)
            inspectorValueRow(resolvedSiteSummary.authenticationLabel, value: resolvedSiteSummary.passwordStatus)

            if showsConnectionSheet {
                Text(resolvedSiteSummary.editorState)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("No saved site is selected. Use Quick Connect to start a one-off session.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var resolvedSiteSummary: SiteSummary? {
        if showsConnectionSheet {
            let trimmedHost = connectionDraft.host.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedName = connectionDraft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedUsername = connectionDraft.username.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = trimmedName.isEmpty ? (trimmedHost.isEmpty ? "Quick Connect" : trimmedHost) : trimmedName
            let port = Int(connectionDraft.port) ?? defaultPort(for: connectionDraft.connectionKind)
            let hostText = trimmedHost.isEmpty ? "Not set" : trimmedHost
            let usernameText = trimmedUsername.isEmpty ? "Not set" : trimmedUsername

            return SiteSummary(
                name: title,
                endpoint: "\(usernameText)@\(hostText):\(port)",
                protocolTitle: connectionDraft.connectionKind.title,
                authenticationLabel: connectionDraft.connectionKind == .cloud
                    ? LocalizedStringKey("Credentials")
                    : LocalizedStringKey("Auth"),
                passwordStatus: draftAuthenticationStatus,
                editorState: selectedServer == nil
                    ? String(localized: "Quick Connect draft is open in the configuration sheet.")
                    : String(localized: "Saved site draft is open in the configuration sheet.")
            )
        }

        guard let selectedServer else { return nil }
        return SiteSummary(
            name: selectedServer.name,
            endpoint: "\(selectedServer.username)@\(selectedServer.endpoint):\(selectedServer.port)",
            protocolTitle: selectedServer.connectionKind.title,
            authenticationLabel: selectedServer.connectionKind == .cloud
                ? LocalizedStringKey("Credentials")
                : LocalizedStringKey("Auth"),
            passwordStatus: savedAuthenticationStatus(for: selectedServer),
            editorState: ""
        )
    }

    private var draftAuthenticationStatus: String {
        if connectionDraft.connectionKind == .cloud {
            let trimmedAccessKey = connectionDraft.username.trimmingCharacters(in: .whitespacesAndNewlines)
            if connectionDraft.clearsSavedPassword {
                return String(localized: "Will clear saved secret key")
            }
            if trimmedAccessKey.isEmpty {
                return String(localized: "Access key not set")
            }
            if !connectionDraft.password.isEmpty {
                return String(localized: "Access key + secret key")
            }
            if hasSavedPasswordForSelectedServer {
                return String(localized: "Secret key saved in Keychain")
            }
            return String(localized: "Secret key not saved")
        }

        if connectionDraft.authenticationMode == .sshKey {
            let keyPath = connectionDraft.privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if keyPath.isEmpty {
                return String(localized: "SSH key not set")
            }
            if !connectionDraft.password.isEmpty {
                return String(localized: "SSH key + passphrase")
            }
            return String(localized: "SSH key")
        }

        if connectionDraft.clearsSavedPassword {
            return String(localized: "Will clear saved password")
        }
        if !connectionDraft.password.isEmpty {
            return String(localized: "Typed in draft")
        }
        if hasSavedPasswordForSelectedServer {
            return String(localized: "Saved in Keychain")
        }
        return String(localized: "Not saved")
    }

    private func savedAuthenticationStatus(for server: ServerProfile) -> String {
        if server.connectionKind == .cloud {
            return hasSavedPasswordForSelectedServer
                ? String(localized: "Secret key saved in Keychain")
                : String(localized: "Secret key not saved")
        }

        switch server.authenticationMode {
        case .password:
            return hasSavedPasswordForSelectedServer
                ? String(localized: "Saved in Keychain")
                : String(localized: "Not saved")
        case .sshKey:
            return server.privateKeyPath == nil
                ? String(localized: "SSH key not set")
                : String(localized: "SSH key")
        }
    }

    private func defaultPort(for connectionKind: ConnectionKind) -> Int {
        switch connectionKind {
        case .sftp:
            return 22
        case .webdav:
            return 80
        case .cloud:
            return 443
        }
    }

    @ViewBuilder
    private func inspectorSection<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
    }

    @ViewBuilder
    private func inspectorValueRow(
        _ label: String,
        value: String,
        prominent: Bool = true,
        monospace: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            if monospace {
                Text(value)
                    .font((prominent ? Font.callout.weight(.medium) : .caption).monospaced())
                    .foregroundStyle(prominent ? .primary : .secondary)
                    .textSelection(.enabled)
            } else {
                Text(value)
                    .font(prominent ? .callout.weight(.medium) : .caption)
                    .foregroundStyle(prominent ? .primary : .secondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func inspectorValueRow(
        _ label: LocalizedStringKey,
        value: String,
        prominent: Bool = true,
        monospace: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            if monospace {
                Text(value)
                    .font((prominent ? Font.callout.weight(.medium) : .caption).monospaced())
                    .foregroundStyle(prominent ? .primary : .secondary)
                    .textSelection(.enabled)
            } else {
                Text(value)
                    .font(prominent ? .callout.weight(.medium) : .caption)
                    .foregroundStyle(prominent ? .primary : .secondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

private struct SiteSummary {
    let name: String
    let endpoint: String
    let protocolTitle: String
    let authenticationLabel: LocalizedStringKey
    let passwordStatus: String
    let editorState: String
}

private struct ToolbarContentView: ToolbarContent {
    @ObservedObject var state: FilePierWorkspaceState

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button {
                    state.openFocusedSelection()
                } label: {
                    Label(String(localized: "Open"), systemImage: "arrow.right.circle")
                }
                .disabled(state.focusedPane == .remote && state.isRemoteBusy)

                if state.isRemoteConnected {
                    Button(role: .destructive) {
                        state.disconnectRemoteSession()
                    } label: {
                        Label(String(localized: "Disconnect"), systemImage: "bolt.slash")
                    }
                }

                Divider()

                Button {
                    state.beginRenamingFocusedSelection()
                } label: {
                    Label(String(localized: "Rename"), systemImage: "pencil")
                }
                .disabled(!state.canRenameFocusedSelection || (state.focusedPane == .remote && state.isRemoteBusy))

                Button(role: .destructive) {
                    state.requestDeleteFocusedSelection()
                } label: {
                    Label(String(localized: "Delete"), systemImage: "trash")
                }
                .disabled(!state.canDeleteFocusedSelection || (state.focusedPane == .remote && state.isRemoteBusy))

                Divider()

                Button {
                    state.addCurrentLocalDirectoryToFavorites()
                } label: {
                    Label(String(localized: "Add to Favorites"), systemImage: "star")
                }
                .disabled(state.focusedPane != .local)
            } label: {
                Label(String(localized: "Actions"), systemImage: "ellipsis.circle")
            }
            .help(String(localized: "Show less common file and workspace actions."))

            Menu {
                ForEach(BrowserDensityMode.allCases, id: \.self) { mode in
                    Button {
                        state.setBrowserDensity(mode)
                    } label: {
                        Label(mode.title, systemImage: state.browserDensity == mode ? "checkmark" : mode.systemImage)
                    }
                }

                Divider()

                Menu(String(localized: "Transfer Concurrency")) {
                    ForEach(1...6, id: \.self) { value in
                        Button {
                            state.setMaxConcurrentTransfers(value)
                        } label: {
                            Label(
                                value == 1 ? String(localized: "1 transfer") : String(localized: "\(value) transfers"),
                                systemImage: state.maxConcurrentTransfers == value ? "checkmark" : "circle"
                            )
                        }
                    }
                }
            } label: {
                Label(String(localized: "View"), systemImage: "rectangle.3.group")
            }
            .help(String(localized: "Adjust browser density."))

            Button {
                state.toggleInspectorVisibility()
            } label: {
                Label(state.showsInspector ? String(localized: "Hide Info") : String(localized: "Show Info"), systemImage: "sidebar.right")
            }
            .labelStyle(.iconOnly)
            .help(state.showsInspector ? String(localized: "Hide the inspector sidebar.") : String(localized: "Show the inspector sidebar."))
        }
    }
}

private struct RemoteSessionStatusBadge: View {
    let status: RemoteSessionStatus
    let isNetworkReachable: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
            Text(titleText)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(detailColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(detailColor.opacity(0.1), in: Capsule())
        .help(helpText)
    }

    private var titleText: String {
        guard isNetworkReachable else {
            return String(localized: "Network Offline")
        }
        switch status {
        case .idle:
            return String(localized: "Idle")
        case .connecting:
            return String(localized: "Connecting to remote host…")
        case .connected:
            return String(localized: "Connected")
        case .failed:
            return String(localized: "Failed")
        }
    }

    private var iconName: String {
        guard isNetworkReachable else {
            return "wifi.slash"
        }
        switch status {
        case .idle, .connected:
            return "lock.shield"
        case .connecting:
            return "arrow.trianglehead.2.clockwise.rotate.90"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        guard isNetworkReachable else {
            return .red
        }
        switch status {
        case .idle, .connected:
            return .green
        case .connecting:
            return .orange
        case .failed:
            return .red
        }
    }

    private var detailColor: Color {
        guard isNetworkReachable else {
            return .red
        }
        switch status {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .failed:
            return .red
        default:
            return .secondary
        }
    }

    private var helpText: String {
        guard isNetworkReachable else {
            return String(localized: "Network connection lost. Check Wi-Fi or Ethernet and reconnect.")
        }
        switch status {
        case .idle:
            return String(localized: "No remote connection is active yet.")
        case .connecting:
            return String(localized: "A remote connection attempt is in progress.")
        case .connected(let details):
            return String(localized: "Connected remote session: \(details)")
        case .failed(let message):
            return String(localized: "Remote connection failed. \(message)")
        }
    }
}

private struct ErrorCopyButton: View {
    let message: String

    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(message, forType: .string)
        } label: {
            Label(String(localized: "Copy Error"), systemImage: "doc.on.doc")
        }
        .labelStyle(.iconOnly)
        .help(String(localized: "Copy the full error message."))
    }
}

private struct ConnectionSheet: View {
    let servers: [ServerProfile]
    let selectedServer: ServerProfile?
    @Binding var draft: ConnectionDraft
    let currentLocalPath: String
    let currentRemotePath: String
    let hasSavedPassword: Bool
    let status: RemoteSessionStatus
    let onSelectServer: (ServerProfile) -> Void
    let onSave: () -> Void
    let onClearSavedPassword: () -> Void
    let onCancel: () -> Void
    let onConnect: () -> Void

    @State private var showsAdvancedSettings = false
    @State private var lastSuggestedPort = ""
    @State private var lastAnalyzedHost = ""

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                Text(selectedServer?.name ?? (draft.name.isEmpty ? String(localized: "Quick Connect") : draft.name))
                    .font(.title3.weight(.semibold))

                Text(selectedServer != nil ? String(localized: "Saved site configuration") : String(localized: "Remote site configuration"))
                    .foregroundStyle(.secondary)

                if !servers.isEmpty {
                    Picker("Server", selection: selectedServerIDBinding) {
                        ForEach(servers) { server in
                            Text("\(server.name) · \(server.connectionKind.title)").tag(Optional(server.id))
                        }
                    }
                    .help(String(localized: "Switch the active remote profile before connecting."))
                }

                TextField(String(localized: "Site Name"), text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .help(String(localized: "Optional label used in the site list."))

                Picker("Protocol", selection: $draft.connectionKind) {
                    ForEach(ConnectionKind.allCases, id: \.self) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .help(String(localized: "Protocol used for this saved site."))

                TextField(hostFieldTitle, text: $draft.host)
                    .textFieldStyle(.roundedBorder)
                    .help(hostFieldHelp)

                HStack {
                    TextField(String(localized: "Port"), text: $draft.port)
                        .textFieldStyle(.roundedBorder)
                        .help(String(localized: "Network port used for the remote protocol."))
                    TextField(accountFieldTitle, text: $draft.username)
                        .textFieldStyle(.roundedBorder)
                        .help(accountFieldHelp)
                }

                if draft.connectionKind != .cloud {
                    Picker("Authentication", selection: $draft.authenticationMode) {
                        ForEach(ConnectionAuthenticationMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .help(String(localized: "Choose whether SFTP should use an account password or an SSH private key."))
                }

                if draft.authenticationMode == .sshKey {
                    VStack(alignment: .leading, spacing: 8) {
                        keyPathField(
                            title: String(localized: "Private Key"),
                            placeholder: String(localized: "Required .pem or OpenSSH private key"),
                            value: $draft.privateKeyPath,
                            choose: choosePrivateKey
                        )
                        keyPathField(
                            title: String(localized: "Public Key"),
                            placeholder: String(localized: "Optional matching public key"),
                            value: $draft.publicKeyPath,
                            choose: choosePublicKey
                        )
                    }
                }

                SecureField(secretFieldTitle, text: passwordBinding)
                    .textFieldStyle(.roundedBorder)
                    .help(secretFieldHelp)

                advancedSection

                if selectedServer != nil {
                    Text(savedPasswordStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button(clearSavedSecretButtonTitle) {
                        onClearSavedPassword()
                    }
                    .buttonStyle(.link)
                    .help(clearSavedSecretHelpText)
                }

                statusView

                HStack {
                    Spacer()
                    Button(selectedServer == nil ? String(localized: "Save Site") : String(localized: "Update Site")) {
                        onSave()
                    }
                    .disabled(draft.host.isEmpty || draft.username.isEmpty || isMissingRequiredAuthentication)
                    .help(String(localized: "Save this site so it appears in the sidebar for future sessions."))
                    Button(String(localized: "Cancel")) {
                        onCancel()
                    }
                    .help(String(localized: "Close this connection sheet without changing the session."))
                    Button(String(localized: "Connect")) {
                        onConnect()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.host.isEmpty || draft.username.isEmpty || status == .connecting || isMissingRequiredAuthentication)
                    .help(String(localized: "Start a remote connection with the current form values."))
                }
            }
            .padding(20)
        }
        .padding(20)
        .frame(width: 440, height: 560)
        .onAppear {
            lastAnalyzedHost = draft.host.trimmingCharacters(in: .whitespacesAndNewlines)
            lastSuggestedPort = draft.port
        }
        .onChange(of: draft.host) { _, newValue in
            applyHostPortSuggestionIfNeeded(for: newValue)
        }
        .onChange(of: draft.connectionKind) { _, _ in
            lastSuggestedPort = draft.port
        }
    }

    private var selectedServerIDBinding: Binding<ServerProfile.ID?> {
        Binding(
            get: { selectedServer?.id },
            set: { newID in
                guard let newID else { return }
                guard let server = servers.first(where: { $0.id == newID }) else { return }
                onSelectServer(server)
            }
        )
    }

    private var passwordBinding: Binding<String> {
        Binding(
            get: { draft.password },
            set: { newValue in
                draft.password = newValue
                draft.clearsSavedPassword = false
            }
        )
    }

    @ViewBuilder
    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    showsAdvancedSettings.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: showsAdvancedSettings ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(String(localized: "Advanced"))
                        .font(.body.weight(.medium))
                    Spacer()
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(String(localized: "Show optional network and default-folder settings."))

            if showsAdvancedSettings {
                VStack(alignment: .leading, spacing: 12) {
                    if draft.connectionKind == .cloud {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(String(localized: "Region"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("us-east-1", text: $draft.s3Region)
                                .textFieldStyle(.roundedBorder)
                                .help(String(localized: "AWS signing region for this S3-compatible endpoint. Change this if the server rejects signatures for us-east-1."))
                        }
                    }

                    Picker("Addressing", selection: $draft.addressPreference) {
                        ForEach(ConnectionAddressPreference.allCases, id: \.self) { preference in
                            Text(preference.title).tag(preference)
                        }
                    }
                    .help(String(localized: "Choose whether remote connections should prefer IPv4, IPv6, or let the resolver decide."))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "Default Local Folder"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            TextField(String(localized: "Optional local folder"), text: $draft.defaultLocalDirectoryPath)
                                .textFieldStyle(.roundedBorder)
                                .help(String(localized: "Optional local folder to open automatically after a successful connection."))
                            Button(String(localized: "Choose…")) {
                                chooseDefaultLocalFolder()
                            }
                            .help(String(localized: "Pick a local folder to open after connecting."))
                            Button(String(localized: "Use Current")) {
                                draft.defaultLocalDirectoryPath = currentLocalPath
                            }
                            .help(String(localized: "Use the local folder currently open in the workspace."))
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "Default Remote Folder"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            TextField(String(localized: "Optional remote folder"), text: $draft.defaultRemotePath)
                                .textFieldStyle(.roundedBorder)
                                .help(String(localized: "Optional remote folder to open automatically after a successful connection."))
                            Button(String(localized: "Use Current")) {
                                draft.defaultRemotePath = currentRemotePath
                            }
                            .help(String(localized: "Use the remote folder currently open in the workspace."))
                        }
                    }
                }
                .padding(.leading, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func applyHostPortSuggestionIfNeeded(for newHostValue: String) {
        let trimmedHost = newHostValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedHost != lastAnalyzedHost else { return }
        lastAnalyzedHost = trimmedHost

        let analysis = analyzeEndpointDraft(draft.host, connectionKind: draft.connectionKind)

        if let explicitPort = analysis.explicitPort {
            let explicitPortText = String(explicitPort)
            if draft.port != explicitPortText {
                draft.port = explicitPortText
            }
            lastSuggestedPort = explicitPortText
            return
        }

        let suggestedPort = String(analysis.suggestedPort)
        let shouldApplyDefault = draft.port.isEmpty || draft.port == lastSuggestedPort
        if shouldApplyDefault, draft.port != suggestedPort {
            draft.port = suggestedPort
        }
        lastSuggestedPort = suggestedPort
    }

    private func analyzeEndpointDraft(_ rawValue: String, connectionKind: ConnectionKind) -> (normalizedHost: String, explicitPort: Int?, suggestedPort: Int) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ("", nil, defaultPort(for: connectionKind))
        }

        let fallbackScheme: String
        switch connectionKind {
        case .sftp:
            fallbackScheme = "sftp"
        case .webdav:
            fallbackScheme = "http"
        case .cloud:
            fallbackScheme = "https"
        }

        let rawEndpoint = trimmed.contains("://") ? trimmed : "\(fallbackScheme)://\(trimmed)"
        if var components = URLComponents(string: rawEndpoint), let host = components.host, !host.isEmpty {
            let explicitPort = components.port
            let normalizedScheme = components.scheme?.lowercased()
            let suggestedPort: Int
            switch normalizedScheme {
            case "http":
                suggestedPort = 80
            case "https":
                suggestedPort = 443
            case "sftp":
                suggestedPort = 22
            default:
                suggestedPort = defaultPort(for: connectionKind)
            }

            components.port = nil
            let normalizedHost: String
            if trimmed.contains("://") {
                normalizedHost = components.string ?? trimmed
            } else {
                var reconstructed = host
                if !components.path.isEmpty {
                    reconstructed += components.path
                }
                if let query = components.percentEncodedQuery, !query.isEmpty {
                    reconstructed += "?\(query)"
                }
                if let fragment = components.percentEncodedFragment, !fragment.isEmpty {
                    reconstructed += "#\(fragment)"
                }
                normalizedHost = reconstructed
            }

            return (normalizedHost, explicitPort, suggestedPort)
        }

        return (trimmed, nil, defaultPort(for: connectionKind))
    }

    private func defaultPort(for connectionKind: ConnectionKind) -> Int {
        switch connectionKind {
        case .sftp:
            return 22
        case .webdav:
            return 80
        case .cloud:
            return 443
        }
    }

    private var hostFieldTitle: String {
        switch draft.connectionKind {
        case .cloud:
            return String(localized: "Endpoint")
        case .sftp, .webdav:
            return String(localized: "Host")
        }
    }

    private var hostFieldHelp: String {
        switch draft.connectionKind {
        case .cloud:
            return String(localized: "S3-compatible endpoint URL or bucket endpoint. Examples: https://s3.example.com or https://bucket.s3.example.com")
        case .sftp, .webdav:
            return String(localized: "Remote host name or IP address.")
        }
    }

    private var accountFieldTitle: String {
        switch draft.connectionKind {
        case .cloud:
            return String(localized: "Access Key")
        case .sftp, .webdav:
            return String(localized: "Username")
        }
    }

    private var accountFieldHelp: String {
        switch draft.connectionKind {
        case .cloud:
            return String(localized: "Access key ID used to sign S3 requests.")
        case .sftp, .webdav:
            return String(localized: "Username used to authenticate with the remote server.")
        }
    }

    private var secretFieldTitle: String {
        if draft.connectionKind == .cloud {
            return String(localized: "Secret Key")
        }
        switch draft.authenticationMode {
        case .password:
            return String(localized: "Password")
        case .sshKey:
            return String(localized: "Key Passphrase")
        }
    }

    private var secretFieldHelp: String {
        if draft.connectionKind == .cloud {
            return String(localized: "Secret access key used to sign S3 requests.")
        }
        switch draft.authenticationMode {
        case .password:
            return String(localized: "Password for the remote account. Leave empty when using key-based auth.")
        case .sshKey:
            return String(localized: "Optional passphrase used to unlock the selected private key.")
        }
    }

    private var isMissingRequiredAuthentication: Bool {
        if draft.connectionKind == .cloud {
            return false
        }
        switch draft.authenticationMode {
        case .password:
            return false
        case .sshKey:
            return draft.privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var clearSavedSecretButtonTitle: String {
        if draft.connectionKind == .cloud {
            return String(localized: "Clear Saved Secret Key")
        }
        switch draft.authenticationMode {
        case .password:
            return String(localized: "Clear Saved Password")
        case .sshKey:
            return String(localized: "Clear Saved Passphrase")
        }
    }

    private var clearSavedSecretHelpText: String {
        if draft.connectionKind == .cloud {
            return String(localized: "Remove the stored secret key for this saved S3 site from Keychain.")
        }
        switch draft.authenticationMode {
        case .password:
            return String(localized: "Remove the stored password for this saved site from Keychain.")
        case .sshKey:
            return String(localized: "Remove the saved key passphrase for this site from Keychain.")
        }
    }

    private var savedPasswordStatusText: String {
        if draft.connectionKind == .cloud {
            if draft.clearsSavedPassword {
                return String(localized: "Saved secret key will be removed when you save this site.")
            }
            if hasSavedPassword, draft.password.isEmpty {
                return String(localized: "A secret key is saved in Keychain and will be kept unless you clear it.")
            }
            if hasSavedPassword {
                return String(localized: "A secret key is currently loaded from Keychain for this site.")
            }
            return String(localized: "No secret key is currently saved for this site.")
        }

        if draft.authenticationMode == .sshKey {
            if draft.privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return String(localized: "Choose a private key file to enable SSH key login.")
            }
            if draft.password.isEmpty {
                return String(localized: "The selected SSH key will be used for passwordless login.")
            }
            return String(localized: "The selected SSH key will use the provided passphrase when connecting.")
        }

        if draft.clearsSavedPassword {
            return String(localized: "Saved password will be removed when you save this site.")
        }
        if hasSavedPassword, draft.password.isEmpty {
            return String(localized: "A password is saved in Keychain and will be kept unless you clear it.")
        }
        if hasSavedPassword {
            return String(localized: "A password is currently loaded from Keychain for this site.")
        }
        return String(localized: "No password is currently saved for this site.")
    }

    private func chooseDefaultLocalFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Default Local Folder")
        panel.message = String(localized: "Select a local folder to open automatically after connecting.")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if !draft.defaultLocalDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            panel.directoryURL = URL(fileURLWithPath: NSString(string: draft.defaultLocalDirectoryPath).expandingTildeInPath)
        } else {
            panel.directoryURL = URL(fileURLWithPath: NSString(string: currentLocalPath).expandingTildeInPath)
        }

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        draft.defaultLocalDirectoryPath = selectedURL.standardizedFileURL.path(percentEncoded: false)
    }

    private func choosePrivateKey() {
        if let selectedFile = chooseKeyFile(
            title: String(localized: "Choose Private Key"),
            message: String(localized: "Select a PEM or OpenSSH private key file for this SFTP host.")
        ) {
            draft.privateKeyPath = selectedFile.path
            draft.privateKeyBookmarkData = selectedFile.bookmarkData
        }
    }

    private func choosePublicKey() {
        if let selectedFile = chooseKeyFile(
            title: String(localized: "Choose Public Key"),
            message: String(localized: "Select the matching public key file when you want to keep the key pair recorded with this site.")
        ) {
            draft.publicKeyPath = selectedFile.path
            draft.publicKeyBookmarkData = selectedFile.bookmarkData
        }
    }

    private struct SelectedKeyFile {
        let path: String
        let bookmarkData: Data?
    }

    private func chooseKeyFile(title: String, message: String) -> SelectedKeyFile? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        // Keep an alias/symbolic-link URL as selected. Resolving it here can require
        // access to its target before the key is actually used.
        panel.resolvesAliases = false
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return nil }
        // Return the picker result untouched. In particular, do not canonicalize it
        // to a link target while the user is selecting a key. NSOpenPanel can
        // nevertheless return the target after browsing through ~/.ssh, so
        // restore that user-facing link spelling before persisting the path.
        let persistedPath = sshKeyPathPreservingHomeSSHLink(for: selectedURL)
        return SelectedKeyFile(
            path: persistedPath,
            // The picker-owned URL is the one macOS grants access to. The
            // persisted path above is deliberately independent of it.
            bookmarkData: try? selectedURL.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        )
    }

    @ViewBuilder
    private func keyPathField(
        title: String,
        placeholder: String,
        value: Binding<String>,
        choose: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField(placeholder, text: value)
                    .textFieldStyle(.roundedBorder)
                Button("Choose…") {
                    choose()
                }
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .idle:
            EmptyView()
        case .connecting:
            Label("Connecting…", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .connected(let details):
            Label(details, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let message):
            HStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                ErrorCopyButton(message: message)
            }
        }
    }
}

private struct RemotePathSheet: View {
    let currentPath: String
    @Binding var draft: String
    let homePath: String?
    let isBusy: Bool
    let onCancel: () -> Void
    let onJumpHome: () -> Void
    let onJumpRoot: () -> Void
    let onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "Go to Remote Folder"))
                .font(.title3.weight(.semibold))

            Text(String(localized: "Jump directly to a remote directory without stepping through each level."))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Current"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(currentPath)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }

            if let homePath {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "Home"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(homePath)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            }

            TextField(String(localized: "Remote path"), text: $draft)
                .textFieldStyle(.roundedBorder)
                .help(String(localized: "Enter an absolute path like /srv or use ~ to jump to the remote home directory."))

            HStack {
                Button(String(localized: "Home"), action: onJumpHome)
                    .disabled(isBusy)
                Button(String(localized: "Root"), action: onJumpRoot)
                    .disabled(isBusy)
                Spacer()
                Button(String(localized: "Cancel"), action: onCancel)
                Button(String(localized: "Open"), action: onCommit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBusy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

private struct RenameSheet: View {
    let request: RenameRequest
    let onCancel: () -> Void
    let onCommit: (String) -> Void

    @State private var proposedName: String

    init(request: RenameRequest, onCancel: @escaping () -> Void, onCommit: @escaping (String) -> Void) {
        self.request = request
        self.onCancel = onCancel
        self.onCommit = onCommit
        _proposedName = State(initialValue: request.proposedName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "Rename Item"))
                .font(.title3.weight(.semibold))

            Text(String(localized: "Update the name for \(request.originalName)."))
                .foregroundStyle(.secondary)

            TextField(String(localized: "Name"), text: $proposedName)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button(String(localized: "Cancel")) {
                    onCancel()
                }
                .help(String(localized: "Close rename without changing the item name."))
                Button(String(localized: "Rename")) {
                    onCommit(proposedName)
                }
                .keyboardShortcut(.defaultAction)
                .help(String(localized: "Apply the new item name."))
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

private struct CreateFolderSheet: View {
    let request: CreateFolderRequest
    let onCancel: () -> Void
    let onCommit: (String) -> Void

    @State private var proposedName: String

    init(request: CreateFolderRequest, onCancel: @escaping () -> Void, onCommit: @escaping (String) -> Void) {
        self.request = request
        self.onCancel = onCancel
        self.onCommit = onCommit
        _proposedName = State(initialValue: request.proposedName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "New Folder"))
                .font(.title3.weight(.semibold))

            Text(String(localized: "Create a folder in \(request.pane.title)."))
                .foregroundStyle(.secondary)

            TextField(String(localized: "Folder Name"), text: $proposedName)
                .textFieldStyle(.roundedBorder)
                .help(String(localized: "Name for the new folder."))

            HStack {
                Spacer()
                Button(String(localized: "Cancel")) {
                    onCancel()
                }
                .help(String(localized: "Close folder creation without making changes."))
                Button(String(localized: "Create")) {
                    onCommit(proposedName)
                }
                .keyboardShortcut(.defaultAction)
                .help(String(localized: "Create the folder with the current name."))
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

private struct FavoriteRenameSheet: View {
    let request: FavoritePlaceRenameRequest
    let onCancel: () -> Void
    let onCommit: (String) -> Void

    @State private var proposedName: String

    init(request: FavoritePlaceRenameRequest, onCancel: @escaping () -> Void, onCommit: @escaping (String) -> Void) {
        self.request = request
        self.onCancel = onCancel
        self.onCommit = onCommit
        _proposedName = State(initialValue: request.proposedName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "Rename Favorite"))
                .font(.title3.weight(.semibold))

            Text(String(localized: "Update the sidebar label for \(request.originalName)."))
                .foregroundStyle(.secondary)

            TextField(String(localized: "Favorite Name"), text: $proposedName)
                .textFieldStyle(.roundedBorder)
                .help(String(localized: "Custom label shown in the Favorites section."))

            HStack {
                Spacer()
                Button(String(localized: "Cancel"), action: onCancel)
                Button(String(localized: "Save")) {
                    onCommit(proposedName)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

#Preview {
    FilePierWorkspaceView(state: FilePierWorkspaceState())
        .frame(width: 1440, height: 900)
}
