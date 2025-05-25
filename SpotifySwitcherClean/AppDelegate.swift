import Cocoa
import SpotifyWebAPI // Not directly used for API calls, but good for context
import CryptoKit

// MARK: - Data Models
struct PlaylistSummary {
    let id: String
    let name: String
}

struct CurrentlyPlayingTrack {
    let id: String
    let name: String
    let artist: String
    let artworkURL: String?
    let uri: String
}

// Changed to a Codable Struct to accept API data
struct SpotifyTrack: Codable, Equatable, Hashable {
    var title: String
    var isLiked: Bool
    var uri: String
    var artworkURL: String?

    // Equatable conformance
    static func == (lhs: SpotifyTrack, rhs: SpotifyTrack) -> Bool {
        return lhs.uri == rhs.uri
    }
    
    // Hashable conformance to allow use in a Set for de-duplication
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
                updateAllData() // Initial data fetch
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

        // Setup a single timer to update all data periodically
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
        
        transferMenuItem = NSMenuItem(title: "Transfer Playback...", action: #selector(promptForDeviceTransfer), keyEquivalent: "")
        menu.addItem(transferMenuItem!)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem.menu = menu
        
        updateHistoryMenu(excluding: nil)
    }
    
    func updateHistoryMenu(excluding currentTrackURI: String?) {
        if let existingItemIndex = statusItem.menu?.items.firstIndex(where: { $0.identifier?.rawValue == "historyMenuItem" }) {
            statusItem.menu?.removeItem(at: existingItemIndex)
             if let separatorIndex = statusItem.menu?.items.firstIndex(where: { $0.isSeparatorItem && $0.identifier?.rawValue == "historySeparator" }) {
                statusItem.menu?.removeItem(at: separatorIndex)
            }
        }

        let tracksToShow = recentTracks.filter { $0.uri != currentTrackURI }

        guard !tracksToShow.isEmpty else { return }

        let historyMenuItem = NSMenuItem()
        historyMenuItem.identifier = NSUserInterfaceItemIdentifier("historyMenuItem")
        historyMenuItem.title = "Recently Played..."

        let historyMenu = NSMenu()

        for track in tracksToShow {
            let item = NSMenuItem()
            item.representedObject = track

            let maxTitleLength = 30
            var displayTitle = track.title
            if displayTitle.count > maxTitleLength {
                let index = displayTitle.index(displayTitle.startIndex, offsetBy: maxTitleLength - 3)
                displayTitle = String(displayTitle[..<index]) + "..."
            }
            
            let attributed = NSMutableAttributedString(string: " " + displayTitle)
            if track.isLiked {
                attributed.append(NSAttributedString(string: " ⭐"))
            }
            item.attributedTitle = attributed
            item.toolTip = track.title
            item.target = self
            item.action = #selector(playTrackFromHistory(_:))
            
            if let artworkURL = track.artworkURL {
                loadAlbumArt(from: artworkURL) { image in
                    guard let image = image else { return }
                    
                    let attachment = NSTextAttachment()
                    attachment.image = image
                    attachment.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)
                    
                    let newAttributedTitle = NSMutableAttributedString()
                    newAttributedTitle.append(NSAttributedString(attachment: attachment))
                    newAttributedTitle.append(NSAttributedString(string: " " + displayTitle))
                     if track.isLiked {
                        newAttributedTitle.append(NSAttributedString(string: " ⭐"))
                    }
                    item.attributedTitle = newAttributedTitle
                }
            }
            
            historyMenu.addItem(item)
        }

        historyMenuItem.submenu = historyMenu
        
        let separator = NSMenuItem.separator()
        separator.identifier = NSUserInterfaceItemIdentifier("historySeparator")
        
