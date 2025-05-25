import Cocoa
import SpotifyWebAPI // Not directly used for API calls, but good for context
import CryptoKit

// MARK: - Data Models
struct PlaylistSummary {
    let id: String
    let name: String
}

struct CurrentlyPlayingTrack {
    let id: String // This is the track ID
    let name: String
    let artist: String
    let artworkURL: String?
    let uri: String
}

// NOTE: SpotifyTrack is now Codable to allow for local storage
struct SpotifyTrack: Codable, Equatable, Hashable {
    var id: String
    var title: String
    var artistName: String // Added for tooltip
    var isLiked: Bool
    var uri: String
    var artworkURL: String?

    // Equatable conformance
    static func == (lhs: SpotifyTrack, rhs: SpotifyTrack) -> Bool {
        return lhs.uri == rhs.uri
    }
    
    // Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(uri)
    }
}

// MARK: - Device Storage
struct SpotifyDeviceStore: Codable {
    var id: String
    var name: String

    static let fileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SpotifyMenubarApp", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        }
        return dir.appendingPathComponent("spotify_device.json")
    }()

    func save() {
        do {
            let data = try JSONEncoder().encode(self)
            try data.write(to: Self.fileURL, options: .atomicWrite)
            NSLog("💾 Device saved to \(Self.fileURL.path)")
        } catch {
            NSLog("❌ Failed to save device: \(error.localizedDescription)")
        }
    }

    static func load() -> SpotifyDeviceStore? {
        guard let data = try? Data(contentsOf: Self.fileURL) else {
            NSLog("ℹ️ No device file found at \(Self.fileURL.path)")
            return nil
        }
        do {
            let deviceStore = try JSONDecoder().decode(SpotifyDeviceStore.self, from: data)
            NSLog("✅ Device loaded from \(Self.fileURL.path)")
            return deviceStore
        } catch {
            NSLog("❌ Failed to decode device from file: \(error.localizedDescription). Deleting corrupt file.")
            delete()
            return nil
        }
    }

    static func delete() {
        do {
            try FileManager.default.removeItem(at: fileURL)
            NSLog("🗑 Device file deleted from \(Self.fileURL.path)")
        } catch {
            NSLog("❌ Failed to delete device file: \(error.localizedDescription)")
        }
    }
}


