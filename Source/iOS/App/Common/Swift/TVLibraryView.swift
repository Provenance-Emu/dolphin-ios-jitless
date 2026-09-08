import SwiftUI
import UIKit
import GameController
import UniformTypeIdentifiers
#if os(iOS)
#endif
import Combine

#if os(iOS) || targetEnvironment(macCatalyst)
import UniformTypeIdentifiers
#if canImport(TipKit)
import TipKit
#endif
private struct KeyCommandHostView: UIViewRepresentable {
  let onLeft: () -> Void
  let onRight: () -> Void
  let onUp: () -> Void
  let onDown: () -> Void
  let onEnter: () -> Void
  let onSpace: () -> Void
  func makeUIView(context: Context) -> KeyInputView {
    let v = KeyInputView()
    v.onLeft = onLeft
    v.onRight = onRight
    v.onUp = onUp
    v.onDown = onDown
    v.onEnter = onEnter
    v.onSpace = onSpace
    DispatchQueue.main.async { _ = v.becomeFirstResponder() }
    return v
  }

  func updateUIView(_ uiView: KeyInputView, context: Context) { }
}
#endif // os(iOS) || targetEnvironment(macCatalyst)

// MARK: - Game Grid Item with Focus Management

enum LibraryLayout {
  static var cardSize: CGSize {
#if os(tvOS)
    return CGSize(width: 260, height: 390)
#else
    return CGSize(width: 140, height: 210)
#endif
  }
}

private final class KeyInputView: UIView {
  var onLeft: (() -> Void)?
  var onRight: (() -> Void)?
  var onUp: (() -> Void)?
  var onDown: (() -> Void)?
  var onEnter: (() -> Void)?
  var onSpace: (() -> Void)?
  override var canBecomeFirstResponder: Bool { true }
  override var keyCommands: [UIKeyCommand]? {
    return [
      UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(handleLeft)),
      UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(handleRight)),
      UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(handleUp)),
      UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(handleDown)),
      UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(handleEnter)),
      UIKeyCommand(input: " ", modifierFlags: [], action: #selector(handleSpace))
    ]
  }
  @objc private func handleLeft() { onLeft?() }
  @objc private func handleRight() { onRight?() }
  @objc private func handleUp() { onUp?() }
  @objc private func handleDown() { onDown?() }
  @objc private func handleEnter() { onEnter?() }
  @objc private func handleSpace() { onSpace?() }
}

// MARK: - Retro UI Helpers

extension TVGameItem: Identifiable {}

private extension View {
  func neonGlowBorder(active: Bool, cornerRadius: CGFloat = 16) -> some View {
    modifier(NeonGlowBorder(active: active, cornerRadius: cornerRadius))
  }

  func retroFocusScale(active: Bool) -> some View {
    self
      .scaleEffect(active ? 1.10 : 1.0)
      .animation(.spring(response: 0.35, dampingFraction: 0.75, blendDuration: 0.0), value: active)
  }
}

// MARK: - Clean Game Card Implementation
// All game card logic is now inline in GameGridItem for better control

@MainActor
final class TVLibraryViewModel: ObservableObject {
  /// Backing collection of games shown in the grid
  @Published var games: [TVGameItem] = []
  /// Indicates whether a metadata rescan is in progress
  @Published var isRescanning: Bool = false
  /// Ensures the initial metadata kick-off runs once
  @Published var didKickoffInitialMetadata: Bool = false
  /// Holds a pending selection when a game is already running
  @Published var pendingSelection: TVGameItem?
  /// Controls the replace-running-game confirmation dialog
  @Published var showReplaceAlert: Bool = false
  /// The currently running or most recently launched game
  @Published var currentGame: TVGameItem?
  /// Grouped items by deduplication key
  @Published var groupsByKey: [String: [TVGameItem]] = [:]

  private var cancellables = Set<AnyCancellable>()

  init() {
    LibraryCoordinator.shared.$games
      .receive(on: RunLoop.main)
      .sink { [weak self] items in
        self?.groupAndDedup(items: items)
      }
      .store(in: &cancellables)
    LibraryCoordinator.shared.start()
  }

  /// Loads the current game list from the bridge
  func load() {
    let items = LibraryCoordinator.shared.games
    groupAndDedup(items: items)
  }

  /// Initiates a rescan and metadata fetch, then reloads the list
  func rescan() {
    guard !isRescanning else { return }
    isRescanning = true
    LibraryCoordinator.shared.refreshAll { [weak self] in
      Task { @MainActor in
        self?.isRescanning = false
      }
    }
  }

  /// Triggers metadata fetch on first appearance to populate artwork
  func kickoffInitialMetadataIfNeeded() {
    guard !didKickoffInitialMetadata, !isRescanning else { return }
    didKickoffInitialMetadata = true
    LibraryCoordinator.shared.refreshLocal()
  }

  func loadGameCubeMainMenu() {
    TVLibraryBridge.loadGameCubeMainMenu()
  }

  func performOnlineSystemUpdate() {
    TVLibraryBridge.performOnlineSystemUpdate()
  }

  private func isLocal(_ item: TVGameItem) -> Bool {
    if let scheme = URL(string: item.filePath)?.scheme?.lowercased() { return scheme == "file" }
    return item.filePath.hasPrefix("/")
  }

  private func key(for item: TVGameItem) -> String {
    // Use filePath as fallback when gameID is empty (common for remote games still being processed)
    let gameID = item.gameID.isEmpty ? item.filePath : item.gameID
    return "\(gameID)|\(item.discNumber)|\(item.revision)"
  }

  private func groupAndDedup(items: [TVGameItem]) {
#if DEBUG
    print("TVLibraryViewModel.groupAndDedup(): processing \(items.count) items")
#endif
    var grouped: [String: [TVGameItem]] = [:]
    for it in items {
      let itemKey = key(for: it)
      let isRemote = !isLocal(it)
#if DEBUG
      print("  Item: '\(it.title)' -> Key: '\(itemKey)' (gameID: '\(it.gameID)', discNumber: \(it.discNumber), revision: \(it.revision), isRemote: \(isRemote), titleEmpty: \(it.title.isEmpty))")
#endif
      grouped[itemKey, default: []].append(it)
    }
#if DEBUG
    print("TVLibraryViewModel.groupAndDedup(): created \(grouped.count) groups")
#endif
    groupsByKey = grouped
    var representatives: [TVGameItem] = []
    for (groupKey, group) in grouped {
#if DEBUG
      print("  Group '\(groupKey)': \(group.count) items")
      for (idx, item) in group.enumerated() {
        print("    [\(idx)]: '\(item.title)' (isLocal: \(isLocal(item)), titleEmpty: \(item.title.isEmpty))")
      }
#endif
      if let local = group.first(where: { isLocal($0) }) {
#if DEBUG
        print("    -> Using local representative: '\(local.title)'")
#endif
        representatives.append(local)
      } else if let any = group.first {
#if DEBUG
        print("    -> Using first representative: '\(any.title)' (titleEmpty: \(any.title.isEmpty))")
#endif
        representatives.append(any)
      } else {
#if DEBUG
        print("    -> No representative found (empty group)")
#endif
      }
    }
#if DEBUG
    print("TVLibraryViewModel.groupAndDedup(): found \(representatives.count) representatives")
#endif
    // Sort games alphabetically using fallback to filename when title is empty
    games = representatives.sorted { (a: TVGameItem, b: TVGameItem) -> Bool in
      let at: String = {
        if !a.title.isEmpty { return a.title }
        if let url = URL(string: a.filePath) { return url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? url.lastPathComponent }
        return a.filePath
      }()
      let bt: String = {
        if !b.title.isEmpty { return b.title }
        if let url = URL(string: b.filePath) { return url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? url.lastPathComponent }
        return b.filePath
      }()
      return at.localizedCaseInsensitiveCompare(bt) == .orderedAscending
    }
#if DEBUG
    print("TVLibraryViewModel.groupAndDedup(): final games count: \(games.count)")
#endif
  }

  func sources(for item: TVGameItem) -> [TVGameItem] {
    groupsByKey[key(for: item)] ?? [item]
  }
}

struct TVLibraryView: View {

  @Environment(\.colorScheme) private var colorScheme

  // MARK: - UI Settings

  @AppStorage("library_background_style") private var backgroundStyle: BackgroundStyle = .gradient
  @AppStorage("library_show_subtitles") private var showSubtitles: Bool = true

  // MARK: - Sort settings (persisted)

  /// Field to sort the library by. Persisted via AppStorage.
  @AppStorage("library_sort_field") private var sortField: SortField = .name
  /// Sort direction. true == ascending. Persisted via AppStorage.
  @AppStorage("library_sort_ascending") private var sortAscending: Bool = true

  // MARK: - Platform filter & grid density (persisted)

  @AppStorage("library_platform_filter") private var platformFilter: LibraryPlatformCategory = .all
  @AppStorage("library_grid_column_offset") private var gridColumnOffset: Int = 0

  // MARK: - Multi-select state

  @State private var isSelectionMode = false
  @State private var selectedFilePaths: Set<String> = []
  @State private var platformOverridesVersion: Int = 0
  @State private var showBatchDeleteConfirm = false
  @State private var pendingBatchDeletePaths: Set<String> = []
  @State private var lastPinchScale: CGFloat = 1.0

  enum SortField: String, CaseIterable {
    case name = "name"
    /// File creation date for local items (a.k.a. "Added" / import date).
    case added = "added"
    /// Disc apploader/build date (offset 0x2440, "YYYY/MM/DD"). The on-disc
    /// dates GameCube/Wii volumes carry — the closest thing iCube has to a
    /// release date. There is no GameTDB release-date field on TVGameItem.
    case discDate = "discDate"

    var displayName: String {
      switch self {
      case .name: return L("Name")
      case .added: return L("Date Added")
      case .discDate: return L("Disc Date")
      }
    }

    var systemImage: String {
      switch self {
      case .name: return "textformat"
      case .added: return "clock"
      case .discDate: return "calendar"
      }
    }
  }

  /// Display title used for sorting/searching, falling back to filename when title is empty.
  private static func sortTitle(for item: TVGameItem) -> String {
    if !item.title.isEmpty { return item.title }
    if let url = URL(string: item.filePath) {
      return url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
    }
    return item.filePath
  }

  /// Resolve a local filesystem path from a TVGameItem.filePath (handles both
  /// bare `/path` and `file://` URLs). Returns nil for remote (webdav/http) items.
  private static func localPath(for item: TVGameItem) -> String? {
    if item.filePath.hasPrefix("/") { return item.filePath }
    if let url = URL(string: item.filePath), url.isFileURL { return url.path }
    return nil
  }

  /// Precompute local file dates once per sort pass (never call FileManager inside a comparator).
  /// Uses explicit import timestamps first, then filesystem creation date (not mtime — ROM copies
  /// preserve the source file's modification time from the PC).
  private func addedDates(for items: [TVGameItem]) -> [String: Date] {
    var map: [String: Date] = [:]
    for item in items {
      guard let path = Self.localPath(for: item) else { continue }
      guard let date = LibraryAddedDateStore.resolvedAddedDate(forPath: path) else { continue }
      map[item.filePath] = date
      map[path] = date
    }
    return map
  }

  private var platformOverrides: [String: LibraryPlatformCategory] {
    _ = platformOverridesVersion
    return LibraryPlatformOverrideStore.load()
  }

  private var showPlatformFilterBar: Bool {
    LibraryPlatformMapper.availableCategories(in: model.games, overrides: platformOverrides).count > 1
  }

  /// Clamps auto-fit column count plus user offset for the current platform.
  private func effectiveColumnCount(autoFit: Int) -> Int {
#if os(tvOS)
    return min(7, max(3, autoFit + gridColumnOffset))
#else
    return min(8, max(2, autoFit + gridColumnOffset))
#endif
  }

  private static func tvOSBaseColumns() -> Int { 5 }

  /// Full library pipeline: platform filter → search → sort.
  private func filteredGames(from games: [TVGameItem]) -> [TVGameItem] {
    let overrides = platformOverrides
    var result = games
    if showPlatformFilterBar, platformFilter != .all {
      result = result.filter {
        LibraryPlatformMapper.category(for: $0, override: overrides[$0.filePath]) == platformFilter
      }
    }
    let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    if !q.isEmpty {
      let needle = q.lowercased()
      result = result.filter { item in
        let title = item.title.lowercased()
        if title.contains(needle) { return true }
        if Self.sortTitle(for: item).lowercased().contains(needle) { return true }
        if item.gameID.lowercased().contains(needle) { return true }
        if item.makerLong.lowercased().contains(needle) { return true }
        if item.countryName.lowercased().contains(needle) { return true }
        if item.gametdbID.lowercased().contains(needle) { return true }
        if item.filePath.lowercased().contains(needle) { return true }
        return false
      }
    }
    return applySort(result)
  }

