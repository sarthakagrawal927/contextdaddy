import AppKit
import ContextCore
import SwiftUI

struct SkillLibraryView: View {
    @Environment(ContextDaddyModel.self) private var model
    @State private var query = ""
    @AppStorage("skillLibraryGuideCompleted") private var guideCompleted = false
    @State private var guideOpen = false
    @State private var guideStep = 0
    @FocusState private var searchFocused: Bool
    private var showsGuide: Bool { guideOpen || !guideCompleted }
    @State private var ownership: SkillOwnership?
    @State private var agent: AgentRuntime?
    @State private var location: String?
    @State private var selectedID: String?
    @State private var page = 0
    @State private var tab = "Overview"
    @State private var favorites = Set(UserDefaults.standard.stringArray(forKey: "skillLibraryFavorites") ?? [])
    @State private var favoriteOnly = false
    @State private var tags = UserDefaults.standard.dictionary(forKey: "skillLibraryTags") as? [String: String] ?? [:]
    @State private var document: String?
    @State private var plan: SkillChangePlan?
    @State private var error: String?
    @State private var notice: String?
    @State private var working = false
    @State private var editor = false
    @State private var draft = ""
    @State private var showCreate = false
    @State private var sharingSkill: SkillRecord?
    @State private var showLocations = false
    @State private var showHistory = false
    @State private var receipts: [SkillChangeReceipt] = []
    @State private var restoreReceipt: SkillChangeReceipt?
    @State private var manager = SkillLibraryManager()

    private var records: [SkillRecord] { model.catalog?.records ?? [] }
    private var results: [SkillRecord] {
        let base = SkillLibraryIndex.matching(records, query: "", ownership: ownership, runtime: agent, location: location)
            .filter { !favoriteOnly || favorites.contains($0.id) }
        guard !query.isEmpty else { return base }
        let matchingIDs = Set(SkillLibraryIndex.matching(base, query: query).map(\.id))
        return base.filter { matchingIDs.contains($0.id) || tags[$0.id, default: ""].localizedCaseInsensitiveContains(query) }
    }
    private var selection: SkillRecord? { results.first { $0.id == selectedID } ?? visible.first }
    private var pageCount: Int { max(1, (results.count + 7) / 8) }
    private var visible: [SkillRecord] { Array(results.dropFirst(min(page, pageCount - 1) * 8).prefix(8)) }

    var body: some View {
        GeometryReader { geometry in
            // Legacy scrollers reserve layout space; overlay scrollers do not.
            let scrollbarWidth = NSScroller.preferredScrollerStyle == .legacy
                ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
            let contentWidth = max(0, geometry.size.width - scrollbarWidth)
            ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    summary
                    if showsGuide && contentWidth >= 1180 {
                        HStack(alignment: .top, spacing: 20) {
                            workspace(width: contentWidth - 344, scroll: scroll)
                            guide(scroll: scroll).frame(width: 280)
                        }
                    } else {
                        if showsGuide { guide(scroll: scroll) }
                        workspace(width: contentWidth - 44, scroll: scroll)
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .onChange(of: selectedID) { _, value in
                if value != nil {
                    if showsGuide && guideStep == 0 { guideStep = 1 }
                    let availableWidth = contentWidth - (showsGuide && contentWidth >= 1180 ? 344 : 44)
                    scroll.scrollTo(availableWidth < 850 ? "skill-inspector" : "skill-columns", anchor: .top)
                }
            }
            }
        }
        .onChange(of: query) { _, _ in resetPage() }
        .onChange(of: ownership) { _, _ in resetPage() }
        .onChange(of: agent) { _, _ in resetPage() }
        .onChange(of: location) { _, _ in resetPage() }
        .onChange(of: favoriteOnly) { _, _ in resetPage() }
        .onChange(of: selection?.id) { _, _ in document = nil; tab = "Overview" }
        .sheet(item: $plan) { pending in changePreview(pending) }
        .sheet(isPresented: $editor) { contentEditor }
        .sheet(item: $sharingSkill) { skill in
            SkillShareSheet(skill: skill) { parent, project in
                sharingSkill = nil
                if let project, !model.extraRoots.contains(project.path) { model.extraRoots.append(project.path) }
                rememberLocation(parent)
                perform { try await manager.prepareLink(skill: URL(fileURLWithPath: skill.id), parent: parent) }
            }
        }
        .sheet(isPresented: $showCreate) {
            SkillCreateSheet { parent, name, text in
                showCreate = false
                rememberLocation(parent)
                perform { try await manager.prepareCreate(parent: parent, name: name, text: text) }
            }
        }
        .sheet(isPresented: $showLocations) { locationsSheet }
        .sheet(isPresented: $showHistory) { historySheet }
        .confirmationDialog("Restore this change? Newer edits are protected; the current version is retained in recovery storage.", isPresented: Binding(get: { restoreReceipt != nil }, set: { if !$0 { restoreReceipt = nil } })) {
            Button("Restore change") {
                guard let receipt = restoreReceipt else { return }
                restoreReceipt = nil
                Task {
                    do { try await manager.restore(receipt.id); receipts = try await manager.history(); await model.refreshSkillLibrary(); notice = "Change restored." }
                    catch { self.error = error.localizedDescription }
                }
            }
        }
    }