// MARK: - AppDelegate
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    
    enum PlaybackState: CustomStringConvertible {
        case loading
        case playing(track: CurrentlyPlayingTrack, isActuallyPlaying: Bool, isLiked: Bool, art: NSImage?)
        case notPlaying(message: String)
        case error(message: String)

        var description: String {
            switch self {
            case .loading: return "PlaybackState.loading"
            case .playing(let track, let isActuallyPlaying, let isLiked, _):
                return "PlaybackState.playing(track: \(track.name), isActuallyPlaying: \(isActuallyPlaying), isLiked: \(isLiked))"
            case .notPlaying(let message): return "PlaybackState.notPlaying(message: \"\(message)\")"
            case .error(let message): return "PlaybackState.error(message: \"\(message)\")"
            }
        }
    }

    var statusItem: NSStatusItem!
    var codeVerifier: String?
    var tokenStore: SpotifyTokenStore?
    var preferredDevice: SpotifyDeviceStore?
    
    var likeMenuItem: NSMenuItem?
    var authorizeMenuItem: NSMenuItem?
    var transferMenuItem: NSMenuItem?
    var addToPlaylistMenuItem: NSMenuItem?
    var playlistsSubmenu: NSMenu?
    
    var recentTracks: [SpotifyTrack] = []
    var lastNowPlayingImage: NSImage?
    private var internalCurrentPlaybackState: PlaybackState = .loading
    private var dataUpdateTimer: Timer?
    private var lastSeenTrackURI: String? // Used for local history tracking
    
    // Identifiers for dynamic menu items
    private let historyMenuItemIdentifier = NSUserInterfaceItemIdentifier("historyMenuItem")
    private let historySeparatorIdentifier = NSUserInterfaceItemIdentifier("historySeparator")


    // MARK: - Lifecycle & Setup
    override init() {
        super.init()
        NSLog("🛠 AppDelegate initialized")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("🚀 AppDelegate launched")
        NSApp.setActivationPolicy(.accessory)
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setupMenu()
        
        // Load locally stored data on launch
        loadRecentTracks()
        updateHistoryMenu(excluding: nil)
        
        if let storedDevice = SpotifyDeviceStore.load() {
            self.preferredDevice = storedDevice
            NSLog("🔊 Loaded preferred device: \(storedDevice.name)")
        }
        
        updateUI(for: .loading)

        if let storedToken = SpotifyTokenStore.load() {
            self.tokenStore = storedToken
            if storedToken.isExpired {
                NSLog("🔑 Token expired, attempting refresh on launch.")
                refreshAccessToken()
            } else {
                self.authorizeMenuItem?.isHidden = true
                NSLog("✅ Loaded valid access token from disk.")
                updateAllData()
            }
        } else {
            NSLog("ℹ️ No token found on disk.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if self.tokenStore == nil {
                     self.updateUI(for: .notPlaying(message: "Please click to authorize"))
                }
            }
            self.authorizeMenuItem?.isHidden = false
        }

        dataUpdateTimer = Timer.scheduledTimer(timeInterval: 5, target: self, selector: #selector(updateAllData), userInfo: nil, repeats: true)
    }

    func setupMenu() {
        let menu = NSMenu()
        
        authorizeMenuItem = NSMenuItem(title: "Authorize Spotify", action: #selector(authorizeSpotify), keyEquivalent: "")
        menu.addItem(authorizeMenuItem!)
        
        menu.addItem(NSMenuItem(title: "Reset Authorization", action: #selector(resetAuthorization), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        
        likeMenuItem = NSMenuItem(title: "♥ Like Song", action: #selector(toggleLikeStatus), keyEquivalent: "")
        menu.addItem(likeMenuItem!)

        addToPlaylistMenuItem = NSMenuItem(title: "Add song to playlist...", action: nil, keyEquivalent: "")
        playlistsSubmenu = NSMenu()
        addToPlaylistMenuItem!.submenu = playlistsSubmenu
        playlistsSubmenu!.delegate = self
        menu.addItem(addToPlaylistMenuItem!)
        
        // Transfer Playback item is added here. "Recently Played" will be inserted before it by updateHistoryMenu.
        transferMenuItem = NSMenuItem(title: "Transfer Playback...", action: #selector(promptForDeviceTransfer), keyEquivalent: "")
        menu.addItem(transferMenuItem!)
        
        menu.addItem(NSMenuItem.separator()) // This separator is before Quit
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem.menu = menu
        
        updateHistoryMenu(excluding: nil)
    }
    
    func updateHistoryMenu(excluding currentTrackURI: String?) {
        guard let menu = statusItem.menu else { return }

        // Remove existing history menu item if it exists
        if let existingItemIndex = menu.items.firstIndex(where: { $0.identifier == historyMenuItemIdentifier }) {
            menu.removeItem(at: existingItemIndex)
        }
        // Remove the old dedicated separator for history if it exists
        if let existingSeparatorIndex = menu.items.firstIndex(where: { $0.identifier == historySeparatorIdentifier }) {
            menu.removeItem(at: existingSeparatorIndex)
        }


        let tracksToShow = recentTracks.filter { $0.uri != currentTrackURI }

        guard !tracksToShow.isEmpty else { return } // Don't add the menu if no tracks to show

        let historyMenuItem = NSMenuItem()
        historyMenuItem.identifier = historyMenuItemIdentifier // Assign identifier
        historyMenuItem.title = "Recently Played..."

        let historySubmenu = NSMenu()

        for track in tracksToShow {
            let item = NSMenuItem()
            item.representedObject = track

            let maxTitleLength = 30
            var displayTitle = track.title
            if displayTitle.count > maxTitleLength {
                let index = displayTitle.index(displayTitle.startIndex, offsetBy: maxTitleLength - 3)
                displayTitle = String(displayTitle[..<index]) + "..."
            }
            
            let attributedTitle = NSMutableAttributedString(string: " " + displayTitle)
            if track.isLiked {
                attributedTitle.append(NSAttributedString(string: " ⭐"))
            }
            item.attributedTitle = attributedTitle
            item.toolTip = "\(track.title) - \(track.artistName)"
            item.target = self
            item.action = #selector(playTrackFromHistory(_:))
            
            if let artworkURLString = track.artworkURL {
                loadAlbumArt(from: artworkURLString) { image in
                    guard let image = image else { return }
                    
                    let attachment = NSTextAttachment()
                    attachment.image = image
                    attachment.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)
                    
                    let newAttributedTitleWithArt = NSMutableAttributedString()
                    newAttributedTitleWithArt.append(NSAttributedString(attachment: attachment))
                    newAttributedTitleWithArt.append(NSAttributedString(string: " " + displayTitle))
                    if track.isLiked {
                        newAttributedTitleWithArt.append(NSAttributedString(string: " ⭐"))
                    }
                    item.attributedTitle = newAttributedTitleWithArt
                }
            }
            
            historySubmenu.addItem(item)
        }

        historyMenuItem.submenu = historySubmenu
        
        // Insert "Recently Played..." before "Transfer Playback..."
        if let transferItemIndex = menu.items.firstIndex(where: { $0 == transferMenuItem }) {
            menu.insertItem(historyMenuItem, at: transferItemIndex)
        } else {
            // Fallback: if transferMenuItem is somehow not found, add before the last separator (before Quit)
            if let lastSeparatorIndex = menu.items.lastIndex(where: { $0.isSeparatorItem }) {
                menu.insertItem(historyMenuItem, at: lastSeparatorIndex)
            } else {
                menu.addItem(historyMenuItem) // Absolute fallback
            }
        }
    }

    func playTrackFromURI(_ uri: String) {
        guard let accessToken = tokenStore?.accessToken else {
            NSLog("❌ Missing access token")
            return
        }

        var urlComponents = URLComponents(string: "https://api.spotify.com/v1/me/player/play")!

        if let deviceId = preferredDevice?.id {
            urlComponents.queryItems = [URLQueryItem(name: "device_id", value: deviceId)]
        }

        guard let url = urlComponents.url else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["uris": [uri]]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            NSLog("❌ Failed to encode play body: \(error)")
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                NSLog("❌ Error starting playback: \(error.localizedDescription)")
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                NSLog("❌ Invalid response from server.")
                return
            }

            if (200...299).contains(httpResponse.statusCode) {
                NSLog("✅ Playback request successful with status: \(httpResponse.statusCode)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.updateAllData()
                }
            } else {
                NSLog("❌ Playback request failed with status: \(httpResponse.statusCode)")
                if let responseData = data,
                   let errorBody = String(data: responseData, encoding: .utf8) {
                    NSLog("❌ Spotify Error Body: \(errorBody)")
                }
            }
        }.resume()
    }

    @objc func playTrackFromHistory(_ sender: NSMenuItem) {
        guard let track = sender.representedObject as? SpotifyTrack else { return }
        playTrackFromURI(track.uri)
    }

    // MARK: - Central UI Update Function
    func updateUI(for state: PlaybackState) {
        DispatchQueue.main.async {
            self.internalCurrentPlaybackState = state
            var currentTrackURI: String? = nil
            
            switch state {
            case .loading:
                if self.lastNowPlayingImage != nil {
                     self.statusItem.button?.image = self.lastNowPlayingImage
                } else {
                    self.statusItem.button?.title = "Loading..."
                    self.statusItem.button?.image = nil
                }
                break

            case .notPlaying(let message):
                self.statusItem.button?.title = "\(message)"
                self.statusItem.button?.image = nil
                self.likeMenuItem?.isHidden = true
                self.addToPlaylistMenuItem?.isHidden = true
                self.transferMenuItem?.isHidden = self.preferredDevice == nil
                self.likeMenuItem?.title = "♡ Like Song"

            case .error(let message):
                self.statusItem.button?.title = "⚠️ \(message)"
                self.statusItem.button?.image = nil
                self.likeMenuItem?.isHidden = true
                self.addToPlaylistMenuItem?.isHidden = true
                self.transferMenuItem?.isHidden = true
                self.likeMenuItem?.title = "♡ Like Song"

            case .playing(let track, let isActuallyPlaying, let isLiked, let art):
                currentTrackURI = track.uri
                self.likeMenuItem?.isHidden = false
                self.addToPlaylistMenuItem?.isHidden = false
                self.transferMenuItem?.isHidden = false
                
                self.likeMenuItem?.isEnabled = true
                self.addToPlaylistMenuItem?.isEnabled = true
                self.transferMenuItem?.isEnabled = true
                self.likeMenuItem?.title = isLiked ? "♥ Unlike Song" : "♡ Like Song"
                
                let playStatusIndicator = isActuallyPlaying ? "" : "⏸ "
                let trackText = "\(playStatusIndicator)\(track.name) – \(track.artist)"
                let starText = isLiked ? " ⭐" : ""
                let font = NSFont.menuBarFont(ofSize: 0)
                let textColor = NSColor.headerTextColor
                let textAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
                let trackTextAttributedString = NSAttributedString(string: trackText, attributes: textAttributes)
                let starTextAttributedString = NSAttributedString(string: starText, attributes: textAttributes)
                
                let iconWidth: CGFloat = 16.0
                let artWidth: CGFloat = art != nil ? 16.0 : 0.0
                let spacing: CGFloat = 4.0
                
                let trackTextSize = trackTextAttributedString.size()
                let starTextSize = starTextAttributedString.size()
                
                var totalWidth = iconWidth + spacing + trackTextSize.width
                if art != nil { totalWidth += spacing + artWidth }
                if isLiked { totalWidth += (art == nil && trackTextSize.width > 0 ? spacing : 0) + starTextSize.width }

                let finalImage = NSImage(size: NSSize(width: totalWidth, height: 18))
                finalImage.lockFocus()

                var currentX: CGFloat = 0
                if let appIcon = NSImage(named: "AppIcon") {
                    appIcon.draw(in: NSRect(x: currentX, y: (finalImage.size.height - 16) / 2, width: 16, height: 16))
                }
                currentX += iconWidth + spacing
                
                let textY = (finalImage.size.height - trackTextSize.height) / 2
                trackTextAttributedString.draw(at: NSPoint(x: currentX, y: textY))
                currentX += trackTextSize.width

                if let albumArt = art {
                    currentX += spacing
                    albumArt.draw(in: NSRect(x: currentX, y: (finalImage.size.height - 16) / 2, width: 16, height: 16))
                    currentX += artWidth
                }

                if isLiked {
                    if art == nil && trackTextSize.width > 0 { currentX += spacing }
                    starTextAttributedString.draw(at: NSPoint(x: currentX, y: (finalImage.size.height - starTextSize.height) / 2))
                }
                finalImage.unlockFocus()
                                
                self.statusItem.button?.image = finalImage
                self.statusItem.button?.title = ""
                self.lastNowPlayingImage = finalImage
            }
            
            self.updateHistoryMenu(excluding: currentTrackURI)
        }
    }
    
    // MARK: - Data Fetching & State Determination
    @objc func updateAllData() {
        fetchCurrentTrackDetails()
        fetchRecentlyPlayed()
    }
    
    func fetchCurrentTrackDetails() {
        guard let token = tokenStore, !token.isExpired else {
            if tokenStore?.isExpired ?? false {
                refreshAccessToken()
            } else if tokenStore == nil {
                updateUI(for: .notPlaying(message: "Please click to authorize"))
            }
            return
        }

        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/currently-playing")!)
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                NSLog("❌ Playback info error: \(error.localizedDescription)")
                self.updateUI(for: .error(message: "Network Error"))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                self.updateUI(for: .error(message: "Server Error"))
                return
            }

            if httpResponse.statusCode == 401 {
                self.refreshAccessToken()
                return
            }
            
            if httpResponse.statusCode == 204 || data == nil {
                self.updateUI(for: .notPlaying(message: "Nothing Playing"))
                return
            }
            
            guard let data = data else { return }
            
            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let item = json["item"] as? [String: Any] else {
                    self.updateUI(for: .notPlaying(message: "Nothing Playing"))
                    return
                }
                
                let isActuallyPlaying = json["is_playing"] as? Bool ?? false

                guard let id = item["id"] as? String,
                      let name = item["name"] as? String,
                      let uri = item["uri"] as? String,
                      let artistsArray = item["artists"] as? [[String: Any]] else {
                    self.updateUI(for: .notPlaying(message: "Track Info Error"))
                    return
                }
                
                let artistNames = artistsArray.compactMap { $0["name"] as? String }.joined(separator: ", ")
                let albumData = item["album"] as? [String: Any]
                let imagesData = albumData?["images"] as? [[String: Any]]
                let artworkURL = imagesData?.first?["url"] as? String
                
                let track = CurrentlyPlayingTrack(id: id, name: name, artist: artistNames, artworkURL: artworkURL, uri: uri)
                
                let newSpotifyTrack = SpotifyTrack(
                    id: track.id,
                    title: track.name,
                    artistName: track.artist,
                    isLiked: false, // Placeholder, will be updated below
                    uri: track.uri,
                    artworkURL: track.artworkURL
                )
                
                let group = DispatchGroup()
                var isLiked: Bool = false
                var albumArtImage: NSImage? = nil
                
                group.enter()
                self.checkIfTrackIsLiked(trackId: track.id, accessToken: token.accessToken) { liked in
                    isLiked = liked
                    group.leave()
                }
                
                if let artURL = track.artworkURL {
                    group.enter()
                    self.loadAlbumArt(from: artURL) { image in
                        albumArtImage = image
                        group.leave()
                    }
                }
                
                group.notify(queue: .main) {
                    
                    // --- FIX IS HERE ---
                    // We no longer use 'if let' because track.uri is not optional.
                    let newTrackURI = track.uri
                    if newTrackURI != self.lastSeenTrackURI {
                    // --- END FIX ---
                    
                        NSLog("🎶 New track detected: \(track.name). Adding to local history.")

                        var trackToAdd = newSpotifyTrack
                        trackToAdd.isLiked = isLiked // Assign the correct liked status

                        self.recentTracks.removeAll { $0.uri == trackToAdd.uri }
                        self.recentTracks.insert(trackToAdd, at: 0)
                        if self.recentTracks.count > 20 {
                            self.recentTracks = Array(self.recentTracks.prefix(20))
                        }

                        self.saveRecentTracks()
                        self.lastSeenTrackURI = newTrackURI
                        
                    } else if let index = self.recentTracks.firstIndex(where: { $0.id == track.id }) {
                        self.recentTracks[index].isLiked = isLiked
                    }
                    
                    self.updateUI(for: .playing(track: track, isActuallyPlaying: isActuallyPlaying, isLiked: isLiked, art: albumArtImage))
                }
                
            } catch {
                NSLog("❌ Error parsing playback JSON: \(error.localizedDescription)")
                self.updateUI(for: .error(message: "Parse Error"))
            }
        }.resume()
    }
    func fetchRecentlyPlayed() {
        guard let token = tokenStore, !token.isExpired else { return }

        guard var urlComponents = URLComponents(string: "https://api.spotify.com/v1/me/player/recently-played") else {
             NSLog("❌ [fetchRecentlyPlayed] Invalid URL components for recently played tracks.")
             return
        }
        urlComponents.queryItems = [URLQueryItem(name: "limit", value: "20")]

        guard let url = urlComponents.url else {
             NSLog("❌ [fetchRecentlyPlayed] Could not construct URL with limit for recently played tracks.")
             return
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData // Good practice to keep this
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")


        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                NSLog("❌ [fetchRecentlyPlayed] Network Error: \(error.localizedDescription)")
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                NSLog("❌ [fetchRecentlyPlayed] HTTP Error: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return
            }
            
            guard let data = data else {
                NSLog("❌ [fetchRecentlyPlayed] No data received.")
                return
            }
            
            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let items = json["items"] as? [[String: Any]] else {
                    NSLog("❌ [fetchRecentlyPlayed] Could not parse recently played items.")
                    return
                }
                
                var parsedTracks: [SpotifyTrack] = []
                for item in items {
                    guard let trackData = item["track"] as? [String: Any],
                          let name = trackData["name"] as? String,
                          let uri = trackData["uri"] as? String,
                          let trackIdFromApi = trackData["id"] as? String else {
                        continue
                    }
                    
                    let artistsArray = trackData["artists"] as? [[String: Any]]
                    let artistName = artistsArray?.compactMap({ $0["name"] as? String }).joined(separator: ", ") ?? "Unknown Artist"

                    let albumData = trackData["album"] as? [String: Any]
                    let imagesData = albumData?["images"] as? [[String: Any]]
                    let artworkURL = imagesData?.first?["url"] as? String
                    
                    parsedTracks.append(SpotifyTrack(id: trackIdFromApi, title: name, artistName: artistName, isLiked: false, uri: uri, artworkURL: artworkURL))
                }
                
                // --- MERGE LOGIC ---
                // Start with our local tracks, which are the most up-to-date for this session.
                var mergedTracks = self.recentTracks
                let localURIs = Set(self.recentTracks.map { $0.uri })

                // Add tracks from the API that we don't already have in our local list.
                for apiTrack in parsedTracks {
                    if !localURIs.contains(apiTrack.uri) {
                        mergedTracks.append(apiTrack)
                    }
                }
                
                // Ensure the final list is unique and limited.
                var uniqueMergedTracks: [SpotifyTrack] = []
                var seenURIs = Set<String>()
                for track in mergedTracks {
                    if !seenURIs.contains(track.uri) {
                        uniqueMergedTracks.append(track)
                        seenURIs.insert(track.uri)
                    }
                }
                // We'll operate on the top 10 for the menu display.
                var top10Tracks = Array(uniqueMergedTracks.prefix(10))

                let group = DispatchGroup()
                for i in 0..<top10Tracks.count {
                    group.enter()
                    self.checkIfTrackIsLiked(trackId: top10Tracks[i].id, accessToken: token.accessToken) { isLikedStatus in
                        if i < top10Tracks.count {
                            top10Tracks[i].isLiked = isLikedStatus
                        }
                        group.leave()
                    }
                }

                group.notify(queue: .main) {
                    // Update our main list with the merged and checked list.
                    self.recentTracks = top10Tracks
                    self.saveRecentTracks() // Save the newly merged list.
                    
                    var currentPlayingURI: String? = nil
                    if case .playing(let currentTrack, _, _, _) = self.internalCurrentPlaybackState {
                        currentPlayingURI = currentTrack.uri
                    }
                    self.updateHistoryMenu(excluding: currentPlayingURI)
                }
                
            } catch let serializationError {
                NSLog("❌ [fetchRecentlyPlayed] JSONSerialization error: \(serializationError)")
            }
        }.resume()
    }

    // MARK: - Local Track Storage
    
    func getRecentTracksFileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SpotifyMenubarApp", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        }
        return dir.appendingPathComponent("spotify_recent_tracks.json")
    }

    func saveRecentTracks() {
        let fileURL = getRecentTracksFileURL()
        do {
            // Limit to saving the most recent 20 tracks to keep the file size reasonable
            let tracksToSave = Array(self.recentTracks.prefix(20))
            let data = try JSONEncoder().encode(tracksToSave)
            try data.write(to: fileURL, options: .atomicWrite)
            NSLog("💾 Recent tracks saved to \(fileURL.path)")
        } catch {
            NSLog("❌ Failed to save recent tracks: \(error.localizedDescription)")
        }
    }

    func loadRecentTracks() {
        let fileURL = getRecentTracksFileURL()
        guard let data = try? Data(contentsOf: fileURL) else {
            NSLog("ℹ️ No recent tracks file found at \(fileURL.path)")
            return
        }
        do {
            self.recentTracks = try JSONDecoder().decode([SpotifyTrack].self, from: data)
            NSLog("✅ Recent tracks loaded from \(fileURL.path)")
        } catch {
            NSLog("❌ Failed to decode recent tracks from file: \(error.localizedDescription).")
        }
    }


    // MARK: - Auth Logic
    @objc func authorizeSpotify() {
        let clientId = "c62a858a7ec0468194da1c197d3c4d3d"
        let redirectURI = "spotify-menubar-app://callback"
        let scope = "user-read-playback-state user-read-currently-playing user-library-read user-library-modify playlist-read-private playlist-read-collaborative playlist-modify-public playlist-modify-private user-modify-playback-state user-read-recently-played"

        // Generate and store the verifier
        self.codeVerifier = PKCE.generateCodeVerifier()

        // Use a guard to safely unwrap the verifier and generate the challenge
        guard let verifier = self.codeVerifier,
              let challenge = PKCE.codeChallenge(for: verifier) else {
            NSLog("❌ Failed to generate PKCE code challenge.")
            return
        }

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: UUID().uuidString)
        ]
        guard let url = components.url else {
            NSLog("❌ Failed to build Spotify authorization URL.")
            return
        }
        NSWorkspace.shared.open(url)
        NSLog("🔑 Opened Spotify authorization URL in browser.")
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            NSLog("❌ No authorization code found in URL: \(urls.first?.absoluteString ?? "nil")")
            return
        }
        NSLog("✅ Received authorization code: \(code)")
        exchangeCodeForToken(code: code)
    }

    func exchangeCodeForToken(code: String) {
        let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let clientId = "c62a858a7ec0468194da1c197d3c4d3d"
        let redirectURI = "spotify-menubar-app://callback"
        
        // This should now work correctly.
        guard let verifier = self.codeVerifier else {
            NSLog("❌ Code verifier missing for token exchange.")
            return
        }

        let params = [
            "client_id": clientId, "grant_type": "authorization_code", "code": code,
            "redirect_uri": redirectURI, "code_verifier": verifier
        ]
        request.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }.joined(separator: "&").data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil else {
                NSLog("❌ Token exchange error: \(error?.localizedDescription ?? "Unknown error")")
                self.updateUI(for: .error(message: "Auth Failed"))
                return
            }
            
            do {
                var tokenDataFromJSON = try JSONDecoder().decode(SpotifyTokenStore.self, from: data)
                tokenDataFromJSON.expirationDate = Date().addingTimeInterval(tokenDataFromJSON.expiresIn)
                tokenDataFromJSON.save()
                self.tokenStore = tokenDataFromJSON
                NSLog("✅ Token exchanged and saved successfully.")
                DispatchQueue.main.async {
                    self.authorizeMenuItem?.isHidden = true
                    self.updateAllData()
                }
            } catch {
                NSLog("❌ Failed to decode token response: \(error.localizedDescription). Response: \(String(data: data, encoding: .utf8) ?? "Non-UTF8 data")")
                self.updateUI(for: .error(message: "Auth Failed"))
            }
        }.resume()
    }
    func refreshAccessToken() {
        guard let currentTokenStore = tokenStore, let refreshToken = currentTokenStore.refreshToken else {
            NSLog("❌ No refresh token available. User needs to re-authorize.")
            handleTokenRefreshFailure(isAuthError: true)
            return
        }
        
        NSLog("⏳ Attempting to refresh access token...")
        
        let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        
        let clientId = "c62a858a7ec0468194da1c197d3c4d3d"
        let params = ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientId]
        request.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }.joined(separator: "&").data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil else {
                NSLog("❌ Token refresh network error: \(error?.localizedDescription ?? "Unknown error")")
                self.handleTokenRefreshFailure()
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 400 {
                 NSLog("❌ Token refresh failed (400 Bad Request - often invalid refresh token). User needs to re-authorize.")
                 self.handleTokenRefreshFailure(isAuthError: true)
                 return
            }

            do {
                var refreshedTokenData = try JSONDecoder().decode(SpotifyTokenStore.self, from: data)
                refreshedTokenData.expirationDate = Date().addingTimeInterval(refreshedTokenData.expiresIn)
                if refreshedTokenData.refreshToken == nil {
                    refreshedTokenData.refreshToken = refreshToken
                }
                self.tokenStore = refreshedTokenData
                self.tokenStore?.save()
                NSLog("🔄 Token refreshed and saved successfully.")
                DispatchQueue.main.async {
                    self.authorizeMenuItem?.isHidden = true
                    self.updateAllData()
                }
            } catch {
                NSLog("❌ Failed to decode refreshed token: \(error.localizedDescription). Response: \(String(data: data, encoding: .utf8) ?? "Non-UTF8 data")")
                self.handleTokenRefreshFailure()
            }
        }.resume()
    }
    
    func handleTokenRefreshFailure(isAuthError: Bool = false) {
        if isAuthError {
            SpotifyTokenStore.delete()
            self.tokenStore = nil
            DispatchQueue.main.async {
                self.authorizeMenuItem?.isHidden = false
                self.updateUI(for: .notPlaying(message: "Please click to authorize"))
            }
            NSLog("🔑 Token refresh failed due to auth error. User needs to re-authorize.")
        } else {
            DispatchQueue.main.async {
                self.updateUI(for: .error(message: "Auth Refresh Failed"))
            }
            NSLog("🔑 Token refresh failed (e.g. network issue).")
        }
    }
    
    @objc func resetAuthorization() {
        SpotifyTokenStore.delete()
        SpotifyDeviceStore.delete()
        // Delete the new recent tracks file
        try? FileManager.default.removeItem(at: getRecentTracksFileURL())
        
        self.tokenStore = nil
        self.preferredDevice = nil
        self.recentTracks = []
        self.codeVerifier = nil
        DispatchQueue.main.async {
            self.authorizeMenuItem?.isHidden = false
            self.updateUI(for: .notPlaying(message: "Please click to authorize"))
            self.updateHistoryMenu(excluding: nil)
        }
        NSLog("🗑 Authorization, device, and local history reset by user.")
    }

    @objc func quitApp() { NSApp.terminate(nil) }

    // MARK: - Track Actions (Like, Playlist)
    func loadAlbumArt(from urlString: String, completion: @escaping (NSImage?) -> Void) {
        guard let url = URL(string: urlString) else { completion(nil); return }
        URLSession.shared.dataTask(with: url) { data, _, error in
            guard let data = data, let image = NSImage(data: data), error == nil else {
                NSLog("🎨 Error downloading or creating image from album art URL: \(urlString). Error: \(error?.localizedDescription ?? "Unknown")")
                completion(nil)
                return
            }
            let targetSize = NSSize(width: 16, height: 16)
            let resizedImage = NSImage(size: targetSize)
            resizedImage.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: targetSize),
                       from: .zero,
                       operation: .sourceOver,
                       fraction: 1.0)
            resizedImage.unlockFocus()
            DispatchQueue.main.async {
                completion(resizedImage)
            }
        }.resume()
    }

    // Expects just the track ID, not the full URI
    func checkIfTrackIsLiked(trackId: String, accessToken: String, completion: @escaping (Bool) -> Void) {
        guard !trackId.isEmpty else {
            NSLog("⚠️ Attempted to check liked status for an empty track ID.")
            completion(false)
            return
        }

        guard var urlComponents = URLComponents(string: "https://api.spotify.com/v1/me/tracks/contains?ids=\(trackId)") else {
            completion(false); return
        }
        urlComponents.queryItems = [URLQueryItem(name: "ids", value: trackId)]
        
        guard let url = urlComponents.url else { completion(false); return }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                NSLog("❌ Failed to check liked status for track ID \(trackId): \(error.localizedDescription)")
                completion(false); return
            }
            guard let data = data,
                  let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                NSLog("❌ Invalid response or non-200 status when checking liked status for track ID \(trackId).")
                completion(false); return
            }
            
            guard let result = try? JSONSerialization.jsonObject(with: data) as? [Bool],
                  let isLiked = result.first else {
                NSLog("❌ Could not parse liked status JSON for track ID \(trackId).")
                completion(false); return
            }
            completion(isLiked)
        }.resume()
    }

    @objc func toggleLikeStatus() {
        guard let currentToken = tokenStore, !currentToken.isExpired else {
            self.updateAllData()
            return
        }
        
        guard case .playing(let track, _, _, _) = self.internalCurrentPlaybackState else {
            return
        }

        let trackID = track.id
        checkIfTrackIsLiked(trackId: trackID, accessToken: currentToken.accessToken) { isCurrentlyLiked in
            let method = isCurrentlyLiked ? "DELETE" : "PUT"
            var likeRequest = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/tracks?ids=\(trackID)")!)
            
            likeRequest.httpMethod = method
            likeRequest.setValue("Bearer \(currentToken.accessToken)", forHTTPHeaderField: "Authorization")
            likeRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let bodyParams = ["ids": [trackID]]
            likeRequest.httpBody = try? JSONSerialization.data(withJSONObject: bodyParams)
            
            URLSession.shared.dataTask(with: likeRequest) { _, response, error in
                if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) {
                    NSLog("✅ Like status toggled successfully for track \(trackID).")
                } else {
                    NSLog("❌ Failed to toggle like status for track \(trackID). Code: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.updateAllData()
                }
            }.resume()
        }
    }
    
    func getCurrentPlaybackStateForAction() -> PlaybackState {
        return self.internalCurrentPlaybackState
    }

    // MARK: - Playlist Management
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu == self.playlistsSubmenu {
            NSLog("🔎 Playlists submenu needs update. Fetching playlists...")
            menu.removeAllItems()
            let loadingItem = NSMenuItem(title: "Loading playlists...", action: nil, keyEquivalent: "")
            loadingItem.isEnabled = false
            menu.addItem(loadingItem)
            fetchUserPlaylists()
        }
    }

    func fetchUserPlaylists() {
        guard let token = tokenStore, !token.isExpired else {
            updatePlaylistsSubmenu(with: .failure(NSError(domain: "SpotifyApp", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not authorized"])))
            return
        }

        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/playlists?limit=50")!)
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                self.updatePlaylistsSubmenu(with: .failure(error))
                return
            }
            guard let data = data,
                  let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let fetchError = NSError(domain: "SpotifyApp", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch playlists."])
                self.updatePlaylistsSubmenu(with: .failure(fetchError))
                return
            }

            do {
                if let jsonResponse = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let items = jsonResponse["items"] as? [[String: Any]] {
                    let playlists: [PlaylistSummary] = items.compactMap { dict in
                        guard let id = dict["id"] as? String, let name = dict["name"] as? String else { return nil }
                        return PlaylistSummary(id: id, name: name)
                    }
                    self.updatePlaylistsSubmenu(with: .success(playlists))
                } else {
                    let parseError = NSError(domain: "SpotifyApp", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not parse playlists."])
                    self.updatePlaylistsSubmenu(with: .failure(parseError))
                }
            } catch {
                self.updatePlaylistsSubmenu(with: .failure(error))
            }
        }.resume()
    }

    func updatePlaylistsSubmenu(with result: Result<[PlaylistSummary], Error>) {
        DispatchQueue.main.async {
            guard let menu = self.playlistsSubmenu else { return }
            menu.removeAllItems()

            switch result {
            case .success(let playlists):
                if playlists.isEmpty {
                    menu.addItem(NSMenuItem(title: "No playlists found", action: nil, keyEquivalent: ""))
                } else {
                    playlists.forEach { playlist in
                        let item = NSMenuItem(title: playlist.name, action: #selector(self.addCurrentSongToSelectedPlaylist(_:)), keyEquivalent: "")
                        item.representedObject = playlist.id
                        item.target = self
                        menu.addItem(item)
                    }
                }
            case .failure(let error):
                let errorItem = NSMenuItem(title: "Error loading playlists", action: nil, keyEquivalent: "")
                errorItem.toolTip = error.localizedDescription
                menu.addItem(errorItem)
            }
        }
    }
    
    @objc func addCurrentSongToSelectedPlaylist(_ sender: NSMenuItem) {
        guard let playlistId = sender.representedObject as? String else {
            showErrorAlert(title: "Error", message: "Could not identify the selected playlist.")
            return
        }
        guard let token = tokenStore, !token.isExpired else {
            showErrorAlert(title: "Authorization Error", message: "Please authorize the app first.")
            return
        }
        
        guard case .playing(let track, _, _, _) = self.internalCurrentPlaybackState else {
            showErrorAlert(title: "Error Adding Song", message: "No song is currently playing or paused.")
            return
        }
        let trackURI = track.uri
        
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/playlists/\(playlistId)/tracks")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["uris": [trackURI]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 201 {
                    self.showSuccessAlert(title: "Song Added", message: "Successfully added '\(track.name)' to playlist '\(sender.title)'.")
                } else {
                    self.showErrorAlert(title: "Error Adding Song", message: "Failed to add song.")
                }
            }
        }.resume()
    }
    
    // MARK: - Device Transfer
    @objc func promptForDeviceTransfer() {
        guard let token = tokenStore, !token.isExpired else {
            showErrorAlert(title: "Authorization Error", message: "Please authorize the app first.")
            return
        }

        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/devices")!)
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                guard let data = data,
                      let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let devices = json["devices"] as? [[String: Any]] else {
                    self.showErrorAlert(title: "Device Error", message: "Could not parse device list.")
                    return
                }

                if devices.isEmpty {
                    self.showErrorAlert(title: "No Devices", message: "No active Spotify devices found.")
                    return
                }

                let alert = NSAlert()
                alert.messageText = "Select a Device"
                alert.informativeText = "Choose a device to transfer playback to:"
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Cancel")

                let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 250, height: 24), pullsDown: false)
                devices.forEach { deviceData in
                    if let name = deviceData["name"] as? String, let id = deviceData["id"] as? String {
                        popup.addItem(withTitle: name)
                        popup.lastItem?.representedObject = id
                    }
                }
                alert.accessoryView = popup

                if alert.runModal() == .alertFirstButtonReturn {
                    if let selectedItem = popup.selectedItem, let deviceId = selectedItem.representedObject as? String {
                        self.transferPlaybackToSelectedDevice(deviceId: deviceId, deviceName: selectedItem.title, play: true)
                    }
                }
            }
        }.resume()
    }

    func transferPlaybackToSelectedDevice(deviceId: String, deviceName: String, play: Bool) {
        guard let token = tokenStore, !token.isExpired else {
            showErrorAlert(title: "Authorization Error", message: "Please authorize the app first.")
            return
        }

        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player")!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["device_ids": [deviceId], "play": play]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 204 {
                    NSLog("✅ Playback transferred successfully to \(deviceName).")
                    self.showSuccessAlert(title: "Playback Transferred", message: "Playback transferred to \(deviceName).")
                    
                    let deviceToSave = SpotifyDeviceStore(id: deviceId, name: deviceName)
                    deviceToSave.save()
                    self.preferredDevice = deviceToSave
                    
                    self.updateAllData()
                } else {
                    self.showErrorAlert(title: "Transfer Failed", message: "Could not transfer playback.")
                }
            }
        }.resume()
    }
    
    // MARK: - Alert Helpers
    func showErrorAlert(title: String, message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    func showSuccessAlert(title: String, message: String) {
         DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
    
    // MARK: - App Behavior
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        return false
    }
}