  /// Apply the persisted sort to an already-filtered list of games.
  private func applySort(_ games: [TVGameItem]) -> [TVGameItem] {
    let asc = sortAscending
    switch sortField {
    case .name:
      return games.sorted { a, b in
        let r = Self.sortTitle(for: a).localizedCaseInsensitiveCompare(Self.sortTitle(for: b))
        if r == .orderedSame { return Self.sortTitle(for: a) < Self.sortTitle(for: b) }
        return asc ? (r == .orderedAscending) : (r == .orderedDescending)
      }
    case .added:
      let dates = addedDates(for: games)
      return games.sorted { a, b in
        let da = dates[a.filePath] ?? Self.localPath(for: a).flatMap { dates[$0] }
        let db = dates[b.filePath] ?? Self.localPath(for: b).flatMap { dates[$0] }
#if DEBUG
        // Lightweight audit: log first pass only when sorting by added with 3+ items.
        if games.count >= 3, games.first?.filePath == a.filePath {
          for item in games.prefix(5) {
            let d = dates[item.filePath] ?? Self.localPath(for: item).flatMap { dates[$0] }
            print("[LIB_SORT] added: '\(item.title)' date=\(d?.description ?? "nil")")
          }
        }
#endif
        // Items with no local date (remote) sort last regardless of direction.
        switch (da, db) {
        case let (x?, y?):
          if x == y { return Self.sortTitle(for: a).localizedCaseInsensitiveCompare(Self.sortTitle(for: b)) == .orderedAscending }
          return asc ? (x < y) : (x > y)
        case (nil, nil):
          return Self.sortTitle(for: a).localizedCaseInsensitiveCompare(Self.sortTitle(for: b)) == .orderedAscending
        case (_?, nil): return true   // a has a date, sorts before b
        case (nil, _?): return false  // b has a date, sorts before a
        }
      }
    case .discDate:
      // apploaderDateString is "YYYY/MM/DD" (disc offset 0x2440); lexicographic
      // order matches chronological order. Missing dates sort last.
      return games.sorted { a, b in
        let da = a.apploaderDateString
        let db = b.apploaderDateString
        switch (da, db) {
        case let (x?, y?):
          if x == y { return Self.sortTitle(for: a).localizedCaseInsensitiveCompare(Self.sortTitle(for: b)) == .orderedAscending }
          return asc ? (x < y) : (x > y)
        case (nil, nil):
          return Self.sortTitle(for: a).localizedCaseInsensitiveCompare(Self.sortTitle(for: b)) == .orderedAscending
        case (_?, nil): return true
        case (nil, _?): return false
        }
      }
    }
  }

  enum BackgroundStyle: String, CaseIterable {
    case clean = "clean"
    case gradient = "gradient"
    case animated = "animated"

    var displayName: String {
      switch self {
      case .clean: return "Clean"
      case .gradient: return "GameCube Gradient"
      case .animated: return "Animated (Full Effects)"
      }
    }
  }

  // MARK: - Enhanced Font Properties for iOS 16.0+ compatibility

  /// Enhanced title2 font with iOS version compatibility for favorites headers
  private var enhancedTitle2BoldFont: Font {
    return .system(.title2, design: .rounded, weight: .bold)
  }

  /// Enhanced caption medium font with iOS version compatibility
  private var enhancedCaptionMediumFont: Font {
    return .system(.caption, design: .rounded, weight: .medium)
  }

  /// Enhanced large title font with iOS version compatibility for tvOS favorites
  private var enhancedLargeTitleFont: Font {
    return .system(.largeTitle, design: .rounded, weight: .bold)
  }

  /// Enhanced title3 font with iOS version compatibility for tvOS favorites
  private var enhancedTitle3Font: Font {
    return .system(.title3, design: .rounded, weight: .medium)
  }

  @Environment(\.tipsService) private var tipsService

  @StateObject private var model = TVLibraryViewModel()
  @State private var showSettings = false
  @State private var didReloadOnce = false
  @State private var navigateTo: TVGameItem?
  @State private var showUpdateRegions = false
  @State private var showDSUSession = false
  /// Presents the About iCube sheet (tapped via the toolbar Dolphin logo on iOS).
  @State private var showAbout = false

  // MARK: - Computed Bindings (extracted to prevent compiler timeout)

  private struct NavigationItem: Identifiable, Hashable {
    let id = UUID()
  }

#if os(iOS) || targetEnvironment(macCatalyst)
  private var settingsBinding: Binding<NavigationItem?> {
    Binding(
      get: { navigateToSettings ? NavigationItem() : nil },
      set: { navigateToSettings = ($0 != nil) }
    )
  }
#endif

  // MARK: - Navigation Configuration (extracted to prevent compiler timeout)

  @ViewBuilder
  private var navigationContent: some View {
    mainContent
#if os(iOS) || targetEnvironment(macCatalyst)
      .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
        handleDrop(providers: providers)
        return true
      }
#endif
      .modifier(iOS16NavigationStyleModifier())
      .navigationDestination(isPresented: Binding(
        get: { navigateTo != nil },
        set: { if !$0 { navigateTo = nil } }
      )) {
        if let item = navigateTo {
          // Screenshot mode's demo entries have no backing GameFile and no file
          // on disk — booting one would fail (or worse). Show a placeholder so a
          // stray tap during a capture run cannot break the pass.
          if item.isDemoItem {
            ScreenshotDemoUnavailableView(title: item.title)
          } else {
            EmulationScreen(game: item)
              .onAppear { NSLog("[INPUT] NavigationDestination -> EmulationScreen for game: %@", item.title) }
          }
        }
      }
      .navigationDestinationItemCompat(item: $navigateToSaveStates) { route in
        SaveStateFilmstripView(gameID: route.id)
      }
  }

  @ViewBuilder
  private var navigationConfiguration: some View {
    navigationContent
      .navigationTitle(storeForBanner.isScanning ? "" : "iCube Library")
      .toolbar { libraryToolbar }
#if !os(tvOS)
      .navigationBarTitleDisplayMode(.large)
#endif
#if os(iOS) || targetEnvironment(macCatalyst)
      .navigationDestinationItemCompat(item: settingsBinding) { _ in
        TVSettingsPage()
          .navigationBarTitleDisplayMode(.inline)
      }
      .toolbar { ToolbarItem(placement: .bottomBar) { RemoteScanProgressView() } }
      .modifier(LibrarySearchableModifier(searchText: $searchText))
#endif
      .safeAreaInset(edge: .bottom, spacing: 8) {
        libraryBottomChrome
      }
#if !os(tvOS)
      .modifier(LibraryNavigationSubtitleModifier(subtitle: libraryNavigationSubtitle))
#endif
      .onReceive(NotificationCenter.default.publisher(for: Notification.Name("FavoritesChanged"))) { _ in
        favoritesVersion &+= 1
      }
      .onChangeCompat(of: model.games.count) { _, _ in
        if !showPlatformFilterBar { platformFilter = .all }
      }
  }
  /// Game to present in the SwiftUI properties sheet
  @State private var showPropertiesFor: TVGameItem?
  /// Game pending deletion confirmation
  @State private var itemPendingDelete: TVGameItem?
  /// Cheat input modal state
  @State private var cheatInputFor: (item: TVGameItem, type: CheatType)?
  @State private var cheatName: String = ""
  @State private var cheatCreator: String = ""
  @State private var cheatBody: String = ""
  @State private var cheatNotes: String = ""
  @State private var showCheatError: String?
  /// Cheat list modal state
  @State private var showCheatListFor: TVGameItem?
  /// UIKit cheats editors
  @State private var showGeckoEditorFor: TVGameItem?
  @State private var showAREditorFor: TVGameItem?

  /// Currently focused game's file path to drive zIndex and animations
  @State private var focusedFilePath: String?

  @State private var showSources = false
  /// Source picker modal state
  @State private var sourcePickerItems: [TVGameItem]? = nil
  /// Auto pre-cache progress state
  @State private var autoPreCacheProgress: [String: Double] = [:]
  @State private var autoPreCacheActive: Set<String> = []

  /// Storage alerts
  @State private var storageAlertMessage = ""
  @State private var itemPendingLaunch: TVGameItem?

  // Navigation to Save States views
  private struct GameIDRoute: Identifiable, Hashable { let id: String }
  @State private var navigateToSaveStates: GameIDRoute?
  @State private var showSaveStatesBrowser: Bool = false

  /// Separate alert states (SwiftUI works better with simple booleans)
  @State private var showStorageErrorAlert = false
  @State private var showLowStorageWarning = false
  @State private var showCacheInfoFor: TVGameItem?
  @State private var blockingPrecacheItem: TVGameItem?
  @State private var blockingPrecacheProgress: Double = 0

  /// Search text for library filtering
  @State private var searchText: String = ""
  @State private var favoritesVersion: Int = 0

  /// Whether emulation is currently running (disables library input)
  @State private var emulationRunning = false
  /// Current grid columns (kept in state for controller navigation)
  @State private var gridColumnCount: Int = 3

  /// iOS document pickers
#if os(iOS) || targetEnvironment(macCatalyst)
  @State private var showImportSoftwarePicker = false
  @State private var showImportNANDPicker = false
  @State private var showImportSkylanderPicker = false
  @State private var showWebImportSheet = false
  /// Navigate to settings as a push on iOS
  @State private var navigateToSettings = false
  /// Controller navigation repeat throttle
  @State private var lastNavMoveTime: TimeInterval = 0
  @State private var navRepeatInterval: TimeInterval = 0.12
  @State private var emuStartObs: NSObjectProtocol?
  @State private var emuEndObs: NSObjectProtocol?
  /// Previous controller handlers to restore on teardown
  @State private var prevEGPHandlers: [ObjectIdentifier: (GCExtendedGamepad, GCControllerElement) -> Void] = [:]
  @State private var prevMGPHandlers: [ObjectIdentifier: (GCMicroGamepad, GCControllerElement) -> Void] = [:]
  @State private var dropTargeted: Bool = false
  @State private var dropPreviewCount: Int = 0
  // Library GCController observers
  @State private var libGCConnectObs: NSObjectProtocol?
  @State private var libGCDisconnectObs: NSObjectProtocol?
