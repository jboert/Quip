// ProjectsTab.swift
// QuipMac — Settings window pane (split out of SettingsView.swift)

import SwiftUI
import Darwin
import AppKit

// MARK: - Projects Tab
//
// Consolidates the former Directories, swrm, and Prompts tabs into one
// grouped Form with three sections. Each retains its own backing store and
// add/remove flow — only the chrome merged:
//   • Spawn Directories — UserDefaults "projectDirectories"
//   • swrm Watched Roots — SwrmProjectStore (UserDefaults "swrmProjectRoots")
//   • Prompt Library — PromptLibrary (FS-backed, broadcasts to phones on change)

struct ProjectsTab: View {
    // Spawn directories
    @AppStorage("projectDirectories") private var directoriesData: Data = Data()
    @State private var directories: [String] = []

    // swrm roots
    @Environment(SwrmProjectStore.self) private var swrm
    @State private var swrmAddError: String?

    var body: some View {
        Form {
            spawnDirectoriesSection
            swrmSection
        }
        .formStyle(.grouped)
        .onAppear { loadDirectories() }
    }

    // MARK: Spawn directories

    @ViewBuilder
    private var spawnDirectoriesSection: some View {
        Section {
            if directories.isEmpty {
                Text("No directories yet. Add folders to quickly spawn new terminal sessions from the phone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(directories, id: \.self) { dir in
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.secondary)
                        Text(dir)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Remove \(dir)", systemImage: "xmark.circle", role: .destructive) {
                            directories.removeAll { $0 == dir }
                            saveDirectories()
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                }
            }
            Button { addDirectory() } label: {
                Label("Add Directory…", systemImage: "plus")
            }
        } header: {
            Text("Spawn Directories (\(directories.count))")
        } footer: {
            Text("Roots offered when the phone spawns a new terminal session.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func loadDirectories() {
        // An EMPTY blob is the ordinary "never configured" state (the
        // @AppStorage default), so it must stay silent. A non-empty blob that
        // won't decode is a real failure: the user's configured roots silently
        // disappear from Settings and from the phone's spawn picker.
        do {
            guard !directoriesData.isEmpty else { return }
            directories = try JSONDecoder().decode([String].self, from: directoriesData)
        } catch {
            QuipLog.write(
                severity: .error, subsystem: "settings",
                message: "projectDirectories failed to decode (\(directoriesData.count) bytes) "
                       + "— configured project roots will appear empty: \(error)",
                to: LogPaths.webSocketPath
            )
        }
    }

    private func saveDirectories() {
        do {
            directoriesData = try JSONEncoder().encode(directories)
        } catch {
            QuipLog.write(
                severity: .error, subsystem: "settings",
                message: "could not encode \(directories.count) project directories "
                       + "— the edit was NOT saved and is lost on relaunch: \(error)",
                to: LogPaths.webSocketPath
            )
        }
    }

    private func addDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a project directory"

        if panel.runModal() == .OK, let url = panel.url {
            let path = url.path
            if !directories.contains(path) {
                directories.append(path)
                saveDirectories()
            }
        }
    }

    // MARK: swrm roots

    @ViewBuilder
    private var swrmSection: some View {
        Section {
            if swrm.roots.isEmpty {
                Text("Add a swrm project root to get a phone card, push, and a terminal notice when one of its stories moves to In Progress.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(swrm.roots, id: \.self) { root in
                    HStack(spacing: 8) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text((root as NSString).lastPathComponent)
                                .font(.body)
                            Text(root)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button("Remove \(root)", systemImage: "xmark.circle", role: .destructive) {
                            swrm.remove(path: root)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                }
            }
            if let swrmAddError {
                Text(swrmAddError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Button { addSwrmRoot() } label: {
                Label("Add Project…", systemImage: "plus")
            }
        } header: {
            Text("swrm Watched Roots (\(swrm.roots.count))")
        } footer: {
            Text("Each root is tailed live — add or remove without restarting Quip.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func addSwrmRoot() {
        swrmAddError = nil
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a swrm project root (the folder that contains, or will contain, .swrm/)"

        if panel.runModal() == .OK, let url = panel.url {
            if let error = swrm.add(path: url.path) {
                swrmAddError = error.localizedDescription
            }
        }
    }

}