    private func workspace(width availableWidth: CGFloat, scroll: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 18) {
                    filters
                    if let notice { Text(notice).font(.callout).foregroundStyle(DaddyTheme.mint).textSelection(.enabled) }
                    if let error { Text(error).font(.callout).foregroundStyle(DaddyTheme.coral).textSelection(.enabled) }
                    if model.lastError != nil { Text("Scan needs attention. Showing the last available library.").foregroundStyle(DaddyTheme.amber) }
                    if results.isEmpty {
                        ContentUnavailableView(model.isLoading ? "Scanning skill locations…" : "No matching skills", systemImage: "books.vertical",
                            description: Text(records.isEmpty ? "Add a skill folder or search location to begin." : "Try another search, agent, or ownership filter."))
                    } else if availableWidth >= 850 {
                        HStack(alignment: .top, spacing: 16) {
                            libraryList.frame(width: min(360, availableWidth * 0.35))
                            if let selection { inspector(selection, scroll: scroll).frame(maxWidth: .infinity, alignment: .topLeading) }
                        }.id("skill-columns")
                    } else {
                        libraryList.id("skill-list")
                        if let selection {
                            Button("Back to skills") { scroll.scrollTo("skill-list", anchor: .top) }
                                .buttonStyle(ContextDaddyButtonStyle()).id("skill-inspector")
                            inspector(selection, scroll: scroll)
                        }
                    }
        }.frame(width: max(0, availableWidth), alignment: .leading)
    }

    private func guide(scroll: ScrollViewProxy) -> some View {
        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("YOUR FIRST SKILL · \(guideStep + 1) OF 3")
                        .font(.caption2.weight(.bold)).foregroundStyle(DaddyTheme.mint)
                    Spacer()
                    Button("Skip") { guideCompleted = true; guideOpen = false }
                        .font(.caption).accessibilityLabel("Dismiss skill guide")
                }
                Text(["Find something you use", "See who can use it", "Know what you can change"][guideStep])
                    .font(.title3.weight(.semibold))
                Text([
                    "Search a name or topic, then select a skill. One definition can appear in several locations through links. Browsing changes nothing.",
                    "Open Access on the selected skill. It explains each agent’s discovery and invocation policy. An installed plugin is not necessarily enabled.",
                    "Local skills can be edited or shared after a preview. Linked locations use the same definition. Plugin-managed skills are changed through their installer. History keeps recovery records for changes made here."
                ][guideStep]).font(.callout).foregroundStyle(DaddyTheme.muted).fixedSize(horizontal: false, vertical: true)
                if guideStep == 0 {
                    Button("Find a skill") {
                        searchFocused = true
                        scroll.scrollTo("skill-search", anchor: .top)
                    }
                } else if guideStep == 1 {
                    Button("Show agent access") {
                        tab = "Access"
                        scroll.scrollTo(selection?.id, anchor: .top)
                    }.disabled(selection == nil)
                } else {
                    Button("Explore this skill") {
                        tab = "Overview"
                        guideCompleted = true; guideOpen = false
                        scroll.scrollTo(selection?.id, anchor: .top)
                    }.disabled(selection == nil)
                }
                HStack {
                    if guideStep > 0 { Button("Back") { guideStep -= 1 } }
                    Spacer()
                    Button(guideStep == 2 ? "Finish guide" : "Next") {
                        if guideStep == 2 { guideCompleted = true; guideOpen = false }
                        else { guideStep += 1 }
                    }
                }.font(.caption)
                Text("Reopen anytime with Guide.").font(.caption2).foregroundStyle(DaddyTheme.muted)
            }
        }
        .id("skill-guide")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Skill library guide")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("YOUR SKILLS, ONE LIBRARY").font(.caption.weight(.semibold)).tracking(1.4).foregroundStyle(DaddyTheme.mint)
                    Text("Skills").font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("Search for a skill, then select it to see its instructions and which agents can use it.").foregroundStyle(DaddyTheme.muted)
                }
                Spacer()
                ContextDoodleArt(topic: .skills).frame(width: 92, height: 72)
            }
            ViewThatFits(in: .horizontal) {
                HStack { actions; Spacer(); navigation }
                VStack(alignment: .leading, spacing: 10) { actions; navigation }
            }
        }
    }
    private var actions: some View {
        HStack {
            Menu {
                Button("Create skill…") { showCreate = true }
                Button("Import local skill folder…") { importFolder() }
                Button("Add search location…") { addLocation() }
            } label: { Label("Add skill", systemImage: "plus") }
            .menuStyle(.borderlessButton).fixedSize().padding(9).background(DaddyTheme.mint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            Button("Guide") { guideOpen = true; guideStep = 0 }
            Button("Locations") { showLocations = true }
            Button("History") { Task { do { receipts = try await manager.history(); showHistory = true } catch { self.error = error.localizedDescription } } }
        }.buttonStyle(ContextDaddyButtonStyle()).disabled(working)
    }
    private var navigation: some View {
        HStack {
            Button("Agent policies") { model.skillsMode = .ledger }
            Button("Review duplicates") { model.skillsMode = .redundancy }
        }.buttonStyle(ContextDaddyButtonStyle())
    }
    private var summary: some View {
        Panel(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 24) { summaryFacts }
                    VStack(alignment: .leading, spacing: 6) { summaryFacts }
                }
                HStack {
                    Text(model.catalog?.coverage.isPartial == true ? "Some folders could not be fully scanned. Open Locations to see what is missing." : "Locations include links to the same skill. Installed plugins may not be enabled.")
                        .font(.caption).foregroundStyle(model.catalog?.coverage.isPartial == true ? DaddyTheme.amber : DaddyTheme.muted)
                    Spacer()
                    Button(model.isLoading ? "Scanning…" : "Rescan") { Task { await model.refreshSkillLibrary() } }.disabled(model.isLoading)
                }
            }
        }
    }
    @ViewBuilder private var summaryFacts: some View {
        Text("\(records.count) skill definitions").fontWeight(.semibold)
        Text("\(records.reduce(0) { $0 + $1.exposures.count }) agent locations").foregroundStyle(DaddyTheme.muted)
        Text("\(records.filter { $0.ownership == .plugin }.count) plugin managed").foregroundStyle(DaddyTheme.muted)
    }
    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search skills, agents, paths, descriptions, or tags", text: $query).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search skill library").focused($searchFocused).id("skill-search")
            ViewThatFits(in: .horizontal) {
                HStack { filterMenus; Spacer(); favoritesButton }
                VStack(alignment: .leading) { filterMenus; favoritesButton }
            }
        }
    }
    private var filterMenus: some View {
        ViewThatFits(in: .horizontal) {
            HStack { ownerPicker; agentPicker; locationPicker }
            VStack(alignment: .leading, spacing: 8) { ownerPicker; agentPicker; locationPicker }
        }.font(.caption)
    }
    private var ownerPicker: some View {
            Picker("Owner", selection: $ownership) {
                Text("All owners").tag(nil as SkillOwnership?)
                ForEach(SkillOwnership.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
            }
    }
    private var agentPicker: some View {
            Picker("Agent", selection: $agent) {
                Text("All agents").tag(nil as AgentRuntime?)
                ForEach(AgentRuntime.allCases) { Text($0.rawValue).tag(Optional($0)) }
            }
    }
    private var locationPicker: some View {
            Menu {
                Button("All locations") { location = nil }
                ForEach(Array(Set(records.flatMap { $0.exposures.map(\.source) })).sorted(), id: \.self) { source in
                    Button(source) { location = source }
                }
            } label: { Label(location ?? "All locations", systemImage: "folder") }
            .fixedSize(horizontal: true, vertical: false)
    }
    private var favoritesButton: some View {
        Button { favoriteOnly.toggle() } label: { Label("Favorites", systemImage: favoriteOnly ? "star.fill" : "star") }
            .buttonStyle(ContextDaddyButtonStyle()).accessibilityValue(favoriteOnly ? "On" : "Off")
    }
    private var libraryList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(results.count) matching skills").font(.caption).foregroundStyle(DaddyTheme.muted)
            ForEach(visible) { skill in
                Button { selectedID = skill.id } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(skill.name).font(.headline).lineLimit(1)
                            Spacer(minLength: 2)
                            if favorites.contains(skill.id) { Image(systemName: "star.fill").foregroundStyle(DaddyTheme.amber) }
                            if skill.hasDefinitionConflict { Image(systemName: "exclamationmark.triangle").foregroundStyle(DaddyTheme.amber) }
                        }
                        Text(skill.description).font(.caption).foregroundStyle(DaddyTheme.muted).lineLimit(2)
                        Text(skill.locationSummary).font(.caption2).foregroundStyle(DaddyTheme.mint)
                    }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                        .background(selection?.id == skill.id ? DaddyTheme.mint.opacity(0.14) : DaddyTheme.raised, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selection?.id == skill.id ? DaddyTheme.mint : DaddyTheme.line))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(selection?.id == skill.id ? .isSelected : [])
            }
            HStack {
                Button("Previous") { page = max(0, page - 1); selectedID = visible.first?.id }.disabled(page == 0)
                Spacer()
                Text("\(min(page, pageCount - 1) + 1) / \(pageCount)").font(.caption.monospacedDigit())
                Spacer()
                Button("Next") { page += 1; selectedID = visible.first?.id }.disabled(page >= pageCount - 1)
            }.buttonStyle(ContextDaddyButtonStyle())
        }
    }
    private func inspector(_ skill: SkillRecord, scroll: ScrollViewProxy) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 16) {
                if showsGuide {
                    Button("Back to guide") { scroll.scrollTo("skill-guide", anchor: .top) }
                        .font(.caption)
                }
                HStack(alignment: .top) {
                    Text(skill.name).font(.system(size: 24, weight: .semibold, design: .rounded)).textSelection(.enabled)
                    Spacer()
                    Button {
                        if favorites.contains(skill.id) { favorites.remove(skill.id) } else { favorites.insert(skill.id) }
                        UserDefaults.standard.set(Array(favorites), forKey: "skillLibraryFavorites")
                    } label: { Image(systemName: favorites.contains(skill.id) ? "star.fill" : "star") }.help("Favorite this skill")
                }
                Text(skill.description).font(.callout).foregroundStyle(DaddyTheme.muted).textSelection(.enabled)
                Picker("Skill details", selection: $tab) {
                    ForEach(["Overview", "Content", "Access"], id: \.self) { Text($0) }
                }.pickerStyle(.segmented).labelsHidden()
                if tab == "Overview" { overview(skill) }
                else if tab == "Content" { content(skill) }
                else { access(skill) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.id(skill.id)
    }
    private func overview(_ skill: SkillRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(skill.ownership.rawValue, systemImage: skill.ownership == .local ? "doc.text" : "shippingbox").foregroundStyle(DaddyTheme.mint)
            Text("Physical definition").font(.caption).foregroundStyle(DaddyTheme.muted)
            path(skill.id)
            TextField("Tags, separated by commas", text: Binding(get: { tags[skill.id, default: ""] }, set: {
                tags[skill.id] = $0; UserDefaults.standard.set(tags, forKey: "skillLibraryTags")
            })).textFieldStyle(.roundedBorder)
            Text("Tags and favorites stay in ContextDaddy.").font(.caption2).foregroundStyle(DaddyTheme.muted)
            Divider()
            Text("Where this skill appears").font(.headline)
            ForEach(skill.exposures) { exposure in
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(exposure.provider.rawValue) · \(exposure.scope.rawValue) · \(exposure.applicability.rawValue)").font(.caption.weight(.semibold))
                    path(exposure.logicalPath)
                    Text(exposure.logicalPath == exposure.resolvedPath ? "Physical source" : "Linked to the physical source above").font(.caption2).foregroundStyle(DaddyTheme.muted)
                }
            }
            if skill.hasDefinitionConflict {
                Button("Review overlapping definitions") { model.search = skill.name; model.skillsMode = .redundancy }
                    .buttonStyle(ContextDaddyButtonStyle())
            }
            if skill.ownership == .local {
                ViewThatFits(in: .horizontal) {
                    HStack { managementActions(skill) }
                    VStack(alignment: .leading) { managementActions(skill) }
                }
            } else {
                Text("Managed by \(skill.ownership == .plugin ? "the plugin installer" : "the system skill owner"). Update or remove it through that owner. Cached installation alone does not prove agent access.")
                    .font(.callout).foregroundStyle(DaddyTheme.amber)
            }
        }
    }
    @ViewBuilder private func managementActions(_ skill: SkillRecord) -> some View {
        Button("Edit content") { loadEditor(skill) }
        Button("Update from folder…") {
            guard let source = chooseFolder("Choose the replacement skill folder") else { return }
            perform { try await manager.prepareUpdate(skill: URL(fileURLWithPath: skill.id), source: source) }
        }
        Menu("More") {
            Button("Share to agent or project…") { share(skill) }
            Button("Archive skill…") { perform { try await manager.prepareArchive(skill: URL(fileURLWithPath: skill.id)) } }
        }
    }
    private func content(_ skill: SkillRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let document {
                Text(document).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if skill.ownership == .local { Button("Edit content") { draft = document; editor = true }.buttonStyle(ContextDaddyButtonStyle()) }
            } else {
                Text("Open SKILL.md explicitly to inspect its instructions. Supporting scripts are never executed.").foregroundStyle(DaddyTheme.muted)
                Button("Read SKILL.md") {
                    do {
                        let result = try SkillDocumentReader.read(url: URL(fileURLWithPath: skill.id))
                        document = result.text
                        if result.truncated { notice = "Preview is truncated to 256 KiB. Editing is unavailable for larger documents." }
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(ContextDaddyButtonStyle())
            }
        }
    }
    private func access(_ skill: SkillRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Discovery, invocation, and installation are separate controls. These policies describe local evidence, not a live session.").font(.caption).foregroundStyle(DaddyTheme.muted)
            ForEach(skill.policies) { policy in
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text(policy.runtime.rawValue).font(.headline); Spacer(); Text(policy.mode.rawValue).font(.caption).foregroundStyle(DaddyTheme.color(for: policy.mode)) }
                    Text(policy.reason).font(.caption).textSelection(.enabled)
                    Text(policy.explicit ? "Explicit control" : "Derived default · no explicit override found").font(.caption2).foregroundStyle(DaddyTheme.muted)
                    if policy.isExposed {
                        Button("Copy \(policy.invocation)") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(policy.invocation, forType: .string) }
                    }
                }
                Divider()
            }
            Text("Edit SKILL.md to change its declared controls. Codex may also use agents/openai.yaml; global settings and plugin enablement remain with their owning agent.").font(.caption).foregroundStyle(DaddyTheme.muted)
            if skill.ownership == .local {
                Button("Share to agent or project…") { share(skill) }.buttonStyle(ContextDaddyButtonStyle())
                ForEach(skill.exposures.filter { $0.logicalPath != $0.resolvedPath }) { exposure in
                    Button("Remove link: \(exposure.logicalPath)") {
                        perform { try await manager.prepareUnlink(path: URL(fileURLWithPath: exposure.logicalPath).deletingLastPathComponent()) }
                    }.font(.caption).lineLimit(2)
                }
            }
        }
    }
    private func path(_ value: String) -> some View {
        HStack(alignment: .top) {
            Text(value.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: value)]) } label: { Image(systemName: "folder") }.help("Reveal in Finder")
        }
    }
    private var contentEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit skill content").font(.title2.bold())
            Text("Changes affect every link to this physical definition. Review before saving.").foregroundStyle(DaddyTheme.muted)
            TextEditor(text: $draft).font(.system(.body, design: .monospaced)).frame(minHeight: 340)
            HStack {
                Button("Cancel") { editor = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Review changes") {
                    guard let selection else { return }
                    let text = draft
                    editor = false
                    perform { try await manager.prepareEdit(skill: URL(fileURLWithPath: selection.id), text: text) }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 720, height: 560)
    }
    private func changePreview(_ pending: SkillChangePlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(pending.title).font(.title2.bold())
            Text(pending.destination).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Text(pending.detail).foregroundStyle(DaddyTheme.muted)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(pending.fileChanges, id: \.self) { Text($0).font(.caption.monospaced()) }
                    Divider()
                HStack(alignment: .top, spacing: 16) {
                    previewText("Current", pending.before)
                    previewText("Proposed", pending.after)
                }
                }
            }
            HStack {
                Button("Cancel") { plan = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply change") {
                    plan = nil; working = true
                    Task {
                        defer { working = false }
                        do {
                            let receipt = try await manager.apply(pending.id)
                            document = nil
                            notice = "\(receipt.title) completed. Recovery is available in History."
                            await model.refreshSkillLibrary()
                        } catch { self.error = error.localizedDescription }
                    }
                }.keyboardShortcut(.defaultAction).disabled(working || model.isLoading)
            }
        }.padding(24).frame(width: 760, height: 570)
    }
    private func previewText(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.headline)
            Text(text.isEmpty ? "No content" : text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var locationsSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Skill locations").font(.title2.bold())
            Text("Known agent roots and plugin caches are scanned automatically. Add a folder for skills stored elsewhere; adding it to this library does not enable it for any agent.").foregroundStyle(DaddyTheme.muted)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.catalog?.coverage.limitReasons ?? [], id: \.self) { Text($0).foregroundStyle(DaddyTheme.amber) }
                    if let coverage = model.catalog?.coverage {
                        Text("\(coverage.unreadableCount) unreadable locations · \(coverage.skippedLinks) skipped links").font(.caption)
                    }
                    ForEach(Array(Set(model.catalog?.coverage.roots ?? [])).sorted(), id: \.self) { path($0) }
                    Divider()
                    Text("Added skill folders").font(.headline)
                    ForEach(UserDefaults.standard.stringArray(forKey: "contextDaddySkillRoots") ?? [], id: \.self) { root in
                        HStack {
                            path(root)
                            Button("Stop scanning") {
                                let roots = (UserDefaults.standard.stringArray(forKey: "contextDaddySkillRoots") ?? []).filter { $0 != root }
                                UserDefaults.standard.set(roots, forKey: "contextDaddySkillRoots")
                                Task { await model.refreshSkillLibrary() }
                            }
                        }
                    }
                }
            }
            HStack { Button("Add skill location…") { addLocation() }; Spacer(); Button("Done") { showLocations = false }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 720, height: 580)
    }
    private var historySheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Change history & recovery").font(.title2.bold())
            Text("Only changes made through ContextDaddy appear here. Restoring never overwrites newer edits.").foregroundStyle(DaddyTheme.muted)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if receipts.isEmpty { Text("No changes yet.") }
                    ForEach(receipts) { receipt in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(receipt.title).font(.headline)
                            Text(receipt.date, style: .date).font(.caption)
                            path(receipt.destination)
                            if !receipt.completed {
                                Text("Incomplete action · inspect recovery files before retrying").foregroundStyle(DaddyTheme.amber)
                                if let backup = receipt.backupPath { path(backup) }
                            }
                            else if receipt.restored { Text("Restored").foregroundStyle(DaddyTheme.mint) }
                            else { Button("Restore…") { restoreReceipt = receipt } }
                        }
                        Divider()
                    }
                }
            }
            if let error { Text(error).foregroundStyle(DaddyTheme.coral) }
            Button("Done") { showHistory = false }.keyboardShortcut(.cancelAction)
        }.padding(24).frame(width: 720, height: 560)
    }
    private func resetPage() { page = 0; selectedID = nil; document = nil }
    private func perform(_ operation: @escaping () async throws -> SkillChangePlan) {
        working = true; error = nil; notice = nil
        Task { defer { working = false }; do { plan = try await operation() } catch { self.error = error.localizedDescription } }
    }
    private func loadEditor(_ skill: SkillRecord) {
        do {
            let result = try SkillDocumentReader.read(url: URL(fileURLWithPath: skill.id))
            guard !result.truncated else { throw SkillManagementError(message: "This document is too large to edit safely.") }
            draft = result.text; editor = true
        } catch { self.error = error.localizedDescription }
    }
    private func chooseFolder(_ message: String) -> URL? {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }
    private func addLocation() {
        guard let root = chooseFolder("Choose a skill folder or a directory containing skills") else { return }
        var roots = UserDefaults.standard.stringArray(forKey: "contextDaddySkillRoots") ?? []
        if !roots.contains(root.path) { roots.append(root.path); UserDefaults.standard.set(roots, forKey: "contextDaddySkillRoots") }
        Task { await model.refreshSkillLibrary() }
    }
    private func importFolder() {
        guard let source = chooseFolder("Choose one skill folder containing SKILL.md"),
              let parent = chooseFolder("Choose the destination skills directory (for example ~/.agents/skills)") else { return }
        rememberLocation(parent)
        perform { try await manager.prepareImport(source: source, parent: parent) }
    }
    private func share(_ skill: SkillRecord) { sharingSkill = skill }
    private func rememberLocation(_ root: URL) {
        var roots = UserDefaults.standard.stringArray(forKey: "contextDaddySkillRoots") ?? []
        if !roots.contains(root.path) { roots.append(root.path); UserDefaults.standard.set(roots, forKey: "contextDaddySkillRoots") }
    }
}