#endif

  /// Storage space management
  static let STORAGE_BUFFER_MB: Int64 = 100 * 1024 * 1024 // 100MB buffer
  static let LOW_STORAGE_THRESHOLD_MB: Int64 = 100 * 1024 * 1024 // 100MB warning threshold

  /// Check available storage space
  static func getAvailableStorageSpace() -> Int64 {
    guard let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
      return 0
    }

    do {
      let resourceValues = try cachesURL.resourceValues(forKeys: [.volumeAvailableCapacityKey])
      return Int64(resourceValues.volumeAvailableCapacity ?? 0)
    } catch {
      print("Error getting storage space: \(error)")
      return 0
    }
  }

  /// Check if there's enough space for pre-caching (file size + 100MB buffer)
  static func hasEnoughSpaceForPreCache(fileSize: Int64) -> Bool {
    let availableSpace = getAvailableStorageSpace()
    let requiredSpace = fileSize + STORAGE_BUFFER_MB
    return availableSpace >= requiredSpace
  }

  /// Check if storage is critically low (< 100MB)
  static func isStorageCriticallyLow() -> Bool {
    return getAvailableStorageSpace() < LOW_STORAGE_THRESHOLD_MB
  }

  /// Format storage space for user display
  static func formatStorageSpace(_ bytes: Int64) -> String {
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  /// Customizable background based on user preference
  @ViewBuilder
  private var backgroundGradient: some View {
    switch backgroundStyle {
    case .clean:
      cleanBackground
    case .gradient:
      gradientBackground
    case .animated:
      animatedBackground
    }
  }

  @ViewBuilder
  private var cleanBackground: some View {
    Color.black
      .ignoresSafeArea()
  }

  @ViewBuilder
  private var gradientBackground: some View {
    if colorScheme == .dark {
      LinearGradient(
        colors: [
          Color(red: 0.08, green: 0.12, blue: 0.22),
          Color(red: 0.04, green: 0.06, blue: 0.15),
          Color.black
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .ignoresSafeArea()
    } else {
      LinearGradient(
        colors: [
          Color(red: 0.90, green: 0.93, blue: 0.98), // light top
          Color(red: 0.84, green: 0.89, blue: 0.98), // mid
          Color(red: 0.96, green: 0.97, blue: 1.00)  // near white
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .ignoresSafeArea()
    }
  }

  @ViewBuilder
  private var animatedBackground: some View {
    ZStack {
      // Premium gradient switches for light/dark
      if colorScheme == .dark {
        RadialGradient(
          colors: [
            Color(red: 0.12, green: 0.15, blue: 0.28),
            Color(red: 0.08, green: 0.12, blue: 0.22),
            Color(red: 0.04, green: 0.06, blue: 0.15),
            Color.black
          ],
          center: .topLeading,
          startRadius: 100,
          endRadius: 800
        )
        .ignoresSafeArea()
      } else {
        RadialGradient(
          colors: [
            Color(red: 0.92, green: 0.95, blue: 1.00),
            Color(red: 0.88, green: 0.93, blue: 1.00),
            Color(red: 0.98, green: 0.99, blue: 1.00)
          ],
          center: .topLeading,
          startRadius: 100,
          endRadius: 800
        )
        .ignoresSafeArea()
      }

      // Elegant animated orbs with GameCube/Wii theming
      ForEach(0..<5, id: \.self) { index in
        Circle()
          .fill(
            RadialGradient(
              colors: [
                (colorScheme == .dark ? (index % 2 == 0 ? Color.purple.opacity(0.06) : Color.blue.opacity(0.05))
                 : (index % 2 == 0 ? Color.purple.opacity(0.10) : Color.blue.opacity(0.10))),
                (colorScheme == .dark ? (index % 2 == 0 ? Color.purple.opacity(0.03) : Color.blue.opacity(0.025))
                 : Color.white.opacity(0.0)),
                Color.clear
              ],
              center: .center,
              startRadius: 20,
              endRadius: 180
            )
          )
          .frame(width: CGFloat.random(in: 200...400), height: CGFloat.random(in: 200...400))
          .offset(
            x: CGFloat.random(in: -150...150),
            y: CGFloat.random(in: -200...200)
          )
          .scaleEffect(0.8 + CGFloat(index) * 0.1)
          .animation(
            Animation.easeInOut(duration: Double.random(in: 10...18))
              .repeatForever(autoreverses: true)
              .delay(Double(index) * 1.5),
            value: UUID()
          )
      }

      // Subtle grid pattern
      Canvas { context, size in
        let spacing: CGFloat = 80
        let lineWidth: CGFloat = 0.5
        let gradient = Gradient(colors: [
          (colorScheme == .dark ? .white.opacity(0.08) : .black.opacity(0.06)),
          .clear,
          (colorScheme == .dark ? .white.opacity(0.04) : .black.opacity(0.03))
        ])

        context.stroke(
          Path { path in
            for x in stride(from: 0, through: size.width, by: spacing) {
              path.move(to: CGPoint(x: x, y: 0))
              path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in stride(from: 0, through: size.height, by: spacing) {
              path.move(to: CGPoint(x: 0, y: y))
              path.addLine(to: CGPoint(x: size.width, y: y))
            }
          },
          with: .linearGradient(
            gradient,
            startPoint: CGPoint(x: 0, y: 0),
            endPoint: CGPoint(x: size.width, y: size.height)
          ),
          lineWidth: lineWidth
        )
      }
      .ignoresSafeArea()
      .opacity(colorScheme == .dark ? 0.6 : 0.25)

      // Minor grid checks (subtle)
      Canvas { context, size in
        let spacing: CGFloat = 20
        let lineWidth: CGFloat = 0.25
        let strokeColor = (colorScheme == .dark ? Color.white.opacity(0.02) : Color.black.opacity(0.02))
        context.stroke(
          Path { path in
            for x in stride(from: 0, through: size.width, by: spacing) {
              path.move(to: CGPoint(x: x, y: 0))
              path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in stride(from: 0, through: size.height, by: spacing) {
              path.move(to: CGPoint(x: 0, y: y))
              path.addLine(to: CGPoint(x: size.width, y: y))
            }
          },
          with: .color(strokeColor),
          lineWidth: lineWidth
        )
      }
      .ignoresSafeArea()
      .opacity(colorScheme == .dark ? 0.25 : 0.12)

      // Floating elements
      ForEach(0..<8, id: \.self) { index in
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .fill(
            LinearGradient(
              colors: [
                (colorScheme == .dark ? Color.white.opacity(0.03) : Color.white.opacity(0.5)),
                Color.clear
              ],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
          .frame(width: CGFloat.random(in: 20...40), height: CGFloat.random(in: 20...40))
          .offset(x: CGFloat.random(in: -200...200), y: CGFloat.random(in: -300...300))
          .rotationEffect(.degrees(Double.random(in: 0...360)))
          .animation(Animation.linear(duration: Double.random(in: 20...30)).repeatForever(autoreverses: false).delay(Double(index) * 2), value: UUID())
      }
    }
    .clipped()
  }

  private enum CheatType { case gecko, ar }

  /// Helper function to check if a URL is a remote URL (HTTP/HTTPS/WebDAV)
  static func isRemoteURL(_ urlString: String) -> Bool {
    let lower = urlString.lowercased()
    return lower.hasPrefix("http://") ||
    lower.hasPrefix("https://") ||
    lower.hasPrefix("webdav://") ||
    lower.hasPrefix("webdavs://")
  }

  private enum Constants {
    static let gridVerticalSpacing: CGFloat = {
#if os(tvOS)
      return 40  // More breathing room for focus effects
#else
      return 20  // Enhanced spacing for iOS
#endif
    }()
    static let gridHorizontalSpacing: CGFloat = {
#if os(tvOS)
      return 52  // Better visual balance
#else
      return 16  // Modern iOS spacing
#endif
    }()
#if os(tvOS)
    static let gridNumberOfColumns = 5  // Better proportion for wide screens
#else
    static let gridNumberOfColumns = 3
#endif
    static let gridHorizontalPadding: CGFloat = {
#if os(tvOS)
      return 80  // More immersive padding
#else
      return 20  // Clean iOS margins
#endif
    }()
    static let gridVerticalPadding: CGFloat = {
#if os(tvOS)
      return 100  // Premium spacing for focus effects
#else
      return 28   // Modern iOS vertical rhythm
#endif
    }()
    static var columns: [GridItem] {
      return Array(repeating: GridItem(.flexible(), spacing: gridHorizontalSpacing), count: gridNumberOfColumns)
    }
  }

  @ViewBuilder
  private var mainContent: some View {
    ZStack {
      // Beautiful GameCube/Wii inspired background
      backgroundGradient

      if model.games.isEmpty {
        emptyLibraryView
      } else if filteredGames(from: model.games).isEmpty {
        filteredEmptyLibraryView
      } else {
        libraryView
      }
    }
    .task {
#if canImport(TipKit)
      if #available(iOS 17, tvOS 17, *), !didReloadOnce {
        // Wait for first load to complete before showing tips
        // Simple debounce: small delay after initial load to allow UI to settle
        try? await Task.sleep(nanoseconds: 300_000_000)
      }
#endif
    }
  }

  private var isSearching: Bool {
    !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  @ViewBuilder
  private var libraryView: some View {
    let _ = favoritesVersion
    let _ = platformOverridesVersion
    let displayGames = filteredGames(from: model.games)
#if os(iOS) || targetEnvironment(macCatalyst)
    libraryView_iOS(displayGames)
#else
    libraryView_tvOS(displayGames)
#endif
  }

  /// Shared grid item builder wired to selection mode and context actions.
  @ViewBuilder
  private func gameGridItem(for item: TVGameItem) -> some View {
    GameGridItem(
      item: item,
      select: selectGame,
      focusedFilePath: $focusedFilePath,
      showProperties: { showPropertiesFor = $0 },
      showCheatList: { showCheatListFor = $0 },
      downloadGeckoAction: { downloadGecko(for: $0) },
      presentCheatGecko: { showGeckoEditorFor = $0 },
      presentCheatAR: { showAREditorFor = $0 },
      requestDelete: { itemPendingDelete = $0 },
      showFavoriteToggle: { toggleFavorite(for: $0) },
      showStorageAlert: { message in
        storageAlertMessage = message
        showStorageErrorAlert = true
      },
      showCacheInfo: { showCacheInfoFor = $0 },
      showSaveStates: { item in
        let gid = item.gameID
        if !gid.isEmpty {
          navigateToSaveStates = GameIDRoute(id: gid)
        }
      },
      autoPreCacheProgress: autoPreCacheProgress[item.filePath] ?? 0.0,
      isAutoPreCaching: autoPreCacheActive.contains(item.filePath),
      showSubtitles: showSubtitles,
      selectionMode: isSelectionMode,
      isSelected: selectedFilePaths.contains(item.filePath),
      onToggleSelection: { toggleSelection(for: item) },
      onEnterSelectionMode: { enterSelectionMode(selecting: item) }
    )
  }

  #if os(tvOS)
  private func libraryView_tvOS(_ displayGames: [TVGameItem]) -> some View {
    ScrollView {
      libraryToolbar_tvOS_favorites
      libraryToolbar_tvOS_main(displayGames)
        .padding(.bottom, libraryBottomInsetPadding)
    }
  }

  @ViewBuilder
  private var libraryToolbar_tvOS_favorites: some View {
    if !isSearching, let favs = favorites(), !favs.isEmpty {
      VStack(alignment: .leading, spacing: 16) {
        // Stunning tvOS favorites header
        HStack {
          VStack(alignment: .leading, spacing: 6) {
            Text("⭐ Favorites")
              .font(enhancedLargeTitleFont)
              .foregroundStyle(
                LinearGradient(
                  colors: [Color.primary, Color.primary.opacity(0.8)],
                  startPoint: .leading,
                  endPoint: .trailing
                )
              )

            Text("Your championship collection")
              .font(enhancedTitle3Font)
              .foregroundColor(.secondary)
          }
          Spacer()

          // Elegant floating elements
          HStack(spacing: 8) {
            Image(systemName: "sparkles")
              .font(.system(size: 24, weight: .light))
              .foregroundColor(.yellow.opacity(0.8))
            Image("DolphinLogo")
              .resizable()
              .aspectRatio(contentMode: .fit)
              .frame(width: 32, height: 32)
              .opacity(0.7)
          }
        }
        .padding(.horizontal, Constants.gridHorizontalPadding)

        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: Constants.gridHorizontalSpacing) {
            ForEach(favs, id: \.filePath) { fav in
              gameGridItem(for: fav)
            }
          }
          .background(
            // Elegant material backdrop for tvOS favorites with proper clipping
            RoundedRectangle(cornerRadius: 28, style: .continuous)
              .fill(.ultraThinMaterial.opacity(0.15))
              .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                  .stroke(.white.opacity(0.08), lineWidth: 1.5)
              )
              .padding(.horizontal, 20)
              .clipped()
          )
        }
      }
    }
  }

  @ViewBuilder
  private func libraryToolbar_tvOS_main(_ displayGames: [TVGameItem]) -> some View {
    let count = effectiveColumnCount(autoFit: Self.tvOSBaseColumns())
    let columns = Array(repeating: GridItem(.flexible(), spacing: Constants.gridHorizontalSpacing), count: count)
    LazyVGrid(columns: columns, spacing: Constants.gridVerticalSpacing) {
      ForEach(displayGames, id: \.filePath) { item in
        gameGridItem(for: item)
      }
    }
    .padding(.horizontal, Constants.gridHorizontalPadding)
    .padding(.vertical, Constants.gridVerticalPadding)
    .onAppear { gridColumnCount = count }
    .onChangeCompat(of: count) { _, newVal in gridColumnCount = newVal }
  }
  #endif // os(tvOS)

  #if !os(tvOS)
  @ViewBuilder
  private func libraryView_iOS(_ displayGames: [TVGameItem]) -> some View {
    GeometryReader { proxy in
      let paddingH = Constants.gridHorizontalPadding
      let spacingH = Constants.gridHorizontalSpacing
      let cardW = LibraryLayout.cardSize.width
      let available = max(0, proxy.size.width - (paddingH * 2))
      let autoCount = max(2, Int((available + spacingH) / (cardW + spacingH)))
      let count = effectiveColumnCount(autoFit: autoCount)
      let columns = Array(repeating: GridItem(.flexible(), spacing: spacingH), count: count)
      ScrollViewReader { scr in
        ScrollView {
          if !isSearching, let favs = favorites(), !favs.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
              // Premium favorites header
              HStack {
                VStack(alignment: .leading, spacing: 4) {
                  Text("⭐ Favorites")
                    .font(enhancedTitle2BoldFont)
                    .foregroundStyle(
                      LinearGradient(
                        colors: [Color.primary, Color.primary.opacity(0.8)],
                        startPoint: .leading,
                        endPoint: .trailing
                      )
                    )

                  Text("Your most-loved games")
                    .font(enhancedCaptionMediumFont)
                    .foregroundColor(.secondary)
                }
                Spacer()

                // Subtle floating sparkle
                Image(systemName: "sparkles")
                  .font(.system(size: 16, weight: .light))
                  .foregroundColor(.yellow.opacity(0.7))
                  .scaleEffect(0.9)
              }
              .padding(.horizontal, paddingH)

              ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: spacingH) {
                  ForEach(favs, id: \.filePath) { fav in
                    gameGridItem(for: fav)
                  }
                }
                .padding(.horizontal, paddingH)
                .padding(.vertical, Constants.gridVerticalSpacing)
              }
              .background(
                // Refined material backdrop for favorites with proper clipping
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                  .fill(.ultraThinMaterial.opacity(0.2))
                  .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                      .stroke(.white.opacity(0.1), lineWidth: 1)
                  )
                  .padding(.horizontal, 12)
                  .clipped()
              )
            }
          }
          LazyVGrid(columns: columns, spacing: Constants.gridVerticalSpacing) {
            ForEach(displayGames, id: \.filePath) { item in
              gameGridItem(for: item)
              .id(item.filePath)
              .overlay(
                RoundedRectangle(cornerRadius: 14)
                  .stroke(focusedFilePath == item.filePath ? Color.accentColor : Color.clear, lineWidth: 3)
              )
              .onChangeCompat(of: focusedFilePath) { _, newVal in
                if newVal == item.filePath {
                  let gen = UIImpactFeedbackGenerator(style: .light)
                  gen.impactOccurred()
                  // Auto-scroll to follow focus
                  DispatchQueue.main.async {
                    scr.scrollTo(item.filePath, anchor: .center)
                  }
                }
              }
            }
          }
          .padding(.horizontal, paddingH)
          .padding(.vertical, Constants.gridVerticalSpacing)
          .padding(.bottom, libraryBottomInsetPadding)
        }
        .simultaneousGesture(
          MagnificationGesture()
            .onChanged { scale in
              let delta = scale - lastPinchScale
              if delta > 0.12 {
                adjustGridZoom(delta: 1)
                lastPinchScale = scale
              } else if delta < -0.12 {
                adjustGridZoom(delta: -1)
                lastPinchScale = scale
              }
            }
            .onEnded { _ in lastPinchScale = 1.0 }
        )
        .background((!emulationRunning) ? AnyView(KeyCommandHostView(
          onLeft: {
            let idx = displayGames.firstIndex(where: { $0.filePath == focusedFilePath }) ?? 0
            let newIndex = max(0, idx - 1)
            focusedFilePath = (displayGames.indices.contains(newIndex) ? displayGames[newIndex].filePath : displayGames.first?.filePath)
            if UserDefaults.standard.bool(forKey: "input_debug") { print("[INPUT][LIB] DPad Left -> index=\(newIndex)") }
          },
          onRight: {
            let idx = displayGames.firstIndex(where: { $0.filePath == focusedFilePath }) ?? 0
            let newIndex = min(displayGames.count - 1, idx + 1)
            focusedFilePath = (displayGames.indices.contains(newIndex) ? displayGames[newIndex].filePath : displayGames.last?.filePath)
            if UserDefaults.standard.bool(forKey: "input_debug") { print("[INPUT][LIB] DPad Right -> index=\(newIndex)") }
          },
          onUp: {
            let idx = displayGames.firstIndex(where: { $0.filePath == focusedFilePath }) ?? 0
            let newIndex = max(0, idx - count)
            focusedFilePath = (displayGames.indices.contains(newIndex) ? displayGames[newIndex].filePath : displayGames.first?.filePath)
            if UserDefaults.standard.bool(forKey: "input_debug") { print("[INPUT][LIB] DPad Up -> index=\(newIndex)") }
          },
          onDown: {
            let idx = displayGames.firstIndex(where: { $0.filePath == focusedFilePath }) ?? 0
            let newIndex = min(displayGames.count - 1, idx + count)
            focusedFilePath = (displayGames.indices.contains(newIndex) ? displayGames[newIndex].filePath : displayGames.last?.filePath)
          },
          onEnter: {
            if let fp = focusedFilePath, let item = displayGames.first(where: { $0.filePath == fp }) { selectGame(item) }
          },
          onSpace: {
            showSources = true
          }
        )) : AnyView(EmptyView()))
        .onAppear {
          emulationRunning = false
          if UserDefaults.standard.bool(forKey: "input_debug") { print("[INPUT][LIB] onAppear: controllers=\(GCController.controllers().count)") }
          // The controller observer is app-wide (started in MainDisplaySceneDelegate)
          // so hotplug auto-assign stays live in the library. The library re-binds its
          // own nav handlers below and on controllerConnectedPublisher, which runs
          // after the manager's connect handler, so nav still wins for grid navigation.
          GCController.shouldMonitorBackgroundEvents = false
          for c in GCController.controllers() {
            c.extendedGamepad?.valueChangedHandler = nil
            c.microGamepad?.valueChangedHandler = nil
            c.extendedGamepad?.buttonMenu.pressedChangedHandler = { _, _, _ in /* swallow to avoid Game Center */ }
            c.microGamepad?.buttonMenu.pressedChangedHandler = { _, _, _ in /* swallow to avoid Game Center */ }
            if UserDefaults.standard.bool(forKey: "input_debug") { print("[INPUT][LIB] cleared handlers for \(c.vendorName ?? "(nil)")") }
            // Ensure microGamepad behaves sanely for library nav
            if let mg = c.microGamepad { mg.reportsAbsoluteDpadValues = true; mg.allowsRotation = true }
          }
          if GCController.controllers().isEmpty { GCController.startWirelessControllerDiscovery(completionHandler: {}) }
          if focusedFilePath == nil, let first = displayGames.first?.filePath { focusedFilePath = first }
          setupControllerNavigation(columns: count)
          emuStartObs = NotificationCenter.default.addObserver(forName: Notification.Name("DOLEmulationDidStartNotification"), object: nil, queue: .main) { _ in
            emulationRunning = true
            teardownControllerNavigation()
          }
          emuEndObs = NotificationCenter.default.addObserver(forName: Notification.Name("DOLEmulationDidEndNotification"), object: nil, queue: .main) { _ in emulationRunning = false }
        }
        .task {
          gridColumnCount = count
          if !emulationRunning { setupControllerNavigation(columns: count) }
        }
        .onChangeCompat(of: count) { _, newVal in
          gridColumnCount = newVal
          if !emulationRunning { setupControllerNavigation(columns: newVal) }
        }
        .onReceive(ControllerManager.shared.controllerConnectedPublisher) { _ in
          ControllerStyleManager.shared.refreshDetection()
          ControllerStyleManager.shared.applyPresetDefaults()
          if !emulationRunning { setupControllerNavigation(columns: count) }
        }
        .onReceive(ControllerManager.shared.controllerDisconnectedPublisher) { _ in
          ControllerStyleManager.shared.refreshDetection()
          if !emulationRunning { setupControllerNavigation(columns: count) }
        }
        .onChangeCompat(of: displayGames.count) { _, newCount in
          if newCount > 0 && focusedFilePath == nil {
            DispatchQueue.main.async { focusedFilePath = displayGames.first?.filePath }
          }
        }
        .onDisappear {
          if let t = emuStartObs { NotificationCenter.default.removeObserver(t); emuStartObs = nil }
          if let t = emuEndObs { NotificationCenter.default.removeObserver(t); emuEndObs = nil }
          if let t = libGCConnectObs { NotificationCenter.default.removeObserver(t); libGCConnectObs = nil }
          if let t = libGCDisconnectObs { NotificationCenter.default.removeObserver(t); libGCDisconnectObs = nil }
          teardownControllerNavigation()
        }
      }
    }
  }
  #endif // !os(tvOS)

  @ViewBuilder
  private var emptyLibraryView: some View {
    ZStack {
      // Ambient swimming dolphins in the background
      SwimmingDolphinsView(count: 3, direction: .leftToRight, maxSize: 120, opacity: 0.22)
      SwimmingDolphinsView(count: 2, direction: .rightToLeft, maxSize: 100, opacity: 0.16)

      // Centered friendly message
      VStack(spacing: 20) {
        DolphinErrorView(
          title: L("Library Empty"),
          message: L("No games found. Add GameCube & Wii ROMs to your library to get started with iCube! 🎮")
        )
      }
      .padding()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private var filteredEmptyLibraryView: some View {
    ZStack {
      SwimmingDolphinsView(count: 2, direction: .leftToRight, maxSize: 100, opacity: 0.18)
      VStack(spacing: 16) {
        DolphinErrorView(
          title: L("No Matching Games"),
          message: filteredEmptyMessage
        )
        if showPlatformFilterBar, platformFilter != .all {
          Button(L("Show All Games")) {
            platformFilter = .all
          }
          .buttonStyle(.borderedProminent)
        } else if isSearching {
          Button(L("Clear Search")) { searchText = "" }
            .buttonStyle(.borderedProminent)
        }
      }
      .padding()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var filteredEmptyMessage: String {
    if isSearching, platformFilter != .all {
      return String(format: L("No %1$@ games match your search."), platformFilter.displayName)
    }
    if platformFilter != .all {
      return String(format: L("No %1$@ games in your library."), platformFilter.displayName)
    }
    return L("No games match your search.")
  }

  #if os(tvOS)
  @ToolbarContentBuilder
  private var libraryToolbar_tvOS: some ToolbarContent {
    ToolbarItem(placement: .navigationBarTrailing) {
      let store = RemoteSourcesStore.shared
      if store.isScanning {
        VStack(spacing: 2) {
          DolphinProgressView(
            progress: store.scanningProgress,
            width: 80,
            direction: .leftToRight
          )
          Text("Refreshing…")
            .font(.caption2)
            .foregroundColor(.secondary)
        }
      }
    }
    ToolbarItem(placement: .navigationBarTrailing) {
      libraryViewMenu
        .focusable(true)
    }
    ToolbarItem(placement: .navigationBarTrailing) {
      libraryImportMenu
        .focusable(true)
    }
    ToolbarItem(placement: .navigationBarTrailing) {
      librarySystemMenu
        .focusable(true)
    }
    ToolbarItem(placement: .navigationBarTrailing) {
      librarySettingsButton
        .focusable(true)
    }
  }
  #else // iOS
  @ToolbarContentBuilder
  private var libraryToolbar_iOS: some ToolbarContent {
    ToolbarItem(placement: .topBarLeading) {
      let store = RemoteSourcesStore.shared
      if store.isScanning {
        // Show swimming dolphin progress instead of static logo
        DolphinProgressView(
          progress: store.scanningProgress,
          width: 140,
          direction: .leftToRight
        )
      } else {
        // Show static dolphin logo when not scanning — tappable to open About.
        // Single glass circle on iOS 26; plain framed button on older OSes.
        aboutDolphinToolbarButton
      }
    }
    ToolbarItem(placement: .navigationBarTrailing) {
      libraryViewMenu
    }
    ToolbarItem(placement: .navigationBarTrailing) {
      libraryImportMenu
        .tipAttachCompat(.importGame)
    }
    ToolbarItem(placement: .navigationBarTrailing) {
      librarySystemMenu
    }
    ToolbarItem(placement: .navigationBarTrailing) {
      librarySettingsButton
    }

  }
  #endif

  @ToolbarContentBuilder
  private var libraryToolbar: some ToolbarContent {
    #if os(tvOS)
    libraryToolbar_tvOS
    #else
    libraryToolbar_iOS
    #endif
  }

  /// View controls: selection, sort, grid zoom, rescan (+ search on tvOS).
  @ViewBuilder
  private var libraryViewMenu: some View {
    Menu {
      libraryViewMenuSection
    } label: {
      Image(systemName: "square.grid.3x3")
    }
    .accessibilityLabel(L("View Options"))
  }

  /// Import paths: files, NAND, Skylanders, sources, Wi-Fi upload guide.
  @ViewBuilder
  private var libraryImportMenu: some View {
    Menu {
      libraryImportMenuSection
    } label: {
      Image(systemName: "square.and.arrow.down")
    }
    .accessibilityLabel(L("Import"))
  }

  /// System boot / update / DSU actions.
  @ViewBuilder
  private var librarySystemMenu: some View {
    Menu {
      librarySystemMenuSection
    } label: {
      Image(systemName: "gamecontroller")
    }
    .accessibilityLabel(L("System"))
  }

  @ViewBuilder
  private var librarySettingsButton: some View {
    Button(action: openLibrarySettings) {
      Image(systemName: "gearshape")
    }
    .accessibilityLabel(L("Settings"))
  }

  private func openLibrarySettings() {
#if os(iOS) || targetEnvironment(macCatalyst)
    navigateToSettings = true
#elseif os(tvOS)
    showSettings = true
#endif
  }

  @ViewBuilder
  private var libraryViewMenuSection: some View {
    Section(L("View")) {
#if os(tvOS)
      Button(action: { showSearchSheet = true }) {
        Label(L("Search"), systemImage: "magnifyingglass")
      }
#endif
      Button(action: {
        if isSelectionMode {
          exitSelectionMode()
        } else {
          isSelectionMode = true
        }
      }) {
        Label(
          isSelectionMode ? L("Done Selecting") : L("Select Games"),
          systemImage: isSelectionMode ? "checkmark.circle.fill" : "checkmark.circle"
        )
      }
      Menu {
        sortMenuItems
      } label: {
        Label(L("Sort"), systemImage: "arrow.up.arrow.down")
      }
      Menu {
        gridZoomMenuItems
      } label: {
        Label(L("Grid Size"), systemImage: "square.grid.3x3")
      }
      Button(action: { model.rescan() }) {
        Label(L("Rescan"), systemImage: "arrow.clockwise")
      }
      .disabled(model.isRescanning)
    }
  }

  /// Tappable dolphin logo for the library toolbar leading slot.
  @ViewBuilder
  private var aboutDolphinToolbarButton: some View {
    Button(action: { showAbout = true }) {
      Image("DolphinLogo")
        .resizable()
        .scaledToFit()
        .frame(width: 28, height: 28)
        .padding(6)
    }
    .buttonStyle(.plain)
    .background { aboutDolphinToolbarBackground }
    .accessibilityLabel(L("About iCube"))
  }

  @ViewBuilder
  private var aboutDolphinToolbarBackground: some View {
    if #available(iOS 26.0, tvOS 26.0, watchOS 26.0, *) {
      Circle()
        .fill(.clear)
        .glassEffect()
    }
  }

  @ViewBuilder
  private var librarySystemMenuSection: some View {
    Section(L("System")) {
      Button(action: { model.loadGameCubeMainMenu() }) {
        Label(L("GameCube: Load Main Menu"), systemImage: "gamecontroller")
      }
#if os(tvOS)
      Button(action: { showUpdateRegions = true }) {
        Label(L("Wii: Online System Update"), systemImage: "arrow.triangle.2.circlepath")
      }
#else
      Button(action: { model.performOnlineSystemUpdate() }) {
        Label(L("Wii: Online System Update"), systemImage: "arrow.triangle.2.circlepath")
      }
#endif
#if os(iOS)
      Divider()
      Button(action: {
        let role = UserDefaults.standard.string(forKey: "dsu_role") ?? "sender"
        if role == "receiver" {
          NotificationCenter.default.post(
            name: NSNotification.Name("DOLShowSnackbar"),
            object: nil,
            userInfo: ["text": L("Switch role to Sender to start DSU Controller")]
          )
        } else {
          showDSUSession = true
        }
      }) {
        Label(L("Start DSU Controller"), systemImage: "dot.radiowaves.left.and.right")
      }
#endif
    }
  }

  @ViewBuilder
  private var libraryImportMenuSection: some View {
    Section(L("Import")) {
      Button(action: {
#if os(iOS) || targetEnvironment(macCatalyst)
        showImportSoftwarePicker = true
#endif
      }) {
        Label(L("Import Game"), systemImage: "doc.badge.plus")
      }
      Button(action: {
#if os(iOS) || targetEnvironment(macCatalyst)
        showImportNANDPicker = true
#endif
      }) {
        Label(L("Import BootMii NAND Backup…"), systemImage: "tray.and.arrow.down")
      }
#if os(iOS)
      if DOLConfigBridge.mainEmulateSkylanderPortal() {
        Button(action: { showImportSkylanderPicker = true }) {
          Label(L("Import Skylander Figure…"), systemImage: "figure.stand")
        }
      }
      Divider()
      Button(action: { showWebImportSheet = true }) {
        Label(L("Upload via Wi-Fi…"), systemImage: "wifi")
      }
      Divider()
#endif
      Button(action: { showSources = true }) {
        Label(L("Manage Sources"), systemImage: "externaldrive.badge.plus")
      }
    }
  }

  @ViewBuilder
  private var sortMenuItems: some View {
    Section(L("Sort By")) {
      ForEach(SortField.allCases, id: \.self) { field in
          Button(action: {
            if sortField == field {
              sortAscending.toggle()
            } else {
              sortField = field
              // Names default A→Z; dates default newest-first.
              sortAscending = (field == .name)
            }
          }) {
          if sortField == field {
            Label(field.displayName, systemImage: sortAscending ? "arrow.up" : "arrow.down")
          } else {
            Label(field.displayName, systemImage: field.systemImage)
          }
        }
      }
    }
    Section(L("Direction")) {
      Button(action: { sortAscending = true }) {
        Label(L("Ascending"), systemImage: sortAscending ? "checkmark" : "arrow.up")
      }
      Button(action: { sortAscending = false }) {
        Label(L("Descending"), systemImage: !sortAscending ? "checkmark" : "arrow.down")
      }
    }
    Section(L("Quick Sort")) {
      Button(action: {
        sortField = .added
        sortAscending = false
      }) {
        Label(L("Newest First"), systemImage: "clock.arrow.circlepath")
      }
    }
  }

  @ViewBuilder
  private var gridZoomMenuItems: some View {
    Button(action: { adjustGridZoom(delta: -1) }) {
      Label(L("Fewer Per Row"), systemImage: "minus.magnifyingglass")
    }
    Button(action: { adjustGridZoom(delta: 1) }) {
      Label(L("More Per Row"), systemImage: "plus.magnifyingglass")
    }
    Button(action: { gridColumnOffset = 0 }) {
      Label(L("Reset Grid Size"), systemImage: "arrow.counterclockwise")
    }
  }

  @ViewBuilder
  private var libraryBottomChrome: some View {
    VStack(spacing: 6) {
      if isSelectionMode && !selectedFilePaths.isEmpty {
        LibrarySelectionActionBar(
          selectedCount: selectedFilePaths.count,
          onDelete: { pendingBatchDeletePaths = selectedFilePaths; showBatchDeleteConfirm = true },
          onFavorite: { batchSetFavorite(true) },
          onUnfavorite: { batchSetFavorite(false) },
          onPlatformOverride: { batchSetPlatformOverride($0) },
          onControllerOverride: { batchSetControllerOverride($0) },
          onSelectAll: { selectAllVisibleGames() },
          onDeselectAll: { selectedFilePaths.removeAll() },
          onProperties: {
            if let path = selectedFilePaths.first,
               let item = model.games.first(where: { $0.filePath == path }) {
              showPropertiesFor = item
            }
          },
          onDone: { exitSelectionMode() }
        )
      }
      if showPlatformFilterBar {
        LibraryPlatformFilterBar(
          selection: $platformFilter,
          games: model.games,
          overrides: platformOverrides
        )
      }
    }
  }

  private var libraryNavigationSubtitle: String {
    let count = filteredGames(from: model.games).count
    if showPlatformFilterBar, platformFilter != .all {
      return "\(platformFilter.displayName) · \(count) \(L("games"))"
    }
    if count != model.games.count {
      return "\(count) \(L("games"))"
    }
    return "\(model.games.count) \(L("games"))"
  }

  /// Extra scroll padding so the last grid row clears bottom filter/selection chrome.
  private var libraryBottomInsetPadding: CGFloat {
    var pad: CGFloat = 0
    if showPlatformFilterBar { pad += 56 }
    if isSelectionMode && !selectedFilePaths.isEmpty { pad += 92 }
    return pad
  }

  private func adjustGridZoom(delta: Int) {
    gridColumnOffset = min(4, max(-3, gridColumnOffset + delta))
  }

  var body: some View {
    NavigationStack {
      navigationConfiguration
    }
    // SaveStatesBrowserView presention
    .sheet(isPresented: $showSaveStatesBrowser) {
      NavigationStack { SaveStatesBrowserView() }
    }
    // About iCube sheet (presented from the tappable toolbar Dolphin logo on iOS)
#if os(iOS) || targetEnvironment(macCatalyst)
    .sheet(isPresented: $showAbout) {
      NavigationStack {
        AboutView()
          .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
              Button(L("Done")) { showAbout = false }
            }
          }
      }
    }
#endif
    // DSU controller session (iOS only)
#if os(iOS)
    .sheet(isPresented: $showDSUSession) {
      if #available(iOS 17.0, *) {
        DSUSessionView()
      } else {
        // Fallback on earlier versions
      }
    }
#endif
    .onAppear {
      // Tips setup
      if #available(iOS 17, tvOS 17, *) {
        tipsService.configure()
      }
      // Date Added sort should default to newest-first; migrate once for existing installs.
      if sortField == .added,
         !UserDefaults.standard.bool(forKey: "library_sort_added_direction_migrated_v1") {
        sortAscending = false
        UserDefaults.standard.set(true, forKey: "library_sort_added_direction_migrated_v1")
      }
      // Initialize shared remote sources store to start querying immediately
      print("TVLibraryView: initializing RemoteSourcesStore.shared")
      let store = RemoteSourcesStore.shared
      print("TVLibraryView: RemoteSourcesStore has \(store.sources.count) sources")

      // Store hydration already starts sources; avoid redundant boot-time refresh triggers

      model.load()
      model.kickoffInitialMetadataIfNeeded()
      if !didReloadOnce {
        didReloadOnce = true
        DispatchQueue.main.async { model.load() }
      }

      // Deep link from Spotlight: launch by GameID
      NotificationCenter.default.addObserver(
        forName: NSNotification.Name("DOLLaunchGameByGameID"),
        object: nil,
        queue: .main
      ) { note in
        guard let gameID = note.userInfo?["gameID"] as? String else { return }
        spotlightLaunchByGameID(gameID, attempts: 10)
      }

      // Quick actions
      NotificationCenter.default.addObserver(forName: NSNotification.Name("DOLShowImportGame"), object: nil, queue: .main) { _ in
#if os(iOS) || targetEnvironment(macCatalyst)
        showImportSoftwarePicker = true
#endif
      }
      NotificationCenter.default.addObserver(forName: NSNotification.Name("DOLShowSettings"), object: nil, queue: .main) { _ in
#if os(iOS) || targetEnvironment(macCatalyst)
        navigateToSettings = true
#endif
      }
      NotificationCenter.default.addObserver(forName: NSNotification.Name("DOLShowSnackbar"), object: nil, queue: .main) { note in
        if let text = note.userInfo?["text"] as? String { snackbarText = text; withAnimation { snackbarVisible = true };
          DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation { snackbarVisible = false } }
        }
      }
      // Rescan library when a file import completes
      NotificationCenter.default.addObserver(forName: NSNotification.Name("DOLImportFileFinishedNotification"), object: nil, queue: .main) { _ in
        Task { @MainActor in
          LibraryAddedDateStore.recordRecentImportsInSoftwareFolder()
          model.rescan()
        }
      }
      // Global DSU approval toast
      NotificationCenter.default.addObserver(forName: NSNotification.Name("DSUNewClientApproval"), object: nil, queue: .main) { note in
        if let addr = note.userInfo?["address"] as? String { approvalBannerAddr = addr }
      }
      // First-run onboarding
      if !UserDefaults.standard.bool(forKey: "onboarding_seen_v1") {
        withAnimation { showOnboarding = true }
      }
    }
    .onDisappear {
      func removeAllObservers() {
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name("DOLLaunchGameByGameID"), object: nil)
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name("DOLShowImportGame"), object: nil)
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name("DOLShowSettings"), object: nil)
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name("GameFileMetadataUpdated"), object: nil)
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name("DOLShowSnackbar"), object: nil)
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name("DOLImportFileFinishedNotification"), object: nil)
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name("DSUNewClientApproval"), object: nil)
      }
      removeAllObservers()
    }