        if let quitItemIndex = statusItem.menu?.items.firstIndex(where: { $0.action == #selector(quitApp) }) {
            statusItem.menu?.insertItem(separator, at: quitItemIndex)
            statusItem.menu?.insertItem(historyMenuItem, at: quitItemIndex + 1)
        } else {
            statusItem.menu?.addItem(separator)
            statusItem.menu?.addItem(historyMenuItem)
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
                break

            case .notPlaying(let message):
                self.statusItem.button?.title = "\(message)"
                self.statusItem.button?.image = nil
                self.likeMenuItem?.isHidden = true
                self.addToPlaylistMenuItem?.isHidden = true
                self.transferMenuItem?.isHidden = true
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
        // This function now triggers all data refreshes
        fetchCurrentTrackDetails()
        fetchRecentlyPlayed()
    }
    
    func fetchCurrentTrackDetails() {
        guard let token = tokenStore, !token.isExpired else {
            if tokenStore?.isExpired ?? false {
                refreshAccessToken()
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
                    self.updateUI(for: .notPlaying(message: "Nothing Playing"))
                    return
                }
                
                let artistNames = artistsArray.compactMap { $0["name"] as? String }.joined(separator: ", ")
                let albumData = item["album"] as? [String: Any]
                let imagesData = albumData?["images"] as? [[String: Any]]
                let artworkURL = imagesData?.first?["url"] as? String
                
                let track = CurrentlyPlayingTrack(id: id, name: name, artist: artistNames, artworkURL: artworkURL, uri: uri)
                
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

        var request = URLRequest(url: URL(string: "https://developer.spotify.com/documentation/web-api/reference/get-recently-played")!)
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                NSLog("❌ Error fetching recently played: \(error.localizedDescription)")
                return
            }
            guard let data = data else { return }

            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let items = json["items"] as? [[String: Any]] else {
                    NSLog("❌ Could not parse recently played JSON.")
                    return
                }

                var fetchedTracks: [SpotifyTrack] = []
                for item in items {
                    guard let trackData = item["track"] as? [String: Any],
                          let name = trackData["name"] as? String,
                          let uri = trackData["uri"] as? String else { continue }
                    
                    let albumData = trackData["album"] as? [String: Any]
                    let imagesData = albumData?["images"] as? [[String: Any]]
                    let artworkURL = imagesData?.first?["url"] as? String
                    
                    let track = SpotifyTrack(title: name, isLiked: false, uri: uri, artworkURL: artworkURL)
                    fetchedTracks.append(track)
                }

                self.recentTracks = Array(Array(Set(fetchedTracks)).prefix(50))
            } catch {
                NSLog("❌ Error decoding recently played: \(error.localizedDescription)")
            }
        }.resume()
    }


    // MARK: - Auth Logic
    @objc func authorizeSpotify() {
        let clientId = "c62a858a7ec0468194da1c197d3c4d3d"
        let redirectURI = "spotify-menubar-app://callback"
        let scope = "user-read-playback-state user-read-currently-playing user-library-read user-library-modify playlist-read-private playlist-read-collaborative playlist-modify-public playlist-modify-private user-modify-playback-state user-read-recently-played"

        self.codeVerifier = PKCE.generateCodeVerifier()
        guard let codeChallenge = PKCE.codeChallenge(for: self.codeVerifier!) else {
            return
        }

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: UUID().uuidString)
        ]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            return
        }
        exchangeCodeForToken(code: code)
    }

    func exchangeCodeForToken(code: String) {
        let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let clientId = "c62a858a7ec0468194da1c197d3c4d3d"
        let redirectURI = "spotify-menubar-app://callback"
        guard let verifier = self.codeVerifier else { return }

        let params = [
            "client_id": clientId, "grant_type": "authorization_code", "code": code,
            "redirect_uri": redirectURI, "code_verifier": verifier
        ]
        request.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }.joined(separator: "&").data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil else {
                self.updateUI(for: .error(message: "Auth Failed"))
                return
            }
            
            do {
                var tokenDataFromJSON = try JSONDecoder().decode(SpotifyTokenStore.self, from: data)
                tokenDataFromJSON.expirationDate = Date().addingTimeInterval(tokenDataFromJSON.expiresIn)
                tokenDataFromJSON.save()
                self.tokenStore = tokenDataFromJSON
                DispatchQueue.main.async {
                    self.authorizeMenuItem?.isHidden = true
                    self.updateAllData()
                }
            } catch {
                self.updateUI(for: .error(message: "Auth Failed"))
            }
        }.resume()
    }

    func refreshAccessToken() {
        guard let currentTokenStore = tokenStore, let refreshToken = currentTokenStore.refreshToken else {
            handleTokenRefreshFailure(isAuthError: true)
            return
        }
        
        let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        
        let clientId = "c62a858a7ec0468194da1c197d3c4d3d"
        let params = ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientId]
        request.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }.joined(separator: "&").data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil else {
                self.handleTokenRefreshFailure()
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 400 {
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
                DispatchQueue.main.async {
                    self.authorizeMenuItem?.isHidden = true
                    self.updateAllData()
                }
            } catch {
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
        } else {
            DispatchQueue.main.async {
                self.updateUI(for: .error(message: "Auth Refresh Failed"))
            }
        }
    }
    
    @objc func resetAuthorization() {
        SpotifyTokenStore.delete()
        SpotifyDeviceStore.delete()
        self.tokenStore = nil
        self.preferredDevice = nil
        self.recentTracks = []
        self.codeVerifier = nil
        DispatchQueue.main.async {
            self.authorizeMenuItem?.isHidden = false
            self.updateUI(for: .notPlaying(message: "Please click to authorize"))
            self.updateHistoryMenu(excluding: nil) // Clear the history menu
        }
        NSLog("🗑 Authorization and device reset by user.")
    }

    @objc func quitApp() { NSApp.terminate(nil) }

    // MARK: - Track Actions (Like, Playlist)
    func loadAlbumArt(from urlString: String, completion: @escaping (NSImage?) -> Void) {
        guard let url = URL(string: urlString) else { completion(nil); return }
        URLSession.shared.dataTask(with: url) { data, _, error in
            guard let data = data, let image = NSImage(data: data), error == nil else {
                completion(nil)
                return
            }
            let targetSize = NSSize(width: 16, height: 16)
            let resizedImage = NSImage(size: targetSize)
            resizedImage.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: targetSize), from: .zero, operation: .sourceOver, fraction: 1.0)
            resizedImage.unlockFocus()
            DispatchQueue.main.async {
                completion(resizedImage)
            }
        }.resume()
    }

    func checkIfTrackIsLiked(trackId: String, accessToken: String, completion: @escaping (Bool) -> Void) {
        let url = URL(string: "https://api.spotify.com/v1/me/tracks/contains?ids=\(trackId)")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data,
                  let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                  let result = try? JSONSerialization.jsonObject(with: data) as? [Bool],
                  let isLiked = result.first else {
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.updateAllData() }
            }.resume()
        }
    }
    
    func getCurrentPlaybackStateForAction() -> PlaybackState {
        return self.internalCurrentPlaybackState
    }

    // MARK: - Playlist Management
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu == self.playlistsSubmenu {
            menu.removeAllItems()
            let loadingItem = NSMenuItem(title: "Loading playlists...", action: nil, keyEquivalent: "")
            loadingItem.isEnabled = false
            menu.addItem(loadingItem)
            fetchUserPlaylists()
        }
    }

    func fetchUserPlaylists() {
        guard let token = tokenStore, !token.isExpired else { return }

        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/playlists?limit=50")!)
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil else { return }

            do {
                if let jsonResponse = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let items = jsonResponse["items"] as? [[String: Any]] {
                    let playlists: [PlaylistSummary] = items.compactMap { dict in
                        guard let id = dict["id"] as? String, let name = dict["name"] as? String else { return nil }
                        return PlaylistSummary(id: id, name: name)
                    }
                    self.updatePlaylistsSubmenu(with: .success(playlists))
                } else {
                    self.updatePlaylistsSubmenu(with: .failure(NSError(domain: "SpotifyApp", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not parse playlists."])))
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
        guard let playlistId = sender.representedObject as? String, let token = tokenStore, !token.isExpired else {
            return
        }
        
        guard case .playing(let track, _, _, _) = self.internalCurrentPlaybackState else {
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
        guard let token = tokenStore, !token.isExpired else { return }

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
                        self.transferPlaybackToSelectedDevice(deviceId: deviceId, deviceName: selectedItem.title, play: true) { success in
                            if success {
                                let deviceToSave = SpotifyDeviceStore(id: deviceId, name: selectedItem.title)
                                deviceToSave.save()
                                self.preferredDevice = deviceToSave
                            }
                        }
                    }
                }
            }
        }.resume()
    }

    func transferPlaybackToSelectedDevice(deviceId: String, deviceName: String, play: Bool, completion: ((Bool) -> Void)? = nil) {
        guard let token = tokenStore, !token.isExpired else {
            completion?(false)
            return
        }

        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player")!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["device_ids": [deviceId], "play": play]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 204 {
                    self.showSuccessAlert(title: "Playback Transferred", message: "Playback transferred to \(deviceName).")
                    self.updateAllData()
                    completion?(true)
                } else {
                    self.showErrorAlert(title: "Transfer Failed", message: "Could not transfer playback.")
                    completion?(false)
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
    static func generateCodeVerifier() -> String {
        var buffer = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
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
            let data = try JSONEncoder().encode(self)
            try data.write(to: Self.fileURL, options: .atomicWrite)
            NSLog("💾 Token saved to \(Self.fileURL.path)")
        } catch {
            NSLog("❌ Failed to save token: \(error.localizedDescription)")
        }
    }
    
    static func load() -> SpotifyTokenStore? {
        guard let data = try? Data(contentsOf: Self.fileURL) else {
            return nil
        }
        do {
            var tokenStore = try JSONDecoder().decode(SpotifyTokenStore.self, from: data)
            if tokenStore.expirationDate == nil {
                 tokenStore.expirationDate = Date().addingTimeInterval(tokenStore.expiresIn)
            }
            return tokenStore
        } catch {
            delete()
            return nil
        }
    }
    
    static func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
