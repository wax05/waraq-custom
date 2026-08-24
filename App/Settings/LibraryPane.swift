//  Waraq - A native macOS animated wallpaper app.
//  Copyright (C) 2026 Omar A. Othman
//
//  This program is free software: you can redistribute it
//  and/or modify it under the terms of the GNU General
//  Public License as published by the Free Software
//  Foundation, either version 3 of the License, or (at
//  your option) any later version.
//
//  This program is distributed in the hope that it will
//  be useful, but WITHOUT ANY WARRANTY; without even the
//  implied warranty of MERCHANTABILITY or FITNESS FOR A
//  PARTICULAR PURPOSE. See the GNU General Public License
//  for more details.
//
//  You should have received a copy of the GNU General
//  Public License along with this program. If not, see
//  <https://www.gnu.org/licenses/>.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryPane: View {
    @StateObject private var library = WallpaperLibrary.shared
    @StateObject private var interpolationQueue = RifeInterpolationQueue.shared
    @State private var searchQuery: String = ""
    @State private var typeFilter: TypeFilter = .all
    @State private var sortOrder: SortOrder = .recentlyAdded
    @State private var selectedID: String?
    @State private var importError: String?
    @State private var showingImportError: Bool = false
    @State private var showingGifImport: Bool = false
    @State private var isDropTargeted: Bool = false

    enum TypeFilter: String, CaseIterable {
        case all = "All"
        case video = "Video"
        case gif = "GIF"
        case builtin = "Built-in"
    }

    enum SortOrder: String, CaseIterable {
        case recentlyAdded = "Recently added"
        case name = "Name"
        case type = "Type"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                titleRow
                toolbar
                counterLine
                interpolationQueueSection
                wallpaperGrid
                restoreFooter
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
        .alert(
            "Import failed",
            isPresented: $showingImportError,
            actions: { Button("OK") {} },
            message: { Text(importError ?? "") }
        )
        .sheet(isPresented: $showingGifImport) {
            GifImportSheet()
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .overlay(dropTargetOverlay)
    }

    @ViewBuilder
    private var dropTargetOverlay: some View {
        if isDropTargeted {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor, lineWidth: 3)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.accentColor.opacity(0.06))
                )
                .padding(8)
                .allowsHitTesting(false)
                .overlay(
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(Color.accentColor)
                        Text("Drop to import")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(20)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .allowsHitTesting(false)
                )
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var anyHandled = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    self.importDroppedURL(url)
                }
            }
            anyHandled = true
        }
        return anyHandled
    }

    private func importDroppedURL(_ url: URL) {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: url.path, isDirectory: &isDir
        )
        guard exists else { return }
        if isDir.boolValue {
            let imported = library.importFolder(at: url)
            if imported.isEmpty {
                importError = NSLocalizedString(
                    "No video or GIF files found in that folder.",
                    comment: "Import error"
                )
                showingImportError = true
            }
        } else {
            let ext = url.pathExtension.lowercased()
            guard WallpaperLibrary.supportedAllExtensions.contains(ext) else {
                importError = String(
                    format: NSLocalizedString(
                        "Unsupported file type: .%@",
                        comment: "Import error"
                    ),
                    ext
                )
                showingImportError = true
                return
            }
            do { _ = try library.importFile(at: url) }
            catch let e as WallpaperImportError {
                importError = e.errorDescription
                showingImportError = true
            } catch {
                importError = error.localizedDescription
                showingImportError = true
            }
        }
    }

    private func setCustomThumbnail(for wallpaper: Wallpaper) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.jpeg, .png, .heic, .image]
        panel.title = NSLocalizedString(
            "Choose custom thumbnail",
            comment: "File panel title"
        )
        panel.message = NSLocalizedString(
            "Pick a JPG, PNG, or HEIC image. It will be resized to 480x300 maximum.",
            comment: "File panel message"
        )
        guard panel.runModal() == .OK,
              let url = panel.url else { return }
        do {
            try library.setCustomThumbnail(from: url, for: wallpaper)
        } catch {
            importError = error.localizedDescription
            showingImportError = true
        }
    }

    private var titleRow: some View {
        HStack {
            Text("Library")
                .font(.system(size: 22, weight: .medium))
                .tracking(-0.2)
            Spacer()
        }
        .padding(.bottom, 16)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                TextField("Search wallpapers", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Picker("", selection: $typeFilter) {
                ForEach(TypeFilter.allCases, id: \.self) { filter in
                    Text(LocalizedStringKey(filter.rawValue)).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
            .labelsHidden()

            Menu {
                ForEach(SortOrder.allCases, id: \.self) { order in
                    Button(LocalizedStringKey(order.rawValue)) {
                        sortOrder = order
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 11))
                    Text("Sort")
                        .font(.system(size: 12))
                }
            }
            .menuStyle(.borderlessButton)
            .frame(width: 60)

            Menu {
                Button("From files...") { runFileImport() }
                Button("From folder...") { runFolderImport() }
                Button("From GIF URL...") { showingGifImport = true }
                Divider()
                Button("From Wallpaper Engine (.we)...") {
                    runWallpaperEngineImport()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                    Text("Import")
                        .font(.system(size: 12, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.bottom, 12)
    }

    private var counterLine: some View {
        let count = filteredAndSorted.count
        let bytes = library.totalSizeBytes
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB, .useGB]
        formatter.countStyle = .file
        let sizeString = bytes > 0
            ? formatter.string(fromByteCount: bytes)
            : NSLocalizedString("0 bytes", comment: "Library size")
        let key = count == 1
            ? "%d wallpaper · %@"
            : "%d wallpapers · %@"
        let summary = String(
            format: NSLocalizedString(key, comment: "Library summary"),
            count,
            sizeString
        )
        return Text(summary)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.bottom, 12)
            .padding(.horizontal, 2)
    }

    @ViewBuilder
    private var interpolationQueueSection: some View {
        if !interpolationQueue.jobs.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("FRAME INTERPOLATION QUEUE")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .tracking(0.4)
                    Spacer()
                    if interpolationQueue.jobs.contains(where: { !$0.isFinished }) {
                        Button {
                            interpolationQueue.setPaused(
                                !interpolationQueue.isPaused
                            )
                        } label: {
                            Label(
                                interpolationQueue.isPaused
                                    ? NSLocalizedString(
                                        "Resume", comment: "Queue action"
                                    )
                                    : NSLocalizedString(
                                        "Pause", comment: "Queue action"
                                    ),
                                systemImage: interpolationQueue.isPaused
                                    ? "play.fill"
                                    : "pause.fill"
                            )
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                    }
                    if interpolationQueue.jobs.contains(where: { $0.isFinished }) {
                        Button("Clear") {
                            interpolationQueue.clearFinished()
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                    }
                }
                .padding(.bottom, 8)

                Card {
                    ForEach(interpolationQueue.jobs) { job in
                        FrameInterpolationQueueRow(job: job)
                        if job.id != interpolationQueue.jobs.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .padding(.bottom, 16)
        }
    }

    private var wallpaperGrid: some View {
        LazyVGrid(
            columns: [GridItem(
                .adaptive(minimum: 140, maximum: 200),
                spacing: 10
            )],
            spacing: 10
        ) {
            ForEach(filteredAndSorted) { wallpaper in
                WallpaperCard(
                    wallpaper: wallpaper,
                    isSelected: wallpaper.id == selectedID
                )
                .contentShape(Rectangle())
                .onTapGesture { selectedID = wallpaper.id }
                .contextMenu {
                    Button("Set Custom Thumbnail...") {
                        setCustomThumbnail(for: wallpaper)
                    }
                    if library.hasCustomThumbnail(for: wallpaper) {
                        Button("Reset to Auto Thumbnail") {
                            library.clearCustomThumbnail(for: wallpaper)
                        }
                    }
                    Divider()
                    if wallpaper.kind == .builtInGradient {
                        Text("Animated Gradient cannot be removed")
                    } else {
                        Button(role: .destructive) {
                            library.remove(wallpaper)
                            if selectedID == wallpaper.id {
                                selectedID = nil
                            }
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private var restoreFooter: some View {
        HStack {
            Spacer()
            Button {
                library.restoreBuiltIns()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11))
                    Text("Restore built-in wallpapers")
                        .font(.system(size: 11))
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 18)
    }

    private var filteredAndSorted: [Wallpaper] {
        var items = library.wallpapers
        switch typeFilter {
        case .all: break
        case .video: items = items.filter { $0.kind == .video }
        case .gif:
            items = items.filter {
                $0.kind == .gif || $0.kind == .gifURL
            }
        case .builtin:
            items = items.filter {
                $0.kind == .builtInGradient || $0.kind == .procedural
            }
        }
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            items = items.filter {
                $0.name.localizedCaseInsensitiveContains(query)
            }
        }
        switch sortOrder {
        case .recentlyAdded:
            items.sort { $0.addedDate > $1.addedDate }
        case .name:
            items.sort {
                $0.name.localizedCaseInsensitiveCompare($1.name)
                    == .orderedAscending
            }
        case .type:
            items.sort { $0.kind.rawValue < $1.kind.rawValue }
        }
        return items
    }

    private func runFileImport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "mp4")!,
            UTType(filenameExtension: "mov")!,
            UTType(filenameExtension: "m4v")!,
            UTType(filenameExtension: "gif")!,
        ]
        panel.title = NSLocalizedString(
            "Import wallpapers",
            comment: "File panel title"
        )
        panel.message = NSLocalizedString(
            "Select MP4, MOV, M4V, or GIF files",
            comment: "File panel message"
        )
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do { _ = try library.importFile(at: url) }
            catch let error as WallpaperImportError {
                importError = error.errorDescription
                showingImportError = true
            } catch {
                importError = error.localizedDescription
                showingImportError = true
            }
        }
    }

    private func runFolderImport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.title = NSLocalizedString(
            "Import from folder",
            comment: "File panel title"
        )
        panel.message = NSLocalizedString(
            "Select a folder. All MP4, MOV, M4V, and GIF files inside will be imported.",
            comment: "File panel message"
        )
        guard panel.runModal() == .OK,
              let folderURL = panel.url else { return }
        let imported = library.importFolder(at: folderURL)
        if imported.isEmpty {
            importError = NSLocalizedString(
                "No video or GIF files found in that folder.",
                comment: "Import error"
            )
            showingImportError = true
        }
    }

    private func runWallpaperEngineImport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.title = NSLocalizedString(
            "Import Wallpaper Engine wallpaper",
            comment: "File panel title"
        )
        panel.message = NSLocalizedString(
            "Select a .we file from your Wallpaper Engine library.",
            comment: "File panel message"
        )
        if let weType = UTType(filenameExtension: "we") {
            panel.allowedContentTypes = [weType]
        }
        guard panel.runModal() == .OK,
              let weURL = panel.url else { return }
        do {
            _ = try WallpaperEngineImporter.importArchive(at: weURL)
        } catch let error as WallpaperEngineImporter.ImportError {
            importError = error.errorDescription
            showingImportError = true
        } catch {
            importError = error.localizedDescription
            showingImportError = true
        }
    }
}

private struct WallpaperCard: View {
    let wallpaper: Wallpaper
    let isSelected: Bool
    @StateObject private var library = WallpaperLibrary.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                thumbnail
                typePill
            }
            footer
        }
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isSelected
                        ? Color.accentColor
                        : Color.primary.opacity(0.08),
                    lineWidth: isSelected ? 2 : 0.5
                )
        )
    }

    @ViewBuilder
    private var thumbnail: some View {
        if library.hasAnyThumbnail(for: wallpaper),
           let nsImage = NSImage(
               contentsOf: library.displayThumbnailURL(for: wallpaper)
           )
        {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(16.0 / 10.0, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .clipped()
        } else {
            Rectangle()
                .fill(thumbnailGradient)
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
        }
    }

    private var thumbnailGradient: LinearGradient {
        switch wallpaper.kind {
        case .builtInGradient:
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.10, blue: 0.22),
                    Color(red: 0.24, green: 0.06, blue: 0.12),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .procedural:
            proceduralGradient(for: wallpaper.proceduralKey ?? "")
        case .video:
            LinearGradient(
                colors: [
                    Color(red: 0.15, green: 0.18, blue: 0.30),
                    Color(red: 0.10, green: 0.12, blue: 0.18),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .gif, .gifURL:
            LinearGradient(
                colors: [
                    Color(red: 0.30, green: 0.20, blue: 0.40),
                    Color(red: 0.15, green: 0.10, blue: 0.20),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .url, .image:
            LinearGradient(
                colors: [.gray.opacity(0.4), .gray.opacity(0.2)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
    }

    private func proceduralGradient(for key: String) -> LinearGradient {
        let colors: [Color] = switch key {
        case "aurora":
            [
                Color(red: 0.10, green: 0.30, blue: 0.40),
                Color(red: 0.30, green: 0.10, blue: 0.45),
            ]
        case "synthwave":
            [
                Color(red: 0.85, green: 0.20, blue: 0.50),
                Color(red: 0.10, green: 0.02, blue: 0.30),
            ]
        case "starfield":
            [Color(red: 0.04, green: 0.04, blue: 0.10), .black]
        case "neural-network":
            [
                Color(red: 0.10, green: 0.20, blue: 0.40),
                Color(red: 0.04, green: 0.05, blue: 0.10),
            ]
        default: [.gray, .black]
        }
        return LinearGradient(
            colors: colors,
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    private var typePill: some View {
        HStack(spacing: 4) {
            Image(systemName: typeIcon)
                .font(.system(size: 9))
            Text(LocalizedStringKey(typeLabel))
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(8)
    }

    private var typeIcon: String {
        switch wallpaper.kind {
        case .builtInGradient: "sparkles"
        case .procedural: "wand.and.stars"
        case .video: "play.fill"
        case .gif: "photo.stack"
        case .gifURL: "photo.stack"
        case .url: "questionmark.circle"
        case .image: "photo"
        }
    }

    private var typeLabel: String {
        switch wallpaper.kind {
        case .builtInGradient: "BUILT-IN"
        case .procedural: "BUILT-IN"
        case .video: "VIDEO"
        case .gif: "GIF"
        case .gifURL: "GIF · URL"
        case .url: "URL"
        case .image: "IMAGE"
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(wallpaper.localizedName)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Text(metaLine)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metaLine: String {
        switch wallpaper.kind {
        case .builtInGradient:
            NSLocalizedString(
                "Lightweight · Cannot be removed",
                comment: "Wallpaper metadata"
            )
        case .procedural:
            NSLocalizedString(
                "Procedural · Zero MB",
                comment: "Wallpaper metadata"
            )
        case .video:
            wallpaper.fileSizeString
                ?? NSLocalizedString("Video", comment: "Wallpaper type")
        case .gif:
            wallpaper.fileSizeString ?? "GIF"
        case .gifURL:
            wallpaper.urlHost
                ?? NSLocalizedString("Remote GIF", comment: "Wallpaper type")
        case .url:
            wallpaper.urlHost
                ?? NSLocalizedString("Deprecated URL", comment: "Wallpaper type")
        case .image:
            wallpaper.fileSizeString
                ?? NSLocalizedString("Still image", comment: "Wallpaper type")
        }
    }
}

private struct FrameInterpolationQueueRow: View {
    let job: RifeInterpolationQueue.Job

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                Text(job.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(statusLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(statusColor)
            }

            ProgressView(value: job.progress)
                .progressViewStyle(.linear)
                .tint(statusColor)

            HStack(spacing: 8) {
                Text(detailLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(Int((job.progress * 100).rounded()))%")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var statusLabel: String {
        switch job.status {
        case .queued: NSLocalizedString("Queued", comment: "Queue status")
        case .processing: NSLocalizedString("Processing", comment: "Queue status")
        case .completed: NSLocalizedString("Completed", comment: "Queue status")
        case .failed: NSLocalizedString("Failed", comment: "Queue status")
        }
    }

    private var statusIcon: String {
        switch job.status {
        case .queued: "clock"
        case .processing: "arrow.triangle.2.circlepath"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch job.status {
        case .queued: .secondary
        case .processing: .accentColor
        case .completed: .green
        case .failed: .red
        }
    }

    private var detailLabel: String {
        switch job.status {
        case .queued:
            if job.targetFrameRates.isEmpty {
                return NSLocalizedString(
                    "Preparing frame-rate plan...",
                    comment: "Queue detail"
                )
            }
            return String(
                format: NSLocalizedString(
                    "%d target rates queued",
                    comment: "Queue detail"
                ),
                job.targetFrameRates.count
            )
        case .processing:
            let frameRate = job.currentFrameRate.map {
                String(
                    format: NSLocalizedString("%d FPS", comment: "Frame rate"),
                    $0
                )
            } ?? NSLocalizedString("Preparing", comment: "Queue detail")
            let completed = job.completedFrameRates.count
            let total = job.targetFrameRates.count
            return String(
                format: NSLocalizedString(
                    "%@ · %d/%d variants",
                    comment: "Queue detail"
                ),
                frameRate,
                completed,
                total
            )
        case .completed:
            return String(
                format: NSLocalizedString(
                    "%d variants ready",
                    comment: "Queue detail"
                ),
                job.completedFrameRates.count
            )
        case .failed:
            return job.errorMessage ?? NSLocalizedString(
                "Frame interpolation failed",
                comment: "Queue detail"
            )
        }
    }
}