#if os(tvOS)
    .fullScreenCover(isPresented: $showSettings) { TVSettingsPage().interactiveDismissDisabled(true) }
    .sheet(isPresented: $showSearchSheet) {
      NavigationStack {
        Form {
          Section(header: Text(L("Search Games"))) {
            TextField(L("Search by title, maker, ID, filename…"), text: $searchText)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled(true)
          }
          if !searchText.isEmpty {
            Text(String(format: L("%1$ld results"), model.games.filter { item in
              let q = searchText.lowercased()
              let title = item.title.lowercased()
              let maker = item.makerLong.lowercased()
              let gid = item.gameID.lowercased()
              let gtdb = item.gametdbID.lowercased()
              let country = item.countryName.lowercased()
              let filename: String = {
                if let url = URL(string: item.filePath) {
                  return (url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? url.lastPathComponent).lowercased()
                }
                return item.filePath.lowercased()
              }()
              return title.contains(q) || maker.contains(q) || gid.contains(q) || gtdb.contains(q) || country.contains(q) || filename.contains(q) || item.filePath.lowercased().contains(q)
            }.count))
            .foregroundStyle(.secondary)
          }
        }
        .navigationTitle(L("Search"))
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button(L("Done")) { showSearchSheet = false } } }
      }
    }
#endif
    .confirmationDialog(L("Select Region"), isPresented: $showUpdateRegions, titleVisibility: .visible) {
      Button(L("Europe")) { TVLibraryBridge.performOnlineSystemUpdate(withRegion: "EUR") }
      Button(L("Japan")) { TVLibraryBridge.performOnlineSystemUpdate(withRegion: "JPN") }
      Button(L("Korea")) { TVLibraryBridge.performOnlineSystemUpdate(withRegion: "KOR") }
      Button(L("United States")) { TVLibraryBridge.performOnlineSystemUpdate(withRegion: "USA") }
      Button(L("Cancel"), role: .cancel) {}
    }
    .confirmationDialog(L("A game is already running."), isPresented: $model.showReplaceAlert, titleVisibility: .visible) {
      Button(L("Replace Game"), role: .destructive) {
        TVEmulationBridge.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
          if let item = model.pendingSelection {
            model.currentGame = item
            navigateTo = item
          }
        }
      }
      Button(L("Continue Current Game"), role: .cancel) { if let current = model.currentGame { navigateTo = current } }
      Button(L("Cancel")) { }
    } message: { Text(L("Do you want to stop the current game and launch the new one?")) }
      .sheet(item: $showPropertiesFor) { TVSoftwarePropertiesView(item: $0) }
      .sheet(item: $showCheatListFor) { TVCheatListView(item: $0) }
      .sheet(isPresented: Binding(get: { sourcePickerItems != nil }, set: { if !$0 { sourcePickerItems = nil } })) {
        if let items = sourcePickerItems {
          SourcePickerView(items: items) { chosen in
            sourcePickerItems = nil
            launchGame(chosen)
          }
        }
      }
    // Sources sheet
      .sheet(isPresented: $showSources) { SourcesView() }