// MARK: - PKCE (Proof Key for Code Exchange) Helper
struct PKCE {
    static func generateCodeVerifier() -> String? {
        var buffer = [UInt8](repeating: 0, count: 32)
        // Ensure the random bytes generation was successful
        guard SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer) == errSecSuccess else {
            return nil
        }
        return Data(buffer).base64URLEncodedString()
    }

    static func codeChallenge(for verifier: String) -> String? {
        guard let data = verifier.data(using: .utf8) else { return nil }
        let hashed = SHA256.hash(data: data)
        return Data(hashed).base64URLEncodedString()
    }
}
// Custom extension for base64URL encoding (RFC 4648)
extension Data {
    func base64URLEncodedString() -> String {
        return self.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Token Storage
struct SpotifyTokenStore: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresIn: TimeInterval
    var expirationDate: Date?

    var isExpired: Bool {
        guard let date = expirationDate else { return true }
        return date < Date()
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }

    static let fileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SpotifyMenubarApp", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        }
        return dir.appendingPathComponent("spotify_tokens.json")
    }()

    func save() {
        do {
            var tokenToSave = self
            tokenToSave.expirationDate = Date().addingTimeInterval(self.expiresIn)
            let data = try JSONEncoder().encode(tokenToSave)
            try data.write(to: Self.fileURL, options: .atomicWrite)
            NSLog("💾 Token saved to \(Self.fileURL.path)")
        } catch {
            NSLog("❌ Failed to save token: \(error.localizedDescription)")
        }
    }
    
    static func load() -> SpotifyTokenStore? {
        guard let data = try? Data(contentsOf: Self.fileURL) else {
            NSLog("ℹ️ No token file found at \(Self.fileURL.path)")
            return nil
        }
        do {
            var tokenStore = try JSONDecoder().decode(SpotifyTokenStore.self, from: data)
            if tokenStore.expirationDate == nil {
                 tokenStore.expirationDate = Date().addingTimeInterval(tokenStore.expiresIn)
            }
            NSLog("✅ Token loaded from \(Self.fileURL.path)")
            return tokenStore
        } catch {
            NSLog("❌ Failed to decode token from file: \(error.localizedDescription). Deleting corrupt file.")
            delete()
            return nil
        }
    }
    
    static func delete() {
        do {
            try FileManager.default.removeItem(at: fileURL)
            NSLog("🗑 Token file deleted from \(Self.fileURL.path)")
        } catch {
            NSLog("❌ Failed to delete token file: \(error.localizedDescription)")
        }
    }
}
