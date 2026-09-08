// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

struct GameGridItem: View {
  let item: TVGameItem
  let select: (TVGameItem) -> Void
  @Binding var focusedFilePath: String?

  // Context menu action closures provided by parent view
  let showProperties: (TVGameItem) -> Void
  let showCheatList: (TVGameItem) -> Void
  let downloadGeckoAction: (TVGameItem) -> Void
  let presentCheatGecko: (TVGameItem) -> Void
  let presentCheatAR: (TVGameItem) -> Void
  let requestDelete: (TVGameItem) -> Void
  let showFavoriteToggle: (TVGameItem) -> Void
  let showStorageAlert: (String) -> Void
  let showCacheInfo: (TVGameItem) -> Void
  let showSaveStates: (TVGameItem) -> Void
  let autoPreCacheProgress: Double
  let isAutoPreCaching: Bool
  let showSubtitles: Bool
  /// When true, taps toggle selection instead of launching the game.
  var selectionMode: Bool = false
  var isSelected: Bool = false
  var onToggleSelection: (() -> Void)?
  var onEnterSelectionMode: (() -> Void)?

  @AppStorage("library_disable_artwork") private var disableArtwork: Bool = false

  @State private var showPreCacheProgress = false
  @State private var preCacheProgress: Double = 0.0
  @State private var isPreCaching = false
  @State private var cacheStateVersion = 0 // Force UI updates when cache state changes

  #if os(tvOS)
  @State private var isFocused: Bool = false
  #endif

  /// Determines remote source type and appropriate icon
  private var remoteIconName: String? {
    guard let url = URL(string: item.filePath), let scheme = url.scheme?.lowercased() else { return nil }
    switch scheme {
    case "webdav", "webdavs": return "externaldrive"
    case "http", "https": return "cloud"
    default: return nil
    }
  }

  /// Check if this is a remote game
  private var isRemoteGame: Bool {
    let result = remoteIconName != nil
    #if DEBUG
    print("DEBUG: isRemoteGame for '\(item.title)' (path: '\(item.filePath)') = \(result)")
    #endif
    return result
  }

  /// Get the WebDAV source for this game (if any)
  private func getWebDAVSource() -> WebDAVSource? {
    guard isRemoteGame, let url = URL(string: item.filePath) else {
      #if DEBUG
      print("DEBUG: getWebDAVSource early return - isRemoteGame: \(isRemoteGame), url valid: \(URL(string: item.filePath) != nil)")
      #endif
      return nil
    }

    func defaultPort(for scheme: String?) -> Int {
      switch scheme?.lowercased() {
      case "https", "webdavs": return 443
      default: return 80
      }
    }

    guard let urlHost = url.host?.lowercased() else {
      #if DEBUG
      print("DEBUG: getWebDAVSource no host for URL: \(url)")
      #endif
      return nil
    }
    let urlPort = url.port ?? defaultPort(for: url.scheme)
    let urlPath = url.path

    #if DEBUG
    print("DEBUG: Looking for WebDAV source matching host: \(urlHost), port: \(urlPort), path: \(urlPath)")
    print("DEBUG: Available sources: \(RemoteSourcesStore.shared.sources.count)")
    #endif

    var bestMatch: (source: WebDAVSource, score: Int)? = nil

    for (index, source) in RemoteSourcesStore.shared.sources.enumerated() {
      #if DEBUG
      print("DEBUG: Source \(index): \(type(of: source))")
      #endif
      guard let webdavSource = source as? WebDAVSource else { continue }
      let base = webdavSource.baseURL
      #if DEBUG
      print("DEBUG: WebDAV source base URL: \(base)")
      #endif
      guard let baseHost = base.host?.lowercased() else { continue }
      let basePort = base.port ?? defaultPort(for: base.scheme)
      #if DEBUG
      print("DEBUG: Comparing - base host: \(baseHost), port: \(basePort) vs url host: \(urlHost), port: \(urlPort)")
      #endif
      guard urlHost == baseHost && urlPort == basePort else { continue }

      // Prefer the source with the longest base path prefix match
      let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
      let score: Int
      if basePath == "/" { score = 1 }
      else if urlPath.hasPrefix(basePath) { score = max(2, basePath.count) }
      else { score = 1 } // host/port match only

      #if DEBUG
      print("DEBUG: Found matching source with score \(score), basePath: '\(basePath)', isPreCachingEnabled: \(webdavSource.isPreCachingEnabled)")
      #endif
      if bestMatch == nil || score > bestMatch!.score {
        bestMatch = (webdavSource, score)
      }
    }

    let result = bestMatch?.source
    #if DEBUG
    print("DEBUG: getWebDAVSource result: \(result != nil ? "found" : "nil"), final isPreCachingEnabled: \(result?.isPreCachingEnabled ?? false)")
    #endif
    return result
  }