#if os(iOS)
      .sheet(isPresented: $showWebImportSheet) {
        LibraryWebImportView()
      }
      .fileImporter(
        isPresented: $showImportSkylanderPicker,
        allowedContentTypes: [.data],
        allowsMultipleSelection: true
      ) { result in
        if case .success(let urls) = result {
          var loadedCount = 0
          for url in urls {
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            let slot = DOLConfigBridge.skylanderLoad(fromPath: url.path)
            if slot > 0 { loadedCount += 1 }
          }
          if loadedCount > 0 {
            let text = loadedCount == 1
              ? L("Skylander loaded in portal")
              : String(format: L("Loaded %1$ld Skylander figures"), loadedCount)
            NotificationCenter.default.post(
              name: NSNotification.Name("DOLShowSnackbar"),
              object: nil,
              userInfo: ["text": text]
            )
          }
        }
      }
#endif
#if os(iOS) || targetEnvironment(macCatalyst)
    // iOS Document Pickers
      .sheet(isPresented: $showImportSoftwarePicker) {
        NavigationStack {
          DocumentPickerView(
            contentTypes: DocumentPickerView.softwareContentTypes,
            allowsMultipleSelection: true,
            onPick: { urls in
              ImportFileManager.shared().importFiles(at: urls as [NSURL])
            }
          )
          .navigationTitle(L("Import Game"))
        }
      }
      .sheet(isPresented: $showImportNANDPicker) {
        NavigationStack {
          DocumentPickerView(
            contentTypes: [DocumentPickerView.binType],
            onPick: { urls in
              guard let url = urls.first else { return }
              NANDImportManager.importNAND(from: url)
            }
          )
          .navigationTitle(L("Import BootMii NAND Backup"))
        }
      }