private struct SkillCreateSheet: View {
    @Environment(\.dismiss) private var dismiss
    let create: (URL, String, String) -> Void
    @State private var name = ""
    @State private var description = ""
    @State private var bodyText = "# Instructions\n\n"
    @State private var parent = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agents/skills")
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create a skill").font(.title2.bold())
            TextField("skill-name", text: $name).textFieldStyle(.roundedBorder)
            TextField("When should an agent use this skill?", text: $description).textFieldStyle(.roundedBorder)
            TextEditor(text: $bodyText).font(.system(.body, design: .monospaced)).frame(minHeight: 220)
            Text(parent.path).font(.caption.monospaced()).textSelection(.enabled)
            Button("Choose destination…") {
                let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                if panel.runModal() == .OK, let url = panel.url { parent = url }
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Review new skill") {
                    let encoded = String(data: try! JSONEncoder().encode(description), encoding: .utf8)!
                    create(parent, name, "---\nname: \(name)\ndescription: \(encoded)\n---\n\n\(bodyText)")
                }.disabled(name.isEmpty || description.isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 680, height: 520)
    }
}

private struct SkillShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    let skill: SkillRecord
    let share: (URL, URL?) -> Void
    @State private var runtime: AgentRuntime = .codex
    @State private var project: URL?
    @State private var projectOnly = false
    private var destination: URL {
        let root = projectOnly ? (project ?? FileManager.default.homeDirectoryForCurrentUser) : FileManager.default.homeDirectoryForCurrentUser
        let directory: String = switch runtime {
        case .codex: ".agents/skills"
        case .claude: ".claude/skills"
        case .cursor: ".cursor/skills"
        case .grok: ".grok/skills"
        case .devin: projectOnly ? ".agents/skills" : ".config/devin/skills"
        }
        return root.appendingPathComponent(directory)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Share \(skill.name)").font(.title2.bold())
            Text("Choose an agent and scope. ContextDaddy creates a link to the existing definition.").foregroundStyle(DaddyTheme.muted)
            Picker("Agent", selection: $runtime) { ForEach(AgentRuntime.allCases) { Text($0.rawValue).tag($0) } }
            Toggle("Only inside a project", isOn: $projectOnly)
            if projectOnly {
                Button(project?.path ?? "Choose project folder…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                    if panel.runModal() == .OK { project = panel.url }
                }
            }
            Text("Destination").font(.headline)
            Text(destination.appendingPathComponent(URL(fileURLWithPath: skill.id).deletingLastPathComponent().lastPathComponent).path)
                .font(.caption.monospaced()).textSelection(.enabled)
            if runtime == .devin {
                Text("Devin local routes are inventory evidence. Runtime discovery and activation must be verified in Devin.").foregroundStyle(DaddyTheme.amber)
            }
            Text("This shares access; it does not force automatic invocation or change agent settings. An existing destination will never be overwritten.").font(.callout).foregroundStyle(DaddyTheme.muted)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Review link") { share(destination, projectOnly ? project : nil) }
                    .disabled(projectOnly && project == nil).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 620)
    }
}