  /// Check if this remote game is cached locally
  private var isCached: Bool {
    _ = cacheStateVersion // Force dependency on cache state changes
    guard let source = getWebDAVSource(),
          let url = URL(string: item.filePath) else { return false }

    let remoteItem = RemoteLibraryItem(url: url, name: item.title, size: 0)
    return source.isCached(remoteItem)
  }

  /// Cover template system derived from DiscIO::Platform via LibraryPlatformMapper.
  private var gameSystem: LibraryGameSystem {
    LibraryGameSystem.from(item: item)
  }

  /// Selection chrome overlaid on the card cover.
  @ViewBuilder
  private var selectionOverlay: some View {
    if selectionMode {
      ZStack(alignment: .topLeading) {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .stroke(isSelected ? Color.accentColor : Color.white.opacity(0.35), lineWidth: isSelected ? 4 : 2)
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 22, weight: .semibold))
          .foregroundStyle(isSelected ? Color.accentColor : Color.white.opacity(0.8))
          .padding(10)
          .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
      }
      .frame(width: LibraryLayout.cardSize.width, height: LibraryLayout.cardSize.height)
      .allowsHitTesting(false)
    }
  }

  private func handlePrimaryAction() {
    if selectionMode {
      onToggleSelection?()
    } else {
      select(item)
    }
  }

  /// Enters multi-select mode with this game already selected.
  ///
  /// `onEnterSelectionMode` already inserts the item into the selection, so this
  /// must not also call `onToggleSelection` — that would immediately deselect it
  /// and leave selection mode active with nothing selected (and therefore no
  /// action bar, which is gated on a non-empty selection).
  private func enterSelectionMode() {
    onEnterSelectionMode?()
  }

  /// Check if we're using the default placeholder cover
  private var isUsingPlaceholderCover: Bool {
    // Global override: when enabled, always use the system templates (no artwork)
    if disableArtwork { return true }

    // This is a heuristic - check if the cover image is the default "NoCover" placeholder
    let image = item.coverImage
    let desc = image.description.lowercased()

    let isPlaceholder = image.size.width <= 1 ||
      image.size.height <= 1 ||
      desc.contains("nocover") ||
      desc.contains("placeholder") ||
      desc.contains("default") ||
      // Check for very small images that are likely placeholders
      (image.size.width < 50 && image.size.height < 50)

    #if DEBUG
    if isPlaceholder {
      print("DEBUG: Using placeholder cover for '\(item.title)' (gameID: '\(item.gameID)'), system: \(gameSystem)")
    }
    #endif

    return isPlaceholder
  }

  /// Stunning templated cover view with authentic GameCube/Wii theming! 🎮✨
  @ViewBuilder
  private var templatedCoverView: some View {
    ZStack {
      // Authentic game case background with system-specific theming
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(
          RadialGradient(
            colors: gameSystem == .gameCube ?
              [
                Color(red: 0.35, green: 0.25, blue: 0.75), // GameCube purple
                Color(red: 0.25, green: 0.15, blue: 0.65),
                Color(red: 0.15, green: 0.08, blue: 0.55)
              ] : [
                Color(red: 0.25, green: 0.55, blue: 0.95), // Wii blue
                Color(red: 0.15, green: 0.45, blue: 0.85),
                Color(red: 0.08, green: 0.35, blue: 0.75)
              ],
            center: .topLeading,
            startRadius: 20,
            endRadius: 200
          )
        )
        .overlay(
          // Enhanced case reflection with depth
          LinearGradient(
            colors: [
              Color.white.opacity(0.4),
              Color.white.opacity(0.15),
              Color.clear,
              Color.black.opacity(0.15),
              Color.black.opacity(0.25)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )
        .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 6)
        .overlay(
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(
              LinearGradient(
                colors: [Color.white.opacity(0.3), Color.clear, Color.white.opacity(0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              ),
              lineWidth: 1.5
            )
        )

      // Authentic GameCube disc case details
      if gameSystem == .gameCube {
        VStack {
          // Top edge highlight
          HStack {
            Rectangle()
              .fill(
                LinearGradient(
                  colors: [Color.white.opacity(0.6), Color.clear],
                  startPoint: .leading,
                  endPoint: .trailing
                )
              )
              .frame(height: 2)
              .padding(.horizontal, 16)
            Spacer()
          }
          Spacer()
        }
        .padding(.top, 4)

        // Left spine with authentic GameCube styling
        HStack {
          VStack(spacing: 2) {
            Rectangle()
              .fill(Color.white.opacity(0.5))
              .frame(width: 6, height: 20)
            Rectangle()
              .fill(Color.white.opacity(0.3))
              .frame(width: 4, height: 40)
            Rectangle()
              .fill(Color.white.opacity(0.5))
              .frame(width: 6, height: 20)
          }
          .padding(.leading, 6)
          Spacer()
        }
      }

      // Authentic full-cover template image like real GameCube/Wii box art
      Image(gameSystem.templateImageName)
        .resizable()
        .aspectRatio(contentMode: .fill)
        .frame(
          width: LibraryLayout.cardSize.width * 0.95,
          height: LibraryLayout.cardSize.height * 0.95
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .blendMode(.overlay)
      //        .offset(y: -5)

      // Authentic Nintendo branding
      //      VStack {
      //        HStack {
      //          Spacer()
      //          VStack(spacing: 2) {
      //            Text("NINTENDO")
      //              .font(.system(
      //                size: screenScaledFontSize(base: 8),
      //                weight: .black,
      //                design: .rounded
      //              ))
      //              .foregroundStyle(
      //                LinearGradient(
      //                  colors: [Color.white, Color.white.opacity(0.8)],
      //                  startPoint: .top,
      //                  endPoint: .bottom
      //                )
      //              )
      //              .modifier(iOS16TrackingModifier(tracking: 2))
      //              .shadow(color: .black.opacity(0.8), radius: 1, x: 0, y: 1)

      //            Text(gameSystem == .gameCube ? "GAMECUBE" : "Wii")
      //              .font(.system(
      //                size: screenScaledFontSize(base: 7),
      //                weight: .bold,
      //                design: .rounded
      //              ))
      //              .foregroundColor(.white.opacity(0.9))
      //              .modifier(iOS16TrackingModifier(tracking: 1.5))
      //              .shadow(color: .black.opacity(0.8), radius: 1, x: 0, y: 1)
      //          }
      //          .padding(.top, screenScaledPadding(base: 12))
      //          .padding(.trailing, screenScaledPadding(base: 12))
      //        }
      //        Spacer()
      //      }

      // Enhanced game info with award-winning typography
      VStack(spacing: screenScaledPadding(base: 10)) {
        Spacer()

        // Title with stunning effect
        Text(item.title.isEmpty ? "Unknown Game" : item.title)
          .font(.system(
            size: screenScaledFontSize(base: 18),
            weight: .black,
            design: .rounded
          ))
          .foregroundStyle(
            LinearGradient(
              colors: [
                Color.white,
                Color.white.opacity(0.95),
                Color.white.opacity(0.9)
              ],
              startPoint: .top,
              endPoint: .bottom
            )
          )
          .multilineTextAlignment(.center)
          .lineLimit(3)
          .minimumScaleFactor(0.6)
          .shadow(color: .black.opacity(0.9), radius: 3, x: 0, y: 2)
          .shadow(color: gameSystem == .gameCube ? .purple.opacity(0.5) : .blue.opacity(0.5),
                  radius: 8, x: 0, y: 0)

        // Enhanced Game ID with authentic styling
        if !item.gameID.isEmpty && showSubtitles {
          Text(item.gameID)
            .font(.system(
              size: screenScaledFontSize(base: 11),
              weight: .bold,
              design: .monospaced
            ))
            .foregroundStyle(
              LinearGradient(
                colors: [Color.white, Color.white.opacity(0.85)],
                startPoint: .top,
                endPoint: .bottom
              )
            )
            .padding(.horizontal, screenScaledPadding(base: 10))
            .padding(.vertical, screenScaledPadding(base: 5))
            .background(
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                  LinearGradient(
                    colors: [
                      Color.black.opacity(0.4),
                      Color.black.opacity(0.6)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                  )
                )
                .overlay(
                  RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
            )
        }
      }
      .padding(.horizontal, screenScaledPadding(base: 12))
      .padding(.bottom, screenScaledPadding(base: 16))

      // Subtle animated sparkles for magic ✨
      ForEach(0 ..< 3, id: \.self) { index in
        Image(systemName: "sparkle")
          .font(.system(size: screenScaledFontSize(base: 8), weight: .light))
          .foregroundColor(.white.opacity(0.4))
          .offset(
            x: CGFloat([20, -25, 15][index]),
            y: CGFloat([-30, -45, -35][index])
          )
          .opacity(0.6)
          .scaleEffect(0.8)
      }
    }
    .frame(width: LibraryLayout.cardSize.width, height: LibraryLayout.cardSize.height)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    // Enhanced 3D perspective
    .rotation3DEffect(
      .degrees(3),
      axis: (x: 0.1, y: 1.0, z: 0),
      perspective: 0.8
    )
  }

  /// Scale font sizes appropriately for tvOS vs iOS
  private func screenScaledFontSize(base: CGFloat) -> CGFloat {
    #if os(tvOS)
    return base * 1.4
    #else
    return base
    #endif
  }

  /// Scale padding appropriately for tvOS vs iOS
  private func screenScaledPadding(base: CGFloat) -> CGFloat {
    #if os(tvOS)
    return base * 1.5
    #else
    return base
    #endif
  }

  /// Enhanced headline font with iOS version compatibility
  private var enhancedHeadlineFont: Font {
    return .system(.headline, design: .rounded, weight: .semibold)
  }

  /// Enhanced caption font with iOS version compatibility
  private var enhancedCaptionFont: Font {
    return .system(.caption, design: .monospaced, weight: .medium)
  }

  var body: some View {
    #if os(tvOS)
    // Clean, simple approach for tvOS
    VStack(alignment: .leading, spacing: 12) {
      ZStack(alignment: .topTrailing) {
        // Show templated cover if using placeholder, otherwise show real cover with skeumorphism
        Group {
          if isUsingPlaceholderCover {
            templatedCoverView
          } else {
            ZStack {
              // Skeumorphic game case for real covers
              Image(uiImage: item.coverImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: LibraryLayout.cardSize.width, height: LibraryLayout.cardSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: Color.black.opacity(0.3), radius: 10, x: 0, y: 5)
                .overlay(
                  // Subtle case reflection
                  LinearGradient(
                    colors: [Color.white.opacity(0.15), Color.clear, Color.black.opacity(0.1)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                  )
                  .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                )
                .overlay(
                  RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
                // Add subtle 3D perspective to real covers too
                .rotation3DEffect(
                  .degrees(1),
                  axis: (x: 0.05, y: 1.0, z: 0),
                  perspective: 1.2
                )
            }
          }
        }
        .overlay(
          // Award-winning focus glow with GameCube/Wii theming
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(
              LinearGradient(
                colors: isFocused ? [
                  Color.cyan.opacity(0.95),
                  Color(.dolphinTint).opacity(0.9),
                  Color.purple.opacity(0.95),
                  Color.cyan.opacity(0.95)
                ] : [Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              ),
              lineWidth: isFocused ? 8 : 0
            )
            .shadow(color: .cyan.opacity(isFocused ? 0.8 : 0), radius: isFocused ? 25 : 0)
            .shadow(color: .blue.opacity(isFocused ? 0.6 : 0), radius: isFocused ? 35 : 0)
            .shadow(color: .purple.opacity(isFocused ? 0.7 : 0), radius: isFocused ? 45 : 0)
            .animation(.easeInOut(duration: 0.6), value: isFocused)
        )
        .overlay(
          // Inner highlight for premium feel
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(
              Color.white.opacity(isFocused ? 0.4 : 0),
              lineWidth: isFocused ? 2 : 0
            )
            .padding(4)
            .animation(.easeInOut(duration: 0.4), value: isFocused)
        )
        .shadow(
          color: Color.black.opacity(isFocused ? 0.4 : 0.2),
          radius: isFocused ? 20 : 8,
          x: 0,
          y: isFocused ? 12 : 6
        )

        if isFocused {
          VStack { LinearGradient(colors: [Color.white.opacity(0.2), .clear], startPoint: .top, endPoint: .center)
            Spacer()
          }
          .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
          .frame(width: LibraryLayout.cardSize.width, height: LibraryLayout.cardSize.height)
          .allowsHitTesting(false)
        }

        if let icon = remoteIconName {
          ZStack {
            if isPreCaching {
              // Show manual pre-cache progress indicator
              DolphinCircularSpinner(
                size: 24,
                lineWidth: 2,
                dolphinSize: 8,
                progress: preCacheProgress
              )
            } else {
              Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)

              // Show checkmark if cached
              if isCached {
                Image(systemName: "checkmark.circle.fill")
                  .font(.system(size: 12, weight: .bold))
                  .foregroundColor(.green)
                  .background(Color.white, in: Circle())
                  .offset(x: 8, y: -8)
              }
            }
          }
          .padding(8)
          .background(.ultraThinMaterial, in: Circle())
          .padding(8)
        }

        // Region flag badge (top-left), styled like the cloud indicator
        if !item.countryName.isEmpty {
          Text(RegionFlagMapper.compactFlag(for: item.countryName))
            .font(.system(size: 18))
            .padding(8)
            .background(.ultraThinMaterial, in: Circle())
            .padding(8)
            .frame(width: LibraryLayout.cardSize.width, height: LibraryLayout.cardSize.height, alignment: .topLeading)
            .allowsHitTesting(false)
        }
      }

      VStack(alignment: .leading, spacing: 6) {
        // Enhanced title with better typography
        Text(item.title)
          .font(.system(.headline, design: .rounded, weight: .semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.75)
          .foregroundStyle(
            LinearGradient(
              colors: [Color.primary, Color.primary.opacity(0.8)],
              startPoint: .top,
              endPoint: .bottom
            )
          )
          .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)

        if showSubtitles {
          HStack {
            // Game ID with enhanced styling
            Text(item.gameID)
              .font(enhancedCaptionFont)
              .foregroundStyle(
                LinearGradient(
                  colors: [Color.secondary, Color.secondary.opacity(0.8)],
                  startPoint: .top,
                  endPoint: .bottom
                )
              )
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(
                Capsule()
                  .fill(Color.primary.opacity(0.05))
                  .overlay(
                    Capsule()
                      .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                  )
              )

            Spacer()

            // Auto pre-cache progress indicator with better styling
            if isAutoPreCaching {
              HStack(spacing: 4) {
                CompactDolphinCircularSpinner()
                Text("\(Int(autoPreCacheProgress * 100))%")
                  .font(.system(.caption2, design: .monospaced, weight: .medium))
                  .foregroundColor(.secondary)
              }
              .padding(.horizontal, 8)
              .padding(.vertical, 4)
              .background(
                Capsule()
                  .fill(.ultraThinMaterial)
                  .overlay(
                    Capsule()
                      .stroke(Color(.dolphinTint).opacity(0.3), lineWidth: 1)
                  )
              )
            }
          }
        }
      }
    }
    .frame(width: LibraryLayout.cardSize.width)
    .scaleEffect(isFocused ? 1.08 : 1.0)
    .rotation3DEffect(
      .degrees(isFocused ? 5 : 2),
      axis: (x: 0.1, y: 1.0, z: 0),
      perspective: isFocused ? 0.8 : 1.0
    )
    .shadow(
      color: .black.opacity(isFocused ? 0.4 : 0.2),
      radius: isFocused ? 20 : 8,
      x: 0,
      y: isFocused ? 12 : 4
    )
    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isFocused)
    .focusable(true) { focused in
      withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
        isFocused = focused
        if focused { focusedFilePath = item.filePath } else if focusedFilePath == item.filePath { focusedFilePath = nil }
      }
    }
    .overlay(selectionOverlay)
    .onTapGesture { handlePrimaryAction() }
    .onLongPressGesture(minimumDuration: 0.5) { enterSelectionMode() }
    .onPlayPauseCommand {
      if selectionMode { handlePrimaryAction() } else { select(item) }
    }
    .contextMenu {
      Button(action: { showProperties(item) }) {
        Label(L("Properties"), systemImage: "info.circle")
      }
      //            Button(L("View Save States")) { showSaveStates(item) }

      // Cheats menu with tvOS 16 compatibility
      if #available(tvOS 17.0, iOS 14.0, *) {
        Menu {
          Button(action: { showCheatList(item) }) {
            Label(L("Manage..."), systemImage: "slider.horizontal.3")
          }
          Button(action: { downloadGeckoAction(item) }) {
            Label(L("Download Codes"), systemImage: "arrow.down.doc")
          }
          Divider()
          Menu {
            Button(action: { presentCheatGecko(item) }) {
              Label(L("Add..."), systemImage: "plus.circle")
            }
          } label: {
            Label(L("Gecko"), systemImage: "chevron.left.slash.chevron.right")
          }
          Menu {
            Button(action: { presentCheatAR(item) }) {
              Label(L("Add..."), systemImage: "plus.circle")
            }
          } label: {
            Label(L("Action Replay"), systemImage: "number")
          }
        } label: {
          Label(L("Cheats"), systemImage: "wand.and.stars")
        }
      } else {
        // Fallback for tvOS 16: Flatten menu structure
        Button(action: { showCheatList(item) }) {
          Label(L("Manage Cheats"), systemImage: "slider.horizontal.3")
        }
        Button(action: { downloadGeckoAction(item) }) {
          Label(L("Download Cheat Codes"), systemImage: "arrow.down.doc")
        }
        Button(action: { presentCheatGecko(item) }) {
          Label(L("Add Gecko Code"), systemImage: "chevron.left.slash.chevron.right")
        }
        Button(action: { presentCheatAR(item) }) {
          Label(L("Add Action Replay Code"), systemImage: "number")
        }
      }
      if isRemoteGame {
        if let source = getWebDAVSource() {
          if isCached {
            Button(action: { removeCachedFile() }) {
              Label(L("Remove from Cache"), systemImage: "trash")
            }
            Button(action: { showCacheInfo(item) }) {
              Label(L("Cache Info"), systemImage: "info.circle")
            }
          } else {
            Button(action: { startPreCache() }) {
              Label(L("Download to Cache"), systemImage: "arrow.down.circle")
            }
            .disabled(isPreCaching)

            if isPreCaching {
              Button(action: { cancelPreCache() }) {
                Label(L("Cancel Download"), systemImage: "xmark.circle")
              }
            }
          }
        } else {
          // Show cute dolphin error for unavailable source
          CompactDolphinError(message: L("Remote Source Unavailable"))
        }
      }
      if item.isFavorite {
        Button(action: { showFavoriteToggle(item) }) {
          Label(L("Unfavorite"), systemImage: "star.fill")
        }
      } else {
        Button(action: { showFavoriteToggle(item) }) {
          Label(L("Favorite"), systemImage: "star")
        }
      }
      Button(role: .destructive) { requestDelete(item) } label: { Label(L("Delete"), systemImage: "trash") }
    }
    .zIndex(isFocused ? 1 : 0)
    #else
    Button(action: { handlePrimaryAction() }) {
      VStack(alignment: .leading, spacing: 12) {
        ZStack(alignment: .topTrailing) {
          // Show templated cover if using placeholder, otherwise show real cover with skeumorphism
          if isUsingPlaceholderCover {
            templatedCoverView
          } else {
            ZStack {
              // Skeumorphic game case for real covers
              Image(uiImage: item.coverImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: LibraryLayout.cardSize.width, height: LibraryLayout.cardSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)
                .overlay(
                  // Subtle case reflection
                  LinearGradient(
                    colors: [Color.white.opacity(0.12), Color.clear, Color.black.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                  )
                  .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                )
                .overlay(
                  RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
                // Add subtle 3D perspective to real covers too
                .rotation3DEffect(
                  .degrees(0.8),
                  axis: (x: 0.05, y: 1.0, z: 0),
                  perspective: 1.5
                )
            }
          }

          if let icon = remoteIconName {
            ZStack {
              if isPreCaching {
                // Show progress indicator
                DolphinCircularSpinner(
                  size: 20,
                  lineWidth: 2,
                  dolphinSize: 7,
                  progress: preCacheProgress
                )
              } else {
                Image(systemName: icon)
                  .font(.system(size: 16, weight: .semibold))
                  .foregroundColor(.white)

                // Show checkmark if cached
                if isCached {
                  Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.green)
                    .background(Color.white, in: Circle())
                    .offset(x: 6, y: -6)
                }
              }
            }
            .padding(8)
            .background(.ultraThinMaterial, in: Circle())
            .padding(8)
          }
        }

        VStack(alignment: .leading, spacing: 6) {
          // Enhanced title with better typography
          Text(item.title)
            .font(enhancedHeadlineFont)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .foregroundStyle(
              LinearGradient(
                colors: [Color.primary, Color.primary.opacity(0.8)],
                startPoint: .top,
                endPoint: .bottom
              )
            )
            .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)

          // Game ID with enhanced styling
          if showSubtitles {
            Text(item.gameID)
              .font(enhancedCaptionFont)
              .foregroundStyle(
                LinearGradient(
                  colors: [Color.secondary, Color.secondary.opacity(0.8)],
                  startPoint: .top,
                  endPoint: .bottom
                )
              )
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(
                Capsule()
                  .fill(Color.primary.opacity(0.05))
                  .overlay(
                    Capsule()
                      .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                  )
              )
          }
        }
      }
      .frame(width: LibraryLayout.cardSize.width)
    }
    .buttonStyle(.plain)
    .scaleEffect(1.0)
    .overlay(selectionOverlay)
    .overlay(
      // Subtle iOS press highlight
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(Color.white.opacity(0.1))
        .opacity(0)
        .animation(.easeInOut(duration: 0.15), value: UUID())
    )
    // NOTE: no long-press gesture here. On iOS the long press belongs to
    // `.contextMenu` (UIKit's context-menu interaction cancels any competing
    // long-press recogniser at ~0.4s anyway, so a gesture here never fired).
    // Multi-select is entered from the "Select Games" item below, or from the
    // library's View Options menu.
    .contextMenu {
      // Align with tvOS context menu
      Button(action: { showProperties(item) }) {
        Label(L("Properties"), systemImage: "info.circle")
      }
      if !selectionMode {
        Button(action: { enterSelectionMode() }) {
          Label(L("Select Games"), systemImage: "checkmark.circle")
        }
      }
      //            Button(L("View Save States")) { showSaveStates(item) }

      // Cheats menu with tvOS 16 compatibility
      if #available(tvOS 17.0, iOS 14.0, *) {
        Menu {
          Button(action: { showCheatList(item) }) {
            Label(L("Manage..."), systemImage: "slider.horizontal.3")
          }
          Button(action: { downloadGeckoAction(item) }) {
            Label(L("Download Codes"), systemImage: "arrow.down.doc")
          }
          Divider()
          Menu {
            Button(action: { presentCheatGecko(item) }) {
              Label(L("Add..."), systemImage: "plus.circle")
            }
          } label: {
            Label(L("Gecko"), systemImage: "chevron.left.slash.chevron.right")
          }
          Menu {
            Button(action: { presentCheatAR(item) }) {
              Label(L("Add..."), systemImage: "plus.circle")
            }
          } label: {
            Label(L("Action Replay"), systemImage: "number")
          }
        } label: {
          Label(L("Cheats"), systemImage: "wand.and.stars")
        }
      } else {
        // Fallback for tvOS 16: Flatten menu structure
        Button(action: { showCheatList(item) }) {
          Label(L("Manage Cheats"), systemImage: "slider.horizontal.3")
        }
        Button(action: { downloadGeckoAction(item) }) {
          Label(L("Download Cheat Codes"), systemImage: "arrow.down.doc")
        }
        Button(action: { presentCheatGecko(item) }) {
          Label(L("Add Gecko Code"), systemImage: "chevron.left.slash.chevron.right")
        }
        Button(action: { presentCheatAR(item) }) {
          Label(L("Add Action Replay Code"), systemImage: "number")
        }
      }
      if isRemoteGame {
        if let _ = getWebDAVSource() {
          if isCached {
            Button(action: { removeCachedFile() }) {
              Label(L("Remove from Cache"), systemImage: "trash")
            }
            Button(action: { showCacheInfo(item) }) {
              Label(L("Cache Info"), systemImage: "info.circle")
            }
          } else {
            Button(action: { startPreCache() }) {
              Label(L("Download to Cache"), systemImage: "arrow.down.circle")
            }
            .disabled(isPreCaching)

            if isPreCaching {
              Button(action: { cancelPreCache() }) {
                Label(L("Cancel Download"), systemImage: "xmark.circle")
              }
            }
          }
        } else {
          // Show cute dolphin error for unavailable source
          CompactDolphinError(message: L("Remote Source Unavailable"))
        }
      }
      if item.isFavorite {
        Button(action: { showFavoriteToggle(item) }) {
          Label(L("Unfavorite"), systemImage: "star.fill")
        }
      } else {
        Button(action: { showFavoriteToggle(item) }) {
          Label(L("Favorite"), systemImage: "star")
        }
      }
      Button(role: .destructive) { requestDelete(item) } label: { Label(L("Delete"), systemImage: "trash") }
    }
    #endif
  }

  // MARK: - Pre-cache Methods

  private func startPreCache() {
    guard let source = getWebDAVSource(),
          let url = URL(string: item.filePath) else { return }

    isPreCaching = true
    preCacheProgress = 0.0
    showPreCacheProgress = true

    Task {
      do {
        // Use the file size from TVGameItem (which comes from WebDAV PROPFIND)
        let fileSize = Int64(item.fileSize)
        #if DEBUG
        print("Using cached file size for \(item.title): \(fileSize) bytes")
        print("DEBUG: TVGameItem.fileSize = \(item.fileSize)")
        #endif

        // Check if we have enough storage space (file size + 100MB buffer)
        if !TVLibraryView.hasEnoughSpaceForPreCache(fileSize: fileSize) {
          let availableSpace = TVLibraryView.getAvailableStorageSpace()
          let requiredSpace = fileSize + TVLibraryView.STORAGE_BUFFER_MB

          DispatchQueue.main.async {
            self.isPreCaching = false
            self.showPreCacheProgress = false
            let message = """
            Not enough storage space to download \(self.item.title).

            Available: \(TVLibraryView.formatStorageSpace(availableSpace))
            Required: \(TVLibraryView.formatStorageSpace(requiredSpace))

            Please free up some space and try again.
            """
            self.showStorageAlert(message)
          }
          return
        }

        // Create RemoteLibraryItem with correct size
        let remoteItem = RemoteLibraryItem(
          url: url,
          name: item.title,
          size: fileSize
        )

        _ = try await source.preCacheItem(remoteItem) { progress in
          DispatchQueue.main.async {
            self.preCacheProgress = progress
          }
        }

        DispatchQueue.main.async {
          self.isPreCaching = false
          self.showPreCacheProgress = false
          self.cacheStateVersion += 1 // Force UI update
          print("Pre-cache completed for: \(self.item.title)")
        }
      } catch {
        DispatchQueue.main.async {
          self.isPreCaching = false
          self.showPreCacheProgress = false
          self.cacheStateVersion += 1 // Force UI update even on error

          // Show user-friendly error message
          let message: String
          if let nsError = error as NSError?, nsError.domain == NSPOSIXErrorDomain, nsError.code == 28 {
            message = """
            Download failed: Not enough storage space.

            The device ran out of space while downloading \(self.item.title).
            Please free up some space and try again.
            """
          } else {
            message = """
            Download failed: \(error.localizedDescription)

            Unable to download \(self.item.title) to cache.
            """
          }
          self.showStorageAlert(message)
          print("Pre-cache failed for \(self.item.title): \(error)")
        }
      }
    }
  }

  private func cancelPreCache() {
    guard let source = getWebDAVSource(),
          let url = URL(string: item.filePath) else { return }

    let remoteItem = RemoteLibraryItem(
      url: url,
      name: item.title,
      size: 0
    )

    Task {
      await source.cancelPreCache(remoteItem)
      DispatchQueue.main.async {
        self.isPreCaching = false
        self.showPreCacheProgress = false
        self.cacheStateVersion += 1 // Force UI update
      }
    }
  }

  private func removeCachedFile() {
    guard let source = getWebDAVSource(),
          let url = URL(string: item.filePath) else { return }

    let remoteItem = RemoteLibraryItem(
      url: url,
      name: item.title,
      size: 0
    )

    Task {
      do {
        try await source.removeCachedItem(remoteItem)
        DispatchQueue.main.async {
          self.cacheStateVersion += 1 // Force UI update for cache state
        }
      } catch {
        print("Error: \(error.localizedDescription)")
      }
    }
  }

  private func presentCheatGecko(_ item: TVGameItem) {
    Task { @MainActor in
      showCheatList(item)
    }
  }

  private func presentCheatAR(_ item: TVGameItem) {
    Task { @MainActor in
      showCheatList(item)
    }
  }
}