#endif
    /// Delete confirmation and action
      .alert(L("Delete Game?"), isPresented: Binding(get: { itemPendingDelete != nil }, set: { if !$0 { itemPendingDelete = nil } })) {
        Button(L("Delete"), role: .destructive) {
          if let toDelete = itemPendingDelete {
            if deleteLocalGame(toDelete) { model.rescan() }
            itemPendingDelete = nil
          }
        }
        Button(L("Cancel"), role: .cancel) { itemPendingDelete = nil }
      } message: { if let item = itemPendingDelete { Text(L("This will delete \(item.title). This action cannot be undone.")) } }
      .alert(L("Delete Selected Games?"), isPresented: $showBatchDeleteConfirm) {
        Button(L("Delete"), role: .destructive) {
          performBatchDelete(paths: pendingBatchDeletePaths)
          pendingBatchDeletePaths.removeAll()
        }
        Button(L("Cancel"), role: .cancel) {
          pendingBatchDeletePaths.removeAll()
        }
      } message: {
        Text("\(pendingBatchDeletePaths.count) \(L("selected games will be deleted. This cannot be undone."))")
      }
    // Storage error alert
      .alert(L("Storage Error"), isPresented: $showStorageErrorAlert) {
        Button(L("OK")) {}
      } message: { Text(storageAlertMessage) }
    // Low storage warning - using confirmationDialog instead of alert to avoid conflicts
      .confirmationDialog(L("Low Storage Warning"), isPresented: $showLowStorageWarning, titleVisibility: .visible) {
        Button(L("Continue Anyway")) {
          if let item = itemPendingLaunch {
            proceedWithGameLaunch(item)
          }
        }
        Button(L("Cancel"), role: .cancel) {}
      } message: { Text(storageAlertMessage) }
      .sheet(item: $showCacheInfoFor) { item in
        CacheInfoView(item: item, showSubtitles: showSubtitles)
      }
      .overlay(blockingPrecacheOverlay)
      .overlay(offlineBanner)
#if os(iOS) || targetEnvironment(macCatalyst)
      .overlay(dropHighlight)
#endif
      .overlay(searchHintBanner)
      .overlay(snackbar)
      .overlay(dsuApprovalBanner)
      .overlay(onboardingOverlay)
#if os(iOS)
      .sheet(isPresented: Binding(get: { showGeckoEditorFor != nil }, set: { if !$0 { showGeckoEditorFor = nil } })) {
        if let item = showGeckoEditorFor { GeckoCodesModal(item: item) }
      }
      .sheet(isPresented: Binding(get: { showAREditorFor != nil }, set: { if !$0 { showAREditorFor = nil } })) {
        if let item = showAREditorFor { ActionReplayCodesModal(item: item) }
      }
#endif
  }

  @State private var snackbarText: String = ""
  @State private var snackbarVisible: Bool = false
  @State private var showOnboarding: Bool = false
  @StateObject private var storeForBanner = RemoteSourcesStore.shared
  @State private var offlineBannerDismissed: Bool = false
  // DSU approval banner state
  @State private var approvalBannerAddr: String? = nil
#if os(tvOS)
  @State private var showSearchSheet: Bool = false
#endif

  @ViewBuilder private var snackbar: some View {
    if snackbarVisible {
      VStack {
        Spacer()
        HStack {
          Text(snackbarText).foregroundStyle(.white).font(.subheadline)
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.black.opacity(0.8))
        .clipShape(Capsule())
        .padding(.bottom, 16)
      }
      .transition(.move(edge: .bottom).combined(with: .opacity))
    }
  }

  @ViewBuilder private var dsuApprovalBanner: some View {
    if let addr = approvalBannerAddr {
      VStack {
        HStack(spacing: 12) {
          Image(systemName: "antenna.radiowaves.left.and.right").foregroundColor(.white)
          VStack(alignment: .leading, spacing: 2) {
            Text(L("Receiver requests input")).foregroundColor(.white).font(.subheadline)
            Text(addr).foregroundColor(.white.opacity(0.9)).font(.caption)
          }
          Spacer()
          Button(L("Always Allow")) {
            DSUServerBridge.setClient(addr, allowed: true)
            approvalBannerAddr = nil
            NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": String(format: L("Always allowed %@"), addr)])
          }
          .buttonStyle(.borderedProminent)
          Button(L("Block")) {
            DSUServerBridge.setClient(addr, allowed: false)
            approvalBannerAddr = nil
            NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": String(format: L("Blocked %@"), addr)])
          }
          .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.top, 8)
        .padding(.horizontal, 12)
        Spacer()
      }
      .contentShape(Rectangle())
      .onTapGesture {
        // Open DSU Controller sheet for details
#if os(iOS)
        showDSUSession = true
#endif
        // Dismiss the banner after opening
        approvalBannerAddr = nil
      }
      .transition(.move(edge: .top).combined(with: .opacity))
    }
  }

  @ViewBuilder private var offlineBanner: some View {
    // Only surface a source that is reachable (the host answered our probe) but returning errors —
    // e.g. bad auth, wrong path, a 5xx. A source that's simply unreachable because we're off its
    // network is NOT worth nagging about every boot, so it's excluded (serverReachable == false).
    let anyServerError = storeForBanner.sources.contains { (src) -> Bool in
      guard let w = src as? WebDAVSource else { return false }
      return w.isOnline == false && w.serverReachable
    }
    if anyServerError && !offlineBannerDismissed {
      VStack {
        HStack(spacing: 10) {
          Image(systemName: "exclamationmark.icloud").foregroundStyle(.white)
          Text(L("A remote source is reachable but returning errors. Retrying…")).foregroundStyle(.white)
            .lineLimit(2)
          Spacer(minLength: 8)
          Button(action: { withAnimation { offlineBannerDismissed = true } }) {
            Image(systemName: "xmark").foregroundStyle(.white)
          }
          .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .onAppear {
          DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            withAnimation { offlineBannerDismissed = true }
          }
        }
        Spacer()
      }
      .transition(.move(edge: .top).combined(with: .opacity))
    } else if !anyServerError && offlineBannerDismissed {
      EmptyView()
        .onAppear { offlineBannerDismissed = false }
    } else {
      EmptyView()
    }
  }

  @ViewBuilder private var searchHintBanner: some View {
#if os(tvOS)
    let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    if !q.isEmpty {
      let needle = q.lowercased()
      let filenameLower: (String) -> String = { path in
        if let url = URL(string: path) {
          return (url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? url.lastPathComponent).lowercased()
        }
        return path.lowercased()
      }
      let hasMatches = model.games.contains { item in
        let title = item.title.lowercased()
        if title.contains(needle) { return true }
        if filenameLower(item.filePath).contains(needle) { return true }
        if item.gameID.lowercased().contains(needle) { return true }
        if item.makerLong.lowercased().contains(needle) { return true }
        if item.countryName.lowercased().contains(needle) { return true }
        if item.gametdbID.lowercased().contains(needle) { return true }
        if item.filePath.lowercased().contains(needle) { return true }
        return false
      }
      if !hasMatches {
        VStack {
          Spacer().frame(height: 8)
          HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.white)
            Text(L("No results. Try title, maker, Game ID, or filename."))
              .foregroundStyle(.white)
              .lineLimit(2)
            Spacer(minLength: 8)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 10)
          .background(Color.gray.opacity(0.85))
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          .padding(.horizontal, 12)
          .padding(.top, 8)
          Spacer()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
      } else { EmptyView() }
    } else { EmptyView() }
#else
    EmptyView()
#endif
  }

  @ViewBuilder
  private var blockingPrecacheOverlay: some View {
    if let current = blockingPrecacheItem {
      ZStack {
        Color.black.opacity(0.6).ignoresSafeArea()
        VStack(spacing: 14) {
          Image(systemName: "arrow.down.circle.fill")
            .font(.system(size: 44, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 2)

          Text(L("Preparing cache"))
            .font(.title3).fontWeight(.semibold)
            .foregroundStyle(.white)

          Text(current.title)
            .font(.callout)
            .foregroundStyle(.white.opacity(0.85))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: 280)

          DolphinCircularSpinner(
            size: 64,
            lineWidth: 8,
            dolphinSize: 20,
            progress: blockingPrecacheProgress
          )
          .padding(.top, 6)

          Text("\(Int(blockingPrecacheProgress * 100))%")
            .font(.footnote).fontWeight(.semibold)
            .foregroundStyle(.white)
            .monospacedDigit()

          HStack(spacing: 12) {
            Button(role: .cancel) {
              if let url = URL(string: current.filePath), let source = getMatchingWebDAVSource(for: url) {
                let remoteItem = RemoteLibraryItem(url: url, name: current.title, size: Int64(current.fileSize))
                Task { await source.cancelPreCache(remoteItem) }
              }
              blockingPrecacheItem = nil
              blockingPrecacheProgress = 0
              emulationRunning = false
              // Restore controller navigation if we were in library
#if os(iOS) || targetEnvironment(macCatalyst)
              Task { @MainActor in
                // Re-setup navigation using the last known grid column count
                setupControllerNavigation(columns: max(2, gridColumnCount))
              }
#endif
            } label: {
              Text(L("Cancel"))
                .font(.callout).fontWeight(.semibold)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Color.white.opacity(0.15), in: Capsule())
            }
          }
          .padding(.top, 4)
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 24)
        .background(
          RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.ultraThinMaterial)
            .shadow(color: .black.opacity(0.25), radius: 18, x: 0, y: 10)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
      }
      .transition(.opacity)
      .zIndex(10)
    }
  }

  @ViewBuilder private var onboardingOverlay: some View {
    if showOnboarding {
      ZStack {
        Color.black.opacity(0.5).ignoresSafeArea()
        VStack(spacing: 20) {
          // Header icon and title
          VStack(spacing: 10) {
            ZStack {
              Circle()
                .fill(.white.opacity(0.12))
                .frame(width: 64, height: 64)
              Image(systemName: "gamecontroller.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
            }
            Text(L("Welcome to iCube"))
              .font(.title2).fontWeight(.bold)
              .foregroundStyle(.white)
          }

          // Subtitle
          Text(L("Get started by importing a game or adding a remote source."))
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.85))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)

          // Primary actions
          HStack(spacing: 12) {
            Button(action: {
#if os(iOS) || targetEnvironment(macCatalyst)
              showImportSoftwarePicker = true
#endif
              UserDefaults.standard.set(true, forKey: "onboarding_seen_v1")
              withAnimation { showOnboarding = false }
            }) {
              HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down")
                Text(L("Import Game"))
              }
              .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color("DolphinTint"))

            Button(action: {
              showSources = true
              UserDefaults.standard.set(true, forKey: "onboarding_seen_v1")
              withAnimation { showOnboarding = false }
            }) {
              HStack(spacing: 8) {
                Image(systemName: "externaldrive.badge.plus")
                Text(L("Add Remote Source"))
              }
              .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
          }

          // Secondary action
          Button(L("Maybe Later")) {
            UserDefaults.standard.set(true, forKey: "onboarding_seen_v1")
            withAnimation { showOnboarding = false }
          }
          .buttonStyle(.bordered)
          .tint(.white)

          // Lineage / credits — iCube is a downstream fork; credit the projects it builds on.
          VStack(spacing: 4) {
            Text(L("iCube is a fork of DolphiniOS, based on the Dolphin emulator."))
              .font(.caption2)
              .foregroundStyle(.white.opacity(0.6))
              .multilineTextAlignment(.center)
#if os(iOS) || targetEnvironment(macCatalyst)
            HStack(spacing: 16) {
              if let u = URL(string: "https://dolphinios.oatmealdome.me") {
                Link("DolphiniOS", destination: u)
              }
              if let u = URL(string: "https://dolphin-emu.org") {
                Link("Dolphin", destination: u)
              }
            }
            .font(.caption2.weight(.semibold))
            .tint(Color("DolphinTint"))
#endif
          }
          .padding(.top, 6)
        }
        .padding(22)
        .background(
          RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(.ultraThinMaterial)
            .shadow(color: .black.opacity(0.25), radius: 18, x: 0, y: 10)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .padding(.horizontal, 24)
      }
      .transition(.opacity)
    }
  }

  private func downloadGecko(for item: TVGameItem) {
    TVCheatsBridge.downloadGeckoCodes(forGameId: item.gameID, revision: item.revision, gametdbId: item.gametdbID) { success, _, _ in
      if !success { showCheatError = L("Failed to download Gecko codes.") }
    }
  }

  private func presentCheatInput(for item: TVGameItem, type: CheatType) {
    cheatName = ""; cheatCreator = ""; cheatBody = ""; cheatNotes = ""
    cheatInputFor = (item, type); showCheatError = nil
  }

  private func saveCheat(_ ctx: (item: TVGameItem, type: CheatType)) {
#if os(tvOS)
    if ctx.type == .gecko {
      if !TVCheatsBridge.addGeckoCode(forGameId: ctx.item.gameID, revision: ctx.item.revision, name: cheatName, creator: cheatCreator, codeText: cheatBody, notesText: cheatNotes) { showCheatError = L("Failed to add Gecko code"); return }
    } else {
      if !TVCheatsBridge.addActionReplayCode(forGameId: ctx.item.gameID, revision: ctx.item.revision, name: cheatName, codeText: cheatBody) { showCheatError = L("Failed to add AR code"); return }
    }
    cheatInputFor = nil
#endif
  }

  private func selectGame(_ item: TVGameItem) {
    let sources = model.sources(for: item)
    if sources.count > 1 {
      sourcePickerItems = sources
      return
    }
    emulationRunning = true
    teardownControllerNavigation()
    launchGame(item)
  }

  private func launchGame(_ item: TVGameItem) {
    // Check for critically low storage before launching any game
    if TVLibraryView.isStorageCriticallyLow() {
      let availableSpace = TVLibraryView.getAvailableStorageSpace()
      itemPendingLaunch = item
      storageAlertMessage = """
            Warning: Low Storage Space

            Available space: \(TVLibraryView.formatStorageSpace(availableSpace))

            The emulator may act erratically with low storage space. Consider freeing up some space before playing.

            Do you want to continue anyway?
            """
      showLowStorageWarning = true
      return
    }

    // If remote and auto-precache enabled, ensure cache exists before launch
    if let url = URL(string: item.filePath), Self.isRemoteURL(item.filePath) {
      for source in RemoteSourcesStore.shared.sources {
        if let webdav = source as? WebDAVSource, webdav.isPreCachingEnabled {
          let remoteItem = RemoteLibraryItem(url: url, displayName: item.title, sizeBytes: Int64(item.fileSize), etag: nil, lastModified: nil)
          if !webdav.isCached(remoteItem) {
            blockingPrecacheItem = item
            blockingPrecacheProgress = 0
            Task {
              do {
                let _ = try await webdav.preCacheItem(remoteItem) { progress in
                  DispatchQueue.main.async { blockingPrecacheProgress = progress }
                }
                DispatchQueue.main.async {
                  blockingPrecacheItem = nil
                  proceedWithGameLaunch(item)
                }
              } catch {
                DispatchQueue.main.async {
                  blockingPrecacheItem = nil
                  proceedWithGameLaunch(item) // fallback
                }
              }
            }
            return
          }
          break
        }
      }
    }

    proceedWithGameLaunch(item)
  }

  /// Actually launch the game (called after low storage warning is dismissed)
  private func proceedWithGameLaunch(_ item: TVGameItem) {
    GameProfiles.shared.applyProfileIfAvailable(for: item)
    if TVEmulationBridge.isRunning() {
      model.pendingSelection = item
      model.showReplaceAlert = true
    } else {
      NSLog("[INPUT] TVLibraryView selecting game: %@", item.title)

      // Auto pre-cache if enabled and not already cached
      if let url = URL(string: item.filePath),
         Self.isRemoteURL(item.filePath) {
        // This is a remote game - check for auto pre-caching
        for source in RemoteSourcesStore.shared.sources {
          if let webdavSource = source as? WebDAVSource,
             webdavSource.isPreCachingEnabled {
            // Start background pre-caching with progress tracking
            let gameKey = item.filePath
            autoPreCacheActive.insert(gameKey)
            autoPreCacheProgress[gameKey] = 0.0

            Task {
              do {
                // Use the file size from TVGameItem (which comes from WebDAV PROPFIND)
                let fileSize = Int64(item.fileSize)

                // Skip auto pre-cache if insufficient storage space
                if !TVLibraryView.hasEnoughSpaceForPreCache(fileSize: fileSize) {
                  let availableSpace = TVLibraryView.getAvailableStorageSpace()
                  print("Auto pre-cache skipped for \(item.title): insufficient space. Available: \(TVLibraryView.formatStorageSpace(availableSpace)), Required: \(TVLibraryView.formatStorageSpace(fileSize + TVLibraryView.STORAGE_BUFFER_MB))")
                  DispatchQueue.main.async {
                    autoPreCacheActive.remove(gameKey)
                    autoPreCacheProgress.removeValue(forKey: gameKey)
                  }
                  return
                }

                let remoteItem = RemoteLibraryItem(url: url, name: item.title, size: fileSize)

                // Check if already cached with correct size
                if !webdavSource.isCached(remoteItem) {
                  let _ = try await webdavSource.preCacheItem(remoteItem) { progress in
                    DispatchQueue.main.async {
                      autoPreCacheProgress[gameKey] = progress
                    }
                  }
                }
                DispatchQueue.main.async {
                  autoPreCacheActive.remove(gameKey)
                  autoPreCacheProgress.removeValue(forKey: gameKey)
                }
              } catch {
                print("Auto pre-cache failed: \(error)")
                DispatchQueue.main.async {
                  autoPreCacheActive.remove(gameKey)
                  autoPreCacheProgress.removeValue(forKey: gameKey)
                }
              }
            }
            break
          }
        }
      }

      model.currentGame = item
      navigateTo = item
    }
  }

  private func spotlightLaunchByGameID(_ gameID: String, attempts: Int) {
    let match = model.games.first { $0.gameID == gameID }
    ?? TVLibraryBridge.currentGames().first { $0.gameID == gameID }
    guard let item = match else {
      if attempts > 0 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
          spotlightLaunchByGameID(gameID, attempts: attempts - 1)
        }
      }
      return
    }
    GameProfiles.shared.applyProfileIfAvailable(for: item)
    if let url = URL(string: item.filePath), Self.isRemoteURL(item.filePath) {
      if let webdav = getMatchingWebDAVSource(for: url), webdav.isPreCachingEnabled {
        let remoteItem = RemoteLibraryItem(url: url, name: item.title, size: 0)
        if !webdav.isCached(remoteItem) {
          blockingPrecacheItem = item
          blockingPrecacheProgress = 0
          Task {
            do {
              let _ = try await webdav.preCacheItem(remoteItem) { progress in
                DispatchQueue.main.async { blockingPrecacheProgress = progress }
              }
              DispatchQueue.main.async {
                blockingPrecacheItem = nil
                navigateTo = item
              }
            } catch {
              DispatchQueue.main.async {
                blockingPrecacheItem = nil
                navigateTo = item // fallback to stream
              }
            }
          }
          return
        }
      }
    }
    navigateTo = item
  }

  private func setupControllerNavigation(columns: Int) {
#if !os(tvOS)
    GCController.shouldMonitorBackgroundEvents = false
    for c in GCController.controllers() {
      c.extendedGamepad?.buttonMenu.pressedChangedHandler = { _, _, _ in /* swallow to avoid Game Center */ }
      c.microGamepad?.buttonMenu.pressedChangedHandler = { _, _, _ in /* swallow to avoid Game Center */ }

      if let egp = c.extendedGamepad {
        let cid = ObjectIdentifier(c)
        if prevEGPHandlers[cid] == nil { prevEGPHandlers[cid] = egp.valueChangedHandler }
        egp.valueChangedHandler = { (gamepad: GCExtendedGamepad, element: GCControllerElement) in
          guard !model.games.isEmpty else { return }
          let index: Int = {
            if let current = focusedFilePath, let idx = model.games.firstIndex(where: { $0.filePath == current }) { return idx }
            return 0
          }()
          func move(_ delta: Int, dir: String) {
            let now = Date().timeIntervalSince1970
            if now - lastNavMoveTime < navRepeatInterval { return }
            lastNavMoveTime = now
            DispatchQueue.main.async {
              let newIndex = max(0, min(index + delta, model.games.count - 1))
              focusedFilePath = model.games[newIndex].filePath
            }
          }
          let dpad = gamepad.dpad
          if element == dpad.up, dpad.up.isPressed { move(-columns, dir: "up") }
          if element == dpad.down, dpad.down.isPressed { move(columns, dir: "down") }
          if element == dpad.left, dpad.left.isPressed { move(-1, dir: "left") }
          if element == dpad.right, dpad.right.isPressed { move(1, dir: "right") }
          if element == dpad {
            let vx = dpad.xAxis.value
            let vy = dpad.yAxis.value
            if vy > 0.5 { move(-columns, dir: "up") }
            if vy < -0.5 { move(columns, dir: "down") }
            if vx < -0.5 { move(-1, dir: "left") }
            if vx > 0.5 { move(1, dir: "right") }
          }
          // Left thumbstick support
          let lx = gamepad.leftThumbstick.xAxis.value
          let ly = gamepad.leftThumbstick.yAxis.value
          if element == gamepad.leftThumbstick {
            if ly > 0.6 { move(-columns, dir: "up") }
            if ly < -0.6 { move(columns, dir: "down") }
            if lx < -0.6 { move(-1, dir: "left") }
            if lx > 0.6 { move(1, dir: "right") }
          }
          if element == gamepad.buttonA, gamepad.buttonA.isPressed {
            if let fp = focusedFilePath, let item = model.games.first(where: { $0.filePath == fp }) { DispatchQueue.main.async { selectGame(item) } }
            let gen = UIImpactFeedbackGenerator(style: .medium)
            gen.impactOccurred()
          }
        }
      }
      if let mgp = c.microGamepad {
        mgp.reportsAbsoluteDpadValues = true
        mgp.allowsRotation = true
        let cid = ObjectIdentifier(c)
        if prevMGPHandlers[cid] == nil { prevMGPHandlers[cid] = mgp.valueChangedHandler }
        mgp.valueChangedHandler = {(gamepad: GCMicroGamepad, element: GCControllerElement) in
          guard !model.games.isEmpty else { return }
          let index: Int = {
            if let current = focusedFilePath, let idx = model.games.firstIndex(where: { $0.filePath == current }) { return idx }
            return 0
          }()
          func move(_ delta: Int, dir: String) {
            let now = Date().timeIntervalSince1970
            if now - lastNavMoveTime < navRepeatInterval { return }
            lastNavMoveTime = now
            DispatchQueue.main.async {
              let newIndex = max(0, min(index + delta, model.games.count - 1))
              focusedFilePath = model.games[newIndex].filePath
            }
          }
          if element == gamepad.dpad {
            let vx = gamepad.dpad.xAxis.value, vy = gamepad.dpad.yAxis.value
            if vy > 0.5 { move(-columns, dir: "up") }
            if vy < -0.5 { move(columns, dir: "down") }
            if vx < -0.5 { move(-1, dir: "left") }
            if vx > 0.5 { move(1, dir: "right") }
          }
          if element == gamepad.buttonA, gamepad.buttonA.isPressed {
            if let fp = focusedFilePath, let item = model.games.first(where: { $0.filePath == fp }) { DispatchQueue.main.async { selectGame(item) } }
            let gen = UIImpactFeedbackGenerator(style: .medium)
            gen.impactOccurred()
          }
        }
      }
    }
#endif
  }

  private func teardownControllerNavigation() {
#if !os(tvOS)
    for c in GCController.controllers() {
      let cid = ObjectIdentifier(c)
      if let egp = c.extendedGamepad {
        if let prev = prevEGPHandlers[cid] {
          egp.valueChangedHandler = prev
        } else {
          egp.valueChangedHandler = nil
        }
      }
      if let mgp = c.microGamepad {
        if let prev = prevMGPHandlers[cid] {
          mgp.valueChangedHandler = prev
        } else {
          mgp.valueChangedHandler = nil
        }
      }
      c.extendedGamepad?.buttonMenu.pressedChangedHandler = nil
      c.microGamepad?.buttonMenu.pressedChangedHandler = nil
      prevEGPHandlers.removeValue(forKey: cid)
      prevMGPHandlers.removeValue(forKey: cid)
    }
#endif
  }

  // MARK: - Selection & batch actions

  private func enterSelectionMode(selecting item: TVGameItem) {
    isSelectionMode = true
    selectedFilePaths.insert(item.filePath)
  }

  private func toggleSelection(for item: TVGameItem) {
    if selectedFilePaths.contains(item.filePath) {
      selectedFilePaths.remove(item.filePath)
    } else {
      selectedFilePaths.insert(item.filePath)
    }
  }

  private func exitSelectionMode() {
    isSelectionMode = false
    selectedFilePaths.removeAll()
  }

  private func selectAllVisibleGames() {
    let visible = filteredGames(from: model.games)
    selectedFilePaths = Set(visible.map(\.filePath))
  }

  private func batchSetFavorite(_ favorite: Bool) {
    var favDict = UserDefaults.standard.dictionary(forKey: "favorites_by_gameid") ?? [:]
    let items = model.games.filter { selectedFilePaths.contains($0.filePath) }
    for item in items where !item.gameID.isEmpty {
      favDict[item.gameID] = favorite
      item.isFavorite = favorite
    }
    UserDefaults.standard.set(favDict, forKey: "favorites_by_gameid")
    favoritesVersion &+= 1
    NotificationCenter.default.post(name: Notification.Name("FavoritesChanged"), object: nil)
  }

  private func batchSetPlatformOverride(_ category: LibraryPlatformCategory?) {
    LibraryPlatformOverrideStore.batchSetOverride(category, forFilePaths: Array(selectedFilePaths))
    platformOverridesVersion &+= 1
    showSnackbar(L("Platform assignment updated"))
  }

  private func batchSetControllerOverride(_ override: TouchControllerOverride) {
    let gameIDs = model.games
      .filter { selectedFilePaths.contains($0.filePath) }
      .map(\.gameID)
      .filter { !$0.isEmpty }
    GameProfiles.shared.batchSetControllerOverride(override, forGameIDs: gameIDs)
    showSnackbar(L("Controller assignment updated"))
  }

  private func deleteLocalGame(_ item: TVGameItem) -> Bool {
    guard let path = Self.localPath(for: item) else {
      showSnackbar(L("Remote games cannot be deleted from the library."))
      return false
    }
    do {
      try FileManager.default.removeItem(atPath: path)
      return true
    } catch {
      showSnackbar(String(format: L("Delete failed: %1$@"), error.localizedDescription))
      return false
    }
  }

  private func performBatchDelete(paths: Set<String>) {
    var deleted = 0
    var skippedRemote = 0
    for path in paths {
      guard let item = model.games.first(where: { $0.filePath == path }) else { continue }
      if deleteLocalGame(item) { deleted += 1 } else { skippedRemote += 1 }
    }
    if deleted > 0 { model.rescan() }
    if skippedRemote > 0 {
      showSnackbar("\(skippedRemote) \(L("remote items could not be deleted."))")
    } else if deleted > 0 {
      showSnackbar("\(L("Deleted")) \(deleted) \(L("games."))")
    }
    exitSelectionMode()
  }

  private func showSnackbar(_ text: String) {
    snackbarText = text
    withAnimation { snackbarVisible = true }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
      withAnimation { snackbarVisible = false }
    }
  }

  private func favorites() -> [TVGameItem]? {
    let favDict = UserDefaults.standard.dictionary(forKey: "favorites_by_gameid") ?? [:]
    let set = Set(favDict.compactMap { (k, v) in (v as? Bool) == true ? k : nil })
    guard !set.isEmpty else { return [] }
    var items = model.games.filter { set.contains($0.gameID) }
    if showPlatformFilterBar, platformFilter != .all, !isSearching {
      let overrides = platformOverrides
      items = items.filter {
        LibraryPlatformMapper.category(for: $0, override: overrides[$0.filePath]) == platformFilter
      }
    }
    return items
  }

  private func toggleFavorite(for item: TVGameItem) {
    item.isFavorite = !item.isFavorite
    // Nudge UI to update favorites row
    // Reload lightweight by touching state
  }
}

// MARK: - Source Picker

@MainActor
func getMatchingWebDAVSource(for url: URL) -> WebDAVSource? {
  func defaultPort(for scheme: String?) -> Int { (scheme?.lowercased() == "https" || scheme?.lowercased() == "webdavs") ? 443 : 80 }
  guard let urlHost = url.host?.lowercased() else { return nil }
  let urlPort = url.port ?? defaultPort(for: url.scheme)
  for source in RemoteSourcesStore.shared.sources {
    guard let w = source as? WebDAVSource else { continue }
    let base = w.baseURL
    guard let baseHost = base.host?.lowercased() else { continue }
    let basePort = base.port ?? defaultPort(for: base.scheme)
    if baseHost == urlHost && basePort == urlPort { return w }
  }
  return nil
}


private struct SourcePickerView: View {
  let items: [TVGameItem]
  let onPick: (TVGameItem) -> Void
  @Environment(\.dismiss) private var dismiss

  private func label(for item: TVGameItem) -> String {
    if let scheme = URL(string: item.filePath)?.scheme?.lowercased() {
      switch scheme {
      case "file": return L("Local")
      case "webdav", "webdavs":
        let host = URL(string: item.filePath)?.host ?? "WebDAV"
        return "WebDAV — \(host)"
      case "http", "https":
        let host = URL(string: item.filePath)?.host ?? "HTTP"
        return "HTTP — \(host)"
      default:
        return scheme.uppercased()
      }
    }
    return L("Local")
  }

  var body: some View {
    NavigationStack {
      List {
        Section(L("Choose Source")) {
          ForEach(items, id: \.filePath) { item in
            Button(action: { onPick(item) }) {
              HStack {
                Text(label(for: item))
                Spacer()
                Text(URL(string: item.filePath)?.lastPathComponent ?? "")
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
      }
      .navigationTitle(L("Select Source"))
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(L("Cancel"), role: .cancel) {
            dismiss()
          }
        }
      }
    }
  }
}

#if os(iOS)
/// Minimal share sheet wrapper
struct ShareSheet: UIViewControllerRepresentable {
  let activityItems: [Any]
  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
  }
  func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

// MARK: - Remote scan progress view (toolbar)
private struct RemoteScanProgressView: View {
  @StateObject private var store = RemoteSourcesStore.shared
  var body: some View {
    if store.isScanning {
      DolphinProgressView(
        progress: store.scanningProgress,
        width: 200,
        showPercentage: true,
        direction: .leftToRight
      )
      .frame(maxWidth: .infinity)
    }
  }
}

// MARK: - Safe index helper
private extension Array {
  subscript(safe index: Int) -> Element? {
    return indices.contains(index) ? self[index] : nil
  }
}

#if os(iOS) || targetEnvironment(macCatalyst)
extension TVLibraryView {
  private var dropHighlight: some View {
    if dropTargeted {
      return AnyView(
        VStack {
          Spacer().frame(height: 8)
          HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down").foregroundStyle(.white)
            if dropPreviewCount > 0 {
              Text(String(format: L("Drop %1$ld files to import"), dropPreviewCount))
                .foregroundStyle(.white)
            } else {
              Text(L("Drop files to import")).foregroundStyle(.white)
            }
            Spacer(minLength: 8)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 10)
          .background(Color.accentColor.opacity(0.9))
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          .padding(.horizontal, 12)
          .padding(.top, 8)
          Spacer()
        }
          .transition(.move(edge: .top).combined(with: .opacity))
      )
    }
    return AnyView(EmptyView())
  }

  private func handleDrop(providers: [NSItemProvider]) {
    let wanted = UTType.fileURL.identifier
    var pendingURLs: [URL] = []
    let group = DispatchGroup()
    for provider in providers {
      if provider.hasItemConformingToTypeIdentifier(wanted) {
        group.enter()
        provider.loadItem(forTypeIdentifier: wanted, options: nil) { (item, error) in
          defer { group.leave() }
          if let nsURL = item as? NSURL, let url = nsURL as URL? {
            pendingURLs.append(url)
          }
        }
      }
    }
    group.notify(queue: .main) {
      dropPreviewCount = pendingURLs.count
      let files = ImportableFileTypes.filterImportURLs(pendingURLs)
      guard !files.isEmpty else {
        NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": L("No supported files to import")])
        return
      }
      NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": String(format: L("Importing %1$ld files…"), files.count)])
      ImportFileManager.shared().importFiles(at: files as [NSURL])
    }
  }
}
#endif

#if canImport(TipKit)
import TipKit
@available(iOS 17, tvOS 17, *)
private struct AttachTipModifier: ViewModifier {
  enum Kind { case importGame, addSource, search }
  let kind: Kind
  static func tip(_ kind: Kind) -> AttachTipModifier { AttachTipModifier(kind: kind) }
  func body(content: Content) -> some View {
    switch kind {
    case .importGame:
      content.popoverTip(ImportGameTip())
    case .addSource:
      content.popoverTip(AddRemoteSourceTip())
    case .search:
      content.popoverTip(SearchLibraryTip())
    }
  }
}
#endif

// MARK: - Compatibility Helpers (iOS 16)

private enum TipKind { case importGame, addSource, search }

private extension View {
  @ViewBuilder
  func onChangeCompat<T: Equatable>(of value: T, initial: Bool = false,
                                    _ handler: @escaping (_ old: T?, _ new: T) -> Void) -> some View {
    if #available(iOS 17, tvOS 17, *) {
      self.onChange(of: value, initial: initial, handler)
    } else {
      self.onChange(of: value) { new in handler(nil, new) }
    }
  }

  @ViewBuilder
  func navigationDestinationItemCompat<Item: Identifiable & Hashable, Destination: View>(
    item: Binding<Item?>,
    @ViewBuilder destination: @escaping (Item) -> Destination
  ) -> some View {
    self.navigationDestination(item: item, destination: destination)
  }

  @ViewBuilder
  func tipAttachCompat(_ kind: TipKind) -> some View {
#if canImport(TipKit)
    if #available(iOS 17, tvOS 17, *) {
      let mapped: AttachTipModifier.Kind = {
        switch kind {
        case .importGame: return .importGame
        case .addSource: return .addSource
        case .search: return .search
        }
      }()
      self.modifier(AttachTipModifier.tip(mapped))
    } else {
      self
    }
#else
    self
#endif
  }
}

/// iOS 16.0+ tracking modifier for backward compatibility
struct iOS16TrackingModifier: ViewModifier {
  let tracking: CGFloat

  func body(content: Content) -> some View {
    content.tracking(tracking)
  }
}

/// iOS 16.0+ navigation styling modifier for backward compatibility
struct iOS16NavigationStyleModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
      .toolbarColorScheme(.dark, for: .navigationBar)
#if !os(tvOS)
      .scrollContentBackground(.hidden)
#endif
  }
}

#if !os(tvOS)
/// Applies navigationSubtitle on iOS 17+; no-op on earlier OS versions.
private struct LibraryNavigationSubtitleModifier: ViewModifier {
  let subtitle: String

  func body(content: Content) -> some View {
    if #available(iOS 26.0, *) {
      content.navigationSubtitle(subtitle)
    } else {
      content
    }
  }
}
#endif

#if os(iOS) || targetEnvironment(macCatalyst)
/// Searchable modifier that adopts the iOS 26 "Liquid Glass" floating search
/// field where available, and otherwise falls back to the iOS 17–25 static
/// navigation-bar-drawer search. The iOS 26 path uses the system floating
/// search placement plus `.searchToolbarBehavior(.minimize)`, which collapses
/// the search field into the toolbar on scroll — reclaiming the header space
/// the old always-visible drawer wasted. The large title also collapses
/// natively on scroll under iOS 26, freeing more vertical room for games.
struct LibrarySearchableModifier: ViewModifier {
  @Binding var searchText: String

  func body(content: Content) -> some View {
    if #available(iOS 26.0, *) {
      // Floating/minimizing search: default placement floats the field and
      // `.minimize` tucks it into the toolbar on scroll.
      content
        .searchable(text: $searchText)
        .searchToolbarBehavior(.minimize)
    } else {
      // iOS 17–25: keep the existing always-visible search drawer unchanged.
      content
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
    }
  }
}
#endif


/// Stand-in for `EmulationScreen` when a screenshot-mode demo entry is opened.
/// Demo entries are synthetic (see `TVLibraryBridge.isScreenshotDemoMode`) and
/// have nothing to boot; this is never reachable in a Release build because
/// `isDemoItem` is always false there.
struct ScreenshotDemoUnavailableView: View {
  let title: String

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "photo.on.rectangle.angled")
        .font(.system(size: 48, weight: .light))
        .foregroundStyle(.secondary)
      Text(title)
        .font(.title2.weight(.semibold))
      Text("Demo entry — screenshot mode has no disc image to boot.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
